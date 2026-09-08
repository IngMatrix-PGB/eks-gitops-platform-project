output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "VPC ID, consumed by terraform/envs/eks/."
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnets
  description = "Private subnet IDs (nodes/pods), consumed by terraform/envs/eks/."
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnets
  description = "Public subnet IDs (NAT Gateway/ALB only)."
}
