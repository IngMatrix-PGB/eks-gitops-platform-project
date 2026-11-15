# Phase 3.4.3c - the one source of the per-environment ESO identity
# contract: each spoke's ESO controller namespace and ServiceAccount (the
# lab's scoped release, Phase 2.6/2.7.4) and its Secrets Manager secret
# name. Terraform reads the entry for var.environment;
# scripts/validate/check-standard-workload-chart.sh reads this same block
# to cross-validate the aws-eks overlays (values-<env>-aws.yaml), so the
# two can never drift apart.
#
# LAYOUT IS PARSED BY THAT CHECK: keep exactly one environment per line,
# in the form
#   <env> = { namespace = "...", service_account = "...", secret_name = "..." }
# The check fails loudly if it does not find exactly dev, uat and prod.
#
# A variable (not a local) only so a test can feed a colliding table to
# the cross-environment check below; it is never meant to be overridden
# at apply time.

variable "environment_identities" {
  type = map(object({
    namespace       = string
    service_account = string
    secret_name     = string
  }))
  description = "Per-environment ESO identity contract (namespace, ServiceAccount, Secrets Manager secret name). See the layout note above."

  default = {
    dev  = { namespace = "eso-dev", service_account = "eso-dev-external-secrets", secret_name = "eks-gitops-platform-project/dev/backend" }
    uat  = { namespace = "eso-uat", service_account = "eso-uat-external-secrets", secret_name = "eks-gitops-platform-project/uat/backend" }
    prod = { namespace = "eso-prod", service_account = "eso-prod-external-secrets", secret_name = "eks-gitops-platform-project/prod/backend" }
  }

  validation {
    condition     = toset(keys(var.environment_identities)) == toset(["dev", "uat", "prod"])
    error_message = "environment_identities must have exactly the keys dev, uat and prod."
  }
}

# The table still names all three environments, so no two of them may
# share a Secrets Manager secret name or a (namespace, ServiceAccount)
# pair - even though each account applies only its own entry.
check "environments_never_share_identity" {
  assert {
    condition     = length(distinct([for e in values(var.environment_identities) : e.secret_name])) == length(var.environment_identities)
    error_message = "Two environments in environment_identities share a Secrets Manager secret name."
  }

  assert {
    condition     = length(distinct([for e in values(var.environment_identities) : "${e.namespace}/${e.service_account}"])) == length(var.environment_identities)
    error_message = "Two environments in environment_identities share the same (namespace, service_account) pair."
  }
}
