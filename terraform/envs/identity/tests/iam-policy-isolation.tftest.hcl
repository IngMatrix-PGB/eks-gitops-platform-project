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

run "no_wildcard_actions_and_correct_isolation" {
  command = apply

  # --- No wildcard action anywhere, in any environment. ---------------
  assert {
    condition     = !contains(module.eso_dev.secretsmanager_actions, "secretsmanager:*")
    error_message = "dev must never be granted secretsmanager:*"
  }
  assert {
    condition     = !contains(module.eso_dev.kms_actions, "kms:*")
    error_message = "dev must never be granted kms:*"
  }
  assert {
    condition     = !contains(module.eso_uat.secretsmanager_actions, "secretsmanager:*")
    error_message = "uat must never be granted secretsmanager:*"
  }
  assert {
    condition     = !contains(module.eso_uat.kms_actions, "kms:*")
    error_message = "uat must never be granted kms:*"
  }
  assert {
    condition     = !contains(module.eso_prod.secretsmanager_actions, "secretsmanager:*")
    error_message = "prod must never be granted secretsmanager:*"
  }
  assert {
    condition     = !contains(module.eso_prod.kms_actions, "kms:*")
    error_message = "prod must never be granted kms:*"
  }

  # --- Every granted action is one of the exact, evidence-based
  # actions this design authorizes - never one action more. ------------
  assert {
    condition = alltrue([
      for a in module.eso_dev.secretsmanager_actions :
      contains([
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:ListSecretVersionIds",
      ], a)
    ])
    error_message = "dev's secretsmanager_actions contains an action beyond ESO's own documented minimum policy"
  }
  assert {
    condition = alltrue([
      for a in module.eso_dev.kms_actions : a == "kms:Decrypt"
    ])
    error_message = "dev's kms_actions must be exactly kms:Decrypt, nothing else"
  }
  assert {
    condition = alltrue([
      for a in module.eso_uat.secretsmanager_actions :
      contains([
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:ListSecretVersionIds",
      ], a)
    ])
    error_message = "uat's secretsmanager_actions contains an action beyond ESO's own documented minimum policy"
  }
  assert {
    condition = alltrue([
      for a in module.eso_uat.kms_actions : a == "kms:Decrypt"
    ])
    error_message = "uat's kms_actions must be exactly kms:Decrypt, nothing else"
  }
  assert {
    condition = alltrue([
      for a in module.eso_prod.secretsmanager_actions :
      contains([
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:ListSecretVersionIds",
      ], a)
    ])
    error_message = "prod's secretsmanager_actions contains an action beyond ESO's own documented minimum policy"
  }
  assert {
    condition = alltrue([
      for a in module.eso_prod.kms_actions : a == "kms:Decrypt"
    ])
    error_message = "prod's kms_actions must be exactly kms:Decrypt, nothing else"
  }

  # --- No Resource: "*" anywhere - every permissions-policy resource
  # reference is a real Terraform resource ARN, never a wildcard
  # string. ---------------------------------------------------------
  assert {
    condition     = !contains(module.eso_dev.permissions_resource_refs, "*")
    error_message = "dev's permissions policy must never reference Resource: \"*\""
  }
  assert {
    condition     = !contains(module.eso_uat.permissions_resource_refs, "*")
    error_message = "uat's permissions policy must never reference Resource: \"*\""
  }
  assert {
    condition     = !contains(module.eso_prod.permissions_resource_refs, "*")
    error_message = "prod's permissions policy must never reference Resource: \"*\""
  }

  # --- Cross-environment isolation, for every pair: no environment's
  # policy references another environment's secret or KMS key ARN. ----
  assert {
    condition     = length(setintersection(toset(module.eso_dev.permissions_resource_refs), toset(module.eso_uat.permissions_resource_refs))) == 0
    error_message = "dev and uat permissions policies must never reference an overlapping resource ARN"
  }
  assert {
    condition     = !contains(module.eso_dev.permissions_resource_refs, module.eso_uat.secret_arn)
    error_message = "dev must never reference uat's secret ARN"
  }
  assert {
    condition     = !contains(module.eso_dev.permissions_resource_refs, module.eso_uat.kms_key_arn)
    error_message = "dev must never reference uat's KMS key ARN"
  }
  assert {
    condition     = !contains(module.eso_uat.permissions_resource_refs, module.eso_dev.secret_arn)
    error_message = "uat must never reference dev's secret ARN"
  }
  assert {
    condition     = !contains(module.eso_uat.permissions_resource_refs, module.eso_dev.kms_key_arn)
    error_message = "uat must never reference dev's KMS key ARN"
  }
  assert {
    condition     = length(setintersection(toset(module.eso_dev.permissions_resource_refs), toset(module.eso_prod.permissions_resource_refs))) == 0
    error_message = "dev and prod permissions policies must never reference an overlapping resource ARN"
  }
  assert {
    condition     = !contains(module.eso_dev.permissions_resource_refs, module.eso_prod.secret_arn)
    error_message = "dev must never reference prod's secret ARN"
  }
  assert {
    condition     = !contains(module.eso_dev.permissions_resource_refs, module.eso_prod.kms_key_arn)
    error_message = "dev must never reference prod's KMS key ARN"
  }
  assert {
    condition     = !contains(module.eso_prod.permissions_resource_refs, module.eso_dev.secret_arn)
    error_message = "prod must never reference dev's secret ARN"
  }
  assert {
    condition     = !contains(module.eso_prod.permissions_resource_refs, module.eso_dev.kms_key_arn)
    error_message = "prod must never reference dev's KMS key ARN"
  }
  assert {
    condition     = length(setintersection(toset(module.eso_uat.permissions_resource_refs), toset(module.eso_prod.permissions_resource_refs))) == 0
    error_message = "uat and prod permissions policies must never reference an overlapping resource ARN"
  }
  assert {
    condition     = !contains(module.eso_uat.permissions_resource_refs, module.eso_prod.secret_arn)
    error_message = "uat must never reference prod's secret ARN"
  }
  assert {
    condition     = !contains(module.eso_uat.permissions_resource_refs, module.eso_prod.kms_key_arn)
    error_message = "uat must never reference prod's KMS key ARN"
  }
  assert {
    condition     = !contains(module.eso_prod.permissions_resource_refs, module.eso_uat.secret_arn)
    error_message = "prod must never reference uat's secret ARN"
  }
  assert {
    condition     = !contains(module.eso_prod.permissions_resource_refs, module.eso_uat.kms_key_arn)
    error_message = "prod must never reference uat's KMS key ARN"
  }
}
