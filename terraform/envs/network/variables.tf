# No default for region/CIDR/availability-zones - these are exactly
# the values the canonical plan
# (.local/evidence/phase-2.7-eks-aws-foundation-plan.md, S16) and
# docs/adr/0012-network-eks-iac-foundation.md mark as requiring
# explicit user confirmation, never an invented production default.
#
# availability_zones is a deliberate, explicit list input - this
# module never calls `data "aws_availability_zones"` to derive it
# automatically (an explicit decision preserving the zero-AWS-contact
# offline contract's narrow, unwidened allowlist - see
# scripts/validate/check-terraform-offline.sh check 6b).

variable "aws_region" {
  type        = string
  description = "AWS region. No default - must be explicitly supplied."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC. No default - must be explicitly supplied."
}

variable "availability_zones" {
  type        = list(string)
  description = "Explicit list of availability zone names to use (e.g. [\"us-east-1a\", \"us-east-1b\"]). No default. Never derived from aws_availability_zones."

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required for a highly-available EKS control plane."
  }
}

variable "environment" {
  type        = string
  description = "Which account this VPC is applied in (Phase 3.4.3, ADR-0016): platform (the hub), dev, uat or prod. One state per account."

  validation {
    condition     = contains(["platform", "dev", "uat", "prod"], var.environment)
    error_message = "environment must be exactly platform, dev, uat or prod."
  }
}

variable "single_nat_gateway" {
  type        = bool
  description = "Override the per-environment NAT layout: null (default) means one NAT Gateway per availability zone in prod, and a single shared one elsewhere (lab-cost shape)."
  default     = null
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, passed through to modules/tags. No default - must be explicitly supplied."
}

variable "project" {
  type        = string
  description = "Project name, passed through to modules/tags and used as the VPC name prefix."
  default     = "eks-gitops-platform-project"
}
