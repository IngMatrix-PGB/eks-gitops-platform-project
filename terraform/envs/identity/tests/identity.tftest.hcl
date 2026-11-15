# Structural correctness only (Phase 3.2, rewritten for one spoke per
# state in Phase 3.4.3c). mock_provider "aws" proves this configuration's
# own logic - the right per-environment identity, a policy scoped to this
# environment's own secret and key, the cross-environment uniqueness of
# the contract table, and the child module's guards - against fabricated
# values. It proves NOTHING about a real apply (quota, propagation, real
# IAM simulation), which this repository never runs. `command = apply` is
# a simulated terraform-test run against the mocked provider.
#
# data "aws_iam_policy_document" renders client-side even under a real
# provider, but mock_provider replaces its .json with a placeholder that
# is not valid JSON; every such data source is overridden with a minimal
# valid document. That is why isolation is asserted on the module's
# plain-value outputs (actions, resource refs), never on policy JSON.
#
# Guarantees carried over from the three-instance tests (Phase 3.2):
#   distinct role/secret/key/alias/association per environment
#     -> each environment run asserts its own names, and the
#        environment_identities check forbids shared secret names or
#        (namespace, ServiceAccount) pairs;
#   the six pairwise rejections and "shared namespace alone is fine"
#     -> rejects_* / accepts_* runs over the table;
#   no wildcard action, exact action lists, no Resource "*", no reference
#   to another environment's secret or key
#     -> isolation_* runs: the policy references EXACTLY this
#        environment's own secret and key (stronger than non-overlap);
#   child-module guards (environment, webhook/cert-controller SA, ARN as
#   secret name), region shape, empty owner -> kept unchanged.

mock_provider "aws" {
  override_data {
    target = module.eso.data.aws_caller_identity.current
    values = { account_id = "aws-id" }
  }
  override_data {
    target = module.eso.data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso.data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso.data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso.data.aws_iam_policy_document.secret_resource_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_resource {
    target = module.eso.aws_iam_role.eso
    values = { arn = "arn:aws:iam::aws:role/eso-identity-fixture" }
  }
  override_resource {
    target = module.eso.aws_secretsmanager_secret.this
    values = { arn = "arn:aws:secretsmanager:us-east-1:aws:secret:eso-fixture" }
  }
  override_resource {
    target = module.eso.aws_kms_key.this
    values = { arn = "arn:aws:kms:us-east-1:aws:key/eso-fixture" }
  }
}

variables {
  aws_region  = "us-east-1"
  owner       = "IngMatrix-PGB"
  environment = "dev"
}

run "dev_identity" {
  command = apply
  variables {
    environment = "dev"
  }

  assert {
    condition     = output.cluster_name == "eks-gitops-dev"
    error_message = "The association must target the cluster terraform/envs/eks derives for dev."
  }
  assert {
    condition     = module.eso.secret_name == "eks-gitops-platform-project/dev/backend"
    error_message = "dev must use its own secret name from environment_identities."
  }
  assert {
    condition     = strcontains(module.eso.role_name, "dev") && strcontains(module.eso.kms_alias, "dev")
    error_message = "dev's role and key alias must be named for dev."
  }
  assert {
    condition     = local.identity.namespace == "eso-dev" && local.identity.service_account == "eso-dev-external-secrets"
    error_message = "dev's Pod Identity association must target eso-dev/eso-dev-external-secrets."
  }
}

run "uat_identity" {
  command = apply
  variables {
    environment = "uat"
  }

  assert {
    condition     = output.cluster_name == "eks-gitops-uat"
    error_message = "The association must target the cluster terraform/envs/eks derives for uat."
  }
  assert {
    condition     = module.eso.secret_name == "eks-gitops-platform-project/uat/backend"
    error_message = "uat must use its own secret name from environment_identities."
  }
  assert {
    condition     = strcontains(module.eso.role_name, "uat") && strcontains(module.eso.kms_alias, "uat")
    error_message = "uat's role and key alias must be named for uat."
  }
  assert {
    condition     = local.identity.namespace == "eso-uat" && local.identity.service_account == "eso-uat-external-secrets"
    error_message = "uat's Pod Identity association must target eso-uat/eso-uat-external-secrets."
  }
}

run "prod_identity" {
  command = apply
  variables {
    environment = "prod"
  }

  assert {
    condition     = output.cluster_name == "eks-gitops-prod"
    error_message = "The association must target the cluster terraform/envs/eks derives for prod."
  }
  assert {
    condition     = module.eso.secret_name == "eks-gitops-platform-project/prod/backend"
    error_message = "prod must use its own secret name from environment_identities."
  }
  assert {
    condition     = strcontains(module.eso.role_name, "prod") && strcontains(module.eso.kms_alias, "prod")
    error_message = "prod's role and key alias must be named for prod."
  }
  assert {
    condition     = local.identity.namespace == "eso-prod" && local.identity.service_account == "eso-prod-external-secrets"
    error_message = "prod's Pod Identity association must target eso-prod/eso-prod-external-secrets."
  }
}

run "isolation_exact_actions_and_resources" {
  command = apply

  assert {
    condition     = toset(module.eso.secretsmanager_actions) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:ListSecretVersionIds"])
    error_message = "Secrets Manager actions must be exactly ESO's documented minimum - never secretsmanager:*."
  }
  assert {
    condition     = toset(module.eso.kms_actions) == toset(["kms:Decrypt"])
    error_message = "KMS actions must be exactly kms:Decrypt - never kms:*."
  }
  assert {
    condition     = toset(module.eso.permissions_resource_refs) == toset([module.eso.secret_arn, module.eso.kms_key_arn])
    error_message = "The policy must reference exactly this environment's own secret and key - never \"*\", never another environment's."
  }
  assert {
    condition     = !contains(module.eso.permissions_resource_refs, "*")
    error_message = "The permissions policy must never reference Resource: \"*\"."
  }
}

run "rejects_platform_environment" {
  command = plan
  variables {
    environment = "platform"
  }
  expect_failures = [var.environment]
}

run "accepts_shared_namespace_alone_when_service_account_still_differs" {
  command = plan
  variables {
    environment_identities = {
      dev  = { namespace = "eso-shared", service_account = "eso-dev-external-secrets", secret_name = "p/dev/backend" }
      uat  = { namespace = "eso-shared", service_account = "eso-uat-external-secrets", secret_name = "p/uat/backend" }
      prod = { namespace = "eso-shared", service_account = "eso-prod-external-secrets", secret_name = "p/prod/backend" }
    }
  }
}

run "rejects_dev_and_uat_sharing_the_full_identity_pair" {
  command = plan
  variables {
    environment_identities = {
      dev  = { namespace = "eso-shared", service_account = "shared-controller", secret_name = "p/dev/backend" }
      uat  = { namespace = "eso-shared", service_account = "shared-controller", secret_name = "p/uat/backend" }
      prod = { namespace = "eso-prod", service_account = "eso-prod-external-secrets", secret_name = "p/prod/backend" }
    }
  }
  expect_failures = [check.environments_never_share_identity]
}

run "rejects_dev_and_uat_sharing_the_same_secret_name" {
  command = plan
  variables {
    environment_identities = {
      dev  = { namespace = "eso-dev", service_account = "eso-dev-external-secrets", secret_name = "p/shared/backend" }
      uat  = { namespace = "eso-uat", service_account = "eso-uat-external-secrets", secret_name = "p/shared/backend" }
      prod = { namespace = "eso-prod", service_account = "eso-prod-external-secrets", secret_name = "p/prod/backend" }
    }
  }
  expect_failures = [check.environments_never_share_identity]
}

run "rejects_dev_and_prod_sharing_the_full_identity_pair" {
  command = plan
  variables {
    environment_identities = {
      dev  = { namespace = "eso-shared", service_account = "shared-controller", secret_name = "p/dev/backend" }
      uat  = { namespace = "eso-uat", service_account = "eso-uat-external-secrets", secret_name = "p/uat/backend" }
      prod = { namespace = "eso-shared", service_account = "shared-controller", secret_name = "p/prod/backend" }
    }
  }
  expect_failures = [check.environments_never_share_identity]
}

run "rejects_dev_and_prod_sharing_the_same_secret_name" {
  command = plan
  variables {
    environment_identities = {
      dev  = { namespace = "eso-dev", service_account = "eso-dev-external-secrets", secret_name = "p/shared/backend" }
      uat  = { namespace = "eso-uat", service_account = "eso-uat-external-secrets", secret_name = "p/uat/backend" }
      prod = { namespace = "eso-prod", service_account = "eso-prod-external-secrets", secret_name = "p/shared/backend" }
    }
  }
  expect_failures = [check.environments_never_share_identity]
}

run "rejects_uat_and_prod_sharing_the_full_identity_pair" {
  command = plan
  variables {
    environment_identities = {
      dev  = { namespace = "eso-dev", service_account = "eso-dev-external-secrets", secret_name = "p/dev/backend" }
      uat  = { namespace = "eso-shared", service_account = "shared-controller", secret_name = "p/uat/backend" }
      prod = { namespace = "eso-shared", service_account = "shared-controller", secret_name = "p/prod/backend" }
    }
  }
  expect_failures = [check.environments_never_share_identity]
}

run "rejects_uat_and_prod_sharing_the_same_secret_name" {
  command = plan
  variables {
    environment_identities = {
      dev  = { namespace = "eso-dev", service_account = "eso-dev-external-secrets", secret_name = "p/dev/backend" }
      uat  = { namespace = "eso-uat", service_account = "eso-uat-external-secrets", secret_name = "p/shared/backend" }
      prod = { namespace = "eso-prod", service_account = "eso-prod-external-secrets", secret_name = "p/shared/backend" }
    }
  }
  expect_failures = [check.environments_never_share_identity]
}

run "rejects_table_missing_an_environment" {
  command = plan
  variables {
    environment_identities = {
      dev = { namespace = "eso-dev", service_account = "eso-dev-external-secrets", secret_name = "p/dev/backend" }
      uat = { namespace = "eso-uat", service_account = "eso-uat-external-secrets", secret_name = "p/uat/backend" }
    }
  }
  expect_failures = [var.environment_identities]
}

run "rejects_invalid_region_shape" {
  command = plan
  variables {
    aws_region = "not-a-region"
  }
  expect_failures = [var.aws_region]
}

run "rejects_empty_owner" {
  command = plan
  variables {
    owner = ""
  }
  expect_failures = [var.owner]
}

# --- child-module guards, run against terraform/modules/eso-identity directly ---
run "rejects_invalid_environment_value_in_child_module" {
  command = plan

  # The root hard-codes "dev"/"uat"/"prod" as the literal environment
  # argument in each module block - this run
  # instead exercises the same validation rule directly via a
  # standalone instantiation, proving the rule fires independent of
  # which root ever calls it.
  module {
    source = "../../modules/eso-identity"
  }

  override_data {
    target = data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.secret_resource_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  variables {
    environment     = "not-a-real-environment"
    aws_region      = "us-east-1"
    cluster_name    = "eks-gitops-uat"
    namespace       = "eso-uat"
    service_account = "eso-uat-external-secrets"
    secret_name     = "eks-gitops-platform-project/uat/backend"
    owner           = "IngMatrix-PGB"
  }

  expect_failures = [
    var.environment,
  ]
}

run "rejects_webhook_service_account_in_child_module" {
  command = plan

  module {
    source = "../../modules/eso-identity"
  }

  override_data {
    target = data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.secret_resource_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  variables {
    environment     = "uat"
    aws_region      = "us-east-1"
    cluster_name    = "eks-gitops-uat"
    namespace       = "eso-uat"
    service_account = "external-secrets-webhook"
    secret_name     = "eks-gitops-platform-project/uat/backend"
    owner           = "IngMatrix-PGB"
  }

  expect_failures = [
    var.service_account,
  ]
}

run "rejects_cert_controller_service_account_in_child_module" {
  command = plan

  module {
    source = "../../modules/eso-identity"
  }

  override_data {
    target = data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.secret_resource_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  variables {
    environment     = "uat"
    aws_region      = "us-east-1"
    cluster_name    = "eks-gitops-uat"
    namespace       = "eso-uat"
    service_account = "external-secrets-cert-controller"
    secret_name     = "eks-gitops-platform-project/uat/backend"
    owner           = "IngMatrix-PGB"
  }

  expect_failures = [
    var.service_account,
  ]
}

run "rejects_secret_name_that_is_actually_an_arn" {
  command = plan

  module {
    source = "../../modules/eso-identity"
  }

  override_data {
    target = data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.secret_resource_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  variables {
    environment     = "uat"
    aws_region      = "us-east-1"
    cluster_name    = "eks-gitops-uat"
    namespace       = "eso-uat"
    service_account = "eso-uat-external-secrets"
    secret_name     = "arn:aws:secretsmanager:us-east-1:aws:secret:example"
    owner           = "IngMatrix-PGB"
  }

  expect_failures = [
    var.secret_name,
  ]
}
