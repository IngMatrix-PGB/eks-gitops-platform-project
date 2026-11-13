# Phase 3.4.2 (docs/adr/0016-aws-organization-and-guardrails.md,
# amendment). Applied once per member account, with that account's
# credentials, through the account access role - the only principal the
# hardening and security-services guardrails exempt. No provider block
# (offline contract): regional resources use the per-resource `region`
# argument of hashicorp/aws 6.x instead of provider aliases.

variable "project" {
  type        = string
  description = "Project name, passed through to modules/tags and used as a name prefix."
  default     = "eks-gitops-platform-project"
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, passed through to modules/tags. No default."
}

variable "account_role" {
  type        = string
  description = "Which member account this apply targets - one of the keys of terraform/envs/org's account_ids output."

  validation {
    condition     = contains(["security", "platform", "dev", "uat", "prod"], var.account_role)
    error_message = "account_role must be exactly security, platform, dev, uat or prod."
  }
}

variable "allowed_regions" {
  type        = list(string)
  description = "The same list as terraform/envs/org's allowed_regions: every regional control is applied in each of them. No default."

  validation {
    condition     = length(var.allowed_regions) > 0 && alltrue([for r in var.allowed_regions : can(regex("^[a-z]{2}-[a-z]+-[0-9]$", r))])
    error_message = "allowed_regions must be a non-empty list of AWS region names."
  }
}

variable "home_region" {
  type        = string
  description = "The one region that also records the global IAM resource types (so they are recorded once). Must be in allowed_regions."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.home_region))
    error_message = "home_region must be an AWS region name."
  }
}

variable "config_bucket_name" {
  type        = string
  description = "terraform/envs/security output config_bucket_name."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.config_bucket_name))
    error_message = "config_bucket_name must be a valid S3 bucket name."
  }
}

variable "config_kms_key_arn" {
  type        = string
  description = "terraform/envs/security output config_kms_key_arn."

  validation {
    condition     = can(regex("^arn:aws:kms:[a-z]{2}-[a-z]+-[0-9]:[^:]+:key/.+$", var.config_kms_key_arn))
    error_message = "config_kms_key_arn must be a KMS key ARN."
  }
}

variable "monthly_budget_usd" {
  type        = number
  description = "This account's monthly cost budget in USD. No default - an explicit spend decision per account."

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero."
  }
}

variable "budget_notification_emails" {
  type        = list(string)
  description = "Recipients of this account's budget alerts. No default."

  validation {
    condition     = length(var.budget_notification_emails) > 0 && alltrue([for e in var.budget_notification_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "budget_notification_emails must be a non-empty list of email addresses."
  }
}
