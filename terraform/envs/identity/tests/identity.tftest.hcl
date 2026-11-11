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
    target = module.eso_dev.data.aws_caller_identity.current
    values = {
      account_id = "aws-id"
    }
  }

  override_data {
    target = module.eso_uat.data.aws_caller_identity.current
    values = {
      account_id = "aws-id"
    }
  }

  override_data {
    target = module.eso_prod.data.aws_caller_identity.current
    values = {
      account_id = "aws-id"
    }
  }

  override_data {
    target = module.eso_dev.data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_dev.data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_dev.data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_dev.data.aws_iam_policy_document.secret_resource_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = module.eso_uat.data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_uat.data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_uat.data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_uat.data.aws_iam_policy_document.secret_resource_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  override_data {
    target = module.eso_prod.data.aws_iam_policy_document.eso_trust
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_prod.data.aws_iam_policy_document.eso_permissions
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_prod.data.aws_iam_policy_document.kms_key_policy
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = module.eso_prod.data.aws_iam_policy_document.secret_resource_policy
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
    target = module.eso_dev.aws_iam_role.eso
    values = {
      arn  = "arn:aws:iam::aws:role/eso-identity-dev-fixture"
      name = "eso-identity-dev-fixture"
    }
  }
  override_resource {
    target = module.eso_uat.aws_iam_role.eso
    values = {
      arn  = "arn:aws:iam::aws:role/eso-identity-uat-fixture"
      name = "eso-identity-uat-fixture"
    }
  }
  override_resource {
    target = module.eso_prod.aws_iam_role.eso
    values = {
      arn  = "arn:aws:iam::aws:role/eso-identity-prod-fixture"
      name = "eso-identity-prod-fixture"
    }
  }

  override_resource {
    target = module.eso_dev.aws_secretsmanager_secret.this
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:aws:secret:eks-gitops-platform-project/dev/backend-fixture"
    }
  }
  override_resource {
    target = module.eso_uat.aws_secretsmanager_secret.this
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:aws:secret:eks-gitops-platform-project/uat/backend-fixture"
    }
  }
  override_resource {
    target = module.eso_prod.aws_secretsmanager_secret.this
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:aws:secret:eks-gitops-platform-project/prod/backend-fixture"
    }
  }

  override_resource {
    target = module.eso_dev.aws_kms_key.this
    values = {
      arn = "arn:aws:kms:us-east-1:aws:key/dev-fixture"
    }
  }
  override_resource {
    target = module.eso_uat.aws_kms_key.this
    values = {
      arn = "arn:aws:kms:us-east-1:aws:key/uat-fixture"
    }
  }
  override_resource {
    target = module.eso_prod.aws_kms_key.this
    values = {
      arn = "arn:aws:kms:us-east-1:aws:key/prod-fixture"
    }
  }
}

variables {
  aws_region   = "us-east-1"
  cluster_name = "eks-gitops-platform"
  owner        = "IngMatrix-PGB"
}

run "plan_creates_distinct_roles_per_environment" {
  # command = apply, not plan: mock_provider only resolves fake
  # computed values (like an ARN) during apply by default - a plan-
  # phase comparison of not-yet-known ARNs cannot be evaluated.
  # This is still a fully simulated terraform-test run against the
  # mocked provider, never a real terraform apply against AWS.
  command = apply

  assert {
    condition     = module.eso_dev.role_arn != module.eso_uat.role_arn
    error_message = "dev and uat must have distinct IAM role ARNs"
  }

  assert {
    condition     = module.eso_dev.role_name != module.eso_uat.role_name
    error_message = "dev and uat must have distinct IAM role names"
  }

  assert {
    condition     = module.eso_dev.role_arn != module.eso_prod.role_arn
    error_message = "dev and prod must have distinct IAM role ARNs"
  }

  assert {
    condition     = module.eso_dev.role_name != module.eso_prod.role_name
    error_message = "dev and prod must have distinct IAM role names"
  }

  assert {
    condition     = module.eso_uat.role_arn != module.eso_prod.role_arn
    error_message = "uat and prod must have distinct IAM role ARNs"
  }

  assert {
    condition     = module.eso_uat.role_name != module.eso_prod.role_name
    error_message = "uat and prod must have distinct IAM role names"
  }
}

run "apply_creates_distinct_secret_kms_and_association_per_environment" {
  command = apply

  assert {
    condition     = module.eso_dev.secret_name != module.eso_uat.secret_name
    error_message = "dev and uat must have distinct secret names"
  }

  assert {
    condition     = module.eso_dev.secret_arn != module.eso_uat.secret_arn
    error_message = "dev and uat must have distinct secret ARNs"
  }

  assert {
    condition     = module.eso_dev.kms_key_arn != module.eso_uat.kms_key_arn
    error_message = "dev and uat must have distinct KMS keys"
  }

  assert {
    condition     = module.eso_dev.kms_alias != module.eso_uat.kms_alias
    error_message = "dev and uat must have distinct KMS aliases"
  }

  assert {
    condition     = module.eso_dev.association_id != module.eso_uat.association_id
    error_message = "dev and uat must have distinct Pod Identity Associations"
  }

  assert {
    condition     = module.eso_dev.secret_name != module.eso_prod.secret_name
    error_message = "dev and prod must have distinct secret names"
  }

  assert {
    condition     = module.eso_dev.secret_arn != module.eso_prod.secret_arn
    error_message = "dev and prod must have distinct secret ARNs"
  }

  assert {
    condition     = module.eso_dev.kms_key_arn != module.eso_prod.kms_key_arn
    error_message = "dev and prod must have distinct KMS keys"
  }

  assert {
    condition     = module.eso_dev.kms_alias != module.eso_prod.kms_alias
    error_message = "dev and prod must have distinct KMS aliases"
  }

  assert {
    condition     = module.eso_dev.association_id != module.eso_prod.association_id
    error_message = "dev and prod must have distinct Pod Identity Associations"
  }

  assert {
    condition     = module.eso_uat.secret_name != module.eso_prod.secret_name
    error_message = "uat and prod must have distinct secret names"
  }

  assert {
    condition     = module.eso_uat.secret_arn != module.eso_prod.secret_arn
    error_message = "uat and prod must have distinct secret ARNs"
  }

  assert {
    condition     = module.eso_uat.kms_key_arn != module.eso_prod.kms_key_arn
    error_message = "uat and prod must have distinct KMS keys"
  }

  assert {
    condition     = module.eso_uat.kms_alias != module.eso_prod.kms_alias
    error_message = "uat and prod must have distinct KMS aliases"
  }

  assert {
    condition     = module.eso_uat.association_id != module.eso_prod.association_id
    error_message = "uat and prod must have distinct Pod Identity Associations"
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
    dev_namespace  = "eso-shared"
    uat_namespace  = "eso-shared"
    prod_namespace = "eso-shared"
  }
}

run "rejects_dev_and_uat_sharing_the_full_identity_pair" {
  command = plan

  variables {
    dev_namespace       = "eso-shared"
    dev_service_account = "shared-controller"
    uat_namespace       = "eso-shared"
    uat_service_account = "shared-controller"
  }

  expect_failures = [
    check.environments_never_share_identity,
  ]
}

run "rejects_dev_and_uat_sharing_the_same_secret_name" {
  command = plan

  variables {
    dev_secret_name = "eks-gitops-platform-project/shared/backend"
    uat_secret_name = "eks-gitops-platform-project/shared/backend"
  }

  expect_failures = [
    check.environments_never_share_identity,
  ]
}

run "rejects_dev_and_prod_sharing_the_full_identity_pair" {
  command = plan

  variables {
    dev_namespace        = "eso-shared"
    dev_service_account  = "shared-controller"
    prod_namespace       = "eso-shared"
    prod_service_account = "shared-controller"
  }

  expect_failures = [
    check.environments_never_share_identity,
  ]
}

run "rejects_dev_and_prod_sharing_the_same_secret_name" {
  command = plan

  variables {
    dev_secret_name  = "eks-gitops-platform-project/shared/backend"
    prod_secret_name = "eks-gitops-platform-project/shared/backend"
  }

  expect_failures = [
    check.environments_never_share_identity,
  ]
}

run "rejects_uat_and_prod_sharing_the_full_identity_pair" {
  command = plan

  variables {
    uat_namespace        = "eso-shared"
    uat_service_account  = "shared-controller"
    prod_namespace       = "eso-shared"
    prod_service_account = "shared-controller"
  }

  expect_failures = [
    check.environments_never_share_identity,
  ]
}

run "rejects_uat_and_prod_sharing_the_same_secret_name" {
  command = plan

  variables {
    uat_secret_name  = "eks-gitops-platform-project/shared/backend"
    prod_secret_name = "eks-gitops-platform-project/shared/backend"
  }

  expect_failures = [
    check.environments_never_share_identity,
  ]
}

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
    cluster_name    = "eks-gitops-platform"
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
    cluster_name    = "eks-gitops-platform"
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
    cluster_name    = "eks-gitops-platform"
    namespace       = "eso-uat"
    service_account = "external-secrets-cert-controller"
    secret_name     = "eks-gitops-platform-project/uat/backend"
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
    environment     = "uat"
    aws_region      = "us-east-1"
    cluster_name    = "eks-gitops-platform"
    namespace       = "eso-uat"
    service_account = "eso-uat-external-secrets"
    secret_name     = "arn:aws:secretsmanager:us-east-1:aws:secret:example"
    owner           = "IngMatrix-PGB"
  }

  expect_failures = [
    var.secret_name,
  ]
}
