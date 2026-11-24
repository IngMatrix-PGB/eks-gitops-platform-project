# Phase 6.4a (ADR-0024): the first thing a sandbox session creates and the
# last it destroys - one monthly cost budget for the sandbox account, and
# nothing else. terraform/envs/account-baseline also holds a budget, but
# with Config, EBS and IMDS defaults and the account-wide S3 block, which
# outlive a session; this root leaves nothing behind after destroy.

module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

resource "aws_budgets_budget" "sandbox" {
  name         = "${var.project}-sandbox-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", threshold = 50 },
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
