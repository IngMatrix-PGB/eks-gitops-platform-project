# No backend block - matching terraform/envs/network/'s and
# terraform/envs/eks/'s current state (no real backend exists yet in
# this offline-only design). Same exact pins as every other root/child.
terraform {
  required_version = "= 1.16.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
