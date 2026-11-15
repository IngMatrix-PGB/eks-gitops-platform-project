module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = var.environment
  owner       = var.owner
}

locals {
  identity     = var.environment_identities[var.environment]
  cluster_name = coalesce(var.cluster_name, "eks-gitops-${var.environment}")
}

# Phase 3.4.3c: one instance per spoke account (ADR-0016) - the account
# boundary, not three side-by-side instances in one cluster, now keeps
# dev, uat and prod apart. The child module creates this environment's
# complete identity graph: role, scoped inline policy, KMS key and alias,
# secret and its resource policy, Pod Identity association. See
# terraform/modules/eso-identity/main.tf.
module "eso" {
  source = "../../modules/eso-identity"

  environment                    = var.environment
  aws_region                     = var.aws_region
  cluster_name                   = local.cluster_name
  namespace                      = local.identity.namespace
  service_account                = local.identity.service_account
  secret_name                    = local.identity.secret_name
  kms_deletion_window_in_days    = var.kms_deletion_window_in_days
  secret_recovery_window_in_days = var.secret_recovery_window_in_days
  owner                          = var.owner
  project                        = var.project
}
