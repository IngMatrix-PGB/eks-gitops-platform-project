output "tags" {
  value       = local.tags
  description = "The computed tag map every terraform/bootstrap and terraform/envs/* resource should merge into its own tags."
}
