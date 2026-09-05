# No backend block yet - this root module continues using
# `terraform init -backend=false` exclusively until a real, separately
# authorized apply-capable phase exists. When that phase adds one, it
# must be empty/partial ("backend \"s3\" {}", real bucket/key/region
# supplied later via -backend-config) - see docs/adr/0012-network-eks-
# iac-foundation.md.
terraform {
  required_version = "= 1.16.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
