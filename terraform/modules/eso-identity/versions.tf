# Reusable child module - instantiated once per environment by
# terraform/envs/identity/. No backend/state of its own (inherits the
# calling root's), but declares its own provider requirement per
# Terraform best practice for a module using AWS-specific resources.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
