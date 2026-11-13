output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name."
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS API server endpoint - never a credential or kubeconfig."
}

output "environment" {
  value       = var.environment
  description = "Which account this cluster belongs to."
}

output "vpc_cni_role_arn" {
  value       = aws_iam_role.vpc_cni.arn
  description = "Pod Identity role of the VPC CNI (aws-node) - AmazonEKS_CNI_Policy only."
}

output "addon_names" {
  value       = sort(keys(module.eks.cluster_addons))
  description = "EKS add-ons this cluster runs, each at an explicit version."
}

output "karpenter_queue_name" {
  value       = one(module.karpenter[*].queue_name)
  description = "Karpenter interruption queue (Helm value settings.interruptionQueue in Phase 6.4); null on the hub."
}

output "karpenter_node_iam_role_name" {
  value       = one(module.karpenter[*].node_iam_role_name)
  description = "Role of Karpenter-provisioned nodes (EC2NodeClass spec.role in Phase 6.4); null on the hub."
}

output "argocd_hub_role_arn" {
  value       = one(aws_iam_role.argocd_hub[*].arn)
  description = "Hub only: the role Argo CD's controller and server use (Pod Identity) to assume the spoke argocd-manager roles."
}

output "argocd_manager_role_arn" {
  value       = one(aws_iam_role.argocd_manager[*].arn)
  description = "Spokes only: the role the hub's Argo CD assumes (cluster Secret awsAuthConfig.roleARN, Phase 3.4.4b)."
}
