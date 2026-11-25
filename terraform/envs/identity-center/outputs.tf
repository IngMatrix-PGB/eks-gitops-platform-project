output "permission_set_arns" {
  description = "Permission set ARNs by name. The role each creates in an account is AWSReservedSSO_<name>_<random>; its ARN without the path is what terraform/envs/eks takes for an access entry."
  value       = { for k, ps in aws_ssoadmin_permission_set.this : k => ps.arn }
}

output "group_ids" {
  description = "Identity store group IDs by name."
  value       = { for k, g in aws_identitystore_group.this : k => g.group_id }
}

output "standing_assignments" {
  description = "Standing access as group/permission-set/account keys."
  value       = sort(keys(local.standing_assignments))
}

output "active_elevations" {
  description = "Time-bound grants in this apply, with their expiry."
  value       = { for k, e in local.elevation_assignments : k => e.expires_at }
}
