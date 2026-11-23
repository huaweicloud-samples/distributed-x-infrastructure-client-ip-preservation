terraform {
  # terraform_data 用于把配置自检提前到 plan 阶段，该资源自 1.4 起提供。
  required_version = ">= 1.4.0"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = ">= 1.60.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# 凭据通过环境变量注入
#
# 认证信息一律通过环境变量提供，不写入 .tf / .tfvars / 版本库：
#   export HW_ACCESS_KEY=<AK>
#   export HW_SECRET_KEY=<SK>
#   export HW_REGION_NAME=<region>
# ---------------------------------------------------------------------------
provider "huaweicloud" {
  region = var.region
}

resource "random_id" "suffix" {
  byte_length = 4
}
