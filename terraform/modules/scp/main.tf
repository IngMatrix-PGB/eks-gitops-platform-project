locals {
  exempt_principal_arns = [for n in var.exempt_role_names : "arn:aws:iam::*:role/${n}"]

  # Global (or region-agnostic) actions that must keep working whatever
  # the request region is - AWS's documented starting list for a
  # region-restriction SCP. Anything not listed is denied outside
  # var.allowed_regions.
  global_actions = [
    "a4b:*", "acm:*", "aws-marketplace-management:*", "aws-marketplace:*",
    "aws-portal:*", "budgets:*", "ce:*", "chime:*", "cloudfront:*",
    "config:*", "cur:*", "directconnect:*", "ec2:DescribeRegions",
    "ec2:DescribeTransitGateways", "ec2:DescribeVpnGateways", "fms:*",
    "globalaccelerator:*", "health:*", "iam:*", "importexport:*", "kms:*",
    "mobileanalytics:*", "networkmanager:*", "organizations:*", "pricing:*",
    "route53:*", "route53domains:*", "route53-recovery-cluster:*",
    "route53-recovery-control-config:*", "route53-recovery-readiness:*",
    "s3:GetAccountPublic*", "s3:ListAllMyBuckets",
    "s3:ListMultiRegionAccessPoints", "s3:PutAccountPublic*", "shield:*",
    "sts:*", "support:*", "trustedadvisor:*", "waf-regional:*", "waf:*",
    "wafv2:*", "wellarchitected:*",
  ]

  # Actions that would switch off or blind a security service. Denied to
  # everyone except var.exempt_role_names; the delegated-admin account
  # (security OU) is not attached this policy (see envs/org).
  security_service_actions = [
    "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount",
    "guardduty:DisassociateFromAdministratorAccount", "guardduty:UpdateDetector",
    "guardduty:DeleteMembers", "guardduty:DisassociateMembers",
    "guardduty:StopMonitoringMembers",
    "config:DeleteConfigurationRecorder", "config:DeleteDeliveryChannel",
    "config:StopConfigurationRecorder", "config:DeleteRetentionConfiguration",
    "cloudtrail:DeleteTrail", "cloudtrail:StopLogging", "cloudtrail:UpdateTrail",
    "cloudtrail:PutEventSelectors",
    "securityhub:DisableSecurityHub", "securityhub:DisassociateFromMasterAccount",
    "securityhub:DisassociateFromAdministratorAccount", "securityhub:DeleteMembers",
    "securityhub:DisassociateMembers", "securityhub:BatchDisableStandards",
    "access-analyzer:DeleteAnalyzer",
  ]

  # Account-level hardening a member must not undo (set by the account
  # baseline, Phase 3.4.2).
  hardening_actions = [
    "ec2:DisableEbsEncryptionByDefault",
    "s3:PutAccountPublicAccessBlock",
    "s3:DeleteAccountPublicAccessBlock",
  ]

  region_guardrail = {
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyOutsideAllowedRegions"
      Effect    = "Deny"
      NotAction = local.global_actions
      Resource  = "*"
      Condition = {
        StringNotEquals = { "aws:RequestedRegion" = var.allowed_regions }
      }
    }]
  }

  security_services = {
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ProtectSecurityServices"
      Effect   = "Deny"
      Action   = local.security_service_actions
      Resource = "*"
      Condition = {
        ArnNotLike = { "aws:PrincipalArn" = local.exempt_principal_arns }
      }
    }]
  }

  member_hardening = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyLeaveOrganization"
        Effect   = "Deny"
        Action   = ["organizations:LeaveOrganization"]
        Resource = "*"
      },
      {
        Sid      = "DenyRootUser"
        Effect   = "Deny"
        Action   = "*"
        Resource = "*"
        Condition = {
          ArnLike = { "aws:PrincipalArn" = ["arn:aws:iam::*:root"] }
        }
      },
      {
        Sid      = "ProtectAccountHardening"
        Effect   = "Deny"
        Action   = local.hardening_actions
        Resource = "*"
        Condition = {
          ArnNotLike = { "aws:PrincipalArn" = local.exempt_principal_arns }
        }
      },
    ]
  }
}
