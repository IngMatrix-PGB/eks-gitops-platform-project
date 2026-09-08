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

variable "single_nat_gateway" {
  type        = bool
  description = "Use a single, shared NAT Gateway (lab-cost default, canonical plan S7.1 estimate A/B) instead of one per AZ (S7.2 estimate C, closer-to-production shape). A sensible starting default, not a security- or cost-invariant value, so it MAY default (unlike region/CIDR/AZs)."
  default     = true
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
