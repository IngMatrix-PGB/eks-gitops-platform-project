# Reusable child module - no provider, no state, no backend of its own
# (called by a root module, never applied directly). See
# docs/adr/0012-network-eks-iac-foundation.md.

variable "project" {
  type        = string
  description = "Project name, used verbatim as the Project tag value."
}

variable "environment" {
  type        = string
  description = "Environment name - exactly \"staging\", \"production\", or \"shared\" (for account/region-wide resources like the state bucket that are not specific to either workload environment)."

  validation {
    condition     = contains(["staging", "production", "shared"], var.environment)
    error_message = "environment must be exactly \"staging\", \"production\", or \"shared\"."
  }
}

variable "owner" {
  type        = string
  description = "GitHub handle of the resource owner, used verbatim as the Owner tag value. No default - must be explicitly supplied by the calling root module."
}
