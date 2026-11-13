# Phase 3.4.2 - the baseline every member account gets (ADR-0016
# amendment). Plan-only: never applied by this repository. GuardDuty and
# Security Hub need nothing here (organization auto-enable from the
# security account), nor does IAM Access Analyzer (the organization
# analyzer covers every member).

check "home_region_is_allowed" {
  assert {
    condition     = contains(var.allowed_regions, var.home_region)
    error_message = "home_region must be one of allowed_regions."
  }
}

module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = contains(["dev", "uat", "prod"], var.account_role) ? var.account_role : "shared"
  owner       = var.owner
}

locals {
  is_prod = var.account_role == "prod"
  regions = toset(var.allowed_regions)

  # What AWS Config records (an explicit list, never "all supported" -
  # cost scales with what is recorded). Regional types are recorded in
  # every allowed region; the global IAM types only in home_region, so
  # they are recorded once.
  regional_resource_types = [
    "AWS::EKS::Cluster", "AWS::EKS::Nodegroup", "AWS::EKS::Addon",
    "AWS::EC2::Instance", "AWS::EC2::LaunchTemplate", "AWS::EC2::Volume",
    "AWS::EC2::SecurityGroup", "AWS::EC2::VPC", "AWS::EC2::Subnet",
    "AWS::EC2::RouteTable", "AWS::EC2::NetworkAcl", "AWS::EC2::EIP",
    "AWS::EC2::NatGateway", "AWS::AutoScaling::AutoScalingGroup",
    "AWS::ElasticLoadBalancingV2::LoadBalancer",
    "AWS::ElasticLoadBalancingV2::Listener",
    "AWS::S3::Bucket", "AWS::S3::AccountPublicAccessBlock",
    "AWS::KMS::Key", "AWS::ECR::Repository", "AWS::SecretsManager::Secret",
    "AWS::Lambda::Function", "AWS::SQS::Queue", "AWS::Events::Rule",
    "AWS::CloudTrail::Trail", "AWS::Config::ResourceCompliance",
  ]
  global_resource_types = [
    "AWS::IAM::Role", "AWS::IAM::Policy", "AWS::IAM::User", "AWS::IAM::Group",
  ]

  # prod records every change; elsewhere a daily snapshot is enough.
  recording_frequency = local.is_prod ? "CONTINUOUS" : "DAILY"
  # 2557 days (7 years) is AWS Config's maximum and default.
  config_retention_days = local.is_prod ? 2557 : 365
}

# --- AWS Config, in every allowed region ---------------------------------------
resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
  tags             = module.tags.tags
}

resource "aws_config_configuration_recorder" "this" {
  for_each = local.regions

  region   = each.key
  name     = "${var.project}-recorder"
  role_arn = aws_iam_service_linked_role.config.arn

  recording_group {
    all_supported                 = false
    include_global_resource_types = false
    resource_types                = each.key == var.home_region ? concat(local.regional_resource_types, local.global_resource_types) : local.regional_resource_types

    recording_strategy {
      use_only = "INCLUSION_BY_RESOURCE_TYPES"
    }
  }

  recording_mode {
    recording_frequency = local.recording_frequency
  }
}

resource "aws_config_delivery_channel" "this" {
  for_each = local.regions

  region         = each.key
  name           = "${var.project}-delivery"
  s3_bucket_name = var.config_bucket_name
  s3_key_prefix  = "config/${var.account_role}"
  s3_kms_key_arn = var.config_kms_key_arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  for_each = local.regions

  region     = each.key
  name       = aws_config_configuration_recorder.this[each.key].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

resource "aws_config_retention_configuration" "this" {
  for_each = local.regions

  region                   = each.key
  retention_period_in_days = local.config_retention_days
}

# --- EC2 defaults, in every allowed region -------------------------------------
resource "aws_ebs_encryption_by_default" "this" {
  for_each = local.regions

  region  = each.key
  enabled = true
}

# IMDSv2 required account-wide; hop limit 2 so a pod on an EKS node can
# still reach IMDS where it must (node groups and Karpenter set their own
# launch templates in Phase 3.4.3).
resource "aws_ec2_instance_metadata_defaults" "this" {
  for_each = local.regions

  region                      = each.key
  http_tokens                 = "required"
  http_put_response_hop_limit = 2
}

# --- S3 account-level public access block (global) -----------------------------
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- budget for this account -----------------------------------------------------
resource "aws_budgets_budget" "account" {
  name         = "${var.project}-${var.account_role}-monthly"
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
