# Phase 2.7.1 - Terraform Toolchain and Offline Validation. Pins the
# Terraform CLI and AWS provider version this repository validates
# against. No infrastructure is designed here - see main.tf's own
# comment and .local/evidence/phase-2.7-eks-aws-foundation-plan.md for
# why. Versions verified directly against releases.hashicorp.com and
# registry.terraform.io on 2026-09-05 (see docs/adr/0011-terraform-
# foundation.md); re-verify at actual infrastructure-authoring time
# rather than trusting this comment indefinitely.
terraform {
  required_version = "= 1.16.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
