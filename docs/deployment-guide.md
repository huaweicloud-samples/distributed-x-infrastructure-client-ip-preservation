# 部署指南

> 本指南说明如何把本套件部署到华为云。资源规格已在变量中显式写明。
> 凭据一律通过环境变量注入，不写入任何 `.tf` / `.tfvars` 文件。

---

## 1. 前置条件

| 项目 | 要求 |
|------|------|
| 华为云账号 | 具备 VPC、ECS、ELB、NAT、EIP 的创建权限 |
| 访问密钥 | 有效的 `HW_ACCESS_KEY` / `HW_SECRET_KEY`（以及可选 `HW_SECURITY_TOKEN`） |
| 区域 | 已开通独享型 ELB 的 Region，例如 `cn-north-4` |
| Terraform | >= 1.9（已验证 1.9.8 通过） |
| 本地依赖 | `git`、`bash`；若离线校验需缓存 provider 二进制（见 §6） |

> 环境变量名是华为云 provider 的规范命名：认证用 `HW_ACCESS_KEY` + `HW_SECRET_KEY`，区域用 `HW_REGION_NAME`。

---

## 2. 准备凭据（不落盘）

```bash
export HW_ACCESS_KEY="<AK>" # 仅占位，请填真实值；切勿写入文件
export HW_SECRET_KEY="<SK>"
export HW_REGION_NAME="cn-north-4"
# 使用临时安全凭证时补充：
# export HW_SECURITY_TOKEN="<TOKEN>"
```

> 请通过环境变量注入真实凭据，不要将凭据写入任何交付文件。

---

## 3. 配置变量

复制示例变量文件，按需修改：

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

常用变量（详见 `infra/variables.tf`）：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `region` | `cn-north-4` | 资源所在区域 |
| `name_prefix` | `ppv2-demo` | 资源名前缀 |
| `availability_zone` | `""`（自动取首个） | 显式指定可填 `cn-north-4a` |
| `web_server` | `nginx` | `nginx` 或 `haproxy` |
| `client_cidr` | `0.0.0.0/0` | 监听器客户端白名单；生产请收紧 |
| `ssh_source_cidr` | `0.0.0.0/0` | SSH 登录来源；生产请收紧 |
| `ecs_flavor_name` | `s6.large.2` | ECS 规格码（按名精确匹配） |
| `elb_flavor_type` | `L4_elastic_max` | ELB 四层规格类型 |
| `elb_flavor_name` | `L4_flavor.elb.pro.max` | ELB 规格名（按名精确匹配） |
| `key_pair` | `""` | 登录密钥对名；留空则不绑定 |

> ⚠️ **规格必须按名称精确指定**：`huaweicloud_elb_flavors` / `huaweicloud_compute_flavors` 的下标与规格大小无关，随机命中会导致规格不符合预期。本套件已在 `variables.tf` 中做精确匹配，并在 `main.tf` 用 `precondition` 兜住「命中数 ≠ 1」。

---

## 4. 初始化

```bash
terraform init
```

> 若运行环境无法访问 Terraform Registry（例如离线 / 沙箱），改用 `dev_overrides` 加载本地缓存的 provider 二进制（见 §6）。

---

## 5. 预览与部署

```bash
# 预览（不创建资源）
terraform plan

# 确认无误后部署
terraform apply
```

`terraform apply` 前，请确认资源清单符合预期。

部署完成后，`terraform output` 会给出：

- `elb_public_ip`：ELB 绑定的公网 EIP；
- `demo_url_ppv2`：`https://<ELB_EIP>:443/index.php`（入口 A，TLS + PPv2）；
- `demo_url_plain`：`http://<ELB_EIP>:80/index.php`（入口 B，TCP 源地址透传）。

---

## 6. 离线 / 受限网络下的校验（可选）

当执行机无法访问 `registry.terraform.io` 时，可用 `dev_overrides` 直接加载本地缓存的 provider 二进制，绕开 Registry 下载：

1. 准备本地解包目录，例如 `~/terraform-providers/`，内含已下载的：
- `huaweicloud` 1.96.0（unpacked 二进制）；
- `tls` 4.3.0；
- `random` 3.9.0。
2. 在 `terraform.rc`（或 `~/.terraformrc`）中声明：

```hcl
provider_installation {
dev_overrides {
"huaweicloud/huaweicloud" = "C:/path/to/terraform-providers/huaweicloud"
"hashicorp/tls" = "C:/path/to/terraform-providers/tls"
"hashicorp/random" = "C:/path/to/terraform-providers/random"
}
direct {}
}
```
3. `terraform init` 会跳过 Registry，直接加载本地二进制；随后 `terraform validate` 即可离线校验配置（本仓库已对 `nginx` 与 `haproxy` 两种 `web_server` 均通过）。

> 注意：`dev_overrides` 会跳过版本锁定与校验，仅用于离线校验/调试；正式发布仍以 `.terraform.lock.hcl` 锁定版本为准。

---

## 7. 验证（部署后）

```bash
# 入口 A：TLS + PPv2，页面应显示「Proxy Protocol」标签与真实客户端 IP
curl -k https://<ELB_EIP>:443/index.php

# 入口 B：TCP 源地址透传，页面应显示「源地址透传」标签与真实客户端 IP
curl http://<ELB_EIP>:80/index.php
```

预期：页面表格中「客户端 IP（Proxy Protocol 头）」与「TCP 连接源地址 REMOTE_ADDR」均等于你的公网 IP。

> 浏览器访问 `https://<ELB_EIP>:443` 会因自签证书弹出警告，属预期；继续访问即可。

---

## 8. 清理资源

```bash
terraform destroy
```

> 收工务必 `destroy`。`0 destroyed` ≠ 云端干净，必要时到控制台/API 直查确认无残留 EIP、ELB、NAT。
