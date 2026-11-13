# Minified JSON (jsonencode emits no whitespace) - what AWS measures
# against the 5,120-character service control policy limit.

output "region_guardrail_json" {
  description = "SCP: deny regional actions outside var.allowed_regions (global services exempted)."
  value       = jsonencode(local.region_guardrail)
}

output "security_services_json" {
  description = "SCP: deny disabling or blinding GuardDuty, Config, CloudTrail, Security Hub and IAM Access Analyzer, except for var.exempt_role_names."
  value       = jsonencode(local.security_services)
}

output "member_hardening_json" {
  description = "SCP: deny leaving the organization, any root-user action, and undoing account-level hardening (EBS default encryption, S3 account public access block)."
  value       = jsonencode(local.member_hardening)
}

output "global_actions" {
  description = "The NotAction exemption list of the region guardrail (exposed for tests and documentation)."
  value       = local.global_actions
}

output "security_service_actions" {
  description = "The actions the security-services guardrail denies (exposed for tests and documentation)."
  value       = local.security_service_actions
}
