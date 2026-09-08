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

  # EKS Pod Identity Agent - the cluster-wide DaemonSet every Pod
  # Identity Association (terraform/envs/identity/) depends on to
  # actually deliver credentials. Owned here, in the same state as the
  # cluster itself - an add-on cannot exist independent of its cluster,
  # and this module's own addons input is its designed
  # mechanism for managing exactly this (see
  # .local/evidence/phase-3.2-pod-identity-secrets-manager-iac-plan.md
  # S11 for the full ownership reasoning - no separate root, no
  # duplicated ownership). Version is an explicit, required, validated
  # input - never most_recent, never a hardcoded guess: no static
  # version table exists for this add-on (re-verified 2026-09-08); the
  # real, current-for-this-cluster-version value must be queried live
  # via `aws eks describe-addon-versions --addon-name
  # eks-pod-identity-agent --kubernetes-version <version>` at real,
  # future, separately authorized deploy time. Created via this
  # Terraform module only - never Helm, never GitOps, never
  # IRSA/OIDC.
  addons = {
    eks-pod-identity-agent = {
      addon_version = var.pod_identity_agent_addon_version
      # Explicit, never most_recent - most_recent defaults to true on
      # this module's own addons variable, which this design
      # deliberately overrides to false since the version is always
      # the caller-supplied, explicitly pinned value above, never
      # resolved implicitly by the module/API.
      most_recent = false
    }
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
