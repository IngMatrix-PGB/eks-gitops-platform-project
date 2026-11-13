# Reusable child module - no provider, no state, no resources (Phase
# 3.4.1, docs/adr/0016-aws-organization-and-guardrails.md). It only
# renders service control policy documents as JSON strings with
# jsonencode(), so their exact content is asserted by terraform test
# without any provider (an aws_iam_policy_document data source would be
# replaced by a placeholder under mock_provider and prove nothing).

variable "allowed_regions" {
  type        = list(string)
  description = "Regions where regional services may be used. Global services are exempted by NotAction (see main.tf). No default - an explicit decision."

  validation {
    condition     = length(var.allowed_regions) > 0 && alltrue([for r in var.allowed_regions : can(regex("^[a-z]{2}-[a-z]+-[0-9]$", r))])
    error_message = "allowed_regions must be a non-empty list of AWS region names (e.g. us-east-1)."
  }
}

variable "exempt_role_names" {
  type        = list(string)
  description = "IAM role names (not ARNs - matched in every member account) allowed to change the protected security services and account-level hardening settings, e.g. the role Terraform applies the account baseline with. Never exempted from the root-user and leave-organization denies."

  validation {
    condition     = length(var.exempt_role_names) > 0 && alltrue([for n in var.exempt_role_names : can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", n))])
    error_message = "exempt_role_names must be a non-empty list of valid IAM role names (not ARNs, no wildcards)."
  }
}
