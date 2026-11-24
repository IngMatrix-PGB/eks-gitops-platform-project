output "budget_name" {
  description = "The sandbox budget's name; preflight checks it exists before any other stack is applied."
  value       = aws_budgets_budget.sandbox.name
}
