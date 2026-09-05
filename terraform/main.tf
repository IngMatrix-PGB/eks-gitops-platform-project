# Toolchain smoke-test fixture ONLY. This file exists solely so
# terraform/tests/toolchain.tftest.hcl has something to exercise while
# proving the offline validation pipeline itself works (terraform fmt/
# init -backend=false/validate/test with mock_provider "aws", zero AWS
# credentials, zero network contact to AWS). It is NOT the start of
# VPC/EKS/IAM/Secrets Manager design - that is explicitly out of scope
# until Phase 2.7.2 and later (see
# .local/evidence/phase-2.7-eks-aws-foundation-plan.md, section "2.7.1
# - Terraform Toolchain and Offline Validation").
#
# Both data sources below are read-only, account-shape-revealing calls
# with no side effect and no dependency on any project-specific
# resource - chosen deliberately over anything domain-specific
# (aws_secretsmanager_secret, aws_iam_role, etc.) so this fixture can
# never be mistaken for real infrastructure intent.

variable "expected_environment" {
  type        = string
  description = "Toolchain smoke-test input only - exercises variable validation mechanics, not a real environment."

  validation {
    condition     = contains(["staging", "production"], var.expected_environment)
    error_message = "expected_environment must be exactly \"staging\" or \"production\"."
  }
}

data "aws_caller_identity" "toolchain_smoke" {}

data "aws_region" "toolchain_smoke" {}

output "toolchain_smoke_account_id" {
  value = data.aws_caller_identity.toolchain_smoke.account_id
}

output "toolchain_smoke_region" {
  value = data.aws_region.toolchain_smoke.region
}
