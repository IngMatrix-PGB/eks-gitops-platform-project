# Structural identifiers only - future/not-yet-deployed. Never a
# credential, never a secret payload.

output "staging_role_arn" {
  value       = module.eso_staging.role_arn
  description = "Staging ESO controller IAM role ARN."
}

output "staging_association_id" {
  value       = module.eso_staging.association_id
  description = "Staging Pod Identity Association ID."
}

output "staging_secret_arn" {
  value       = module.eso_staging.secret_arn
  description = "Staging Secrets Manager secret ARN (metadata only - no payload)."
}

output "staging_secret_name" {
  value       = module.eso_staging.secret_name
  description = "Staging Secrets Manager secret name."
}

output "staging_kms_key_arn" {
  value       = module.eso_staging.kms_key_arn
  description = "Staging KMS key ARN."
}

output "staging_kms_alias" {
  value       = module.eso_staging.kms_alias
  description = "Staging KMS key alias."
}

output "staging_secretsmanager_actions" {
  value       = module.eso_staging.secretsmanager_actions
  description = "Staging's exact Secrets Manager IAM actions - never secretsmanager:*."
}

output "staging_kms_actions" {
  value       = module.eso_staging.kms_actions
  description = "Staging's exact KMS IAM actions - never kms:*."
}

output "staging_permissions_resource_refs" {
  value       = module.eso_staging.permissions_resource_refs
  description = "Staging's exact policy resource ARNs - never a wildcard, never production's."
}

output "production_role_arn" {
  value       = module.eso_production.role_arn
  description = "Production ESO controller IAM role ARN."
}

output "production_association_id" {
  value       = module.eso_production.association_id
  description = "Production Pod Identity Association ID."
}

output "production_secret_arn" {
  value       = module.eso_production.secret_arn
  description = "Production Secrets Manager secret ARN (metadata only - no payload)."
}

output "production_secret_name" {
  value       = module.eso_production.secret_name
  description = "Production Secrets Manager secret name."
}

output "production_kms_key_arn" {
  value       = module.eso_production.kms_key_arn
  description = "Production KMS key ARN."
}

output "production_kms_alias" {
  value       = module.eso_production.kms_alias
  description = "Production KMS key alias."
}

output "production_secretsmanager_actions" {
  value       = module.eso_production.secretsmanager_actions
  description = "Production's exact Secrets Manager IAM actions - never secretsmanager:*."
}

output "production_kms_actions" {
  value       = module.eso_production.kms_actions
  description = "Production's exact KMS IAM actions - never kms:*."
}

output "production_permissions_resource_refs" {
  value       = module.eso_production.permissions_resource_refs
  description = "Production's exact policy resource ARNs - never a wildcard, never staging's."
}
