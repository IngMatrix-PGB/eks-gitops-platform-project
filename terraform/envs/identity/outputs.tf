# Structural identifiers only - future/not-yet-deployed. Never a
# credential, never a secret payload.

output "dev_role_arn" {
  value       = module.eso_dev.role_arn
  description = "Dev ESO controller IAM role ARN."
}

output "dev_association_id" {
  value       = module.eso_dev.association_id
  description = "Dev Pod Identity Association ID."
}

output "dev_secret_arn" {
  value       = module.eso_dev.secret_arn
  description = "Dev Secrets Manager secret ARN (metadata only - no payload)."
}

output "dev_secret_name" {
  value       = module.eso_dev.secret_name
  description = "Dev Secrets Manager secret name."
}

output "dev_kms_key_arn" {
  value       = module.eso_dev.kms_key_arn
  description = "Dev KMS key ARN."
}

output "dev_kms_alias" {
  value       = module.eso_dev.kms_alias
  description = "Dev KMS key alias."
}

output "dev_secretsmanager_actions" {
  value       = module.eso_dev.secretsmanager_actions
  description = "Dev's exact Secrets Manager IAM actions - never secretsmanager:*."
}

output "dev_kms_actions" {
  value       = module.eso_dev.kms_actions
  description = "Dev's exact KMS IAM actions - never kms:*."
}

output "dev_permissions_resource_refs" {
  value       = module.eso_dev.permissions_resource_refs
  description = "Dev's exact policy resource ARNs - never a wildcard, never another environment's."
}

output "uat_role_arn" {
  value       = module.eso_uat.role_arn
  description = "UAT ESO controller IAM role ARN."
}

output "uat_association_id" {
  value       = module.eso_uat.association_id
  description = "UAT Pod Identity Association ID."
}

output "uat_secret_arn" {
  value       = module.eso_uat.secret_arn
  description = "UAT Secrets Manager secret ARN (metadata only - no payload)."
}

output "uat_secret_name" {
  value       = module.eso_uat.secret_name
  description = "UAT Secrets Manager secret name."
}

output "uat_kms_key_arn" {
  value       = module.eso_uat.kms_key_arn
  description = "UAT KMS key ARN."
}

output "uat_kms_alias" {
  value       = module.eso_uat.kms_alias
  description = "UAT KMS key alias."
}

output "uat_secretsmanager_actions" {
  value       = module.eso_uat.secretsmanager_actions
  description = "UAT's exact Secrets Manager IAM actions - never secretsmanager:*."
}

output "uat_kms_actions" {
  value       = module.eso_uat.kms_actions
  description = "UAT's exact KMS IAM actions - never kms:*."
}

output "uat_permissions_resource_refs" {
  value       = module.eso_uat.permissions_resource_refs
  description = "UAT's exact policy resource ARNs - never a wildcard, never another environment's."
}

output "prod_role_arn" {
  value       = module.eso_prod.role_arn
  description = "Prod ESO controller IAM role ARN."
}

output "prod_association_id" {
  value       = module.eso_prod.association_id
  description = "Prod Pod Identity Association ID."
}

output "prod_secret_arn" {
  value       = module.eso_prod.secret_arn
  description = "Prod Secrets Manager secret ARN (metadata only - no payload)."
}

output "prod_secret_name" {
  value       = module.eso_prod.secret_name
  description = "Prod Secrets Manager secret name."
}

output "prod_kms_key_arn" {
  value       = module.eso_prod.kms_key_arn
  description = "Prod KMS key ARN."
}

output "prod_kms_alias" {
  value       = module.eso_prod.kms_alias
  description = "Prod KMS key alias."
}

output "prod_secretsmanager_actions" {
  value       = module.eso_prod.secretsmanager_actions
  description = "Prod's exact Secrets Manager IAM actions - never secretsmanager:*."
}

output "prod_kms_actions" {
  value       = module.eso_prod.kms_actions
  description = "Prod's exact KMS IAM actions - never kms:*."
}

output "prod_permissions_resource_refs" {
  value       = module.eso_prod.permissions_resource_refs
  description = "Prod's exact policy resource ARNs - never a wildcard, never another environment's."
}
