# Cross-environment IAM isolation checks. Asserts on plain-value
# locals exposed via outputs (never a mock_provider-computed
# attribute) - see terraform/modules/eso-identity/main.tf's own
# comment for why data "aws_iam_policy_document"'s .json output cannot
# be inspected this way (mock_provider replaces it unconditionally,
# even though this data source never calls AWS even for real). Proves
# this configuration's own logic, never real AWS policy simulation -
# see identity.tftest.hcl's header comment for the same distinction.

mock_provider "aws" {
  override_data {
    target = module.eso_staging.data.aws_caller_identity.current
    values = { account_id = "aws" }
  }
  override_data {
    target = module.eso_production.data.aws_caller_identity.current
    values = { account_id = "aws" }
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

run "no_wildcard_actions_and_correct_isolation" {
  command = apply

  # --- No wildcard action anywhere, in either environment. ------------
  assert {
    condition     = !contains(module.eso_staging.secretsmanager_actions, "secretsmanager:*")
    error_message = "staging must never be granted secretsmanager:*"
  }
  assert {
    condition     = !contains(module.eso_production.secretsmanager_actions, "secretsmanager:*")
    error_message = "production must never be granted secretsmanager:*"
  }
  assert {
    condition     = !contains(module.eso_staging.kms_actions, "kms:*")
    error_message = "staging must never be granted kms:*"
  }
  assert {
    condition     = !contains(module.eso_production.kms_actions, "kms:*")
    error_message = "production must never be granted kms:*"
  }

  # --- Every granted action is one of the exact, evidence-based
  # actions this design authorizes - never one action more. ------------
  assert {
    condition = alltrue([
      for a in module.eso_staging.secretsmanager_actions :
      contains([
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:ListSecretVersionIds",
      ], a)
    ])
    error_message = "staging's secretsmanager_actions contains an action beyond ESO's own documented minimum policy"
  }
  assert {
    condition = alltrue([
      for a in module.eso_staging.kms_actions : a == "kms:Decrypt"
    ])
    error_message = "staging's kms_actions must be exactly kms:Decrypt, nothing else"
  }

  # --- No Resource: "*" anywhere - every permissions-policy resource
  # reference is a real Terraform resource ARN, never a wildcard
  # string. ---------------------------------------------------------
  assert {
    condition     = !contains(module.eso_staging.permissions_resource_refs, "*")
    error_message = "staging's permissions policy must never reference Resource: \"*\""
  }
  assert {
    condition     = !contains(module.eso_production.permissions_resource_refs, "*")
    error_message = "production's permissions policy must never reference Resource: \"*\""
  }

  # --- Cross-environment isolation: staging's policy never references
  # any of production's resource ARNs, and vice versa. -----------------
  assert {
    condition     = length(setintersection(toset(module.eso_staging.permissions_resource_refs), toset(module.eso_production.permissions_resource_refs))) == 0
    error_message = "staging and production permissions policies must never reference an overlapping resource ARN"
  }
  assert {
    condition     = !contains(module.eso_staging.permissions_resource_refs, module.eso_production.secret_arn)
    error_message = "staging must never reference production's secret ARN"
  }
  assert {
    condition     = !contains(module.eso_staging.permissions_resource_refs, module.eso_production.kms_key_arn)
    error_message = "staging must never reference production's KMS key ARN"
  }
  assert {
    condition     = !contains(module.eso_production.permissions_resource_refs, module.eso_staging.secret_arn)
    error_message = "production must never reference staging's secret ARN"
  }
  assert {
    condition     = !contains(module.eso_production.permissions_resource_refs, module.eso_staging.kms_key_arn)
    error_message = "production must never reference staging's KMS key ARN"
  }
}
