output "organization_id" {
  description = "Organization ID - input to terraform/envs/security (bucket and key policies)."
  value       = aws_organizations_organization.this.id
}

output "management_account_id" {
  description = "The organization's management account ID - input to terraform/envs/security (the trail is created here)."
  value       = aws_organizations_organization.this.master_account_id
}

output "root_id" {
  description = "Organization root ID - target of Security Hub's central configuration policy association (envs/security)."
  value       = local.root_id
}

output "organizational_unit_ids" {
  description = "Organizational unit IDs by key (security, platform, nonprod, prod)."
  value       = local.ou_ids
}

output "account_ids" {
  description = "Member account IDs by key (security, platform, dev, uat, prod)."
  value       = { for k, a in aws_organizations_account.this : k => a.id }
}

output "service_control_policy_ids" {
  description = "Service control policy IDs by name."
  value = {
    region_guardrail  = aws_organizations_policy.region_guardrail.id
    member_hardening  = aws_organizations_policy.member_hardening.id
    security_services = aws_organizations_policy.security_services.id
  }
}

output "org_trail_arn" {
  description = "Organization trail ARN, or null before the second apply."
  value       = one(aws_cloudtrail.organization[*].arn)
}
