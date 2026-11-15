# Structural correctness only (Phase 3.4.1): mock_provider "aws" proves
# this root's own logic - the trail bucket and key only admit the one
# organization trail, organization-wide GuardDuty with the intended
# protection plans, central Security Hub configuration, the Config
# aggregator and the organization Access Analyzer - against fabricated
# values. Nothing here is ever applied against AWS. Account IDs are
# generated with format() so no 12-digit literal is committed
# (scripts/validate/check-forbidden-terms.sh).

mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = format("%012d", 7) }
  }
  # The provider validates these shapes even under a mock (a UUID policy
  # ID, an ARN for the aggregator role).
  override_resource {
    target = aws_securityhub_configuration_policy.organization
    values = { id = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d" }
  }
  override_resource {
    target = aws_iam_role.config_aggregator
    values = { arn = "arn:aws:iam::aws:role/example-config-aggregator" }
  }
  override_resource {
    target = aws_s3_bucket.org_trail
    values = { arn = "arn:aws:s3:::example-org-trail", bucket = "example-org-trail", id = "example-org-trail" }
  }
  override_resource {
    target = aws_kms_key.org_trail
    values = { arn = "arn:aws:kms:us-east-1:aws:key/example" }
  }
  override_resource {
    target = aws_s3_bucket.config
    values = { arn = "arn:aws:s3:::example-config", bucket = "example-config", id = "example-config" }
  }
  override_resource {
    target = aws_kms_key.config
    values = { arn = "arn:aws:kms:us-east-1:aws:key/example-config" }
  }
}

variables {
  owner                 = "IngMatrix-PGB"
  aws_region            = "us-east-1"
  aggregated_regions    = ["us-east-1", "us-west-2"]
  organization_id       = "o-exampleorg01"
  organization_root_id  = "r-ab12"
  management_account_id = format("%012d", 5)
}

run "org_trail_bucket_and_key" {
  command = apply

  assert {
    condition     = !contains(flatten([for s in jsondecode(aws_kms_key.org_trail.policy).Statement : s.Action]), "kms:*") && !contains(flatten([for s in jsondecode(aws_kms_key.org_trail.policy).Statement : s.Action]), "kms:Encrypt")
    error_message = "The trail key policy must grant explicit actions only - no kms:* and no direct Encrypt for any principal."
  }
  assert {
    condition     = aws_kms_key.org_trail.enable_key_rotation && aws_kms_key.org_trail.deletion_window_in_days == 30
    error_message = "The trail key must rotate and keep the maximum deletion window."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_kms_key.org_trail.policy).Statement :
      s.Sid == "SecurityAccountAdministers" ? s.Principal.AWS == "arn:aws:iam::${format("%012d", 7)}:root" :
    s.Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:us-east-1:${format("%012d", 5)}:trail/org-trail"])
    error_message = "The key must be administered by the security account and used by the organization trail only."
  }
  assert {
    condition = (
      aws_s3_bucket_public_access_block.org_trail.block_public_acls &&
      aws_s3_bucket_public_access_block.org_trail.block_public_policy &&
      aws_s3_bucket_public_access_block.org_trail.ignore_public_acls &&
      aws_s3_bucket_public_access_block.org_trail.restrict_public_buckets
    )
    error_message = "The trail bucket must block every form of public access."
  }
  assert {
    condition     = aws_s3_bucket.org_trail.force_destroy == false && aws_s3_bucket_versioning.org_trail.versioning_configuration[0].status == "Enabled"
    error_message = "The trail bucket must be versioned and never force-destroyed."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.org_trail.rule).apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.org_trail.arn
    error_message = "The trail bucket must be encrypted with the trail key."
  }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.org_trail.rule).expiration[0].days == 365
    error_message = "Trail logs must expire after trail_log_retention_days (default 365)."
  }
  assert {
    condition = toset(flatten([for s in jsondecode(aws_s3_bucket_policy.org_trail.policy).Statement : s.Resource if s.Sid == "OrgTrailWrite"])) == toset([
      "${aws_s3_bucket.org_trail.arn}/AWSLogs/${format("%012d", 5)}/*",
      "${aws_s3_bucket.org_trail.arn}/AWSLogs/o-exampleorg01/*",
    ])
    error_message = "The trail may write only under the management account's and the organization's log prefixes."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_s3_bucket_policy.org_trail.policy).Statement :
    s.Effect == "Deny" || (s.Principal.Service == "cloudtrail.amazonaws.com" && s.Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:us-east-1:${format("%012d", 5)}:trail/org-trail")])
    error_message = "Every Allow in the bucket policy must be for CloudTrail, scoped to the organization trail."
  }
  assert {
    condition     = anytrue([for s in jsondecode(aws_s3_bucket_policy.org_trail.policy).Statement : s.Sid == "DenyInsecureTransport" && s.Effect == "Deny" && s.Condition.Bool["aws:SecureTransport"] == "false"])
    error_message = "The bucket policy must deny non-TLS access."
  }
}

run "guardduty_organization_wide" {
  command = apply

  assert {
    condition     = aws_guardduty_detector.this.enable && aws_guardduty_organization_configuration.this.auto_enable_organization_members == "ALL"
    error_message = "GuardDuty must be enabled and auto-enabled for every member, existing and new."
  }
  assert {
    condition = toset([for f in [
      aws_guardduty_organization_configuration_feature.s3,
      aws_guardduty_organization_configuration_feature.eks_audit,
      aws_guardduty_organization_configuration_feature.runtime,
    ] : "${f.name}:${f.auto_enable}"]) == toset(["S3_DATA_EVENTS:ALL", "EKS_AUDIT_LOGS:ALL", "RUNTIME_MONITORING:ALL"])
    error_message = "S3, EKS audit-log and runtime protection must be auto-enabled for all members."
  }
  assert {
    condition     = one(aws_guardduty_organization_configuration_feature.runtime.additional_configuration).name == "EKS_ADDON_MANAGEMENT" && one(aws_guardduty_organization_configuration_feature.runtime.additional_configuration).auto_enable == "ALL"
    error_message = "Runtime monitoring must manage its EKS add-on in every member."
  }
}

run "security_hub_central_configuration" {
  command = apply

  assert {
    condition     = one(aws_securityhub_organization_configuration.this.organization_configuration).configuration_type == "CENTRAL" && aws_securityhub_organization_configuration.this.auto_enable == false
    error_message = "Security Hub must use central configuration (policies), not local auto-enable."
  }
  assert {
    condition = one(aws_securityhub_configuration_policy.organization.configuration_policy).service_enabled && toset(one(aws_securityhub_configuration_policy.organization.configuration_policy).enabled_standard_arns) == toset([
      "arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0",
      "arn:aws:securityhub:us-east-1::standards/cis-aws-foundations-benchmark/v/3.0.0",
    ])
    error_message = "The central policy must enable Security Hub with the AWS FSBP and CIS 3.0 standards."
  }
  assert {
    condition     = aws_securityhub_configuration_policy_association.root.target_id == "r-ab12"
    error_message = "The central policy must be associated with the organization root."
  }
}

run "config_aggregator_and_access_analyzer" {
  command = apply

  assert {
    condition     = toset(one(aws_config_configuration_aggregator.organization.organization_aggregation_source).regions) == toset(["us-east-1", "us-west-2"]) && one(aws_config_configuration_aggregator.organization.organization_aggregation_source).all_regions == false
    error_message = "The Config aggregator must collect exactly the allowed regions, not all regions."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.config_aggregator.policy_arn == "arn:aws:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
    error_message = "The aggregator role must use the AWS-managed organizations aggregation policy only."
  }
  assert {
    condition     = jsondecode(aws_iam_role.config_aggregator.assume_role_policy).Statement[0].Principal.Service == "config.amazonaws.com"
    error_message = "Only AWS Config may assume the aggregator role."
  }
  assert {
    condition     = aws_accessanalyzer_analyzer.organization.type == "ORGANIZATION"
    error_message = "The Access Analyzer must use the organization as its zone of trust."
  }
}

run "central_config_bucket" {
  command = apply

  assert {
    condition = (
      aws_s3_bucket_public_access_block.config.block_public_acls &&
      aws_s3_bucket_public_access_block.config.block_public_policy &&
      aws_s3_bucket_public_access_block.config.ignore_public_acls &&
      aws_s3_bucket_public_access_block.config.restrict_public_buckets &&
      aws_s3_bucket.config.force_destroy == false &&
      aws_s3_bucket_versioning.config.versioning_configuration[0].status == "Enabled"
    )
    error_message = "The Config bucket must block public access, be versioned and never be force-destroyed."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.config.rule).apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.config.arn && aws_kms_key.config.enable_key_rotation
    error_message = "Config deliveries must be encrypted with the dedicated, rotating key."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_s3_bucket_policy.config.policy).Statement :
    s.Effect == "Deny" || (s.Principal.Service == "config.amazonaws.com" && s.Condition.StringEquals["aws:SourceOrgID"] == "o-exampleorg01")])
    error_message = "Every Allow in the Config bucket policy must be for AWS Config, scoped to this organization."
  }
  assert {
    condition     = one([for s in jsondecode(aws_s3_bucket_policy.config.policy).Statement : s.Resource if s.Sid == "OrganizationConfigDelivery"]) == "arn:aws:s3:::example-config/config/*/AWSLogs/*/Config/*"
    error_message = "AWS Config may write only under config/<account>/AWSLogs/<id>/Config/."
  }
  assert {
    condition     = anytrue([for s in jsondecode(aws_s3_bucket_policy.config.policy).Statement : s.Sid == "DenyInsecureTransport" && s.Effect == "Deny"])
    error_message = "The Config bucket policy must deny non-TLS access."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_kms_key.config.policy).Statement :
    s.Sid == "SecurityAccountAdministers" || (s.Principal.Service == "config.amazonaws.com" && s.Condition.StringEquals["aws:SourceOrgID"] == "o-exampleorg01" && toset(s.Action) == toset(["kms:GenerateDataKey", "kms:Decrypt"]))])
    error_message = "AWS Config may only generate data keys and decrypt, and only for this organization."
  }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.config.rule).expiration[0].days == 730
    error_message = "Config history must expire after config_log_retention_days (default 730)."
  }
}

run "rejects_short_config_retention" {
  command = plan
  variables {
    config_log_retention_days = 90
  }
  expect_failures = [var.config_log_retention_days]
}

# --- rejections ----------------------------------------------------------------
run "rejects_short_retention" {
  command = plan
  variables {
    trail_log_retention_days = 30
  }
  expect_failures = [var.trail_log_retention_days]
}

run "rejects_bad_organization_id" {
  command = plan
  variables {
    organization_id = "not-an-org"
  }
  expect_failures = [var.organization_id]
}

run "rejects_bad_management_account_id" {
  command = plan
  variables {
    management_account_id = "management"
  }
  expect_failures = [var.management_account_id]
}

run "rejects_bad_root_id" {
  command = plan
  variables {
    organization_root_id = "root"
  }
  expect_failures = [var.organization_root_id]
}
