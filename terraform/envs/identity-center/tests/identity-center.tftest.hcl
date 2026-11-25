# Structural correctness only (Phase 4d, ADR-0025): mock_provider "aws"
# proves the permission sets, the standing assignments and the elevation
# rules against fabricated values. Nothing is ever applied against AWS.
#
#   - four permission sets, AWS managed policies only, one-hour sessions
#     (four for ReadOnly), one inline policy with no wildcard action and
#     no Resource "*";
#   - standing access: no admin, developer or break-glass grant in prod,
#     ReadOnly only; developers only in their own account;
#   - elevations: accepted within 8 hours with a reason; refused without
#     an expiry, longer than 8 hours, reversed, unknown, unexplained,
#     duplicated, or repeating a standing assignment.

mock_provider "aws" {}

variables {
  sso_instance_arn  = "arn:aws:sso:::instance/ssoins-abcdefabcdefabcd"
  identity_store_id = "d-abcdefabcd"
  owner             = "not-a-real-owner-handle"
  account_ids = {
    security = format("%012d", 1)
    platform = format("%012d", 2)
    dev      = format("%012d", 11)
    uat      = format("%012d", 12)
    prod     = format("%012d", 13)
  }
}

run "permission_sets" {
  command = plan

  assert {
    condition     = toset(keys(aws_ssoadmin_permission_set.this)) == toset(["PlatformAdmin", "Developer", "ReadOnly", "BreakGlass"])
    error_message = "Exactly four permission sets."
  }
  assert {
    condition = (
      aws_ssoadmin_permission_set.this["PlatformAdmin"].session_duration == "PT1H" &&
      aws_ssoadmin_permission_set.this["Developer"].session_duration == "PT1H" &&
      aws_ssoadmin_permission_set.this["BreakGlass"].session_duration == "PT1H" &&
      aws_ssoadmin_permission_set.this["ReadOnly"].session_duration == "PT4H"
    )
    error_message = "Sessions last one hour, four for ReadOnly."
  }
  assert {
    condition     = alltrue([for a in aws_ssoadmin_managed_policy_attachment.this : startswith(a.managed_policy_arn, "arn:aws:iam::aws:policy/")])
    error_message = "Only AWS managed policies are attached."
  }
  assert {
    condition = toset([for k, a in aws_ssoadmin_managed_policy_attachment.this : k]) == toset([
      "PlatformAdmin/arn:aws:iam::aws:policy/AdministratorAccess",
      "Developer/arn:aws:iam::aws:policy/job-function/ViewOnlyAccess",
      "ReadOnly/arn:aws:iam::aws:policy/ReadOnlyAccess",
      "ReadOnly/arn:aws:iam::aws:policy/SecurityAudit",
      "BreakGlass/arn:aws:iam::aws:policy/AdministratorAccess",
    ])
    error_message = "Each permission set has exactly its managed policies."
  }
  assert {
    condition = alltrue([for st in jsondecode(aws_ssoadmin_permission_set_inline_policy.developer.inline_policy).Statement :
      st.Effect == "Allow" && !contains(st.Action, "*") && !anytrue([for a in st.Action : endswith(a, ":*")]) && !contains(st.Resource, "*")
    ])
    error_message = "The Developer inline policy has no wildcard action and no Resource \"*\"."
  }
  assert {
    condition     = jsondecode(aws_ssoadmin_permission_set_inline_policy.developer.inline_policy).Statement[0].Action == ["eks:DescribeCluster"] && jsondecode(aws_ssoadmin_permission_set_inline_policy.developer.inline_policy).Statement[0].Resource == ["arn:aws:eks:*:*:cluster/eks-gitops-*"]
    error_message = "Developer may only describe the project's EKS clusters."
  }
}

run "standing_access" {
  command = plan

  assert {
    condition     = length(aws_ssoadmin_account_assignment.standing) == 12 && length(aws_ssoadmin_account_assignment.elevation) == 0
    error_message = "Twelve standing assignments and no elevation by default."
  }
  assert {
    condition     = toset([for k, a in aws_ssoadmin_account_assignment.standing : k if a.target_id == format("%012d", 13)]) == toset(["platform-admins/ReadOnly/prod", "auditors/ReadOnly/prod"])
    error_message = "Prod has ReadOnly only: no standing admin, developer or break-glass access."
  }
  assert {
    condition = (
      toset([for k, a in aws_ssoadmin_account_assignment.standing : a.target_id if startswith(k, "developers-dev/")]) == toset([format("%012d", 11)]) &&
      toset([for k, a in aws_ssoadmin_account_assignment.standing : a.target_id if startswith(k, "developers-uat/")]) == toset([format("%012d", 12)])
    )
    error_message = "Developers have standing access to their own environment's account only."
  }
  assert {
    condition     = length([for k, a in aws_ssoadmin_account_assignment.standing : k if startswith(k, "breakglass/")]) == 0 && length([for k, a in aws_ssoadmin_account_assignment.standing : k if strcontains(k, "/BreakGlass/")]) == 0
    error_message = "Break-glass has no standing assignment."
  }
  assert {
    condition     = length([for k, a in aws_ssoadmin_account_assignment.standing : k if startswith(k, "auditors/") && strcontains(k, "/ReadOnly/")]) == 5
    error_message = "Auditors read every account."
  }
  assert {
    condition     = alltrue([for a in aws_ssoadmin_account_assignment.standing : a.principal_type == "GROUP" && a.target_type == "AWS_ACCOUNT"])
    error_message = "Access is granted to groups, on accounts - never to a single user."
  }
  assert {
    condition     = toset(keys(aws_identitystore_group.this)) == toset(["platform-admins", "developers-dev", "developers-uat", "auditors", "breakglass"])
    error_message = "The five groups, named as in the lab realm plus breakglass."
  }
}

run "accepts_a_short_prod_elevation" {
  command = plan
  variables {
    elevations = [{
      group          = "breakglass"
      permission_set = "BreakGlass"
      account        = "prod"
      starts_at      = "2026-11-25T14:00:00Z"
      expires_at     = "2026-11-25T16:00:00Z"
      reason         = "incident: prod deployments stuck, see the incident ticket"
    }]
  }

  assert {
    condition     = length(aws_ssoadmin_account_assignment.elevation) == 1 && aws_ssoadmin_account_assignment.elevation["breakglass/BreakGlass/prod"].target_id == format("%012d", 13)
    error_message = "A valid elevation becomes exactly one assignment in its account."
  }
  assert {
    condition     = output.active_elevations == { "breakglass/BreakGlass/prod" = "2026-11-25T16:00:00Z" }
    error_message = "The output lists the elevation with its expiry."
  }
}

run "accepts_exactly_eight_hours" {
  command = plan
  variables {
    elevations = [{
      group     = "platform-admins", permission_set = "PlatformAdmin", account = "prod"
      starts_at = "2026-11-25T08:00:00Z", expires_at = "2026-11-25T16:00:00Z", reason = "planned prod maintenance window"
    }]
  }
  assert {
    condition     = length(aws_ssoadmin_account_assignment.elevation) == 1
    error_message = "Eight hours is the limit, inclusive."
  }
}

run "rejects_an_elevation_without_expiry" {
  command = plan
  variables {
    elevations = [{
      group     = "breakglass", permission_set = "BreakGlass", account = "prod"
      starts_at = "2026-11-25T14:00:00Z", expires_at = "", reason = "incident without an end time"
    }]
  }
  expect_failures = [var.elevations]
}

run "rejects_a_time_with_an_offset" {
  command = plan
  variables {
    elevations = [{
      group     = "breakglass", permission_set = "BreakGlass", account = "prod"
      starts_at = "2026-11-25T08:00:00-06:00", expires_at = "2026-11-25T10:00:00-06:00", reason = "local time instead of UTC"
    }]
  }
  expect_failures = [var.elevations]
}

run "rejects_an_elevation_longer_than_eight_hours" {
  command = plan
  variables {
    elevations = [{
      group     = "platform-admins", permission_set = "PlatformAdmin", account = "prod"
      starts_at = "2026-11-25T08:00:00Z", expires_at = "2026-11-25T16:00:01Z", reason = "a maintenance window one second too long"
    }]
  }
  expect_failures = [var.elevations]
}

run "rejects_an_expiry_before_the_start" {
  command = plan
  variables {
    elevations = [{
      group     = "breakglass", permission_set = "BreakGlass", account = "prod"
      starts_at = "2026-11-25T16:00:00Z", expires_at = "2026-11-25T14:00:00Z", reason = "dates swapped by mistake"
    }]
  }
  expect_failures = [var.elevations]
}

run "rejects_an_unknown_permission_set" {
  command = plan
  variables {
    elevations = [{
      group     = "developers-dev", permission_set = "AdministratorAccess", account = "prod"
      starts_at = "2026-11-25T14:00:00Z", expires_at = "2026-11-25T15:00:00Z", reason = "not one of the four permission sets"
    }]
  }
  expect_failures = [var.elevations]
}

run "rejects_an_elevation_without_reason" {
  command = plan
  variables {
    elevations = [{
      group     = "breakglass", permission_set = "BreakGlass", account = "prod"
      starts_at = "2026-11-25T14:00:00Z", expires_at = "2026-11-25T15:00:00Z", reason = "fix"
    }]
  }
  expect_failures = [var.elevations]
}

run "rejects_a_duplicate_elevation" {
  command = plan
  variables {
    elevations = [
      { group = "breakglass", permission_set = "BreakGlass", account = "prod", starts_at = "2026-11-25T14:00:00Z", expires_at = "2026-11-25T15:00:00Z", reason = "first entry for this grant" },
      { group = "breakglass", permission_set = "BreakGlass", account = "prod", starts_at = "2026-11-25T16:00:00Z", expires_at = "2026-11-25T17:00:00Z", reason = "second entry for the same grant" },
    ]
  }
  expect_failures = [var.elevations]
}

run "rejects_an_elevation_repeating_standing_access" {
  command = plan
  variables {
    elevations = [{
      group     = "auditors", permission_set = "ReadOnly", account = "prod"
      starts_at = "2026-11-25T14:00:00Z", expires_at = "2026-11-25T15:00:00Z", reason = "already standing, would grant nothing"
    }]
  }
  expect_failures = [aws_ssoadmin_account_assignment.elevation]
}

run "rejects_missing_prod_account" {
  command = plan
  variables {
    account_ids = {
      security = format("%012d", 1)
      platform = format("%012d", 2)
      dev      = format("%012d", 11)
      uat      = format("%012d", 12)
    }
  }
  expect_failures = [var.account_ids]
}

run "rejects_a_malformed_instance_arn" {
  command = plan
  variables {
    sso_instance_arn = "arn:aws:sso:::instance/not-an-instance"
  }
  expect_failures = [var.sso_instance_arn]
}
