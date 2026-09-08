# No default for anything environment/security-specific - see
# docs/adr/0012-network-eks-iac-foundation.md's "no invented production
# default" principle and
# .local/evidence/phase-3.2-pod-identity-secrets-manager-iac-plan.md
# S12. Every validation below is a STATIC, offline format/shape check -
# none of them contact AWS, and none can substitute for real validation
# against a live account.

variable "environment" {
  type        = string
  description = "Exactly \"staging\" or \"production\" - never shared, never invented, never a third value."

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be exactly \"staging\" or \"production\"."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region. No default - must be explicitly supplied. Validated only against the static AWS region name shape (e.g. us-east-1) - never checked against a real AWS endpoint or account."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must match the standard AWS region name shape (e.g. us-east-1) - a static format check only."
  }
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (terraform/envs/eks's own cluster_name, passed as an explicit input - no remote state, no data source). No default."

  validation {
    condition     = length(var.cluster_name) > 0 && can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be non-empty, start with a letter, and contain only letters, digits, and hyphens (EKS cluster naming rules)."
  }
}

variable "namespace" {
  type        = string
  description = "Exact Kubernetes namespace the ESO controller pod runs in - ground truth verified live against the cluster (eso-staging / eso-production), never assumed. No default."

  validation {
    condition     = length(var.namespace) > 0 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a non-empty, valid Kubernetes namespace name (RFC 1123 label)."
  }
}

variable "service_account" {
  type        = string
  description = "Exact ServiceAccount name - ground truth verified live against the cluster (eso-staging-external-secrets / eso-production-external-secrets). No default."

  validation {
    condition     = length(var.service_account) > 0 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.service_account))
    error_message = "service_account must be a non-empty, valid Kubernetes ServiceAccount name (RFC 1123 label)."
  }

  validation {
    condition     = !contains(["external-secrets-webhook", "external-secrets-cert-controller"], var.service_account)
    error_message = "service_account must never be the webhook or cert-controller singleton ServiceAccount - neither may ever receive a Pod Identity Association."
  }
}

variable "secret_name" {
  type        = string
  description = "Deterministic Secrets Manager secret name (e.g. eks-gitops-platform-project/staging/backend). No default. Must be a plain name, never a hardcoded ARN."

  validation {
    condition     = length(var.secret_name) > 0 && !can(regex("^arn:", var.secret_name))
    error_message = "secret_name must be a plain secret name, never a hardcoded ARN."
  }
}

variable "kms_deletion_window_in_days" {
  type        = number
  description = "KMS key deletion window in days. AWS-enforced bounds are 7-30; never immediate."
  default     = 30

  validation {
    condition     = var.kms_deletion_window_in_days >= 7 && var.kms_deletion_window_in_days <= 30
    error_message = "kms_deletion_window_in_days must be between 7 and 30 (AWS-enforced bounds)."
  }
}

variable "secret_recovery_window_in_days" {
  type        = number
  description = "Secrets Manager recovery window in days before permanent deletion. AWS-enforced range 7-30; never 0 (immediate deletion) by default."
  default     = 30

  validation {
    condition     = var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30
    error_message = "secret_recovery_window_in_days must be between 7 and 30 (AWS-enforced bounds)."
  }
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, passed through to modules/tags. No default - must be explicitly supplied."

  validation {
    condition     = length(var.owner) > 0
    error_message = "owner must not be empty."
  }
}

variable "project" {
  type        = string
  description = "Project name, passed through to modules/tags and used in resource naming."
  default     = "eks-gitops-platform-project"

  validation {
    condition     = length(var.project) > 0
    error_message = "project must not be empty."
  }
}
