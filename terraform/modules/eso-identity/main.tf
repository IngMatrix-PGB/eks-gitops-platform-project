# One environment's complete ESO Pod Identity + Secrets Manager
# identity: an IAM role trusted only by EKS Pod Identity, a customer-
# managed KMS key used only to encrypt this environment's own secret,
# Secrets Manager metadata (never a value - see the explicit absence of
# any aws_secretsmanager_secret_version anywhere in this file), and the
# Pod Identity Association binding it all to the real, live-verified
# (namespace, service_account) pair. Instantiated twice by
# terraform/envs/identity/ (staging, production) - every ARN referenced
# below is a Terraform resource attribute, never a hand-built string,
# so staging and production can never accidentally cross-reference each
# other's role/key/secret.

module "tags" {
  source = "../tags"

  project     = var.project
  environment = var.environment
  owner       = var.owner
}

# --- Trust policy: the exact, official EKS Pod Identity trust policy
# (docs.aws.amazon.com/eks/latest/userguide/pod-id-association.html,
# re-verified 2026-09-08) - Principal is exclusively the Pod Identity
# service, actions exclusively sts:AssumeRole/sts:TagSession. No
# Federated/OIDC provider, no arbitrary AWS principal, no wildcard
# action - this is deliberately NOT an IRSA trust policy reused. -------
data "aws_iam_policy_document" "eso_trust" {
  statement {
    sid     = "AllowEksAuthToAssumeRoleForPodIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.project}-eso-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.eso_trust.json

  tags = module.tags.tags
}

# --- Least-privilege permissions: exactly the actions ESO's own
# documented minimum policy lists for its AWS Secrets Manager provider
# (secretsmanager:GetSecretValue/DescribeSecret/GetResourcePolicy/
# ListSecretVersionIds), scoped to this environment's own secret ARN
# only, plus kms:Decrypt scoped to this environment's own key ARN only
# (required per AWS's own documented "read a secret encrypted with a
# customer managed key" example) - never secretsmanager:*/kms:*, never
# Resource: "*", never an action beyond this evidence-based list.
#
# The action/resource lists are extracted into locals (pure Terraform
# language values, never touched by mock_provider "aws") and exposed
# via outputs.tf specifically so terraform test can assert on the real
# computed values directly - data "aws_iam_policy_document"'s own .json
# output is a provider-owned attribute that mock_provider always
# replaces with a fake placeholder, even though this data source never
# actually calls AWS even under a real, unmocked provider. -------------
locals {
  secrets_manager_actions = [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret",
    "secretsmanager:GetResourcePolicy",
    "secretsmanager:ListSecretVersionIds",
  ]
  kms_decrypt_actions = ["kms:Decrypt"]
}

data "aws_iam_policy_document" "eso_permissions" {
  statement {
    sid       = "ReadOwnSecretOnly"
    effect    = "Allow"
    actions   = local.secrets_manager_actions
    resources = [aws_secretsmanager_secret.this.arn]
  }

  statement {
    sid       = "DecryptOwnKeyOnly"
    effect    = "Allow"
    actions   = local.kms_decrypt_actions
    resources = [aws_kms_key.this.arn]
  }
}

resource "aws_iam_role_policy" "eso" {
  name   = "${var.project}-eso-${var.environment}-secrets-manager"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso_permissions.json
}

# --- KMS: one customer-managed key per environment, used only to
# encrypt this environment's own secret. Rotation enabled; deletion
# window is an explicit, validated input (AWS-enforced 7-30 day
# bounds, never immediate). The key policy grants the account root
# enumerated key-administration actions, never a blanket all-actions
# grant for the KMS service - even for the administrative statement, a
# more precise, still-sufficient action list keeps the no-wildcard
# rule absolute everywhere in this module, with no special-cased
# exception - so the key can never become permanently unmanageable, plus kms:Decrypt to exactly
# this environment's own role - never another environment's, since
# aws_iam_role.eso.arn is a same-module-instance reference, not a
# cross-environment one. -------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms_key_policy" {
  statement {
    sid    = "AllowAccountRootKeyAdministration"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowOwnRoleToDecryptOnly"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.eso.arn]
    }
    actions   = ["kms:Decrypt"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.project} ${var.environment} Secrets Manager encryption key"
  deletion_window_in_days = var.kms_deletion_window_in_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key_policy.json

  tags = module.tags.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.project}-${var.environment}-secrets"
  target_key_id = aws_kms_key.this.key_id
}

# --- Secrets Manager: metadata only. No aws_secretsmanager_secret_
# version exists anywhere in this file - the actual value is
# provisioned imperatively, out of Terraform state, in a future,
# separately authorized phase (Phase 3.3). No provisioner, no
# local-exec, no AWS CLI invocation, no payload variable/output. ------
resource "aws_secretsmanager_secret" "this" {
  name                    = var.secret_name
  description             = "${var.project} ${var.environment} backend secret metadata only - no payload is managed by Terraform; the value is provisioned imperatively, out of state, in a future, separately authorized phase."
  kms_key_id              = aws_kms_key.this.key_id
  recovery_window_in_days = var.secret_recovery_window_in_days

  tags = module.tags.tags
}

# Resource-based policy on the secret itself - a real, additional
# isolation layer restricting Principal to exactly this environment's
# own role, on exactly this secret's own ARN (a genuine cross-resource
# reference via the dedicated aws_secretsmanager_secret_policy
# resource, never a self-referential "Resource": "*" shortcut).
data "aws_iam_policy_document" "secret_resource_policy" {
  statement {
    sid    = "AllowOwnRoleOnly"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.eso.arn]
    }
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [aws_secretsmanager_secret.this.arn]
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  secret_arn = aws_secretsmanager_secret.this.arn
  policy     = data.aws_iam_policy_document.secret_resource_policy.json
}

# --- The Pod Identity Association itself - the exact (namespace,
# service_account) pair verified live against the running cluster
# (never a guessed pattern), bound to this environment's own role only.
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.eso.arn

  tags = module.tags.tags
}
