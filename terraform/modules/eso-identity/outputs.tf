# Structural identifiers only - future/not-yet-deployed. Never a
# credential, never a secret payload, never anything an operator could
# read to obtain a value.

output "role_arn" {
  value       = aws_iam_role.eso.arn
  description = "IAM role ARN for this environment's ESO controller."
}

output "role_name" {
  value       = aws_iam_role.eso.name
  description = "IAM role name for this environment's ESO controller."
}

output "association_id" {
  value       = aws_eks_pod_identity_association.this.association_id
  description = "Pod Identity Association ID."
}

output "association_arn" {
  value       = aws_eks_pod_identity_association.this.association_arn
  description = "Pod Identity Association ARN."
}

output "secret_arn" {
  value       = aws_secretsmanager_secret.this.arn
  description = "Secrets Manager secret ARN (metadata only - no payload)."
}

output "secret_name" {
  value       = aws_secretsmanager_secret.this.name
  description = "Secrets Manager secret name."
}

output "kms_key_arn" {
  value       = aws_kms_key.this.arn
  description = "This environment's own KMS key ARN."
}

output "kms_alias" {
  value       = aws_kms_alias.this.name
  description = "This environment's own KMS key alias."
}

# Plain-value (never provider-computed, never mock-replaceable)
# structural facts about the permissions policy this module builds -
# exposed specifically so terraform test can assert on the REAL
# action/resource lists directly, bypassing mock_provider "aws"'s
# blanket replacement of every data "aws_iam_policy_document"'s own
# .json attribute (see main.tf's comment on locals.secrets_manager_
# actions/local.kms_decrypt_actions for why).

output "secretsmanager_actions" {
  value       = local.secrets_manager_actions
  description = "The exact Secrets Manager IAM actions granted to this environment's role - never secretsmanager:*."
}

output "kms_actions" {
  value       = local.kms_decrypt_actions
  description = "The exact KMS IAM actions granted to this environment's role - never kms:*."
}

output "permissions_resource_refs" {
  value       = [aws_secretsmanager_secret.this.arn, aws_kms_key.this.arn]
  description = "The exact resource ARNs the permissions policy is scoped to - always this environment's own Secrets Manager secret and KMS key, never a wildcard, never the other environment's."
}
