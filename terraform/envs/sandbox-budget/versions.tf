# No backend block: the Phase 6.4a session (scripts/terraform/aws-session.sh)
# keeps this root's state in a working copy under .local/eks-sandbox/.
# Same exact pins as every other root/child.
terraform {
  required_version = "= 1.16.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.63.0"
    }
  }
}
