# No default for anything region/naming-specific - see
# docs/adr/0012-network-eks-iac-foundation.md, "Human Decisions Carried
# as Explicit Variables": these are exactly the values the canonical
# plan (.local/evidence/phase-2.7-eks-aws-foundation-plan.md, S16)
# marks as requiring explicit user confirmation, never an invented
# production default.

variable "aws_region" {
  type        = string
  description = "AWS region the Terraform state bucket is created in. No default - must be explicitly supplied."
}

variable "state_bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for Terraform state. No default - must be explicitly supplied."
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, passed through to modules/tags. No default - must be explicitly supplied."
}

variable "project" {
  type        = string
  description = "Project name, passed through to modules/tags."
  default     = "eks-gitops-platform-project"
}
