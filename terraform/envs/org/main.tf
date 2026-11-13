# Phase 3.4.1 - the AWS Organization, its accounts and guardrails
# (docs/adr/0016-aws-organization-and-guardrails.md). Plan-only: never
# applied by this repository. The organization's management account
# hosts nothing else - no workloads, no hub cluster, no delegated
# security administration.

module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

module "scp" {
  source = "../../modules/scp"

  allowed_regions   = var.allowed_regions
  exempt_role_names = [var.account_access_role_name]
}

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # Exactly the services this design delegates or runs organization-wide.
  aws_service_access_principals = [
    "access-analyzer.amazonaws.com",
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "config-multiaccountsetup.amazonaws.com",
    "guardduty.amazonaws.com",
    "malware-protection.guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
  ]

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]
}

locals {
  root_id = aws_organizations_organization.this.roots[0].id

  # account key -> organizational unit key
  account_ou = {
    security = "security"
    platform = "platform"
    dev      = "nonprod"
    uat      = "nonprod"
    prod     = "prod"
  }
}

# --- organizational units --------------------------------------------------
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = local.root_id
  tags      = module.tags.tags
}

resource "aws_organizations_organizational_unit" "platform" {
  name      = "Platform"
  parent_id = local.root_id
  tags      = module.tags.tags
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = local.root_id
  tags      = module.tags.tags
}

resource "aws_organizations_organizational_unit" "nonprod" {
  name      = "NonProd"
  parent_id = aws_organizations_organizational_unit.workloads.id
  tags      = module.tags.tags
}

resource "aws_organizations_organizational_unit" "prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
  tags      = module.tags.tags
}

locals {
  ou_ids = {
    security = aws_organizations_organizational_unit.security.id
    platform = aws_organizations_organizational_unit.platform.id
    nonprod  = aws_organizations_organizational_unit.nonprod.id
    prod     = aws_organizations_organizational_unit.prod.id
  }
}

# --- member accounts -------------------------------------------------------
resource "aws_organizations_account" "this" {
  for_each = local.account_ou

  name      = "${var.project}-${each.key}"
  email     = var.account_emails[each.key]
  parent_id = local.ou_ids[each.value]
  role_name = var.account_access_role_name

  iam_user_access_to_billing = "DENY"
  # Closing an AWS account is a separate, deliberate, out-of-band act -
  # never a side effect of removing it from this configuration.
  close_on_deletion = false

  tags = merge(module.tags.tags, { Environment = each.key == "security" || each.key == "platform" ? "shared" : each.key })

  lifecycle {
    # AWS does not return role_name after creation; without this every
    # plan would propose to replace (i.e. recreate) the account.
    ignore_changes = [role_name]
  }
}

# --- service control policies ----------------------------------------------
resource "aws_organizations_policy" "region_guardrail" {
  name        = "${var.project}-region-guardrail"
  description = "Deny regional actions outside the allowed regions (global services exempted)."
  type        = "SERVICE_CONTROL_POLICY"
  content     = module.scp.region_guardrail_json
  tags        = module.tags.tags
}

resource "aws_organizations_policy" "member_hardening" {
  name        = "${var.project}-member-hardening"
  description = "Deny leaving the organization, root-user actions, and undoing account-level hardening."
  type        = "SERVICE_CONTROL_POLICY"
  content     = module.scp.member_hardening_json
  tags        = module.tags.tags
}

resource "aws_organizations_policy" "security_services" {
  name        = "${var.project}-protect-security-services"
  description = "Deny disabling GuardDuty, Config, CloudTrail, Security Hub and IAM Access Analyzer."
  type        = "SERVICE_CONTROL_POLICY"
  content     = module.scp.security_services_json
  tags        = module.tags.tags
}

# Region and member hardening apply to every member account (an SCP never
# applies to the management account itself).
resource "aws_organizations_policy_attachment" "root" {
  for_each = {
    region_guardrail = aws_organizations_policy.region_guardrail.id
    member_hardening = aws_organizations_policy.member_hardening.id
  }

  policy_id = each.value
  target_id = local.root_id
}

# Security-service protection applies to the Platform and Workloads OUs,
# never to the Security OU: the delegated-administrator account there must
# manage GuardDuty/Security Hub/Config membership for the organization.
resource "aws_organizations_policy_attachment" "security_services" {
  for_each = {
    platform  = aws_organizations_organizational_unit.platform.id
    workloads = aws_organizations_organizational_unit.workloads.id
  }

  policy_id = aws_organizations_policy.security_services.id
  target_id = each.value
}

# --- delegated administration: the security account ------------------------
resource "aws_guardduty_organization_admin_account" "security" {
  admin_account_id = aws_organizations_account.this["security"].id
  depends_on       = [aws_organizations_organization.this]
}

resource "aws_securityhub_organization_admin_account" "security" {
  admin_account_id = aws_organizations_account.this["security"].id
  depends_on       = [aws_organizations_organization.this]
}

resource "aws_organizations_delegated_administrator" "security" {
  for_each = toset([
    "access-analyzer.amazonaws.com",
    "config.amazonaws.com",
    "config-multiaccountsetup.amazonaws.com",
  ])

  account_id        = aws_organizations_account.this["security"].id
  service_principal = each.value
  depends_on        = [aws_organizations_organization.this]
}

# --- organization trail (second apply, once envs/security exists) ----------
resource "aws_cloudtrail" "organization" {
  count = var.org_trail_bucket_name == null ? 0 : 1

  name                          = var.org_trail_name
  s3_bucket_name                = var.org_trail_bucket_name
  kms_key_id                    = var.org_trail_kms_key_arn
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  tags = module.tags.tags

  depends_on = [aws_organizations_organization.this]
}

# --- consolidated budget ----------------------------------------------------
resource "aws_budgets_budget" "organization" {
  name         = "${var.project}-organization-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", threshold = 80 },
      { type = "ACTUAL", threshold = 100 },
      { type = "FORECASTED", threshold = 100 },
    ]
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.budget_notification_emails
    }
  }

  tags = module.tags.tags
}
