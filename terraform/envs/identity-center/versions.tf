# No backend block, as every other root in this offline-only design
# (Phase 4d, ADR-0025). Same exact pins as every other root/child.
terraform {
  required_version = "= 1.16.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
