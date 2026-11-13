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
