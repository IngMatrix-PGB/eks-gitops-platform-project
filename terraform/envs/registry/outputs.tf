output "repository_urls" {
  description = "Repository URLs by name - the image references Phase 5.1's CI pushes to."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
