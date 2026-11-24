# Structural correctness only (Phase 6.4a): mock_provider "aws" proves the
# budget's amount, thresholds and recipients against fabricated values.
# Nothing is ever applied against AWS.

mock_provider "aws" {}

variables {
  aws_region                 = "us-east-1"
  owner                      = "not-a-real-owner-handle"
  monthly_budget_usd         = 20
  budget_notification_emails = ["operator@example.invalid"]
}

run "budget_with_four_alerts" {
  command = plan

  assert {
    condition     = aws_budgets_budget.sandbox.limit_amount == "20" && aws_budgets_budget.sandbox.time_unit == "MONTHLY" && aws_budgets_budget.sandbox.budget_type == "COST"
    error_message = "The sandbox budget is a monthly cost budget for the given amount."
  }
  assert {
    condition = toset([for n in aws_budgets_budget.sandbox.notification : "${n.notification_type}:${n.threshold}"]) == toset([
      "ACTUAL:50", "ACTUAL:80", "ACTUAL:100", "FORECASTED:100",
    ])
    error_message = "Alerts at 50, 80 and 100 % actual and 100 % forecast."
  }
  assert {
    condition     = alltrue([for n in aws_budgets_budget.sandbox.notification : n.subscriber_email_addresses == toset(["operator@example.invalid"])])
    error_message = "Every alert goes to the given recipients."
  }
  assert {
    condition     = aws_budgets_budget.sandbox.tags["Project"] == "eks-gitops-platform-project"
    error_message = "The budget carries the project tag the sweep looks for."
  }
}

run "rejects_zero_budget" {
  command = plan
  variables {
    monthly_budget_usd = 0
  }
  expect_failures = [var.monthly_budget_usd]
}

run "rejects_large_budget" {
  command = plan
  variables {
    monthly_budget_usd = 500
  }
  expect_failures = [var.monthly_budget_usd]
}

run "rejects_missing_recipients" {
  command = plan
  variables {
    budget_notification_emails = []
  }
  expect_failures = [var.budget_notification_emails]
}
