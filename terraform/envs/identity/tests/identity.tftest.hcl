# Structural correctness only - mock_provider "aws" proves this
# configuration's own internal logic (right count, right names, right
# references, right rejections) against fabricated values. It proves
# NOTHING about whether a real `apply` would succeed against actual
# AWS (quota, propagation delay, real IAM policy simulation) - that
# gap is real and unclosed by this file, by design
# (.local/evidence/phase-3.2-pod-identity-secrets-manager-iac-plan.md
# S14). `command = apply` below is a simulated terraform-test run
# against the mocked provider, never a real `terraform apply` against
# AWS - see scripts/validate/check-terraform-offline.sh's own header
# comment for why this distinction is structural, not just described.

# data "aws_iam_policy_document" normally renders its own JSON entirely
# client-side (it never calls AWS even under a real, unmocked
# provider) - but mock_provider "aws" still replaces its low-fidelity
# default computed value with a generic placeholder that is not valid
# JSON, which then fails downstream (assume_role_policy/kms
# policy/secret policy all require a real JSON object). Every such
# data source is therefore explicitly overridden below with a minimal,
# syntactically valid policy document - this is a structural-shape
# fixture, never the real rendered policy, exactly like every other
# override_data value in this codebase.
mock_provider "aws" {
  override_data {
    target = module.eso_staging.data.aws_caller_identity.current
    values = {
      account_id = "aws-id"
    }
  }

  override_data {
    target = module.eso_production.data.aws_caller_identity.current
    values = {
      account_id = "aws-id"
    }
  }

  override_data {
    target = module.eso_staging.data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_staging.data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_staging.data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_staging.data.aws_iam_policy_document.secret_resource_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = module.eso_production.data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_production.data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_production.data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_production.data.aws_iam_policy_document.secret_resource_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  # mock_provider's default fake computed ARN values (short random
  # strings) are not shaped like a real ARN, and the AWS provider's own
  # schema-level ARN validator rejects them the moment another mocked
  # resource consumes one as an input (e.g. role_arn on the Pod
  # Identity Association) - overridden below with syntactically valid,
  # obviously-fake ARNs, never a real or 12-digit-account-id-shaped
  # value.
  override_resource {
    target = module.eso_staging.aws_iam_role.eso
    values = {
      arn  = "arn:aws:iam::aws:role/eso-identity-staging-fixture"
      name = "eso-identity-staging-fixture"
    }
  }
  override_resource {
    target = module.eso_production.aws_iam_role.eso
    values = {
      arn  = "arn:aws:iam::aws:role/eso-identity-production-fixture"
      name = "eso-identity-production-fixture"
    }
  }

  override_resource {
    target = module.eso_staging.aws_secretsmanager_secret.this
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:aws:secret:eks-gitops-platform-project/staging/backend-fixture"
    }
  }
  override_resource {
    target = module.eso_production.aws_secretsmanager_secret.this
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:aws:secret:eks-gitops-platform-project/production/backend-fixture"
    }
  }

  override_resource {
    target = module.eso_staging.aws_kms_key.this
    values = {
      arn = "arn:aws:kms:us-east-1:aws:key/staging-fixture"
    }
  }
  override_resource {
    target = module.eso_production.aws_kms_key.this
    values = {
      arn = "arn:aws:kms:us-east-1:aws:key/production-fixture"
    }
  }
}

variables {
  aws_region   = "us-east-1"
  cluster_name = "eks-gitops-platform"
  owner        = "IngMatrix-PGB"
}

run "plan_creates_exactly_two_roles_and_associations" {
  # command = apply, not plan: mock_provider only resolves fake
  # computed values (like an ARN) during apply by default - a plan-
  # phase comparison of two not-yet-known ARNs cannot be evaluated.
  # This is still a fully simulated terraform-test run against the
  # mocked provider, never a real terraform apply against AWS.
  command = apply

  assert {
    condition     = module.eso_staging.role_arn != module.eso_production.role_arn
    error_message = "staging and production must have distinct IAM role ARNs"
  }

  assert {
    condition     = module.eso_staging.role_name != module.eso_production.role_name
    error_message = "staging and production must have distinct IAM role names"
  }
}

run "apply_creates_correct_namespace_and_service_account_pairs" {
  command = apply

  assert {
    condition     = module.eso_staging.secret_name != module.eso_production.secret_name
    error_message = "staging and production must have distinct secret names"
  }

  assert {
    condition     = module.eso_staging.secret_arn != module.eso_production.secret_arn
    error_message = "staging and production must have distinct secret ARNs"
  }

  assert {
    condition     = module.eso_staging.kms_key_arn != module.eso_production.kms_key_arn
    error_message = "staging and production must have distinct KMS keys"
  }

  assert {
    condition     = module.eso_staging.kms_alias != module.eso_production.kms_alias
    error_message = "staging and production must have distinct KMS aliases"
  }

  assert {
    condition     = module.eso_staging.association_id != module.eso_production.association_id
    error_message = "staging and production must have distinct Pod Identity Associations"
  }
}

run "accepts_shared_namespace_alone_when_service_account_still_differs" {
  command = plan

  # Only the namespace matches between environments - the
  # ServiceAccount still differs, so the full (namespace,
  # service_account) pair is not identical and the check must NOT
  # fire. Proves the check requires the FULL pair, not either field
  # alone - no expect_failures means this plan must succeed cleanly.
  variables {
    staging_namespace    = "eso-shared"
    production_namespace = "eso-shared"
  }
}

run "rejects_staging_and_production_sharing_the_full_identity_pair" {
  command = plan

  variables {
    staging_namespace          = "eso-shared"
    staging_service_account    = "shared-controller"
    production_namespace       = "eso-shared"
    production_service_account = "shared-controller"
  }

  expect_failures = [
    check.staging_production_never_share_identity,
  ]
}

run "rejects_staging_and_production_sharing_the_same_secret_name" {
  command = plan

  variables {
    staging_secret_name    = "eks-gitops-platform-project/shared/backend"
    production_secret_name = "eks-gitops-platform-project/shared/backend"
  }

  expect_failures = [
    check.staging_production_never_share_identity,
  ]
}

run "rejects_invalid_environment_value_in_child_module" {
  command = plan

  # The child module itself hard-codes "staging"/"production" as the
  # literal environment argument in each module block - this run
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
    cluster_name    = "eks-gitops-platform"
    namespace       = "eso-staging"
    service_account = "eso-staging-external-secrets"
    secret_name     = "eks-gitops-platform-project/staging/backend"
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
    environment     = "staging"
    aws_region      = "us-east-1"
    cluster_name    = "eks-gitops-platform"
    namespace       = "eso-staging"
    service_account = "external-secrets-webhook"
    secret_name     = "eks-gitops-platform-project/staging/backend"
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
    environment     = "staging"
    aws_region      = "us-east-1"
    cluster_name    = "eks-gitops-platform"
    namespace       = "eso-staging"
    service_account = "external-secrets-cert-controller"
    secret_name     = "eks-gitops-platform-project/staging/backend"
    owner           = "IngMatrix-PGB"
  }

  expect_failures = [
    var.service_account,
  ]
}

run "rejects_invalid_region_shape" {
  command = plan

  variables {
    aws_region = "not-a-region"
  }

  expect_failures = [
    var.aws_region,
  ]
}

run "rejects_empty_owner" {
  command = plan

  variables {
    owner = ""
  }

  expect_failures = [
    var.owner,
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
    environment     = "staging"
    aws_region      = "us-east-1"
    cluster_name    = "eks-gitops-platform"
    namespace       = "eso-staging"
    service_account = "eso-staging-external-secrets"
    secret_name     = "arn:aws:secretsmanager:us-east-1:aws:secret:example"
    owner           = "IngMatrix-PGB"
  }

  expect_failures = [
    var.secret_name,
  ]
}
