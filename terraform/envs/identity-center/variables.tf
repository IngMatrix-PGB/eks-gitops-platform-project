variable "sso_instance_arn" {
  type        = string
  description = "ARN of the organization's IAM Identity Center instance (in the management account, or its delegated administrator). No default; entered at apply time. A variable, not a data source, so plan never contacts AWS."

  validation {
    condition     = can(regex("^arn:aws:sso:::instance/(sso)?ins-[0-9a-f]{16}$", var.sso_instance_arn))
    error_message = "sso_instance_arn must look like arn:aws:sso:::instance/ssoins-<16 hex>."
  }
}

variable "identity_store_id" {
  type        = string
  description = "ID of the instance's identity store (d-<10 hex>), where the groups are created. No default."

  validation {
    condition     = can(regex("^d-[0-9a-f]{10}$", var.identity_store_id))
    error_message = "identity_store_id must look like d-<10 hex>."
  }
}

variable "account_ids" {
  type        = map(string)
  description = "Member account IDs by key: exactly security, platform, dev, uat and prod (terraform/envs/org output account_ids). No default."

  validation {
    condition     = toset(keys(var.account_ids)) == toset(["security", "platform", "dev", "uat", "prod"]) && alltrue([for id in values(var.account_ids) : can(regex("^[0-9]{12}$", id))])
    error_message = "account_ids must have exactly the keys security, platform, dev, uat and prod, each a 12-digit account ID."
  }
}

variable "eks_cluster_name_prefix" {
  type        = string
  description = "Prefix of the EKS cluster names (terraform/envs/eks: eks-gitops-<environment>). The Developer permission set may describe only clusters with this prefix, to write its kubeconfig."
  default     = "eks-gitops-"

  validation {
    condition     = can(regex("^[a-z0-9-]+-$", var.eks_cluster_name_prefix))
    error_message = "eks_cluster_name_prefix must be lowercase letters, digits and dashes, ending in a dash."
  }
}

# Time-bound elevation (ADR-0025, 4d): each entry is a reviewed pull
# request that grants one group one permission set in one account for at
# most 8 hours. elevations.auto.tfvars.json holds the list;
# `make check-elevations` (in validate, so in CI) fails once an entry has
# expired, so stale access cannot stay in main. Removing it from AWS is
# the next apply.
variable "elevations" {
  type = list(object({
    group          = string
    permission_set = string
    account        = string
    starts_at      = string
    expires_at     = string
    reason         = string
  }))
  description = "Time-bound grants beyond the standing assignments. Empty when nobody is elevated."
  default     = []

  validation {
    condition = alltrue([for e in var.elevations :
      contains(["platform-admins", "developers-dev", "developers-uat", "auditors", "breakglass"], e.group) &&
      contains(["PlatformAdmin", "Developer", "ReadOnly", "BreakGlass"], e.permission_set) &&
      contains(["security", "platform", "dev", "uat", "prod"], e.account)
    ])
    error_message = "Each elevation names a group, a permission set and an account this root defines."
  }

  validation {
    condition = alltrue([for e in var.elevations :
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", e.starts_at)) &&
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", e.expires_at)) &&
      try(timecmp(e.starts_at, e.expires_at) < 0, false)
    ])
    error_message = "Each elevation needs starts_at and expires_at as UTC times like 2026-11-25T14:00:00Z (the form make check-elevations reads), with starts_at before expires_at. An elevation without an expiry is refused."
  }

  validation {
    condition = alltrue([for e in var.elevations :
      try(timecmp(e.expires_at, timeadd(e.starts_at, "8h")) <= 0, false)
    ])
    error_message = "An elevation lasts at most 8 hours."
  }

  validation {
    condition     = alltrue([for e in var.elevations : length(trimspace(e.reason)) >= 10])
    error_message = "Each elevation states its reason (at least 10 characters)."
  }

  validation {
    condition     = length(var.elevations) == length(distinct([for e in var.elevations : "${e.group}/${e.permission_set}/${e.account}"]))
    error_message = "At most one elevation per group, permission set and account."
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
  description = "Project name, passed through to modules/tags."
  default     = "eks-gitops-platform-project"
}
