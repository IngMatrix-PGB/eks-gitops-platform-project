module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

# Three independent instantiations of the same child module - dev, uat,
# and prod never share a role, association, Secret, or KMS key by
# construction, since each instantiation creates its own complete
# resource graph. See terraform/modules/eso-identity/main.tf. This root
# still models every environment in one cluster; the per-account split
# of ADR-0015 is Phase 3.4.
module "eso_dev" {
  source = "../../modules/eso-identity"

  environment                    = "dev"
  aws_region                     = var.aws_region
  cluster_name                   = var.cluster_name
  namespace                      = var.dev_namespace
  service_account                = var.dev_service_account
  secret_name                    = var.dev_secret_name
  kms_deletion_window_in_days    = var.kms_deletion_window_in_days
  secret_recovery_window_in_days = var.secret_recovery_window_in_days
  owner                          = var.owner
  project                        = var.project
}

module "eso_uat" {
  source = "../../modules/eso-identity"

  environment                    = "uat"
  aws_region                     = var.aws_region
  cluster_name                   = var.cluster_name
  namespace                      = var.uat_namespace
  service_account                = var.uat_service_account
  secret_name                    = var.uat_secret_name
  kms_deletion_window_in_days    = var.kms_deletion_window_in_days
  secret_recovery_window_in_days = var.secret_recovery_window_in_days
  owner                          = var.owner
  project                        = var.project
}

module "eso_prod" {
  source = "../../modules/eso-identity"

  environment                    = "prod"
  aws_region                     = var.aws_region
  cluster_name                   = var.cluster_name
  namespace                      = var.prod_namespace
  service_account                = var.prod_service_account
  secret_name                    = var.prod_secret_name
  kms_deletion_window_in_days    = var.kms_deletion_window_in_days
  secret_recovery_window_in_days = var.secret_recovery_window_in_days
  owner                          = var.owner
  project                        = var.project
}

# Fail-closed cross-environment invariants a single module instance
# cannot check on its own (each instantiation only sees its own inputs)
# - a human accidentally passing the same namespace/ServiceAccount/
# secret-name to two environments is rejected before any module's own
# resources are even planned. Checked for every pair.
check "environments_never_share_identity" {
  assert {
    condition     = !(var.dev_namespace == var.uat_namespace && var.dev_service_account == var.uat_service_account)
    error_message = "dev and uat must never resolve to the same (namespace, service_account) pair - this would create duplicate Pod Identity Associations."
  }

  assert {
    condition     = var.dev_secret_name != var.uat_secret_name
    error_message = "dev and uat must never share the same Secrets Manager secret name."
  }

  assert {
    condition     = !(var.dev_namespace == var.prod_namespace && var.dev_service_account == var.prod_service_account)
    error_message = "dev and prod must never resolve to the same (namespace, service_account) pair - this would create duplicate Pod Identity Associations."
  }

  assert {
    condition     = var.dev_secret_name != var.prod_secret_name
    error_message = "dev and prod must never share the same Secrets Manager secret name."
  }

  assert {
    condition     = !(var.uat_namespace == var.prod_namespace && var.uat_service_account == var.prod_service_account)
    error_message = "uat and prod must never resolve to the same (namespace, service_account) pair - this would create duplicate Pod Identity Associations."
  }

  assert {
    condition     = var.uat_secret_name != var.prod_secret_name
    error_message = "uat and prod must never share the same Secrets Manager secret name."
  }
}
