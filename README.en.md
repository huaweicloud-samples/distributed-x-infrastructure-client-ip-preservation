# distributed-x-infrastructure-client-ip-preservation

<img src="https://img.shields.io/badge/License-MIT--0-blue.svg" alt="License">
![License](https://img.shields.io/badge/license-MIT-green)
![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-ELB-blue)
![Build](https://img.shields.io/badge/terraform%20validate-passing-brightgreen)

---

## 1. Overview

### Overview

Behind a load balancer, the backend normally only sees the load balancer's IP and the real client address is hidden. This kit provides a **ready-to-launch Huawei Cloud reference implementation** that shows how the backend can obtain the **client's real IP address and port** after traffic passes through a **dedicated load balancer (ELB)**.

The core approach is **Proxy Protocol v2 (PPv2)**, with **TCP source address passthrough** provided as a comparison entry point. Both are shown side by side on the same page so the difference in how the real IP is obtained is immediately clear.

Target audience: architects and developers who need client IP passthrough, log auditing, rate limiting, or risk-control fronting on Huawei Cloud.

---

## 2. Table of Contents

- [1. Overview](#1-overview)
- [2. Table of Contents](#2-table-of-contents)
- [3. Architecture Diagram](#3-architecture-diagram)
- [4. Highlights](#4-highlights)
- [5. Cloud Services Used](#5-cloud-services-used)
- [6. Prerequisites](#6-prerequisites)
- [7. Quick Start](#7-quick-start)
- [8. Step-by-Step Deployment](#8-step-by-step-deployment)
- [9. Usage / Verification](#9-usage--verification)
- [10. Cleanup](#10-cleanup)
- [11. Detailed Explanation](#11-detailed-explanation)
- [12. Dependencies](#12-dependencies)
- [13. FAQ / Troubleshooting](#13-faq--troubleshooting)
- [14. Contributing](#14-contributing)
- [15. License](#15-license)
- [16. Contact / Maintainers](#16-contact--maintainers)

---

## 3. Architecture Diagram

```
Internet
│
▼
┌────────────────────────┐
│ Dedicated ELB (public) │ EIP
└────────────────────────┘
│ │
Entry A │ │ Entry B
TLS :443 + PPv2 │ │ TCP :80 (source address passthrough)
▼ ▼
┌───────────────────────────────────────────┐
│ Backend ECS (private subnet)              │
│ :8080 proxy_protocol │ PPv2 header needed │
│ :80 plain HTTP+/healthz │ TCP source=IP   │
│ Web (nginx/HAProxy) + PHP-FPM              │
│ → index.php displays connection info       │
└───────────────────────────────────────────┘
```

| Entry | Listener | Backend port | Mechanism for obtaining the real IP |
|---|---|---|---|
| A | TLS :443, Proxy Protocol enabled | :8080 | Parse the PPv2 header → client IP/port |
| B | TCP :80, source address passthrough | :80 | The TCP connection source address is the real client IP |

See [docs/architecture.md](docs/architecture.md) for details.

---

## 4. Highlights

- **Two entries for comparison**: a TLS listener + PPv2 to obtain the real IP (requires a protocol header) versus a TCP listener with source address passthrough to obtain the real IP (no protocol header), making the difference between the two mechanisms obvious at a glance.
- **One-click launch**: `terraform apply` creates the complete network / compute / ELB / certificate / whitelist, and the backend is initialized automatically by `user_data` with no manual login or configuration required.
- **Switchable backend**: the variable `web_server` switches between `nginx` and `haproxy` implementations, demonstrating equivalent semantics.
- **Minimal exposure**: the ECS has only a private IP and accesses the internet through NAT; the ELB binds an EIP for external access; client whitelisting is applied at the listener level.
- **No external credentials**: the TLS certificate is self-signed locally by the `tls` provider, and credentials are provided only via environment variables without being written to disk.

---

## 5. Cloud Services Used

This practice uses the following Huawei Cloud services:

| Service | Purpose |
|---|---|
| Dedicated ELB (Elastic Load Balance) | Public entry + TLS/TCP listeners + PPv2 |
| ECS (Elastic Cloud Server) | Backend nginx/HAProxy + PHP-FPM |
| VPC | Private/public subnet isolation |
| NAT Gateway + EIP | Internet access for private ECS (e.g. apt installation) |
| TLS certificate | Self-signed locally by the `tls` provider and hosted on the ELB via `huaweicloud_elb_certificate` |

---

## 6. Prerequisites

| Item | Requirement |
|---|---|
| Huawei Cloud account | Permissions to create VPC / ECS / ELB / NAT / EIP |
| Access keys | `HW_ACCESS_KEY` / `HW_SECRET_KEY` (provided via environment variables, never written to disk) |
| Region | A region where dedicated ELB is available, e.g. `cn-north-4` |
| Terraform | >= 1.9 |
| Local dependencies | `git`, `bash` |

---

## 7. Quick Start

```bash
# 1) Configure the AK/SK access keys via environment variables (never write real values into files)
export HW_ACCESS_KEY="<AK>"
export HW_SECRET_KEY="<SK>"
export HW_REGION_NAME="cn-north-4"

# 2) Configure variables
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set region / web_server / client_cidr etc. as needed

# 3) Initialize and deploy
terraform init
terraform plan
terraform apply
```

After deployment, `terraform output` gives the ELB public IP and the two demo URLs.

---

## 8. Step-by-Step Deployment

1. **Credentials**: set `HW_ACCESS_KEY` / `HW_SECRET_KEY` / `HW_REGION_NAME` as described in "Quick Start" (never write them into `.tfvars`).
2. **Variables**: run `cp terraform.tfvars.example terraform.tfvars` and edit it. Key variables:
- `region` (default `cn-north-4`), `web_server` (`nginx` / `haproxy`), `client_cidr` (whitelist).
- `ecs_flavor_name` and `elb_flavor_type` / `elb_flavor_name` are all matched exactly by name; do not switch to indexes.
3. **Initialize**: `terraform init` (for offline environments see the `dev_overrides` approach in [docs/deployment-guide.md §6](docs/deployment-guide.md)).
4. **Preview**: `terraform plan` — confirm the resource list.
5. **Deploy**: `terraform apply` — wait for the ECS initialization to finish (check for `/var/lib/ppv2-bootstrap.done`).
6. **Get the address**: `terraform output elb_public_ip` to obtain the ELB public IP.

---

## 9. Usage / Verification

### Usage and Verification

After deployment, run the following from your local machine or a jump host:

```bash
# Entry A: TLS + PPv2; should display the "Proxy Protocol" label and the real client IP
curl -k https://<ELB_EIP>:443/index.php

# Entry B: TCP source address passthrough; should display the "source address passthrough" label and the real client IP
curl http://<ELB_EIP>:80/index.php
```

Expected: in the page table, both "Client IP (Proxy Protocol header)" and "TCP connection source address REMOTE_ADDR" equal your public IP. A browser visiting `https://<ELB_EIP>:443` will warn about the self-signed certificate; this is expected.

After deployment, follow these steps to verify that the business functionality works before considering the delivery complete.

---

## 10. Cleanup

```bash
cd infra
terraform destroy
```

Always run `destroy` when finished; `0 destroyed` does not mean the cloud side is clean. If necessary, check directly in the console/API for leftover EIP / ELB / NAT resources.

---

## 11. Detailed Explanation

- [docs/architecture.md](docs/architecture.md) — design of the architecture, network, certificate, health check, and whitelist.
- [docs/deployment-guide.md](docs/deployment-guide.md) — prerequisites, variables, and offline validation.
- `infra/` — all Terraform resources (`main.tf` / `variables.tf` / `outputs.tf` / `versions.tf` / `terraform.tfvars.example`).
- `src/webserver/` — nginx / HAProxy configuration templates, the `index.php` display page, and the PHP-FPM pool configuration.
- `infra/templates/` — cloud-init initialization scripts for both backends.

### Constraints and pitfalls

1. **Proxy Protocol only works on TLS listeners**: for a dedicated ELB, `proxy_protocol_enable` only takes effect on TLS listeners, so PPv2 uses TLS :443.
2. **TCP passes through the source address by default**: a dedicated ELB TCP listener passes through the real client IP by default; the backend reads it directly from `REMOTE_ADDR`.
3. **Security group**: `:8080` only allows the ELB backend subnet CIDR; `:80` must allow both the ELB backend subnet CIDR (health check) and `client_cidr` (real client source IP).
4. **Health check**: always targets `:80/healthz` and **never** `:8080` (the PPv2 port requires a protocol header on every connection, which health checks do not send).
5. **Match flavors by name**: do not use `ids[N]` indexes to select flavors, to avoid randomly picking a large flavor; `main.tf` already uses a `precondition` as a safeguard.
6. **Self-signed certificate**: a TLS listener must have a certificate attached; it is generated locally by the `tls` provider. Use a formal certificate in production.

---

## 12. Dependencies

- **Terraform** + **huaweicloud provider** (pinned to 1.96.0), `tls` (4.3.0), `random` (3.9.0).
- Backend: nginx / HAProxy + PHP-FPM (Ubuntu 22.04 public image).
- The reference implementation approach comes from general best practices for Proxy Protocol v2 and client IP preservation behind load balancers.

---

## 13. FAQ / Troubleshooting

**Q: Entry A via `curl` does not return the client IP?**
A: Confirm the listener has `protocol = "TLS"` and `proxy_protocol_enable = true`; the backend `:8080` must use `listen ... proxy_protocol` (nginx) / `bind ... accept-proxy` (HAProxy).

**Q: Requests to entry B are dropped?**
A: Check whether the backend security group `:80` allows `client_cidr` (with TCP passthrough the source address is the real client IP, not just the ELB subnet).

**Q: Health checks keep failing?**
A: Confirm the monitor targets `:80/healthz` rather than `:8080`, and confirm the ECS initialization has finished (`/var/lib/ppv2-bootstrap.done` exists).

**Q: `terraform init` cannot reach the Registry?**
A: In offline/sandboxed environments, use `dev_overrides` to load a locally cached provider binary; see [docs/deployment-guide.md §6](docs/deployment-guide.md).

**Q: The browser reports the certificate as untrusted?**
A: This is expected with a self-signed certificate; add `-k` to `curl`, and use a formal certificate in production.

---

## 14. Contributing

Issues are welcome for reporting problems or suggesting improvements. Please submit feedback through the project Issue channel.

---

## 15. License

This practice is licensed under **MIT No Attribution**; see the [`LICENSE`](LICENSE) file in the repository root.

---

## 16. Contact / Maintainers
| Item | Content |
|---|---|
| **Creator** | [dgc-git](https://github.com/dgc-git) |
| **Maintainer** | [dgc-git](https://github.com/dgc-git) |
| **Contact** | GitHub Issues / PR (see [Section 14](#14-contributing)) |
