# Phase 3.4.1 - the security account: delegated administrator for
# GuardDuty, Security Hub, AWS Config and IAM Access Analyzer, and home of
# the organization trail's bucket and key
# (docs/adr/0016-aws-organization-and-guardrails.md). Plan-only: never
# applied by this repository. Policies are built with jsonencode() so
# terraform test can assert their content (see modules/scp).

module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

data "aws_caller_identity" "current" {}

locals {
  security_account_id = data.aws_caller_identity.current.account_id
  org_trail_arn       = "arn:aws:cloudtrail:${var.aws_region}:${var.management_account_id}:trail/${var.org_trail_name}"
  bucket_name         = "${var.project}-org-trail-${local.security_account_id}"
}

# --- organization trail: KMS key ---------------------------------------------
resource "aws_kms_key" "org_trail" {
  description             = "Encrypts the organization CloudTrail logs."
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "SecurityAccountAdministers"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.security_account_id}:root" }
        # Explicit administration and log-reading actions instead of
        # kms:* (scripts/validate/check-terraform-offline.sh rule 15):
        # the security account manages the key and decrypts the logs;
        # only the organization trail encrypts with it.
        Action = [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
          "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
          "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource",
          "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
          "kms:Decrypt", "kms:ReEncryptFrom",
        ]
        Resource = "*"
      },
      {
        Sid       = "OrgTrailEncrypts"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:GenerateDataKey*"
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceArn" = local.org_trail_arn }
          StringLike   = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${var.management_account_id}:trail/*" }
        }
      },
      {
        Sid       = "OrgTrailDescribes"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:DescribeKey"
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceArn" = local.org_trail_arn }
        }
      },
    ]
  })

  tags = module.tags.tags
}

# --- organization trail: bucket ----------------------------------------------
resource "aws_s3_bucket" "org_trail" {
  bucket = local.bucket_name
  # Audit logs are never deleted by a terraform destroy.
  force_destroy = false
  tags          = module.tags.tags
}

resource "aws_s3_bucket_ownership_controls" "org_trail" {
  bucket = aws_s3_bucket.org_trail.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "org_trail" {
  bucket                  = aws_s3_bucket.org_trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "org_trail" {
  bucket = aws_s3_bucket.org_trail.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "org_trail" {
  bucket = aws_s3_bucket.org_trail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.org_trail.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "org_trail" {
  bucket = aws_s3_bucket.org_trail.id
  rule {
    id     = "expire-trail-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.trail_log_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "org_trail" {
  bucket = aws_s3_bucket.org_trail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "OrgTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.org_trail.arn
        Condition = { StringEquals = { "aws:SourceArn" = local.org_trail_arn } }
      },
      {
        Sid       = "OrgTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource = [
          "${aws_s3_bucket.org_trail.arn}/AWSLogs/${var.management_account_id}/*",
          "${aws_s3_bucket.org_trail.arn}/AWSLogs/${var.organization_id}/*",
        ]
        Condition = { StringEquals = { "aws:SourceArn" = local.org_trail_arn } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.org_trail.arn, "${aws_s3_bucket.org_trail.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.org_trail]
}

# --- GuardDuty: organization-wide --------------------------------------------
resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = module.tags.tags
}

resource "aws_guardduty_organization_configuration" "this" {
  detector_id                      = aws_guardduty_detector.this.id
  auto_enable_organization_members = "ALL"
}

# Protection plans auto-enabled for every member. EBS malware scanning is
# deliberately left out (per-scan cost; ADR-0016).
resource "aws_guardduty_organization_configuration_feature" "s3" {
  detector_id = aws_guardduty_detector.this.id
  name        = "S3_DATA_EVENTS"
  auto_enable = "ALL"
}

resource "aws_guardduty_organization_configuration_feature" "eks_audit" {
  detector_id = aws_guardduty_detector.this.id
  name        = "EKS_AUDIT_LOGS"
  auto_enable = "ALL"
}

resource "aws_guardduty_organization_configuration_feature" "runtime" {
  detector_id = aws_guardduty_detector.this.id
  name        = "RUNTIME_MONITORING"
  auto_enable = "ALL"

  additional_configuration {
    name        = "EKS_ADDON_MANAGEMENT"
    auto_enable = "ALL"
  }
}

# --- Security Hub: central configuration --------------------------------------
resource "aws_securityhub_account" "this" {
  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true
}

resource "aws_securityhub_organization_configuration" "this" {
  auto_enable           = false
  auto_enable_standards = "NONE"

  organization_configuration {
    configuration_type = "CENTRAL"
  }

  depends_on = [aws_securityhub_account.this]
}

locals {
  securityhub_standard_arns = [
    "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0",
    "arn:aws:securityhub:${var.aws_region}::standards/cis-aws-foundations-benchmark/v/3.0.0",
  ]
}

resource "aws_securityhub_configuration_policy" "organization" {
  name        = "${var.project}-organization"
  description = "Security Hub on in every account with the AWS Foundational Security Best Practices and CIS standards."

  configuration_policy {
    service_enabled       = true
    enabled_standard_arns = local.securityhub_standard_arns
    security_controls_configuration {
      disabled_control_identifiers = []
    }
  }

  depends_on = [aws_securityhub_organization_configuration.this]
}

resource "aws_securityhub_configuration_policy_association" "root" {
  target_id = var.organization_root_id
  policy_id = aws_securityhub_configuration_policy.organization.id
}

# --- AWS Config: organization aggregator -------------------------------------
resource "aws_iam_role" "config_aggregator" {
  name = "${var.project}-config-aggregator"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = module.tags.tags
}

resource "aws_iam_role_policy_attachment" "config_aggregator" {
  role       = aws_iam_role.config_aggregator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
}

resource "aws_config_configuration_aggregator" "organization" {
  name = "${var.project}-organization"

  organization_aggregation_source {
    role_arn    = aws_iam_role.config_aggregator.arn
    regions     = var.aggregated_regions
    all_regions = false
  }

  tags       = module.tags.tags
  depends_on = [aws_iam_role_policy_attachment.config_aggregator]
}

# --- IAM Access Analyzer: organization zone of trust --------------------------
resource "aws_accessanalyzer_analyzer" "organization" {
  analyzer_name = "${var.project}-organization"
  type          = "ORGANIZATION"
  tags          = module.tags.tags
}
