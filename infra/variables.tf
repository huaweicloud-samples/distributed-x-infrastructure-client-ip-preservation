# ---------------------------------------------------------------------------
# 基础
# ---------------------------------------------------------------------------
variable "region" {
  description = "资源所在区域，例如 cn-north-4。"
  type        = string
}

variable "name_prefix" {
  description = "所有资源名称的统一前缀。"
  type        = string
  default     = "ppv2-demo"
}

variable "availability_zone" {
  description = <<-EOT
    显式指定部署可用区（例如 cn-north-4a）。留空则自动取区域内第一个可用区。
    单可用区足以跑通本演示。
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# 网络
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "VPC 的 CIDR。"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "公网子网 CIDR（ELB 自身接口 + NAT 网关所在子网）。"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "私网子网 CIDR（后端 ECS 所在子网）。"
  type        = string
  default     = "10.0.2.0/24"
}

variable "client_cidr" {
  description = <<-EOT
    允许访问负载均衡监听器的客户端网段（白名单）。
    客户端网段白名单。默认 0.0.0.0/0 表示允许全部；生产环境请收紧到你的出口 IP。
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "ssh_source_cidr" {
  description = "允许 SSH(22) 登录 ECS 的网段。默认 0.0.0.0/0，生产环境务必收紧。"
  type        = string
  default     = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# 后端软件
# ---------------------------------------------------------------------------
variable "web_server" {
  description = <<-EOT
    后端 Web 服务器类型：
      nginx   —— 用 nginx + PHP-FPM 承接两条入口（默认）
      haproxy —— 用 HAProxy + PHP-FPM 承接两条入口
    两种实现都演示同一件事：TLS 监听器走 Proxy Protocol v2 拿真实客户端 IP，
    TCP 监听器走源地址透传拿真实客户端 IP。
  EOT
  type        = string
  default     = "nginx"

  validation {
    condition     = contains(["nginx", "haproxy"], var.web_server)
    error_message = "web_server 只能是 nginx 或 haproxy。"
  }
}

variable "docroot" {
  description = "后端 Web 服务的文档根目录。"
  type        = string
  default     = "/var/www/ppv2"
}

variable "ppv2_backend_port" {
  description = "承接 TLS 监听器（已开启 Proxy Protocol）的后端端口。nginx/HAProxy 在此端口要求每个连接都带 PPv2 头。"
  type        = number
  default     = 8080
}

variable "plain_backend_port" {
  description = "承接 TCP 监听器（源地址透传）+ 健康检查 /healthz 的后端端口。"
  type        = number
  default     = 80
}

# ---------------------------------------------------------------------------
# 计算实例
# ---------------------------------------------------------------------------
variable "ecs_flavor_name" {
  description = <<-EOT
    ECS 规格码（即 data.huaweicloud_compute_flavors.flavors[].id，例如 s6.large.2，2 vCPU / 4 GB）。
    该值用于精确匹配规格，避免 data.huaweicloud_compute_flavors 返回多规格时下标碰运气。
  EOT
  type        = string
  default     = "s6.large.2"
}

variable "image_name_regex" {
  description = <<-EOT
    用于挑选镜像的正则表达式，配合 most_recent 取最新匹配项。
    必须用锚定正则精确匹配标准服务器镜像，例如 "^Ubuntu 22.04 server 64bit$"。
    切勿用松散的子串 "Ubuntu 22.04"：most_recent 会挑中带 GPU 显卡驱动的变体
    （名如 "...with Graphic driver 580.x"），该镜像要求 GPU 规格，与普通 s6 规格
    组合会触发 Ecs.0005「flavor does not match the image」。
  EOT
  type        = string
  default     = "^Ubuntu 22.04 server 64bit$"
}

variable "key_pair" {
  description = "登录 ECS 的密钥对名称。留空则不绑定密钥对（仍能通过 user_data 自动初始化，但无法 SSH 登录排查）。"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# 负载均衡
# ---------------------------------------------------------------------------
variable "elb_flavor_type" {
  description = "四层规格类型。L4_elastic_max 为弹性规格。"
  type        = string
  default     = "L4_elastic_max"
}

variable "elb_flavor_name" {
  description = <<-EOT
    四层规格名称，必须精确指定。
    绝不使用 data.huaweicloud_elb_flavors.*.ids[N] 让系统随机挑选：
    该数据源按 flavor UUID 字典序返回，顺序与规格大小和价格无关。
  EOT
  type        = string
  default     = "L4_flavor.elb.pro.max"
}

variable "nat_spec" {
  description = "NAT 网关规格，1=小型。规格直接决定单价。"
  type        = string
  default     = "1"
}

# ---------------------------------------------------------------------------
# 健康检查
# ---------------------------------------------------------------------------
variable "health_check_interval" {
  description = "健康检查间隔（秒）。"
  type        = number
  default     = 5
}

variable "health_check_timeout" {
  description = "健康检查超时（秒）。"
  type        = number
  default     = 3
}

variable "health_check_max_retries" {
  description = "判定后端健康所需的连续成功次数。"
  type        = number
  default     = 3
}
