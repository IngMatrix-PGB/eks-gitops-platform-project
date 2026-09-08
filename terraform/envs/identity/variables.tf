# No default for region/cluster name/owner - explicit human decisions,
# never invented (docs/adr/0012-network-eks-iac-foundation.md). The
# namespace/ServiceAccount defaults below are a deliberate, narrow
# exception: they are not a security/cost decision but an already-
# fixed, already-deployed fact, verified live against the running
# cluster (.local/evidence/phase-3.2-pod-identity-secrets-manager-iac-
# plan.md S5) - still fully overridable, never hardcoded inline in a
# resource block. cluster_name/vpc_id/private_subnet_ids are NOT
# resolved via a `data "terraform_remote_state"` lookup against
# terraform/envs/eks's or terraform/envs/network's own state - that
# mechanism needs a real backend to exist first, deferred to a later,
# separately authorized phase, exactly matching the precedent already
# established between envs/network and envs/eks.

variable "aws_region" {
  type        = string
  description = "AWS region. No default - must be explicitly supplied. Validated only against the static AWS region name shape - never checked against a real AWS endpoint."

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must match the standard AWS region name shape (e.g. us-east-1) - a static format check only."
  }
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (terraform/envs/eks's own cluster_name, passed explicitly). No default."

  validation {
    condition     = length(var.cluster_name) > 0 && can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be non-empty and match EKS cluster naming rules."
  }
}

variable "staging_namespace" {
  type        = string
  description = "Staging ESO controller pod namespace - ground truth verified live against the cluster."
  default     = "eso-staging"
}

variable "staging_service_account" {
  type        = string
  description = "Staging ESO controller ServiceAccount - ground truth verified live against the cluster."
  default     = "eso-staging-external-secrets"
}

variable "production_namespace" {
  type        = string
  description = "Production ESO controller pod namespace - ground truth verified live against the cluster."
  default     = "eso-production"
}

variable "production_service_account" {
  type        = string
  description = "Production ESO controller ServiceAccount - ground truth verified live against the cluster."
  default     = "eso-production-external-secrets"
}

variable "staging_secret_name" {
  type        = string
  description = "Staging Secrets Manager secret name (a naming-convention decision, not a security/cost value)."
  default     = "eks-gitops-platform-project/staging/backend"
}

variable "production_secret_name" {
  type        = string
  description = "Production Secrets Manager secret name."
  default     = "eks-gitops-platform-project/production/backend"
}

variable "kms_deletion_window_in_days" {
  type        = number
  description = "KMS key deletion window in days for both environments. AWS-enforced bounds 7-30."
  default     = 30
}

variable "secret_recovery_window_in_days" {
  type        = number
  description = "Secrets Manager recovery window in days for both environments. AWS-enforced bounds 7-30."
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
