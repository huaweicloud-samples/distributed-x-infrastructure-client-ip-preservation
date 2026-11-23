# 架构说明

> 本套件在华为云上演示：当业务流量经过**独享型负载均衡（ELB）** 后，后端服务器如何拿到**客户端的真实 IP 地址与端口**。
> 核心机制是 **Proxy Protocol v2（PPv2）** 与 **TCP 源地址透传**，并通过同一个展示页面并排对比两种机制的来源差异。

---

## 1. 要解决什么问题

在负载均衡之后，后端 `REMOTE_ADDR` 通常只剩下负载均衡的 IP，真正的客户端地址被掩盖。保留客户端真实 IP 是日志审计、限流、风控、合规的常见前置要求。

本文档介绍两种在华为云独享型 ELB 上「保留客户端真实 IP」的路径，并给出可一键拉起的参考实现：

| 入口 | 监听器协议 | 后端拿到真实 IP 的机制 |
|------|-----------|------------------------|
| 入口 A | **TLS :443，开启 Proxy Protocol** | ELB 在业务数据前插入 Proxy Protocol 头，后端解析头中的客户端 IP/端口 |
| 入口 B | **TCP :80，源地址透传** | 独享型 ELB 默认将客户端真实 IP 作为 TCP 连接源地址直送后端，无需任何额外协议 |

两条入口指向同一台后端服务器上的不同端口，由 `index.php` 在同一页面中并排呈现，便于直观确认真实 IP 究竟从哪来。

---

## 2. 架构总览

```
Internet
│
▼
┌───────────────────┐
│ 独享型 ELB（公网） │ EIP（公网）
│ (Elastic Load │
│ Balance, 独享型) │
└───────────────────┘
│ │
入口 A │ │ 入口 B
TLS :443 + PPv2 │ │ TCP :80（源地址透传）
▼ ▼
┌──────────────────────────┐
│ 后端 ECS（私网子网） │
│ ┌──────────────────────┐ │
│ │ :8080 listen … │ │ 要求每个连接带 PPv2 头
│ │ proxy_protocol │ │
│ ├──────────────────────┤ │
│ │ :80 普通 HTTP │ │ 含 /healthz 健康检查
│ │ + TCP 源透传 │ │
│ └──────────────────────┘ │
│ Web 服务（nginx 或 │
│ HAProxy）+ PHP-FPM │
│ → index.php 展示连接信息 │
└──────────────────────────┘

ELB 接口在「公网子网」；后端 ECS 在「私网子网」（无公网 EIP）。
私网子网默认路由指向 NAT 网关 → 公网 EIP，供 ECS 出网装软件。
```

> 说明：架构图用 ASCII 表达；若需要 mermaid 版本可参考 `docs/` 其余文档或自行补充。

---

## 3. 核心组件

| 层级 | 华为云服务 / 资源 | 作用 |
|------|------------------|------|
| 网络 | 虚拟私有云 `huaweicloud_vpc` | 隔离的网络边界，CIDR `10.0.0.0/16` |
| 网络 | 公网子网 / 私网子网 `huaweicloud_vpc_subnet` | 公网子网放 ELB 接口 + NAT；私网子网放后端 ECS |
| 网络 | 路由表 + NAT 网关 + EIP | 私网 ECS 经 NAT 出公网（apt 安装软件）；ELB 绑定独立 EIP 对外 |
| 计算 | 弹性云服务器 `huaweicloud_compute_instance` | 运行 nginx/HAProxy + PHP-FPM，托管 `index.php` |
| 负载均衡 | 独享型 ELB `huaweicloud_elb_loadbalancer` | 公网接入，双监听器 |
| 负载均衡 | TLS 监听器 + `proxy_protocol_enable` | 入口 A：插入 PPv2 头 |
| 负载均衡 | TCP 监听器（源地址透传） | 入口 B：直送客户端真实 IP |
| 负载均衡 | 后端服务器组 `huaweicloud_elb_pool` ×2 | ppv2 组 → :8080；plain 组 → :80 |
| 负载均衡 | 健康检查 `huaweicloud_elb_monitor` ×2 | HTTP `:80/healthz` |
| 证书 | 自签证书 `huaweicloud_elb_certificate` + `tls` provider | 供 TLS 监听器终止 TLS |
| 安全 | 后端安全组 `huaweicloud_networking_secgroup` | 仅放行 ELB 后端子网 CIDR 与客户端白名单 |
| 白名单 | 客户端 IP 地址组 `huaweicloud_elb_ipgroup` | ELB 监听器级客户端网段白名单 |

---

## 4. 双入口设计要点

### 4.1 入口 A：TLS 监听器 + Proxy Protocol v2

- ELB TLS 监听器（`protocol = "TLS"`, `protocol_port = 443`）开启 `proxy_protocol_enable = true`。
- 建立连接时，ELB 在业务数据前插入 Proxy Protocol v2 二进制头。
- 后端在 `:8080` 上必须使用 `listen ... proxy_protocol`（nginx）或 `bind ... accept-proxy`（HAProxy），否则连接会被拒绝/断开。
- 后端从 PPv2 头解析出客户端 IP + 端口，经 `fastcgi_param` / fcgi-app `set-param` 传入 PHP，显示为「Proxy Protocol 头」来源。

### 4.2 入口 B：TCP 监听器 + 源地址透传

- ELB TCP 监听器（`protocol = "TCP"`, `protocol_port = 80`）默认透传客户端真实 IP。
- 独享型 ELB 的 TCP 监听器默认即透传（`transparent_client_ip_enable` 默认 `true`，且不可关闭）。
- 后端在 `:80` 上以普通 HTTP 承接，直接从 TCP 连接源地址（`REMOTE_ADDR`）拿到客户端公网 IP。
- 这种设计让两个入口形成对照：一个靠「协议头」拿 IP，一个靠「连接源地址」拿 IP。

### 4.3 为什么后端安全组对 :80 要额外放行客户端网段

入口 B 是源地址透传，ELB 与后端通信时**以客户端真实公网 IP 作为源地址**（而非 ELB 自身 IP）。因此后端安全组对 `:80` 必须同时放行：

- ELB 后端子网 CIDR —— 覆盖健康检查探针（来自 ELB 自身 IP）；
- `client_cidr`（客户端网段）—— 覆盖真实客户端流量（源地址是客户端公网 IP）。

入口 A 的 `:8080` 只可能来自 ELB 后端 IP，故仅放行 ELB 后端子网 CIDR。

---

## 5. 网络与子网设计

- ELB 自身接口落在**公网子网**（`ipv4_subnet_id = public_subnet.ipv4_subnet_id`），并绑定 EIP 对外暴露。
- 后端 ECS 落在**私网子网**（仅私网 IP，无公网 EIP），通过 `backend_subnets = [private_subnet_id]` 让 ELB 的后端子网指向私网子网。
- 私网子网的默认路由（路由表）指向 NAT 网关，使 ECS 能出公网完成 `apt` 安装等操作，而无需为 ECS 分配公网 IP（缩小暴露面）。
- 单可用区足以跑通演示，单 AZ 不削弱本演示要表达的后端语义。

---

## 6. 证书处理

TLS 监听器**必须**绑定服务器证书。为避免引入任何外部凭据，本套件用 `tls` provider 在本地（Terraform 执行机）生成 RSA 2048 自签证书，并写入 `huaweicloud_elb_certificate`：

- 私钥与证书仅在 apply 时由 provider 生成并下发到 ELB，不落盘到代码仓库；
- 浏览器访问 `https://<ELB_EIP>:443` 会因自签证书告警，属演示预期；
- 生产环境请将 `huaweicloud_elb_certificate` 替换为正式签发的证书（可改用 `huaweicloud_elb_certificate` 导入或对接证书管理服务）。

---

## 7. 健康检查

- 两个后端服务器组的健康检查都指向 `port = 80`, `url_path = /healthz`（HTTP）。
- **关键约束**：PPv2 端口（`:8080`）要求每个连接都携带 Proxy Protocol 头，而健康检查连接不带该头，因此健康检查**绝不能**探测 `:8080`，统一打到 `:80/healthz`。
- 后端 `:80` 的 `/healthz` 直接返回 `200 ok`，不进入 PHP，避免被 PPv2 规则干扰。

---

## 8. 客户端白名单

- 通过 `huaweicloud_elb_ipgroup` 定义允许访问监听器的客户端网段（`client_cidr`，默认 `0.0.0.0/0`）。
- 两个监听器都启用 `ip_group_enable = "true"` + `access_policy = "white"`，仅放白名单内客户端。
- 生产环境应将 `client_cidr` 与 `ssh_source_cidr` 收紧到实际出口 IP。

---

## 9. 后端软件可切换

通过变量 `web_server` 在两种后端实现间切换，二者演示完全相同的两入口语义：

- `nginx`（默认）：nginx + PHP-FPM，`listen 8080 proxy_protocol` + `listen 80`；
- `haproxy`：HAProxy + PHP-FPM，`bind :8080 accept-proxy` + `bind :80` + `monitor-uri /healthz`。

二者都由 `user_data`（cloud-init）在 ECS 首次启动时自动安装并落盘配置，无需人工登录初始化。

---

## 10. 参考实现文件

| 路径 | 内容 |
|------|------|
| `infra/main.tf` | 全部网络 / 计算 / ELB / 证书 / 白名单资源 |
| `infra/variables.tf` | 可配置变量（区域、规格、端口、白名单等） |
| `infra/outputs.tf` | ELB 公网 IP 与两个演示 URL |
| `infra/versions.tf` | provider 版本锁定（huaweicloud 1.96.0 / tls 4.3.0 / random 3.9.0） |
| `src/webserver/nginx.conf.tftpl` | nginx 双入口配置模板 |
| `src/webserver/haproxy.cfg.tftpl` | HAProxy 双入口配置模板 |
| `src/webserver/index.php` | 客户端连接信息展示页 |
| `src/webserver/php-fpm-www.conf` | PHP-FPM 池配置 |
| `infra/templates/user_data_*.sh.tftpl` | 两套后端的 cloud-init 初始化脚本 |
