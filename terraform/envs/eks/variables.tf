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

variable "environment" {
  type        = string
  description = "Which account this cluster is applied in (Phase 3.4.3, ADR-0016): platform (the hub), dev, uat or prod. One state per account."

  validation {
    condition     = contains(["platform", "dev", "uat", "prod"], var.environment)
    error_message = "environment must be exactly platform, dev, uat or prod."
  }
}

variable "cluster_name" {
  type        = string
  description = "Override of the cluster name; null (default) means eks-gitops-<environment>. Kept short - the module's IAM role naming appends a fixed \"-cluster-\" suffix and name prefixes are capped at 38 characters."
  default     = null

  validation {
    condition     = var.cluster_name == null || can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,24}$", var.cluster_name))
    error_message = "cluster_name must start with a letter and be at most 25 characters (letters, digits, hyphens)."
  }
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
  description = "System node group capacity type; null (default) means ON_DEMAND in prod and SPOT elsewhere (canonical plan S8.1)."
  default     = null

  validation {
    condition     = var.capacity_type == null || contains(["SPOT", "ON_DEMAND"], coalesce(var.capacity_type, "SPOT"))
    error_message = "capacity_type must be exactly \"SPOT\" or \"ON_DEMAND\" (or null for the per-environment default)."
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

variable "vpc_cni_addon_version" {
  type        = string
  description = "Exact Amazon VPC CNI add-on version (e.g. \"v1.2.3-eksbuild.1\"). Query `aws eks describe-addon-versions --addon-name vpc-cni --kubernetes-version <cluster_version>` at real, separately authorized deploy time. No default - never most_recent, never a guess."

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.vpc_cni_addon_version))
    error_message = "vpc_cni_addon_version must match the EKS add-on version shape (e.g. v1.2.3-eksbuild.1) - a static format check only."
  }
}

variable "coredns_addon_version" {
  type        = string
  description = "Exact CoreDNS add-on version (e.g. \"v1.2.3-eksbuild.1\"). Query `aws eks describe-addon-versions --addon-name coredns --kubernetes-version <cluster_version>` at real, separately authorized deploy time. No default - never most_recent, never a guess."

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.coredns_addon_version))
    error_message = "coredns_addon_version must match the EKS add-on version shape (e.g. v1.2.3-eksbuild.1) - a static format check only."
  }
}

variable "kube_proxy_addon_version" {
  type        = string
  description = "Exact kube-proxy add-on version (e.g. \"v1.2.3-eksbuild.1\"). Query `aws eks describe-addon-versions --addon-name kube-proxy --kubernetes-version <cluster_version>` at real, separately authorized deploy time. No default - never most_recent, never a guess."

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.kube_proxy_addon_version))
    error_message = "kube_proxy_addon_version must match the EKS add-on version shape (e.g. v1.2.3-eksbuild.1) - a static format check only."
  }
}

variable "metrics_server_addon_version" {
  type        = string
  description = "Exact metrics-server (EKS community add-on) add-on version (e.g. \"v1.2.3-eksbuild.1\"). Query `aws eks describe-addon-versions --addon-name metrics-server --kubernetes-version <cluster_version>` at real, separately authorized deploy time. No default - never most_recent, never a guess."

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.metrics_server_addon_version))
    error_message = "metrics_server_addon_version must match the EKS add-on version shape (e.g. v1.2.3-eksbuild.1) - a static format check only."
  }
}

# --- Phase 3.4.4a: hub-to-spoke Argo CD identity (TAD R-05) ------------------
variable "hub_account_id" {
  type        = string
  description = "Spokes only: the platform (hub) account ID - the only account whose Argo CD role may assume this spoke's argocd-manager role. Never committed; supplied at apply time."
  default     = null

  validation {
    condition     = var.hub_account_id == null || can(regex("^[0-9]{12}$", coalesce(var.hub_account_id, "x")))
    error_message = "hub_account_id must be a 12-digit AWS account ID."
  }
  validation {
    condition     = var.environment == "platform" || var.hub_account_id != null
    error_message = "A spoke (dev, uat, prod) needs hub_account_id so the hub's Argo CD can reach it."
  }
}

variable "spoke_account_ids" {
  type        = map(string)
  description = "Hub only: the dev, uat and prod account IDs whose argocd-manager roles the hub's Argo CD may assume. Never committed; supplied at apply time."
  default     = null

  validation {
    condition     = var.spoke_account_ids == null || try(toset(keys(var.spoke_account_ids)) == toset(["dev", "uat", "prod"]) && alltrue([for id in values(var.spoke_account_ids) : can(regex("^[0-9]{12}$", id))]), false)
    error_message = "spoke_account_ids must have exactly the keys dev, uat and prod, each a 12-digit AWS account ID."
  }
  validation {
    condition     = var.environment != "platform" || var.spoke_account_ids != null
    error_message = "The hub (platform) needs spoke_account_ids to know which spoke roles its Argo CD may assume."
  }
}
