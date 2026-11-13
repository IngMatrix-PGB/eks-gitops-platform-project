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
}

run "correct_access_entries_wiring" {
  command = plan

  assert {
    condition     = length(module.eks.access_entries) == 2
    error_message = "expected exactly two Access Entries (admin, breakglass)"
  }
  assert {
    condition     = contains(keys(module.eks.access_entries), "admin") && contains(keys(module.eks.access_entries), "breakglass")
    error_message = "expected Access Entries keyed \"admin\" and \"breakglass\""
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
