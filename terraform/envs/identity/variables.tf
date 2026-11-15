# No default for region/owner - explicit human decisions, never invented
# (docs/adr/0012-network-eks-iac-foundation.md). Phase 3.4.3c: one apply
# per spoke account; the per-environment namespace/ServiceAccount/secret
# name live in environments.tf (one table, also read by
# check-standard-workload-chart.sh). cluster_name is derived the same way
# terraform/envs/eks derives it - never read from that root's state,
# which would need a real backend (deferred, as between envs/network and
# envs/eks).

variable "aws_region" {
  type        = string
  description = "AWS region. No default - must be explicitly supplied. Validated only against the static AWS region name shape - never checked against a real AWS endpoint."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must match the standard AWS region name shape (e.g. us-east-1) - a static format check only."
  }
}

variable "environment" {
  type        = string
  description = "Which spoke account this apply targets (Phase 3.4.3c, ADR-0016): dev, uat or prod. One state per account; never applied in the platform (hub) account."

  validation {
    condition     = contains(["dev", "uat", "prod"], var.environment)
    error_message = "environment must be exactly dev, uat or prod - the hub (platform) gets no ESO workload identity here."
  }
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster the Pod Identity association targets. Null (default) means eks-gitops-<environment>, the same name terraform/envs/eks derives."
  default     = null

  validation {
    condition     = var.cluster_name == null || can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,99}$", coalesce(var.cluster_name, "x")))
    error_message = "cluster_name must match EKS cluster naming rules."
  }
}

variable "kms_deletion_window_in_days" {
  type        = number
  description = "KMS key deletion window in days. AWS-enforced bounds 7-30."
  default     = 30
}

variable "secret_recovery_window_in_days" {
  type        = number
  description = "Secrets Manager recovery window in days. AWS-enforced bounds 7-30."
  default     = 30
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
}
