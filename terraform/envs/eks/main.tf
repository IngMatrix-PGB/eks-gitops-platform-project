module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

# EKS cluster + Access Entries (never aws-auth, canonical plan S9.1) +
# one Managed Node Group + the four mandatory add-ons + a customer-
# managed KMS key for envelope encryption. Fargate is not used - Pod
# Identity is not supported on Fargate (canonical plan S8.1/S2.1), and
# Pod Identity is this project's chosen identity mechanism.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  authentication_mode = "API"

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_public_access_cidrs
  endpoint_private_access      = true

  enabled_log_types = ["api", "audit"]

  encryption_config = {
    resources = ["secrets"]
  }

  access_entries = {
    admin = {
      principal_arn = var.admin_principal_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
    breakglass = {
      principal_arn = var.breakglass_principal_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = var.capacity_type

      min_size     = 1
      max_size     = 3
      desired_size = 2

      # IMDSv2 enforced - mirrors the EC2.8 hardening pattern already
      # applied elsewhere (canonical plan S9.1).
      metadata_options = {
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  tags = module.tags.tags
}
