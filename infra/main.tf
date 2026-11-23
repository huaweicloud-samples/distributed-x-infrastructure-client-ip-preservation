# ===========================================================================
# 用 Proxy Protocol v2 + 独享型负载均衡器保留客户端真实 IP
#
# 两条入口，对比两种「拿到客户端真实 IP」的机制：
#
#   入口 A —— ELB TLS 监听器（已开启 Proxy Protocol）
#     ELB 在业务数据前插入 Proxy Protocol 头，后端解析后得到客户端 IP + 端口。
#     华为云 TCP 监听器上的 ProxyProtocol 仍在陆续上线，不保证生效；
#     TLS 监听器官方明确支持 ProxyProtocol，因此走 TLS 路线。
#
#   入口 B —— ELB TCP 监听器（源地址透传，不带 Proxy Protocol）
#     独享型负载均衡的 TCP 监听器默认与后端直接使用客户端真实 IP 通信，
#     不需要任何额外协议，客户端地址直接体现在 TCP 连接的源地址上，
#     该行为不可关闭。
#
# 两种机制在后端 index.php 中并排展示，便于直观确认真实 IP 从哪来。
# ===========================================================================

locals {
  name_prefix = var.name_prefix
  suffix      = random_id.suffix.hex

  # 可用区：单可用区足以跑通演示。
  az = var.availability_zone != "" ? var.availability_zone : data.huaweicloud_availability_zones.this.names[0]

  vpc_id             = huaweicloud_vpc.this.id
  public_subnet_id   = huaweicloud_vpc_subnet.public.id
  public_subnet_cidr = huaweicloud_vpc_subnet.public.cidr
  private_subnet_id  = huaweicloud_vpc_subnet.private.id
  # ELB 后端子网的 CIDR，也是 ELB 访问后端时使用的源地址范围。
  # nginx 的 set_real_ip_from / 安全组放行都基于它。
  elb_backend_cidr = huaweicloud_vpc_subnet.private.cidr

  ecs_flavor_id = [
    for f in data.huaweicloud_compute_flavors.ecs.flavors : f.id
    if f.id == var.ecs_flavor_name
  ][0]
  ecs_image_id = data.huaweicloud_images_image.ecs.id

  docroot = var.docroot

  # 监听器端口（对外，固定）。
  tls_listener_port = 443
  tcp_listener_port = 80
  # 后端端口（承接对应监听器）。
  ppv2_backend_port  = var.ppv2_backend_port
  plain_backend_port = var.plain_backend_port

  # -------------------------------------------------------------------------
  # user_data 渲染：先渲染 Web 服务配置模板，再整体注入到 cloud-init 脚本模板。
  # 顺序：nginx.conf.tftpl / haproxy.cfg.tftpl -> user_data_*.sh.tftpl。
  # -------------------------------------------------------------------------
  index_php     = file("${path.module}/../src/webserver/index.php")
  php_pool_conf = file("${path.module}/../src/webserver/php-fpm-www.conf")

  web_config = var.web_server == "nginx" ? templatefile("${path.module}/../src/webserver/nginx.conf.tftpl", {
    ppv2_backend_port  = local.ppv2_backend_port
    plain_backend_port = local.plain_backend_port
    elb_backend_cidr   = local.elb_backend_cidr
    docroot            = local.docroot
    tls_listener_port  = local.tls_listener_port
    tcp_listener_port  = local.tcp_listener_port
    }) : templatefile("${path.module}/../src/webserver/haproxy.cfg.tftpl", {
    ppv2_backend_port  = local.ppv2_backend_port
    plain_backend_port = local.plain_backend_port
    docroot            = local.docroot
    tls_listener_port  = local.tls_listener_port
    tcp_listener_port  = local.tcp_listener_port
  })

  user_data = var.web_server == "nginx" ? templatefile("${path.module}/templates/user_data_nginx.sh.tftpl", {
    docroot            = local.docroot
    ppv2_backend_port  = local.ppv2_backend_port
    plain_backend_port = local.plain_backend_port
    nginx_conf         = local.web_config
    index_php          = local.index_php
    php_pool_conf      = local.php_pool_conf
    }) : templatefile("${path.module}/templates/user_data_haproxy.sh.tftpl", {
    docroot            = local.docroot
    ppv2_backend_port  = local.ppv2_backend_port
    plain_backend_port = local.plain_backend_port
    haproxy_cfg        = local.web_config
    index_php          = local.index_php
    php_pool_conf      = local.php_pool_conf
  })
}

# 把会在 apply 中途才暴露的配置错误提前到 plan 阶段。
resource "terraform_data" "input_validation" {
  lifecycle {
    precondition {
      condition     = length(data.huaweicloud_elb_flavors.l4.ids) == 1
      error_message = <<-EOT
        elb_flavor_type = "${var.elb_flavor_type}" 与 elb_flavor_name = "${var.elb_flavor_name}"
        在本区域命中的规格数不等于 1。规格目录随区域略有差异，请先实查再指定：
          terraform console
          > data.huaweicloud_elb_flavors.l4
      EOT
    }

    precondition {
      condition = length([
        for f in data.huaweicloud_compute_flavors.ecs.flavors : f.id
        if f.id == var.ecs_flavor_name
      ]) == 1
      error_message = <<-EOT
        在可用区 ${local.az} 未精确命中 ECS 规格 "${var.ecs_flavor_name}"。
        请确认该可用区是否提供此规格，或用 terraform console 查询可用规格名：
          > data.huaweicloud_compute_flavors.ecs.flavors
      EOT
    }
  }
}

data "huaweicloud_availability_zones" "this" {
  state = "available"
}

data "huaweicloud_compute_flavors" "ecs" {
  availability_zone = local.az
  performance_type  = "normal"
}

data "huaweicloud_images_image" "ecs" {
  name_regex    = var.image_name_regex
  most_recent   = true
  architecture  = "x86"
}

# 规格必须按名称精确取。绝不写 data.huaweicloud_elb_flavors.l4.ids[N]：
# 该数据源按 flavor UUID 字典序返回，下标与规格大小、与价格都没有关系，
# 随机命中一个大规格会导致规格不符合预期。
data "huaweicloud_elb_flavors" "l4" {
  type = var.elb_flavor_type
  name = var.elb_flavor_name
}

# ---------------------------------------------------------------------------
# 网络：VPC / 公网子网（ELB 接口 + NAT）/ 私网子网（后端 ECS）
# ---------------------------------------------------------------------------
resource "huaweicloud_vpc" "this" {
  name = "${local.name_prefix}-vpc-${local.suffix}"
  cidr = var.vpc_cidr
}

resource "huaweicloud_vpc_subnet" "public" {
  name       = "${local.name_prefix}-public-${local.suffix}"
  vpc_id     = local.vpc_id
  cidr       = var.public_subnet_cidr
  gateway_ip = cidrhost(var.public_subnet_cidr, 1)
}

resource "huaweicloud_vpc_subnet" "private" {
  name       = "${local.name_prefix}-private-${local.suffix}"
  vpc_id     = local.vpc_id
  cidr       = var.private_subnet_cidr
  gateway_ip = cidrhost(var.private_subnet_cidr, 1)
}

# 私网子网的默认路由指向 NAT 网关，使 ECS 能出公网（apt 安装软件、拉取包）。
#
# 关键约束（踩坑）：本账号 VPC 路由表配额为 1 —— VPC 创建时自带的「默认路由表」
# 已经占用了这唯一的名额，再用 huaweicloud_vpc_route_table 建第二个会报
#   NeutronError RouteTableOverLimit: Route table number of VPC ... exceeds limit: 1
# 因此不能再建自定义路由表，而是用 huaweicloud_vpc_route 往「已存在的默认路由表」
# 追一条 0.0.0.0/0 → NAT 网关 的路由。这样既不触发配额，又能保证全新部署时
# 私网子网也有出网路由（默认路由表只带 local 路由，不带 NAT 路由）。
data "huaweicloud_vpc_route_table" "default" {
  vpc_id = local.vpc_id
}

resource "huaweicloud_vpc_route" "private_nat" {
  vpc_id          = local.vpc_id
  route_table_id = data.huaweicloud_vpc_route_table.default.id
  destination     = "0.0.0.0/0"
  type            = "nat"
  nexthop         = huaweicloud_nat_gateway.this.id
}

# ---------------------------------------------------------------------------
# 出公网：NAT 网关 + EIP（供私网 ECS 出网）
# ---------------------------------------------------------------------------
resource "huaweicloud_vpc_eip" "nat" {
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name        = "${local.name_prefix}-nat-bw-${local.suffix}"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }
}

resource "huaweicloud_nat_gateway" "this" {
  name      = "${local.name_prefix}-nat-${local.suffix}"
  spec      = var.nat_spec
  vpc_id    = local.vpc_id
  subnet_id = local.public_subnet_id
}

resource "huaweicloud_nat_snat_rule" "this" {
  nat_gateway_id = huaweicloud_nat_gateway.this.id
  floating_ip_id = huaweicloud_vpc_eip.nat.id
  subnet_id      = local.private_subnet_id
}

# ---------------------------------------------------------------------------
# 后端安全组
#
# 关键差异点：
#   - 入口 A（PPv2，后端 :8080）：ELB 用自身后端子网 IP 访问后端，
#     因此放行 ELB 后端子网 CIDR 的 8080。
#   - 入口 B（TCP 源地址透传，后端 :80）：独享型 ELB 的 TCP 监听器默认与后端
#     直接使用客户端真实 IP 通信，所以真实客户端流量打到后端的源地址是「客户端公网 IP」，
#     因此 :80 还需放行 client_cidr。健康检查探针仍来自 ELB 后端子网，
#     所以 :80 也要放行 ELB 后端子网 CIDR。
# ---------------------------------------------------------------------------
resource "huaweicloud_networking_secgroup" "ecs" {
  name = "${local.name_prefix}-ecs-sg-${local.suffix}"
}

resource "huaweicloud_networking_secgroup_rule" "ecs_ssh" {
  security_group_id = huaweicloud_networking_secgroup.ecs.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.ssh_source_cidr
}

resource "huaweicloud_networking_secgroup_rule" "ecs_ppv2" {
  security_group_id = huaweicloud_networking_secgroup.ecs.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = local.ppv2_backend_port
  port_range_max    = local.ppv2_backend_port
  remote_ip_prefix  = local.elb_backend_cidr

  depends_on = [huaweicloud_networking_secgroup_rule.ecs_ssh]
}

resource "huaweicloud_networking_secgroup_rule" "ecs_health" {
  security_group_id = huaweicloud_networking_secgroup.ecs.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = local.plain_backend_port
  port_range_max    = local.plain_backend_port
  remote_ip_prefix  = local.elb_backend_cidr

  depends_on = [huaweicloud_networking_secgroup_rule.ecs_ppv2]
}

resource "huaweicloud_networking_secgroup_rule" "ecs_plain" {
  security_group_id = huaweicloud_networking_secgroup.ecs.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = local.plain_backend_port
  port_range_max    = local.plain_backend_port
  remote_ip_prefix  = var.client_cidr

  depends_on = [huaweicloud_networking_secgroup_rule.ecs_health]
}

# 说明：华为云安全组在创建时会由系统自动附加一条「允许所有出方向（egress allow-all）」
# 的默认规则。因此无需、也不应再显式创建一条完全相同的 allow-all egress 规则 ——
# 那样会触发 ELB/API 的「规则重复 → conflict」错误。
# 后端的 apt 安装、出公网等需求正是由这条系统默认 egress 规则满足的。

# ---------------------------------------------------------------------------
# 计算实例（后端）
# ---------------------------------------------------------------------------
resource "huaweicloud_compute_instance" "this" {
  name               = "${local.name_prefix}-ecs-${local.suffix}"
  flavor_id          = local.ecs_flavor_id
  image_id           = local.ecs_image_id
  availability_zone  = local.az
  security_group_ids = [huaweicloud_networking_secgroup.ecs.id]
  user_data          = local.user_data
  key_pair           = var.key_pair != "" ? var.key_pair : null

  network {
    uuid = local.private_subnet_id
  }
}

# ---------------------------------------------------------------------------
# 负载均衡（独享型网络型负载均衡）
#
# 独享型 + 公网（绑定 EIP）。ELB 自身接口在公网子网，后端子网指向私网子网。
# ---------------------------------------------------------------------------
resource "huaweicloud_vpc_eip" "elb" {
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name        = "${local.name_prefix}-elb-bw-${local.suffix}"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }
}

resource "huaweicloud_elb_loadbalancer" "this" {
  name              = "${local.name_prefix}-elb-${local.suffix}"
  vpc_id            = local.vpc_id
  ipv4_subnet_id    = huaweicloud_vpc_subnet.public.ipv4_subnet_id
  backend_subnets   = [local.private_subnet_id]
  availability_zone = [local.az]
  # 按 flavor 名称精确过滤，确保候选集唯一
  l4_flavor_id = data.huaweicloud_elb_flavors.l4.ids[0]
  ipv4_eip_id  = huaweicloud_vpc_eip.elb.id

  lifecycle {
    # 兜住上面那个下标：名称过滤必须刚好命中一个规格，否则 ids[0] 又变成"碰运气"，
    # 而规格直接决定单价。
    precondition {
      condition     = length(data.huaweicloud_elb_flavors.l4.ids) == 1
      error_message = <<-EOT
        elb_flavor_type = "${var.elb_flavor_type}" 与 elb_flavor_name = "${var.elb_flavor_name}"
        在本区域命中的规格数不等于 1。请先实查：terraform console -> data.huaweicloud_elb_flavors.l4
      EOT
    }
  }
}

# 自签证书：用于 TLS 监听器终止 TLS。由 tls provider 在本地生成，不落地任何外部凭据。
resource "tls_private_key" "demo" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "demo" {
  private_key_pem = tls_private_key.demo.private_key_pem

  subject {
    common_name  = "ppv2-demo.local"
    organization = "PPv2 Demo"
  }

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = ["ppv2-demo.local"]
}

resource "huaweicloud_elb_certificate" "demo" {
  name        = "${local.name_prefix}-cert-${local.suffix}"
  certificate = tls_self_signed_cert.demo.cert_pem
  private_key = tls_private_key.demo.private_key_pem
}

# 客户端白名单（ELB 安全组对 ClientCIDR 的放行）。
# 当 client_cidr 为 0.0.0.0/0（允许全部）时，ELB 的 IP 地址组不接受该值，
# 故不创建 IP 组、监听器改为不启用白名单（等同允许全部）。
resource "huaweicloud_elb_ipgroup" "clients" {
  count = var.client_cidr != "0.0.0.0/0" ? 1 : 0
  name  = "${local.name_prefix}-clients-${local.suffix}"
  ip_list {
    ip = var.client_cidr
  }
}

# ---------------------------------------------------------------------------
# 后端服务器组 + 健康检查 + 成员
#
# 两个组都指向同一台 ECS，但端口不同：
#   ppv2 组 -> 后端 :8080（要求 PPv2 头）
#   plain 组 -> 后端 :80（普通 HTTP + /healthz 健康检查）
#
# 健康检查统一打到 :80/healthz：:8080 端口要求每个连接都带 PPv2 头，
# 而健康检查连接不带该头，因此绝不能让健康检查去探 :8080。
# ---------------------------------------------------------------------------
resource "huaweicloud_elb_pool" "ppv2" {
  name       = "${local.name_prefix}-pool-ppv2-${local.suffix}"
  protocol   = "TCP"
  lb_method  = "ROUND_ROBIN"
  type       = "instance"
  ip_version = "v4"
  vpc_id     = local.vpc_id
}

resource "huaweicloud_elb_pool" "plain" {
  name       = "${local.name_prefix}-pool-plain-${local.suffix}"
  protocol   = "TCP"
  lb_method  = "ROUND_ROBIN"
  type       = "instance"
  ip_version = "v4"
  vpc_id     = local.vpc_id
}

resource "huaweicloud_elb_monitor" "ppv2" {
  pool_id     = huaweicloud_elb_pool.ppv2.id
  name        = "${local.name_prefix}-hc-ppv2-${local.suffix}"
  protocol    = "HTTP"
  port        = local.plain_backend_port
  url_path    = "/healthz"
  interval    = var.health_check_interval
  timeout     = var.health_check_timeout
  max_retries = var.health_check_max_retries
}

resource "huaweicloud_elb_monitor" "plain" {
  pool_id     = huaweicloud_elb_pool.plain.id
  name        = "${local.name_prefix}-hc-plain-${local.suffix}"
  protocol    = "HTTP"
  port        = local.plain_backend_port
  url_path    = "/healthz"
  interval    = var.health_check_interval
  timeout     = var.health_check_timeout
  max_retries = var.health_check_max_retries
}

resource "huaweicloud_elb_member" "ppv2" {
  pool_id       = huaweicloud_elb_pool.ppv2.id
  address       = huaweicloud_compute_instance.this.network[0].fixed_ip_v4
  protocol_port = local.ppv2_backend_port
  subnet_id     = huaweicloud_vpc_subnet.private.ipv4_subnet_id
}

resource "huaweicloud_elb_member" "plain" {
  pool_id       = huaweicloud_elb_pool.plain.id
  address       = huaweicloud_compute_instance.this.network[0].fixed_ip_v4
  protocol_port = local.plain_backend_port
  subnet_id     = huaweicloud_vpc_subnet.private.ipv4_subnet_id
}

# ---------------------------------------------------------------------------
# 监听器
# ---------------------------------------------------------------------------

# 入口 A：TLS 监听器 + Proxy Protocol。
# proxy_protocol_enable 仅在 TLS 监听器生效，且 TLS 监听器不支持「获取客户端 IP」，
# 因此 PPv2 是拿到真实客户端 IP 的唯一手段。
resource "huaweicloud_elb_listener" "tls" {
  name                  = "${local.name_prefix}-tls-${local.suffix}"
  protocol              = "TLS"
  protocol_port         = local.tls_listener_port
  loadbalancer_id       = huaweicloud_elb_loadbalancer.this.id
  default_pool_id       = huaweicloud_elb_pool.ppv2.id
  server_certificate    = huaweicloud_elb_certificate.demo.id
  proxy_protocol_enable = true

  ip_group        = length(huaweicloud_elb_ipgroup.clients) > 0 ? huaweicloud_elb_ipgroup.clients[0].id : null
  ip_group_enable = length(huaweicloud_elb_ipgroup.clients) > 0 ? "true" : null
  access_policy   = length(huaweicloud_elb_ipgroup.clients) > 0 ? "white" : null
}

# 入口 B：TCP 监听器 + 源地址透传。
# 独享型 ELB 的 TCP 监听器默认透传客户端真实 IP（transparent_client_ip_enable 默认 true），
# 后端直接从 TCP 连接源地址拿到客户端公网 IP，无需任何额外协议。
resource "huaweicloud_elb_listener" "tcp" {
  name            = "${local.name_prefix}-tcp-${local.suffix}"
  protocol        = "TCP"
  protocol_port   = local.tcp_listener_port
  loadbalancer_id = huaweicloud_elb_loadbalancer.this.id
  default_pool_id = huaweicloud_elb_pool.plain.id

  ip_group        = length(huaweicloud_elb_ipgroup.clients) > 0 ? huaweicloud_elb_ipgroup.clients[0].id : null
  ip_group_enable = length(huaweicloud_elb_ipgroup.clients) > 0 ? "true" : null
  access_policy   = length(huaweicloud_elb_ipgroup.clients) > 0 ? "white" : null
}
