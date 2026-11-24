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

output "nat_public_ips" {
  value       = module.vpc.nat_public_ips
  description = "Public IPs of the NAT Gateways. Phase 6.4a: the hub's NAT IP is added to the spoke's eks_public_access_cidrs, so the hub's Argo CD can reach the spoke's API endpoint."
}
