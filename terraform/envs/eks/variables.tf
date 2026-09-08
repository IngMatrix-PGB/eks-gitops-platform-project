# No default for region/network/access/CIDR values - see
# docs/adr/0012-network-eks-iac-foundation.md, "Human Decisions Carried
# as Explicit Variables". vpc_id/private_subnet_ids are taken as
# explicit input here, NOT via a `data "terraform_remote_state"` lookup
# against terraform/envs/network/'s own state - that mechanism needs a
# real backend to exist first (out of scope for this foundation pass,
# which never runs a real init/apply); wiring the two root modules
# together via remote state is deferred to a later, separately
# authorized phase once a real S3 backend is configured.

variable "aws_region" {
  type        = string
  description = "AWS region. No default - must be explicitly supplied."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. Kept short and distinct from var.project - the module's own internal IAM role naming appends a fixed \"-cluster-\" suffix, and IAM role names are capped at 38 characters for the name_prefix portion."
  default     = "eks-gitops-platform"
}

variable "cluster_version" {
  type        = string
  description = "EKS Kubernetes version. Defaulted to the version confirmed in standard support as of 2026-09-05 (docs/adr/0012-network-eks-iac-foundation.md) - re-verify current EKS-supported versions before ever applying this for real; a stale default here would only be caught at real-apply time, not by any offline check."
  default     = "1.36"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (terraform/envs/network/'s vpc_id output). No default - passed explicitly, not via remote state, in this foundation pass."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs (terraform/envs/network/'s private_subnet_ids output). No default."
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the EKS public API endpoint (e.g. the operator's current IP, /32). No default - an unset value must fail closed rather than silently defaulting to 0.0.0.0/0."
}

variable "admin_principal_arn" {
  type        = string
  description = "IAM principal ARN granted day-to-day cluster-admin access via an EKS Access Entry (AmazonEKSClusterAdminPolicy). No default."
}

variable "breakglass_principal_arn" {
  type        = string
  description = "IAM principal ARN granted the same cluster-admin Access Entry, reserved for break-glass use only (see docs/adr/0012-network-eks-iac-foundation.md, S9.1). No default - distinct from admin_principal_arn."
}

variable "node_instance_types" {
  type        = list(string)
  description = "Managed node group instance types. Graviton/ARM64 default (canonical plan S8.2) - a sensible starting default, not a security- or cost-invariant value."
  default     = ["t4g.small"]
}

variable "capacity_type" {
  type        = string
  description = "Managed node group capacity type - SPOT for the lab shape, ON_DEMAND for anything meant to stay up unattended (canonical plan S8.1)."
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.capacity_type)
    error_message = "capacity_type must be exactly \"SPOT\" or \"ON_DEMAND\"."
  }
}

variable "pod_identity_agent_addon_version" {
  type        = string
  description = "Exact EKS Pod Identity Agent add-on version (e.g. \"v1.3.4-eksbuild.1\"). No static version table exists for this add-on - query `aws eks describe-addon-versions --addon-name eks-pod-identity-agent --kubernetes-version <cluster_version>` at real, future, separately authorized deploy time. No default - never most_recent, never a hardcoded guess."

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.pod_identity_agent_addon_version))
    error_message = "pod_identity_agent_addon_version must match the EKS add-on version shape (e.g. v1.3.4-eksbuild.1) - a static format check only, never a real AWS lookup."
  }
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, passed through to modules/tags. No default - must be explicitly supplied."
}

variable "project" {
  type        = string
  description = "Project name, passed through to modules/tags and used as the cluster name prefix."
  default     = "eks-gitops-platform-project"
}
