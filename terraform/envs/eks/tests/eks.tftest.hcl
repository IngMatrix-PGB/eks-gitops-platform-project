# mock_provider "aws" {} substitutes for a real provider configuration
# entirely - no region, no credentials, no network contact to AWS. It
# proves this root's structural logic only (Phase 3.1, extended in Phase
# 3.4.3): access entries, the per-environment cluster name and capacity,
# the five managed add-ons at explicit versions, the VPC CNI's
# NetworkPolicy setting and its own Pod Identity role, and the system
# node group without the CNI policy. Nothing is ever applied against AWS.

mock_provider "aws" {
  override_data {
    target = module.eks.data.aws_partition.current[0]
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = module.eks.module.eks_managed_node_group["system"].data.aws_partition.current[0]
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = module.eks.data.aws_caller_identity.current[0]
    values = {
      # "aws" is one of the account-id values AWS itself permits in an
      # ARN (alongside a real 12-digit account) - used here so the ARN
      # shape is valid without ever writing a real-looking account id.
      account_id = "aws"
      arn        = "arn:aws:iam::aws:root"
      user_id    = "AIDANOTAREALUSERID"
    }
  }

  override_data {
    target = module.eks.data.aws_iam_policy_document.assume_role_policy[0]
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"eks.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }

  override_data {
    target = module.eks.module.eks_managed_node_group["system"].data.aws_iam_policy_document.assume_role_policy[0]
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }

  override_data {
    target = module.karpenter[0].data.aws_partition.current[0]
    values = { partition = "aws", dns_suffix = "amazonaws.com" }
  }

  override_data {
    target = module.karpenter[0].data.aws_caller_identity.current[0]
    values = { account_id = "aws", arn = "arn:aws:iam::aws:root", user_id = "AIDANOTAREALUSERID" }
  }

  override_data {
    target = module.karpenter[0].data.aws_region.current[0]
    values = { region = "us-east-1", name = "us-east-1" }
  }

  override_data {
    target = module.karpenter[0].data.aws_service_principal.ec2[0]
    values = { name = "ec2.amazonaws.com" }
  }

  override_data {
    target = module.karpenter[0].data.aws_iam_policy_document.controller_assume_role[0]
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = module.karpenter[0].data.aws_iam_policy_document.node_assume_role[0]
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = module.karpenter[0].data.aws_iam_policy_document.controller[0]
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = module.karpenter[0].data.aws_iam_policy_document.queue[0]
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_resource {
    target          = aws_iam_role.argocd_manager
    override_during = plan
    values          = { arn = "arn:aws:iam::aws:role/eks-gitops-dev-argocd-manager" }
  }

  override_resource {
    target          = aws_iam_role.argocd_hub
    override_during = plan
    values          = { arn = "arn:aws:iam::aws:role/eks-gitops-platform-argocd", id = "eks-gitops-platform-argocd" }
  }

  override_resource {
    target          = aws_iam_role.vpc_cni
    override_during = plan
    values          = { arn = "arn:aws:iam::aws:role/eks-gitops-dev-vpc-cni" }
  }
}

variables {
  environment                      = "dev"
  aws_region                       = "us-east-1"
  vpc_id                           = "vpc-not-a-real-id"
  private_subnet_ids               = ["subnet-not-a-real-id-1", "subnet-not-a-real-id-2"]
  eks_public_access_cidrs          = ["203.0.113.1/32"]
  admin_principal_arn              = "arn:aws:iam::aws:role/not-a-real-admin-role"
  breakglass_principal_arn         = "arn:aws:iam::aws:role/not-a-real-breakglass-role"
  owner                            = "not-a-real-owner-handle"
  pod_identity_agent_addon_version = "v1.3.4-eksbuild.1"
  vpc_cni_addon_version            = "v1.19.2-eksbuild.1"
  coredns_addon_version            = "v1.11.4-eksbuild.2"
  kube_proxy_addon_version         = "v1.36.0-eksbuild.1"
  metrics_server_addon_version     = "v0.7.2-eksbuild.1"
  # Generated, never a committed 12-digit literal (check-forbidden-terms).
  hub_account_id = format("%012d", 3)
}

run "correct_access_entries_wiring" {
  command = plan

  assert {
    condition     = toset(keys(module.eks.access_entries)) == toset(["admin", "breakglass", "argocd"])
    error_message = "A spoke has exactly three Access Entries: admin, breakglass and the hub's Argo CD (Phase 3.4.4a)."
  }
}

run "cluster_name_and_capacity_per_environment" {
  command = plan

  assert {
    condition     = local.cluster_name == "eks-gitops-dev" && local.capacity_type == "SPOT"
    error_message = "A non-prod cluster is named eks-gitops-<environment> and runs its system nodes on SPOT."
  }
}

run "prod_runs_on_demand" {
  command = plan
  variables {
    environment = "prod"
  }

  assert {
    condition     = local.cluster_name == "eks-gitops-prod" && local.capacity_type == "ON_DEMAND"
    error_message = "prod's system nodes must be ON_DEMAND."
  }
}

run "five_managed_addons_at_explicit_versions" {
  command = plan

  assert {
    condition     = toset(keys(module.eks.cluster_addons)) == toset(["eks-pod-identity-agent", "vpc-cni", "coredns", "kube-proxy", "metrics-server"])
    error_message = "The cluster must manage exactly the five add-ons it runs (no self-managed defaults outside Terraform)."
  }
  assert {
    condition = (
      module.eks.cluster_addons["vpc-cni"].addon_version == "v1.19.2-eksbuild.1" &&
      module.eks.cluster_addons["coredns"].addon_version == "v1.11.4-eksbuild.2" &&
      module.eks.cluster_addons["kube-proxy"].addon_version == "v1.36.0-eksbuild.1" &&
      module.eks.cluster_addons["metrics-server"].addon_version == "v0.7.2-eksbuild.1" &&
      module.eks.cluster_addons["eks-pod-identity-agent"].addon_version == "v1.3.4-eksbuild.1"
    )
    error_message = "Every add-on must run exactly the version supplied - never a most_recent lookup."
  }
}

run "vpc_cni_enforces_network_policy_with_its_own_identity" {
  command = plan

  assert {
    condition     = jsondecode(module.eks.cluster_addons["vpc-cni"].configuration_values).enableNetworkPolicy == "true"
    error_message = "The VPC CNI must enforce NetworkPolicy (closes R-14)."
  }
  assert {
    condition     = one(module.eks.cluster_addons["vpc-cni"].pod_identity_association).service_account == "aws-node" && one(module.eks.cluster_addons["vpc-cni"].pod_identity_association).role_arn == aws_iam_role.vpc_cni.arn
    error_message = "The VPC CNI's aws-node must get its credentials from its own Pod Identity role."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.vpc_cni.policy_arn == "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    error_message = "The VPC CNI role carries exactly the AWS-managed CNI policy."
  }
  assert {
    condition     = jsondecode(aws_iam_role.vpc_cni.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    error_message = "Only EKS Pod Identity may assume the VPC CNI role."
  }
}

run "system_node_group_without_cni_policy" {
  command = plan

  assert {
    condition     = local.eks_managed_node_groups.system.min_size == 2 && local.eks_managed_node_groups.system.desired_size == 2
    error_message = "The system node group keeps at least two nodes."
  }
  assert {
    condition     = local.eks_managed_node_groups.system.iam_role_attach_cni_policy == false
    error_message = "The node role must not carry the CNI policy - aws-node uses its own Pod Identity role."
  }
  assert {
    condition     = local.eks_managed_node_groups.system.metadata_options.http_tokens == "required" && local.eks_managed_node_groups.system.metadata_options.http_put_response_hop_limit == 1
    error_message = "Nodes require IMDSv2 with a hop limit of 1."
  }
}

run "karpenter_on_spokes" {
  command = plan

  assert {
    condition     = length(module.karpenter) == 1 && module.karpenter[0].namespace == "kube-system" && module.karpenter[0].service_account == "karpenter"
    error_message = "A spoke runs Karpenter, with its controller identity on kube-system/karpenter (Pod Identity)."
  }
  assert {
    condition     = local.karpenter_node_additional_policies == { AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" }
    error_message = "Karpenter's node role adds only SSM access - never the CNI policy."
  }
  assert {
    condition     = local.eks_managed_node_groups.system.taints.critical_addons_only.key == "CriticalAddonsOnly" && local.eks_managed_node_groups.system.taints.critical_addons_only.effect == "NO_SCHEDULE"
    error_message = "On a spoke the system node group is tainted CriticalAddonsOnly - workloads go to Karpenter nodes."
  }
}

run "hub_has_no_karpenter" {
  command = plan
  variables {
    environment       = "platform"
    hub_account_id    = null
    spoke_account_ids = { dev = format("%012d", 11), uat = format("%012d", 12), prod = format("%012d", 13) }
  }

  assert {
    condition     = length(module.karpenter) == 0 && length(local.eks_managed_node_groups.system.taints) == 0
    error_message = "The hub runs no Karpenter and its system node group is untainted (Argo CD runs there)."
  }
  assert {
    condition     = local.cluster_name == "eks-gitops-platform"
    error_message = "The hub cluster is named eks-gitops-platform."
  }
}

# --- Phase 3.4.4a: hub-to-spoke Argo CD identity (TAD R-05) ---------------------
run "spoke_argocd_manager_identity" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.argocd_manager[0].assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::${format("%012d", 3)}:root" &&
      jsondecode(aws_iam_role.argocd_manager[0].assume_role_policy).Statement[0].Condition.ArnEquals["aws:PrincipalArn"] == "arn:aws:iam::${format("%012d", 3)}:role/eks-gitops-platform-argocd"
    )
    error_message = "A spoke's argocd-manager role may be assumed only by the hub's Argo CD role."
  }
  assert {
    condition     = aws_iam_role.argocd_manager[0].name == "eks-gitops-dev-argocd-manager" && length(aws_iam_role_policy.argocd_hub) == 0 && length(aws_iam_role.argocd_hub) == 0
    error_message = "A spoke has its argocd-manager role and no hub Argo CD role or policy."
  }
  assert {
    condition     = local.argocd_access_entry_resolved.argocd.type == "STANDARD" && local.argocd_access_entry_resolved.argocd.kubernetes_groups == ["argocd-manager"]
    error_message = "The hub's Argo CD maps to the argocd-manager Kubernetes group through a STANDARD access entry."
  }
  assert {
    condition     = !can(local.argocd_access_entry_resolved.argocd.policy_associations)
    error_message = "The Argo CD access entry must carry no EKS access policy - permissions come only from the namespaced Role (platform/spoke-access/role.yaml)."
  }
}

run "hub_argocd_identity" {
  command = plan
  variables {
    environment       = "platform"
    hub_account_id    = null
    spoke_account_ids = { dev = format("%012d", 11), uat = format("%012d", 12), prod = format("%012d", 13) }
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.argocd_hub[0].policy).Statement[0].Resource) == toset([
      "arn:aws:iam::${format("%012d", 11)}:role/eks-gitops-dev-argocd-manager",
      "arn:aws:iam::${format("%012d", 12)}:role/eks-gitops-uat-argocd-manager",
      "arn:aws:iam::${format("%012d", 13)}:role/eks-gitops-prod-argocd-manager",
    ])
    error_message = "The hub's Argo CD may assume exactly the three spoke argocd-manager roles - nothing else."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.argocd_hub[0].policy).Statement[0].Action) == toset(["sts:AssumeRole", "sts:TagSession"]) && length(jsondecode(aws_iam_role_policy.argocd_hub[0].policy).Statement) == 1
    error_message = "The hub role's only permission is sts:AssumeRole/TagSession on the spoke roles."
  }
  assert {
    condition     = toset([for a in aws_eks_pod_identity_association.argocd_hub : "${a.namespace}/${a.service_account}"]) == toset(["argocd/argocd-application-controller", "argocd/argocd-server"])
    error_message = "Only Argo CD's application controller and server get the hub role (Pod Identity)."
  }
  assert {
    condition     = length(aws_iam_role.argocd_manager) == 0 && length(local.argocd_access_entry_resolved) == 0
    error_message = "The hub has no argocd-manager role and no Argo CD access entry of its own."
  }
}

run "rejects_spoke_without_hub_account" {
  command = plan
  variables {
    hub_account_id = null
  }
  expect_failures = [var.hub_account_id]
}

run "rejects_hub_without_spoke_accounts" {
  command = plan
  variables {
    environment    = "platform"
    hub_account_id = null
  }
  expect_failures = [var.spoke_account_ids]
}

run "rejects_malformed_spoke_account" {
  command = plan
  variables {
    environment       = "platform"
    hub_account_id    = null
    spoke_account_ids = { dev = "dev", uat = format("%012d", 12), prod = format("%012d", 13) }
  }
  expect_failures = [var.spoke_account_ids]
}

# --- rejections ----------------------------------------------------------------
run "rejects_invalid_capacity_type" {
  command = plan
  variables {
    capacity_type = "RESERVED"
  }
  expect_failures = [var.capacity_type]
}

run "rejects_invalid_pod_identity_agent_addon_version_shape" {
  command = plan
  variables {
    pod_identity_agent_addon_version = "latest"
  }
  expect_failures = [var.pod_identity_agent_addon_version]
}

run "rejects_unpinned_vpc_cni_version" {
  command = plan
  variables {
    vpc_cni_addon_version = "latest"
  }
  expect_failures = [var.vpc_cni_addon_version]
}

run "rejects_unknown_environment" {
  command = plan
  variables {
    environment = "staging"
  }
  expect_failures = [var.environment]
}
