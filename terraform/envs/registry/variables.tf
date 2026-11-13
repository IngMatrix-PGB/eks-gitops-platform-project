# Phase 3.4.3b (docs/adr/0016-aws-organization-and-guardrails.md). Applied
# only in the platform account (the hub's account), with its own
# credentials. No provider block (offline contract).

variable "project" {
  type        = string
  description = "Project name, passed through to modules/tags and used as the repository name prefix."
  default     = "eks-gitops-platform-project"
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, passed through to modules/tags. No default."
}

variable "repositories" {
  type        = list(string)
  description = "One ECR repository per workload image, named <project>/<name>. No default."

  validation {
    condition     = length(var.repositories) > 0 && alltrue([for r in var.repositories : can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*$", r))])
    error_message = "repositories must be a non-empty list of lowercase ECR name components."
  }
  validation {
    condition     = length(distinct(var.repositories)) == length(var.repositories)
    error_message = "repositories must not repeat a name."
  }
}

variable "organization_id" {
  type        = string
  description = "terraform/envs/org output organization_id - pulls are admitted only from principals in this organization."

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must look like o-xxxxxxxxxx."
  }
}

variable "spoke_account_ids" {
  type        = map(string)
  description = "Account IDs allowed to pull, keyed exactly dev, uat, prod (terraform/envs/org output account_ids). Never committed."

  validation {
    condition     = toset(keys(var.spoke_account_ids)) == toset(["dev", "uat", "prod"])
    error_message = "spoke_account_ids must have exactly the keys dev, uat and prod."
  }
  validation {
    condition     = alltrue([for id in values(var.spoke_account_ids) : can(regex("^[0-9]{12}$", id))])
    error_message = "every spoke_account_ids value must be a 12-digit AWS account ID."
  }
}

variable "untagged_expiry_days" {
  type        = number
  description = "Days an untagged image is kept before the lifecycle policy expires it."
  default     = 7

  validation {
    condition     = var.untagged_expiry_days >= 1
    error_message = "untagged_expiry_days must be at least 1."
  }
}

variable "release_images_to_keep" {
  type        = number
  description = "How many v* release images each repository keeps; older ones expire."
  default     = 30

  validation {
    condition     = var.release_images_to_keep >= 5
    error_message = "release_images_to_keep must be at least 5 (room to roll back)."
  }
}
