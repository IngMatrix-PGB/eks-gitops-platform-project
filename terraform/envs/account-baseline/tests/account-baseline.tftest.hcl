# Structural correctness only (Phase 3.4.2): mock_provider "aws" proves
# this root's own logic - one recorder per allowed region with the global
# IAM types only in home_region, the per-environment frequency and
# retention, the delivery path, the EC2 defaults in every region, the S3
# account block and the budget - against fabricated values. Nothing is
# ever applied against AWS.

mock_provider "aws" {
  override_resource {
    target = aws_iam_service_linked_role.config
    values = { arn = "arn:aws:iam::aws:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig" }
  }
}

variables {
  owner                      = "IngMatrix-PGB"
  account_role               = "dev"
  allowed_regions            = ["us-east-1", "us-west-2"]
  home_region                = "us-east-1"
  config_bucket_name         = "example-config"
  config_kms_key_arn         = "arn:aws:kms:us-east-1:aws:key/example-config"
  monthly_budget_usd         = 50
  budget_notification_emails = ["finops@example.invalid"]
}

run "config_recorders_per_region_non_prod" {
  command = apply

  assert {
    condition     = toset([for r in aws_config_configuration_recorder.this : r.region]) == toset(["us-east-1", "us-west-2"])
    error_message = "Every allowed region must get exactly one recorder, created in that region."
  }
  assert {
    condition     = alltrue([for r in aws_config_configuration_recorder.this : one(one(r.recording_group).recording_strategy).use_only == "INCLUSION_BY_RESOURCE_TYPES" && one(r.recording_group).all_supported == false])
    error_message = "Recorders must record an explicit list of resource types, never all supported types."
  }
  assert {
    condition     = contains(one(aws_config_configuration_recorder.this["us-east-1"].recording_group).resource_types, "AWS::IAM::Role") && !contains(one(aws_config_configuration_recorder.this["us-west-2"].recording_group).resource_types, "AWS::IAM::Role")
    error_message = "Global IAM types must be recorded only in home_region."
  }
  assert {
    condition     = alltrue([for t in ["AWS::EKS::Cluster", "AWS::EC2::SecurityGroup", "AWS::S3::Bucket", "AWS::KMS::Key", "AWS::ECR::Repository", "AWS::SecretsManager::Secret"] : contains(one(aws_config_configuration_recorder.this["us-west-2"].recording_group).resource_types, t)])
    error_message = "Every region must record EKS, security groups, S3, KMS, ECR and Secrets Manager."
  }
  assert {
    condition     = alltrue([for r in aws_config_configuration_recorder.this : one(r.recording_mode).recording_frequency == "DAILY"])
    error_message = "Outside prod, recording must be daily."
  }
  assert {
    condition     = alltrue([for r in aws_config_retention_configuration.this : r.retention_period_in_days == 365])
    error_message = "Outside prod, Config history is kept 365 days."
  }
  assert {
    condition     = alltrue([for d in aws_config_delivery_channel.this : d.s3_bucket_name == "example-config" && d.s3_key_prefix == "config/dev" && d.s3_kms_key_arn == "arn:aws:kms:us-east-1:aws:key/example-config"])
    error_message = "Every region must deliver to the central bucket under config/<account_role>, encrypted with the central key."
  }
  assert {
    condition     = toset([for d in aws_config_delivery_channel.this : d.region]) == toset(["us-east-1", "us-west-2"]) && alltrue([for s in aws_config_configuration_recorder_status.this : s.is_enabled])
    error_message = "Each region must have its delivery channel and an enabled recorder."
  }
}

run "config_prod_is_continuous" {
  command = apply
  variables {
    account_role = "prod"
  }

  assert {
    condition     = alltrue([for r in aws_config_configuration_recorder.this : one(r.recording_mode).recording_frequency == "CONTINUOUS"])
    error_message = "prod must record continuously."
  }
  assert {
    condition     = alltrue([for r in aws_config_retention_configuration.this : r.retention_period_in_days == 2557])
    error_message = "prod keeps Config history for the 7-year maximum."
  }
  assert {
    condition     = alltrue([for d in aws_config_delivery_channel.this : d.s3_key_prefix == "config/prod"])
    error_message = "prod must deliver under config/prod."
  }
}

run "ec2_and_s3_hardening" {
  command = apply

  assert {
    condition     = toset([for e in aws_ebs_encryption_by_default.this : "${e.region}:${e.enabled}"]) == toset(["us-east-1:true", "us-west-2:true"])
    error_message = "EBS encryption by default must be on in every allowed region."
  }
  assert {
    condition     = alltrue([for m in aws_ec2_instance_metadata_defaults.this : m.http_tokens == "required" && m.http_put_response_hop_limit == 2]) && length(aws_ec2_instance_metadata_defaults.this) == 2
    error_message = "IMDSv2 must be required account-wide in every allowed region (hop limit 2)."
  }
  assert {
    condition = (
      aws_s3_account_public_access_block.this.block_public_acls &&
      aws_s3_account_public_access_block.this.block_public_policy &&
      aws_s3_account_public_access_block.this.ignore_public_acls &&
      aws_s3_account_public_access_block.this.restrict_public_buckets
    )
    error_message = "The S3 account-level public access block must set all four flags."
  }
}

run "account_budget" {
  command = apply

  assert {
    condition     = aws_budgets_budget.account.limit_amount == "50" && aws_budgets_budget.account.name == "eks-gitops-platform-project-dev-monthly"
    error_message = "Each account gets its own monthly budget at monthly_budget_usd."
  }
  assert {
    condition     = toset([for n in aws_budgets_budget.account.notification : "${n.notification_type}:${n.threshold}"]) == toset(["ACTUAL:80", "ACTUAL:100", "FORECASTED:100"])
    error_message = "Budget alerts must fire at 80 % and 100 % actual and 100 % forecasted."
  }
}

run "shared_accounts_tagged_shared" {
  command = apply
  variables {
    account_role = "security"
  }

  assert {
    condition     = aws_budgets_budget.account.tags["Environment"] == "shared"
    error_message = "security and platform are tagged as shared, not as a workload environment."
  }
}

# --- rejections ----------------------------------------------------------------
run "rejects_unknown_account_role" {
  command = plan
  variables {
    account_role = "qa"
  }
  expect_failures = [var.account_role]
}

run "rejects_home_region_outside_allowed" {
  command = plan
  variables {
    home_region = "eu-west-1"
  }
  expect_failures = [check.home_region_is_allowed]
}

run "rejects_zero_budget" {
  command = plan
  variables {
    monthly_budget_usd = 0
  }
  expect_failures = [var.monthly_budget_usd]
}

run "rejects_non_kms_arn" {
  command = plan
  variables {
    config_kms_key_arn = "alias/aws/s3"
  }
  expect_failures = [var.config_kms_key_arn]
}
