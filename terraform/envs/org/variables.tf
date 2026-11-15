# Phase 3.4.1 (docs/adr/0016-aws-organization-and-guardrails.md). Applied
# only with the organization's management-account credentials, which the
# runner supplies - this root has no provider block (offline contract,
# scripts/validate/check-terraform-offline.sh). No default for any value
# that names a real account, mailbox, region set or spend limit.

variable "project" {
  type        = string
  description = "Project name, passed through to modules/tags and used as a name prefix."
  default     = "eks-gitops-platform-project"
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, passed through to modules/tags. No default."
}

variable "allowed_regions" {
  type        = list(string)
  description = "Regions member accounts may use for regional services (modules/scp). No default."

  validation {
    condition     = length(var.allowed_regions) > 0 && alltrue([for r in var.allowed_regions : can(regex("^[a-z]{2}-[a-z]+-[0-9]$", r))])
    error_message = "allowed_regions must be a non-empty list of AWS region names (e.g. us-east-1)."
  }
}

variable "account_emails" {
  type        = map(string)
  description = "Root mailbox of each member account, keyed exactly security, platform, dev, uat, prod. Never committed - supplied at apply time. Each must be unique."

  validation {
    condition     = toset(keys(var.account_emails)) == toset(["security", "platform", "dev", "uat", "prod"])
    error_message = "account_emails must have exactly the keys security, platform, dev, uat and prod."
  }
  validation {
    condition     = alltrue([for e in values(var.account_emails) : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "every account_emails value must be an email address."
  }
  validation {
    condition     = length(distinct(values(var.account_emails))) == length(var.account_emails)
    error_message = "account_emails values must be unique - AWS requires one root mailbox per account."
  }
}

variable "account_access_role_name" {
  type        = string
  description = "Role AWS Organizations creates in every new member account for administration from the management account. Also exempted from the security-services and hardening guardrails, since the account baseline (Phase 3.4.2) is applied through it."
  default     = "OrganizationAccountAccessRole"
}

variable "org_trail_bucket_name" {
  type        = string
  description = "S3 bucket in the security account (terraform/envs/security output org_trail_bucket_name) the organization trail delivers to. Null until envs/security has been applied: the trail is created by a second apply of this root (see the apply order in ADR-0016)."
  default     = null
}

variable "org_trail_kms_key_arn" {
  type        = string
  description = "KMS key in the security account (terraform/envs/security output org_trail_kms_key_arn) that encrypts the trail. Required together with org_trail_bucket_name."
  default     = null

  validation {
    condition     = (var.org_trail_kms_key_arn == null) == (var.org_trail_bucket_name == null)
    error_message = "org_trail_bucket_name and org_trail_kms_key_arn must be set together (both null before envs/security exists)."
  }
}

variable "org_trail_name" {
  type        = string
  description = "Organization trail name - must match the name envs/security scopes its bucket and key policies to."
  default     = "org-trail"
}

variable "monthly_budget_usd" {
  type        = number
  description = "Consolidated monthly cost budget for the whole organization, in USD. No default - an explicit spend decision."

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero."
  }
}

variable "budget_notification_emails" {
  type        = list(string)
  description = "Recipients of the organization budget alerts (80 % and 100 % actual, 100 % forecasted). No default."

  validation {
    condition     = length(var.budget_notification_emails) > 0 && alltrue([for e in var.budget_notification_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "budget_notification_emails must be a non-empty list of email addresses."
  }
}
