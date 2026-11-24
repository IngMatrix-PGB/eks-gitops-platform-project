variable "aws_region" {
  type        = string
  description = "Region of the session. Budgets are global; kept so every session root takes the same inputs."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like an AWS region (e.g. us-east-1)."
  }
}

variable "monthly_budget_usd" {
  type        = number
  description = "The sandbox account's monthly cost budget in USD. No default - an explicit spend decision (ADR-0024 proposes 20)."

  validation {
    condition     = var.monthly_budget_usd > 0 && var.monthly_budget_usd <= 100
    error_message = "monthly_budget_usd must be greater than 0 and at most 100 - a sandbox session, not a running platform."
  }
}

variable "budget_notification_emails" {
  type        = list(string)
  description = "Recipients of the budget alerts. No default; entered at apply time, never committed."

  validation {
    condition     = length(var.budget_notification_emails) > 0 && alltrue([for e in var.budget_notification_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "budget_notification_emails must be a non-empty list of email addresses."
  }
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, passed through to modules/tags. No default."

  validation {
    condition     = length(var.owner) > 0
    error_message = "owner must not be empty."
  }
}

variable "project" {
  type        = string
  description = "Project name, passed through to modules/tags and used in the budget name."
  default     = "eks-gitops-platform-project"
}
