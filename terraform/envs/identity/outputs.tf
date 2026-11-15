# Structural identifiers only - future/not-yet-deployed. Never a
# credential, never a secret payload. Phase 3.4.3c: one environment per
# state, so the outputs are no longer prefixed by environment.

output "environment" {
  value       = var.environment
  description = "The spoke this state belongs to."
}

output "cluster_name" {
  value       = local.cluster_name
  description = "Cluster the Pod Identity association targets."
}

output "role_arn" {
  value       = module.eso.role_arn
  description = "ESO controller IAM role ARN."
}

output "association_id" {
  value       = module.eso.association_id
  description = "Pod Identity Association ID."
}

output "secret_arn" {
  value       = module.eso.secret_arn
  description = "Secrets Manager secret ARN (metadata only - no payload)."
}

output "secret_name" {
  value       = module.eso.secret_name
  description = "Secrets Manager secret name."
}

output "kms_key_arn" {
  value       = module.eso.kms_key_arn
  description = "KMS key ARN."
}

output "kms_alias" {
  value       = module.eso.kms_alias
  description = "KMS key alias."
}

output "secretsmanager_actions" {
  value       = module.eso.secretsmanager_actions
  description = "The exact Secrets Manager IAM actions granted - never secretsmanager:*."
}

output "kms_actions" {
  value       = module.eso.kms_actions
  description = "The exact KMS IAM actions granted - never kms:*."
}

output "permissions_resource_refs" {
  value       = module.eso.permissions_resource_refs
  description = "The exact resource ARNs the permissions policy is scoped to - this environment's own secret and key only."
}
