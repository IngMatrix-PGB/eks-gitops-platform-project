output "config_recorder_regions" {
  description = "Regions with an AWS Config recorder in this account."
  value       = sort([for r in aws_config_configuration_recorder.this : r.region])
}

output "config_recording_frequency" {
  description = "CONTINUOUS in prod, DAILY elsewhere."
  value       = local.recording_frequency
}

output "budget_name" {
  description = "This account's monthly budget."
  value       = aws_budgets_budget.account.name
}
