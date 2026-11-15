output "org_trail_bucket_name" {
  description = "Input org_trail_bucket_name of terraform/envs/org's second apply."
  value       = aws_s3_bucket.org_trail.bucket
}

output "org_trail_kms_key_arn" {
  description = "Input org_trail_kms_key_arn of terraform/envs/org's second apply."
  value       = aws_kms_key.org_trail.arn
}

output "guardduty_detector_id" {
  description = "Delegated-administrator GuardDuty detector."
  value       = aws_guardduty_detector.this.id
}

output "securityhub_configuration_policy_id" {
  description = "Security Hub central configuration policy associated with the organization root."
  value       = aws_securityhub_configuration_policy.organization.id
}

output "config_aggregator_arn" {
  description = "Organization-wide AWS Config aggregator."
  value       = aws_config_configuration_aggregator.organization.arn
}

output "access_analyzer_arn" {
  description = "Organization-scoped IAM Access Analyzer."
  value       = aws_accessanalyzer_analyzer.organization.arn
}

output "config_bucket_name" {
  description = "Central AWS Config bucket - input config_bucket_name of terraform/envs/account-baseline."
  value       = aws_s3_bucket.config.bucket
}

output "config_kms_key_arn" {
  description = "Key encrypting the Config deliveries - input config_kms_key_arn of terraform/envs/account-baseline."
  value       = aws_kms_key.config.arn
}
