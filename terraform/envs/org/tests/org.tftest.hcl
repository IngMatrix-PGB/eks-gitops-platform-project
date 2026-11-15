# Structural correctness only (Phase 3.4.1): mock_provider "aws" proves
# this root's own logic - accounts in the right OUs, guardrails attached
# where intended, delegated administration pointing at the security
# account, the exact content of every service control policy - against
# fabricated values. It proves nothing about a real apply, which this
# repository never runs. `command = apply` is a simulated run against the
# mock provider. No account ID or mailbox below is real.

mock_provider "aws" {
  override_resource {
    target = aws_organizations_organization.this
    values = {
      id                = "o-exampleorg01"
      master_account_id = "management-account"
      roots             = [{ id = "r-ab12", arn = "root-arn", name = "Root", policy_types = [] }]
    }
  }
  # The provider validates account IDs as exactly 12 digits even under a
  # mock. The value is generated here so no 12-digit literal is ever
  # committed (scripts/validate/check-forbidden-terms.sh).
  override_resource {
    target = aws_organizations_account.this
    values = { id = format("%012d", 42) }
  }
  override_resource {
    target = aws_organizations_organizational_unit.security
    values = { id = "ou-ab12-security" }
  }
  override_resource {
    target = aws_organizations_organizational_unit.platform
    values = { id = "ou-ab12-platform" }
  }
  override_resource {
    target = aws_organizations_organizational_unit.workloads
    values = { id = "ou-ab12-workloads" }
  }
  override_resource {
    target = aws_organizations_organizational_unit.nonprod
    values = { id = "ou-ab12-nonprod1" }
  }
  override_resource {
    target = aws_organizations_organizational_unit.prod
    values = { id = "ou-ab12-prodou01" }
  }
}

variables {
  owner           = "IngMatrix-PGB"
  allowed_regions = ["us-east-1", "us-west-2"]
  account_emails = {
    security = "aws+security@example.invalid"
    platform = "aws+platform@example.invalid"
    dev      = "aws+dev@example.invalid"
    uat      = "aws+uat@example.invalid"
    prod     = "aws+prod@example.invalid"
  }
  monthly_budget_usd         = 200
  budget_notification_emails = ["finops@example.invalid"]
}

run "organization_accounts_and_ous" {
  command = apply

  assert {
    condition     = aws_organizations_organization.this.feature_set == "ALL" && contains(aws_organizations_organization.this.enabled_policy_types, "SERVICE_CONTROL_POLICY")
    error_message = "The organization must enable all features and service control policies."
  }
  assert {
    condition     = toset(keys(aws_organizations_account.this)) == toset(["security", "platform", "dev", "uat", "prod"])
    error_message = "Exactly five member accounts must be created: security, platform, dev, uat, prod."
  }
  assert {
    condition = (
      aws_organizations_account.this["security"].parent_id == "ou-ab12-security" &&
      aws_organizations_account.this["platform"].parent_id == "ou-ab12-platform" &&
      aws_organizations_account.this["dev"].parent_id == "ou-ab12-nonprod1" &&
      aws_organizations_account.this["uat"].parent_id == "ou-ab12-nonprod1" &&
      aws_organizations_account.this["prod"].parent_id == "ou-ab12-prodou01"
    )
    error_message = "Each account must sit in its OU (security, platform, nonprod for dev/uat, prod)."
  }
  assert {
    condition     = aws_organizations_organizational_unit.nonprod.parent_id == "ou-ab12-workloads" && aws_organizations_organizational_unit.prod.parent_id == "ou-ab12-workloads"
    error_message = "NonProd and Prod must be nested under Workloads."
  }
  assert {
    condition     = alltrue([for a in aws_organizations_account.this : a.close_on_deletion == false && a.iam_user_access_to_billing == "DENY"])
    error_message = "No account may be closed by removing it from configuration, and IAM users never get billing access."
  }
}

run "guardrails_attached_where_intended" {
  command = apply

  assert {
    condition     = toset([for a in aws_organizations_policy_attachment.root : a.target_id]) == toset(["r-ab12"])
    error_message = "Region and member-hardening guardrails must be attached to the organization root."
  }
  assert {
    condition     = length(aws_organizations_policy_attachment.root) == 2
    error_message = "Exactly two policies (region guardrail, member hardening) must be attached to the root."
  }
  assert {
    condition     = toset([for a in aws_organizations_policy_attachment.security_services : a.target_id]) == toset(["ou-ab12-platform", "ou-ab12-workloads"])
    error_message = "Security-service protection must apply to the Platform and Workloads OUs only."
  }
  assert {
    condition     = !contains([for a in aws_organizations_policy_attachment.security_services : a.target_id], "ou-ab12-security")
    error_message = "Security-service protection must never be attached to the Security OU (the delegated administrator manages those services)."
  }
  assert {
    condition     = alltrue([for p in [aws_organizations_policy.region_guardrail, aws_organizations_policy.member_hardening, aws_organizations_policy.security_services] : p.type == "SERVICE_CONTROL_POLICY"])
    error_message = "Every guardrail must be a service control policy."
  }
}

run "service_control_policy_content" {
  command = apply

  assert {
    condition     = alltrue([for p in [module.scp.region_guardrail_json, module.scp.member_hardening_json, module.scp.security_services_json] : length(p) <= 5120])
    error_message = "Every SCP must fit the 5,120-character limit."
  }
  assert {
    condition     = jsondecode(module.scp.region_guardrail_json).Statement[0].Condition.StringNotEquals["aws:RequestedRegion"] == ["us-east-1", "us-west-2"]
    error_message = "The region guardrail must deny exactly outside allowed_regions."
  }
  assert {
    condition     = alltrue([for a in ["iam:*", "sts:*", "organizations:*", "support:*", "budgets:*", "route53:*", "cloudfront:*"] : contains(jsondecode(module.scp.region_guardrail_json).Statement[0].NotAction, a)])
    error_message = "The region guardrail must exempt the global services (iam, sts, organizations, support, budgets, route53, cloudfront)."
  }
  assert {
    condition = length(setintersection(toset(jsondecode(module.scp.region_guardrail_json).Statement[0].NotAction), toset([
      "ec2:*", "eks:*", "ecr:*", "s3:*", "rds:*", "lambda:*", "dynamodb:*", "secretsmanager:*",
      "elasticloadbalancing:*", "autoscaling:*", "logs:*", "sqs:*", "sns:*", "guardduty:*", "securityhub:*",
    ]))) == 0
    error_message = "The region guardrail must never exempt a regional service as a whole (that would let it run in any region)."
  }
  assert {
    condition     = jsondecode(module.scp.region_guardrail_json).Statement[0].Effect == "Deny" && !can(jsondecode(module.scp.region_guardrail_json).Statement[0].Action)
    error_message = "The region guardrail must be a Deny with NotAction, never an Action list."
  }
  assert {
    condition     = alltrue([for a in ["guardduty:DeleteDetector", "guardduty:DisassociateFromAdministratorAccount", "config:StopConfigurationRecorder", "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "securityhub:DisableSecurityHub", "access-analyzer:DeleteAnalyzer"] : contains(jsondecode(module.scp.security_services_json).Statement[0].Action, a)])
    error_message = "The security-services guardrail must deny disabling GuardDuty, Config, CloudTrail, Security Hub and Access Analyzer."
  }
  assert {
    condition     = jsondecode(module.scp.security_services_json).Statement[0].Condition.ArnNotLike["aws:PrincipalArn"] == ["arn:aws:iam::*:role/OrganizationAccountAccessRole"]
    error_message = "Only the account access role may be exempted from the security-services guardrail."
  }
  assert {
    condition = anytrue([for s in jsondecode(module.scp.member_hardening_json).Statement :
    s.Sid == "DenyRootUser" && s.Action == "*" && s.Condition.ArnLike["aws:PrincipalArn"] == ["arn:aws:iam::*:root"] && !can(s.Condition.ArnNotLike)])
    error_message = "Root-user actions must be denied in members with no exemption."
  }
  assert {
    condition = anytrue([for s in jsondecode(module.scp.member_hardening_json).Statement :
    s.Sid == "DenyLeaveOrganization" && s.Action == ["organizations:LeaveOrganization"] && !can(s.Condition)])
    error_message = "Leaving the organization must be denied unconditionally."
  }
  assert {
    condition     = alltrue([for p in [module.scp.region_guardrail_json, module.scp.member_hardening_json, module.scp.security_services_json] : !strcontains(p, "\"Allow\"")])
    error_message = "Guardrails are deny-only; no SCP may contain an Allow statement."
  }
}

# Cross-check with terraform/envs/account-baseline (Phase 3.4.2): every
# write the baseline performs must either be outside every SCP's denied
# actions, or be denied only in a statement that exempts the account
# access role the baseline is applied through. A future SCP change that
# would lock the baseline out fails here.
run "baseline_actions_not_locked_out" {
  command = apply

  assert {
    condition = alltrue(flatten([
      for doc in [module.scp.member_hardening_json, module.scp.security_services_json] : [
        for st in jsondecode(doc).Statement : [
          for a in [
            "config:PutConfigurationRecorder", "config:PutDeliveryChannel",
            "config:StartConfigurationRecorder", "config:PutRetentionConfiguration",
            "ec2:EnableEbsEncryptionByDefault", "ec2:ModifyInstanceMetadataDefaults",
            "s3:PutAccountPublicAccessBlock", "budgets:ModifyBudget",
            "iam:CreateServiceLinkedRole",
          ] :
          !(st.Effect == "Deny" && (try(contains(st.Action, a), false) || try(st.Action == "*", false))) ||
          try(contains(st.Condition.ArnNotLike["aws:PrincipalArn"], "arn:aws:iam::*:role/OrganizationAccountAccessRole"), false) ||
          try(st.Condition.ArnLike["aws:PrincipalArn"] == ["arn:aws:iam::*:root"], false)
        ]
      ]
    ]))
    error_message = "An SCP denies an action the account baseline needs without exempting the account access role."
  }
}

run "delegated_administration_to_security_account" {
  command = apply

  assert {
    condition     = aws_guardduty_organization_admin_account.security.admin_account_id == aws_organizations_account.this["security"].id
    error_message = "GuardDuty must be delegated to the security account."
  }
  assert {
    condition     = aws_securityhub_organization_admin_account.security.admin_account_id == aws_organizations_account.this["security"].id
    error_message = "Security Hub must be delegated to the security account."
  }
  assert {
    condition = alltrue([for d in aws_organizations_delegated_administrator.security : d.account_id == aws_organizations_account.this["security"].id]) && toset(keys(aws_organizations_delegated_administrator.security)) == toset([
      "access-analyzer.amazonaws.com", "config.amazonaws.com", "config-multiaccountsetup.amazonaws.com",
    ])
    error_message = "Access Analyzer and Config must be delegated to the security account."
  }
  assert {
    condition     = aws_guardduty_organization_admin_account.security.admin_account_id != aws_organizations_organization.this.master_account_id
    error_message = "The management account must never be a delegated administrator."
  }
  assert {
    condition     = length(aws_cloudtrail.organization) == 0
    error_message = "The organization trail must not be planned before envs/security provides its bucket and key."
  }
}

run "organization_trail_second_apply" {
  command = apply

  variables {
    org_trail_bucket_name = "example-org-trail-bucket"
    org_trail_kms_key_arn = "arn:aws:kms:us-east-1:aws:key/example"
  }

  assert {
    condition = (
      aws_cloudtrail.organization[0].is_organization_trail &&
      aws_cloudtrail.organization[0].is_multi_region_trail &&
      aws_cloudtrail.organization[0].include_global_service_events &&
      aws_cloudtrail.organization[0].enable_log_file_validation
    )
    error_message = "The organization trail must be org-wide, multi-region, include global events and validate log files."
  }
  assert {
    condition     = aws_cloudtrail.organization[0].s3_bucket_name == "example-org-trail-bucket" && aws_cloudtrail.organization[0].kms_key_id == "arn:aws:kms:us-east-1:aws:key/example"
    error_message = "The trail must deliver to the security account's bucket, encrypted with its key."
  }
}

run "budget_alerts" {
  command = apply

  assert {
    condition     = aws_budgets_budget.organization.limit_amount == "200" && aws_budgets_budget.organization.time_unit == "MONTHLY" && aws_budgets_budget.organization.budget_type == "COST"
    error_message = "The organization budget must be a monthly cost budget at monthly_budget_usd."
  }
  assert {
    condition = toset([for n in aws_budgets_budget.organization.notification : "${n.notification_type}:${n.threshold}"]) == toset([
      "ACTUAL:80", "ACTUAL:100", "FORECASTED:100",
    ])
    error_message = "Budget alerts must fire at 80 % and 100 % actual and 100 % forecasted."
  }
}

# --- rejections ----------------------------------------------------------------
run "rejects_duplicate_account_email" {
  command = plan
  variables {
    account_emails = {
      security = "aws+same@example.invalid"
      platform = "aws+same@example.invalid"
      dev      = "aws+dev@example.invalid"
      uat      = "aws+uat@example.invalid"
      prod     = "aws+prod@example.invalid"
    }
  }
  expect_failures = [var.account_emails]
}

run "rejects_missing_account" {
  command = plan
  variables {
    account_emails = {
      security = "aws+security@example.invalid"
      platform = "aws+platform@example.invalid"
      dev      = "aws+dev@example.invalid"
      prod     = "aws+prod@example.invalid"
    }
  }
  expect_failures = [var.account_emails]
}

run "rejects_trail_bucket_without_key" {
  command = plan
  variables {
    org_trail_bucket_name = "example-org-trail-bucket"
  }
  expect_failures = [var.org_trail_kms_key_arn]
}

run "rejects_zero_budget" {
  command = plan
  variables {
    monthly_budget_usd = 0
  }
  expect_failures = [var.monthly_budget_usd]
}

run "rejects_bad_region" {
  command = plan
  variables {
    allowed_regions = ["us-east-1", "everywhere"]
  }
  expect_failures = [var.allowed_regions]
}
