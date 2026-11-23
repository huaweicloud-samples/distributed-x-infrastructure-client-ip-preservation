# distributed-x-infrastructure-client-ip-preservation · 用 Proxy Protocol v2 + 独享型负载均衡保留客户端真实 IP

<img src="https://img.shields.io/badge/License-MIT--0-blue.svg" alt="License">
![License](https://img.shields.io/badge/license-MIT-green)
![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-ELB-blue)
![Build](https://img.shields.io/badge/terraform%20validate-passing-brightgreen)
---

## 1. 简介 / Overview

### 简介


在负载均衡之后，后端通常只能看到负载均衡的 IP，真正的客户端地址被掩盖。本套件给出一套**可直接拉起的华为云参考实现**，演示当流量经过**独享型负载均衡（ELB）** 后，后端如何拿到**客户端的真实 IP 地址与端口**。

核心做法是 **Proxy Protocol v2（PPv2）**，并额外提供 **TCP 源地址透传** 作为对照入口，二者在同一页面并排展示，便于直观确认真实 IP 的来源差异。

适用人群：需要在华为云上做客户端 IP 透传、日志审计、限流或风控前置的架构师与开发者。

---

## 2. 目录

- [1. 简介 / Overview](#1-简介--overview)
- [2. 目录](#2-目录)
- [3. 架构图](#3-架构图)
- [4. 方案亮点](#4-方案亮点)
- [5. 涉及云服务](#5-涉及云服务)
- [6. 前置条件](#6-前置条件)
- [7. 快速开始](#7-快速开始)
- [8. 分步部署](#8-分步部署)
- [9. 使用方法 / 验证](#9-使用方法--验证)
- [10. 清理资源](#10-清理资源)
- [11. 详细说明](#11-详细说明)
- [12. 依赖](#12-依赖)
- [13. FAQ / 故障排除](#13-faq--故障排除)
- [14. 贡献指南](#14-贡献指南)
- [15. 许可证](#15-许可证)
- [16. 联系方式 / 维护者](#16-联系方式--维护者)

---

## 3. 架构图

```
Internet
│
▼
┌──────────────────┐
│ 独享型 ELB(公网) │ EIP
└──────────────────┘
│ │
入口 A │ │ 入口 B
TLS :443 + PPv2 │ │ TCP :80（源地址透传）
▼ ▼
┌──────────────────────────┐
│ 后端 ECS（私网子网） │
│ :8080 proxy_protocol │ 要求每个连接带 PPv2 头
│ :80 普通 HTTP+/healthz │ TCP 源地址即客户端真实 IP
│ Web(nginx/HAProxy)+PHP-FPM│
│ → index.php 展示连接信息 │
└──────────────────────────┘
```

| 入口 | 监听器 | 后端端口 | 拿到真实 IP 的机制 |
|------|--------|----------|--------------------|
| A | TLS :443，开启 Proxy Protocol | :8080 | 解析 PPv2 头 → 客户端 IP/端口 |
| B | TCP :80，源地址透传 | :80 | TCP 连接源地址即客户端真实 IP |

详见 [docs/architecture.md](docs/architecture.md)。

---

## 4. 方案亮点

- **两条入口对照**：TLS 监听器 + PPv2 拿真实 IP（需协议头） vs TCP 监听器源地址透传拿真实 IP（无需协议头），一眼看清两种机制差异。
- **一键拉起**：`terraform apply` 即生成完整网络 / 计算 / ELB / 证书 / 白名单，后端由 `user_data` 自动初始化，无需人工登机配置。
- **后端可切换**：通过变量 `web_server` 在 `nginx` 与 `haproxy` 两种实现间切换，演示相同语义。
- **最小暴露面**：ECS 仅私网 IP，经 NAT 出网；ELB 绑定 EIP 对外；监听器级客户端白名单。
- **零外部凭据**：TLS 证书由 `tls` provider 本地自签，凭据仅经环境变量提供，不落盘。

---

## 5. 涉及云服务

本实践使用以下华为云服务：

| 服务 | 用途 |
|---|---|
| 独享型 ELB（弹性负载均衡） | 公网入口 + TLS/TCP 监听器 + PPv2 |
| ECS（弹性云服务器） | 后端 nginx/HAProxy + PHP-FPM |
| VPC | 私网/公网子网隔离 |
| NAT 网关 + EIP | 私网 ECS 出公网（apt 安装等） |
| TLS 证书 | `tls` provider 本地自签，经 `huaweicloud_elb_certificate` 托管到 ELB |

---

## 6. 前置条件

| 项目 | 要求 |
|------|------|
| 华为云账号 | 具备 VPC / ECS / ELB / NAT / EIP 创建权限 |
| 访问密钥 | `HW_ACCESS_KEY` / `HW_SECRET_KEY`（通过环境变量提供，不落盘） |
| 区域 | 已开通独享型 ELB 的 Region，例如 `cn-north-4` |
| Terraform | >= 1.9 |
| 本地依赖 | `git`、`bash` |

---

## 7. 快速开始

```bash
# 1) 通过环境变量配置 AK/SK 访问密钥（真实值不要写入文件）
export HW_ACCESS_KEY="<AK>"
export HW_SECRET_KEY="<SK>"
export HW_REGION_NAME="cn-north-4"

# 2) 配置变量
cd infra
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars：按需设置 region / web_server / client_cidr 等

# 3) 初始化与部署
terraform init
terraform plan
terraform apply
```

部署完成后 `terraform output` 会给出 ELB 公网 IP 与两个演示 URL。

---

## 8. 分步部署

1. **凭据**：按「快速开始」设置 `HW_ACCESS_KEY` / `HW_SECRET_KEY` / `HW_REGION_NAME`（绝不要写进 `.tfvars`）。
2. **变量**：`cp terraform.tfvars.example terraform.tfvars` 并修改。关键变量：
- `region`（默认 `cn-north-4`）、`web_server`（`nginx` / `haproxy`）、`client_cidr`（白名单）。
- `ecs_flavor_name`、`elb_flavor_type` / `elb_flavor_name` 均已按名精确匹配，勿改用下标。
3. **初始化**：`terraform init`（离线环境见 [docs/deployment-guide.md §6](docs/deployment-guide.md) 的 `dev_overrides` 方案）。
4. **预览**：`terraform plan` —— 确认资源清单。
5. **部署**：`terraform apply` —— 等待 ECS 初始化完成（看 `/var/lib/ppv2-bootstrap.done`）。
6. **取地址**：`terraform output elb_public_ip` 获取 ELB 公网 IP。

---

## 9. 使用方法 / 验证

### 使用方法与验证


部署后，从本机或跳板机执行：

```bash
# 入口 A：TLS + PPv2，应显示「Proxy Protocol」标签与真实客户端 IP
curl -k https://<ELB_EIP>:443/index.php

# 入口 B：TCP 源地址透传，应显示「源地址透传」标签与真实客户端 IP
curl http://<ELB_EIP>:80/index.php
```

预期：页面表格中「客户端 IP（Proxy Protocol 头）」与「TCP 连接源地址 REMOTE_ADDR」均等于你的公网 IP。浏览器访问 `https://<ELB_EIP>:443` 会因自签证书告警，属预期。

部署完成后请按本节步骤自行验证，确认业务功能可用，方可视为交付完成。

---

## 10. 清理资源

```bash
cd infra
terraform destroy
```

收工务必 `destroy`；`0 destroyed` ≠ 云端干净，必要时到控制台/API 直查无残留 EIP / ELB / NAT。

---

## 11. 详细说明

- [docs/architecture.md](docs/architecture.md) —— 架构、网络、证书、健康检查、白名单设计。
- [docs/deployment-guide.md](docs/deployment-guide.md) —— 前置条件、变量、离线校验。
- `infra/` —— Terraform 全部资源（`main.tf` / `variables.tf` / `outputs.tf` / `versions.tf` / `terraform.tfvars.example`）。
- `src/webserver/` —— nginx / HAProxy 配置模板、`index.php` 展示页、PHP-FPM 池配置。
- `infra/templates/` —— 两套后端的 cloud-init 初始化脚本。

---

### 约束与踩坑


1. **Proxy Protocol 仅 TLS 监听器生效**：独享型 ELB 的 `proxy_protocol_enable` 只在 TLS 监听器生效，故 PPv2 走 TLS :443。
2. **TCP 默认源地址透传**：独享型 ELB TCP 监听器默认透传客户端真实 IP，后端从 `REMOTE_ADDR` 直接拿。
3. **安全组**：`:8080` 仅放行 ELB 后端子网 CIDR；`:80` 必须同时放行 ELB 后端子网 CIDR（健康检查）与 `client_cidr`（真实客户端源 IP）。
4. **健康检查**：统一打 `:80/healthz`，**绝不**探 `:8080`（PPv2 端口要求每连接带协议头，健康检查不带）。
5. **规格按名匹配**：禁用 `ids[N]` 下标取规格，避免随机命中大规格；`main.tf` 已用 `precondition` 兜底。
6. **自签证书**：TLS 监听器必须挂证书，由 `tls` provider 本地生成，生产请换正式证书。

---

## 12. 依赖

- **Terraform** + **huaweicloud provider**（锁定 1.96.0）、`tls`（4.3.0）、`random`（3.9.0）。
- 后端：nginx / HAProxy + PHP-FPM（Ubuntu 22.04 公共镜像）。
- 参考实现思路来自 Proxy Protocol v2 与负载均衡客户端 IP 保留的通用最佳实践。

---

## 13. FAQ / 故障排除

### FAQ


**Q：`curl` 入口 A 拿不到客户端 IP？**
A：确认监听器 `protocol = "TLS"` 且 `proxy_protocol_enable = true`；后端 `:8080` 必须 `listen ... proxy_protocol`（nginx）/ `bind ... accept-proxy`（HAProxy）。

**Q：入口 B 请求被丢弃？**
A：检查后端安全组 `:80` 是否放行了 `client_cidr`（TCP 透传时源地址是客户端真实 IP，不只是 ELB 子网）。

**Q：健康检查一直失败？**
A：确认 monitor 指向 `:80/healthz`，而非 `:8080`；并确认 ECS 初始化完成（`/var/lib/ppv2-bootstrap.done` 存在）。

**Q：`terraform init` 连不上 Registry？**
A：离线/沙箱环境用 `dev_overrides` 加载本地缓存 provider 二进制，见 [docs/deployment-guide.md §6](docs/deployment-guide.md)。

**Q：浏览器报证书不受信任？**
A：自签证书的预期行为；`curl` 加 `-k`，生产换正式证书。

---

## 14. 贡献指南

欢迎提交 Issue 反馈问题或改进建议。请通过项目 Issue 渠道提交反馈。

---

## 15. 许可证

本实践采用 **MIT No Attribution** 许可证，详见仓库根目录 [`LICENSE`](LICENSE) 文件。

---

## 16. 联系方式 / 维护者
| 项 | 内容 |
|---|---|
| **创建者** | [dgc-git](https://github.com/dgc-git) |
| **维护者** | [dgc-git](https://github.com/dgc-git) |
| **联系方式** | GitHub Issues / PR（见[第 14 节](#14-贡献指南)） |
