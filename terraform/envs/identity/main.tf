module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

# Two independent instantiations of the same child module - staging and
# production never share a role, association, Secret, or KMS key by
# construction, since each instantiation creates its own complete
# resource graph. See terraform/modules/eso-identity/main.tf.
module "eso_staging" {
  source = "../../modules/eso-identity"

  environment                    = "staging"
  aws_region                     = var.aws_region
  cluster_name                   = var.cluster_name
  namespace                      = var.staging_namespace
  service_account                = var.staging_service_account
  secret_name                    = var.staging_secret_name
  kms_deletion_window_in_days    = var.kms_deletion_window_in_days
  secret_recovery_window_in_days = var.secret_recovery_window_in_days
  owner                          = var.owner
  project                        = var.project
}

module "eso_production" {
  source = "../../modules/eso-identity"

  environment                    = "production"
  aws_region                     = var.aws_region
  cluster_name                   = var.cluster_name
  namespace                      = var.production_namespace
  service_account                = var.production_service_account
  secret_name                    = var.production_secret_name
  kms_deletion_window_in_days    = var.kms_deletion_window_in_days
  secret_recovery_window_in_days = var.secret_recovery_window_in_days
  owner                          = var.owner
  project                        = var.project
}

# Fail-closed cross-environment invariants a single module instance
# cannot check on its own (each instantiation only sees its own inputs)
# - a human accidentally passing the same namespace/ServiceAccount/
# secret-name to both environments is rejected before either module's
# own resources are even planned.
check "staging_production_never_share_identity" {
  assert {
    condition     = !(var.staging_namespace == var.production_namespace && var.staging_service_account == var.production_service_account)
    error_message = "staging and production must never resolve to the same (namespace, service_account) pair - this would create duplicate Pod Identity Associations."
  }

  assert {
    condition     = var.staging_secret_name != var.production_secret_name
    error_message = "staging and production must never share the same Secrets Manager secret name."
  }
}
