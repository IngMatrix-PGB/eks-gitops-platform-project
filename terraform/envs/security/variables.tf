# Phase 3.4.1 (docs/adr/0016-aws-organization-and-guardrails.md). Applied
# only with the security account's credentials (the delegated
# administrator), after terraform/envs/org's first apply. No provider
# block - credentials come from the runner (offline contract).

variable "project" {
  type        = string
  description = "Project name, passed through to modules/tags and used as a name prefix."
  default     = "eks-gitops-platform-project"
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, passed through to modules/tags. No default."
}

variable "aws_region" {
  type        = string
  description = "Home region of the organization trail and of the security tooling. No default."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must match the AWS region name shape (e.g. us-east-1)."
  }
}

variable "aggregated_regions" {
  type        = list(string)
  description = "Regions the Config aggregator collects from - the same list as envs/org's allowed_regions. No default."

  validation {
    condition     = length(var.aggregated_regions) > 0 && alltrue([for r in var.aggregated_regions : can(regex("^[a-z]{2}-[a-z]+-[0-9]$", r))])
    error_message = "aggregated_regions must be a non-empty list of AWS region names."
  }
}

variable "organization_id" {
  type        = string
  description = "terraform/envs/org output organization_id."

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must look like o-xxxxxxxxxx."
  }
}

variable "organization_root_id" {
  type        = string
  description = "terraform/envs/org output root_id - target of the Security Hub central configuration policy."

  validation {
    condition     = can(regex("^r-[0-9a-z]{4,32}$", var.organization_root_id))
    error_message = "organization_root_id must look like r-xxxx."
  }
}

variable "management_account_id" {
  type        = string
  description = "terraform/envs/org output management_account_id - the account the organization trail is created in."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "org_trail_name" {
  type        = string
  description = "Must equal envs/org's org_trail_name - the bucket and key policies only admit that one trail."
  default     = "org-trail"
}

variable "trail_log_retention_days" {
  type        = number
  description = "Days the organization trail's log objects are kept before expiry."
  default     = 365

  validation {
    condition     = var.trail_log_retention_days >= 90
    error_message = "trail_log_retention_days must be at least 90."
  }
}
