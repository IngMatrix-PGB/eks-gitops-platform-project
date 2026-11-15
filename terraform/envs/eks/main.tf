module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = var.environment == "platform" ? "shared" : var.environment
  owner       = var.owner
}

locals {
  cluster_name  = coalesce(var.cluster_name, "eks-gitops-${var.environment}")
  capacity_type = coalesce(var.capacity_type, var.environment == "prod" ? "ON_DEMAND" : "SPOT")

  # Phase 3.4.3b: workload capacity on the spokes comes from Karpenter.
  # The hub runs only Argo CD and add-ons on its fixed node group.
  karpenter_enabled = var.environment != "platform"

  # Karpenter's node role: the module's worker and image-pull policies
  # plus SSM access. Never the CNI policy - aws-node has its own Pod
  # Identity role (aws_iam_role.vpc_cni).
  karpenter_node_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Phase 3.4.4a (TAD R-05): hub-to-spoke Argo CD identity. Fixed role
  # names on both sides, so each side can name the other's role without
  # reading its state.
  is_hub                   = var.environment == "platform"
  argocd_hub_role_name     = "eks-gitops-platform-argocd"
  argocd_manager_role_name = "eks-gitops-${var.environment}-argocd-manager"
  argocd_manager_group     = "argocd-manager"
  argocd_hub_service_accts = ["argocd-application-controller", "argocd-server"]
  argocd_spoke_role_arns   = local.is_hub ? [for env in sort(keys(var.spoke_account_ids)) : "arn:aws:iam::${var.spoke_account_ids[env]}:role/eks-gitops-${env}-argocd-manager"] : []
  argocd_hub_role_arn      = local.is_hub ? null : "arn:aws:iam::${var.hub_account_id}:role/${local.argocd_hub_role_name}"
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

      # On spokes only add-ons and controllers (Karpenter included) run
      # here; workloads land on Karpenter-provisioned nodes.
      taints = local.karpenter_enabled ? {
        critical_addons_only = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      } : {}

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

  access_entries = merge(local.argocd_access_entry_resolved, {
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
  })

  # Phase 3.4.3: see local.eks_managed_node_groups (kept in a local so
  # terraform test can assert the node group configuration directly).
  eks_managed_node_groups = local.eks_managed_node_groups

  # Phase 3.4.3b: Karpenter discovers the node security group by this tag
  # (the private subnets carry the same tag, set in terraform/envs/network).
  node_security_group_tags = local.karpenter_enabled ? { "karpenter.sh/discovery" = local.cluster_name } : {}

  tags = module.tags.tags
}

# --- Phase 3.4.3b: Karpenter (IaC only) ----------------------------------------
# Controller identity (Pod Identity on kube-system/karpenter), the
# interruption queue with managed encryption and its EventBridge rules,
# the node role and its EKS access entry. The Helm install and the
# NodePool/EC2NodeClass are delivered through GitOps in Phase 6.4.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.25.0"
  count   = local.karpenter_enabled ? 1 : 0

  cluster_name = module.eks.cluster_name

  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  enable_spot_termination   = true
  queue_managed_sse_enabled = true

  node_iam_role_attach_cni_policy   = false
  node_iam_role_additional_policies = local.karpenter_node_additional_policies

  tags = module.tags.tags
}

# --- Phase 3.4.4a: hub-to-spoke Argo CD identity (TAD R-05) --------------------
# Hub (platform): Argo CD's application controller and server get one role
# through Pod Identity; it may only assume the three spoke argocd-manager
# roles. Spokes: an argocd-manager role with no IAM permissions, assumable
# only by that hub role, mapped by the access entry above to the
# argocd-manager Kubernetes group. Argo CD's cluster Secret for a spoke
# carries awsAuthConfig (clusterName, roleARN) - never a token.

locals {
  # A spoke maps its argocd-manager role to a Kubernetes group with NO EKS
  # access policy: its only permissions come from the Role in
  # platform/spoke-access/role.yaml, bound to that group in the spoke
  # namespace (AmazonEKSEditPolicy would include Secrets).
  argocd_access_entry_resolved = local.is_hub ? {} : {
    argocd = {
      principal_arn     = aws_iam_role.argocd_manager[0].arn
      type              = "STANDARD"
      kubernetes_groups = [local.argocd_manager_group]
    }
  }
}

resource "aws_iam_role" "argocd_hub" {
  count = local.is_hub ? 1 : 0

  name = local.argocd_hub_role_name
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

resource "aws_iam_role_policy" "argocd_hub" {
  count = local.is_hub ? 1 : 0

  name = "assume-spoke-argocd-manager"
  role = aws_iam_role.argocd_hub[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeSpokeArgocdManager"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = local.argocd_spoke_role_arns
    }]
  })
}

resource "aws_eks_pod_identity_association" "argocd_hub" {
  for_each = local.is_hub ? toset(local.argocd_hub_service_accts) : toset([])

  cluster_name    = module.eks.cluster_name
  namespace       = "argocd"
  service_account = each.key
  role_arn        = aws_iam_role.argocd_hub[0].arn
  tags            = module.tags.tags
}

resource "aws_iam_role" "argocd_manager" {
  count = local.is_hub ? 0 : 1

  name = local.argocd_manager_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyTheHubArgocdRole"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.hub_account_id}:root" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = { ArnEquals = { "aws:PrincipalArn" = local.argocd_hub_role_arn } }
    }]
  })
  tags = module.tags.tags
}
