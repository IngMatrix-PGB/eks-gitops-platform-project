# Deliberately no backend block at all, ever - this is the ONE root
# module that always uses local state, since it creates the very S3
# bucket every other root module's own backend will point at (see
# docs/adr/0012-network-eks-iac-foundation.md, "Terraform State
# Bootstrap"). Its own state file is never committed to Git (see
# .gitignore's existing *.tfstate* rule) and is treated as sensitive-
# adjacent, backed up manually, out of band.
terraform {
  required_version = "= 1.16.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
