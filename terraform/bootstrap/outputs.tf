output "state_bucket_name" {
  value       = aws_s3_bucket.terraform_state.id
  description = "The Terraform state bucket's name - never a credential, never a secret value."
}

output "state_bucket_arn" {
  value       = aws_s3_bucket.terraform_state.arn
  description = "The Terraform state bucket's ARN."
}
