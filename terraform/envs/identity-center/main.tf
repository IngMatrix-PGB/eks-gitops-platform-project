# Phase 4d (ADR-0025): human access to AWS through IAM Identity Center, as
# offline-tested code; never applied here. Identity Center's own directory
# holds the groups (a future external IdP would provision the same names
# through SCIM). People are added to groups outside Terraform.
#
#   - four permission sets, AWS managed policies only, plus one small
#     inline policy (Developer: describe the project's EKS clusters);
#   - standing assignments as data: admins and developers only in
#     non-prod; prod gets ReadOnly only;
#   - time-bound elevations (var.elevations) for anything more, prod
#     included, each at most 8 hours and refused by CI once expired.
#
# Lives where the Identity Center instance lives: the management account
# (or its delegated administrator).

module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

locals {
  groups = {
    platform-admins = "Platform administrators: admin in non-prod; read-only in prod unless elevated"
    developers-dev  = "Application developers, dev account"
    developers-uat  = "Application developers, uat account"
    auditors        = "Read-only auditors, every account"
    breakglass      = "Break-glass responders: no standing access; elevated per incident"
  }

  # Session lengths are ISO 8601 durations; one hour except ReadOnly.
  permission_sets = {
    PlatformAdmin = {
      description      = "Administer a non-prod account (standing) or prod (elevation only)"
      session_duration = "PT1H"
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    }
    Developer = {
      description      = "See an environment's resources and reach its EKS cluster; Kubernetes rights come from the cluster's access entry"
      session_duration = "PT1H"
      managed_policies = ["arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"]
    }
    ReadOnly = {
      description      = "Read every resource and its security configuration"
      session_duration = "PT4H"
      managed_policies = ["arn:aws:iam::aws:policy/ReadOnlyAccess", "arn:aws:iam::aws:policy/SecurityAudit"]
    }
    BreakGlass = {
      description      = "Incident response in any account; elevation only, never standing"
      session_duration = "PT1H"
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    }
  }

  # Standing access: group -> permission set -> accounts. No admin and no
  # developer access in prod; break-glass has nothing standing.
  standing = {
    platform-admins = {
      PlatformAdmin = ["platform", "dev", "uat"]
      ReadOnly      = ["security", "prod"]
    }
    developers-dev = { Developer = ["dev"] }
    developers-uat = { Developer = ["uat"] }
    auditors       = { ReadOnly = ["security", "platform", "dev", "uat", "prod"] }
  }

  standing_assignments = merge([
    for g, sets in local.standing : merge([
      for ps, accounts in sets : {
        for a in accounts : "${g}/${ps}/${a}" => { group = g, permission_set = ps, account = a }
      }
    ]...)
  ]...)

  elevation_assignments = {
    for e in var.elevations : "${e.group}/${e.permission_set}/${e.account}" => e
  }

  managed_policy_attachments = merge([
    for ps, cfg in local.permission_sets : {
      for p in cfg.managed_policies : "${ps}/${p}" => { permission_set = ps, policy_arn = p }
    }
  ]...)
}

resource "aws_identitystore_group" "this" {
  for_each = local.groups

  identity_store_id = var.identity_store_id
  display_name      = each.key
  description       = each.value
}

resource "aws_ssoadmin_permission_set" "this" {
  for_each = local.permission_sets

  instance_arn     = var.sso_instance_arn
  name             = each.key
  description      = each.value.description
  session_duration = each.value.session_duration

  tags = module.tags.tags
}

resource "aws_ssoadmin_managed_policy_attachment" "this" {
  for_each = local.managed_policy_attachments

  instance_arn       = var.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.permission_set].arn
  managed_policy_arn = each.value.policy_arn
}

# ViewOnlyAccess lists clusters but does not let `aws eks
# update-kubeconfig` describe one; this grants exactly that, on the
# project's clusters only. Plain jsonencode (no data source), so the
# tests read the exact document.
resource "aws_ssoadmin_permission_set_inline_policy" "developer" {
  instance_arn       = var.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this["Developer"].arn
  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DescribeProjectClusters"
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = ["arn:aws:eks:*:*:cluster/${var.eks_cluster_name_prefix}*"]
    }]
  })
}

resource "aws_ssoadmin_account_assignment" "standing" {
  for_each = local.standing_assignments

  instance_arn       = var.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.permission_set].arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.this[each.value.group].group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = var.account_ids[each.value.account]
}

resource "aws_ssoadmin_account_assignment" "elevation" {
  for_each = local.elevation_assignments

  instance_arn       = var.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.this[each.value.permission_set].arn
  principal_type     = "GROUP"
  principal_id       = aws_identitystore_group.this[each.value.group].group_id
  target_type        = "AWS_ACCOUNT"
  target_id          = var.account_ids[each.value.account]

  lifecycle {
    precondition {
      condition     = !contains(keys(local.standing_assignments), each.key)
      error_message = "This elevation repeats a standing assignment: it would grant nothing, and removing it later would remove the standing access too."
    }
  }
}
