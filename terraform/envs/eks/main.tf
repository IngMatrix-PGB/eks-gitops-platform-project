module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = var.environment == "platform" ? "shared" : var.environment
  owner       = var.owner
}

locals {
  cluster_name  = coalesce(var.cluster_name, "eks-gitops-${var.environment}")
  capacity_type = coalesce(var.capacity_type, var.environment == "prod" ? "ON_DEMAND" : "SPOT")
}

locals {
  # Phase 3.4.3: a small "system" node group for add-ons and controllers;
  # workload capacity comes from Karpenter (Phase 3.4.3b).
  eks_managed_node_groups = {
    system = {
      instance_types = var.node_instance_types
      capacity_type  = local.capacity_type

      min_size     = 2
      max_size     = 3
      desired_size = 2

      # CNI credentials come from aws_iam_role.vpc_cni (Pod Identity).
      iam_role_attach_cni_policy = false

      # IMDSv2 enforced - mirrors the EC2.8 hardening pattern already
      # applied elsewhere (canonical plan S9.1).
      metadata_options = {
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }
}

# Phase 3.4.3: the VPC CNI gets its own Pod Identity role with only the
# CNI policy, instead of that policy riding on every node's role (the
# system node group below sets iam_role_attach_cni_policy = false).
resource "aws_iam_role" "vpc_cni" {
  name = "${local.cluster_name}-vpc-cni"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = module.tags.tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# EKS cluster + Access Entries (never aws-auth, canonical plan S9.1) +
# one Managed Node Group + the four mandatory add-ons + a customer-
# managed KMS key for envelope encryption. Fargate is not used - Pod
# Identity is not supported on Fargate (canonical plan S8.1/S2.1), and
# Pod Identity is this project's chosen identity mechanism.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0"

  name               = local.cluster_name
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
  # Phase 3.4.3: every add-on the cluster runs is managed here, each at an
  # explicit, validated version - most_recent is always false (the
  # module's own default is true). vpc-cni and the Pod Identity Agent are
  # installed before the node group (before_compute), so nodes join with
  # a working CNI whose credentials come from Pod Identity. The VPC CNI
  # enforces NetworkPolicy (closes R-14 together with metrics-server).
  addons = {
    eks-pod-identity-agent = {
      addon_version  = var.pod_identity_agent_addon_version
      most_recent    = false
      before_compute = true
    }
    vpc-cni = {
      addon_version        = var.vpc_cni_addon_version
      most_recent          = false
      before_compute       = true
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
      pod_identity_association = [{
        role_arn        = aws_iam_role.vpc_cni.arn
        service_account = "aws-node"
      }]
    }
    coredns = {
      addon_version = var.coredns_addon_version
      most_recent   = false
    }
    kube-proxy = {
      addon_version = var.kube_proxy_addon_version
      most_recent   = false
    }
    metrics-server = {
      addon_version = var.metrics_server_addon_version
      most_recent   = false
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

  # Phase 3.4.3: see local.eks_managed_node_groups (kept in a local so
  # terraform test can assert the node group configuration directly).
  eks_managed_node_groups = local.eks_managed_node_groups

  tags = module.tags.tags
}
