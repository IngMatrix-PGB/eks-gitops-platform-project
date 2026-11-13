# Phase 3.4.3b - the container registry, in the platform account
# (ADR-0016). Plan-only: never applied by this repository. Images are
# pushed only from this account (the image CI of Phase 5.1); the spoke
# accounts may only pull. Policies are built with jsonencode() so
# terraform test asserts their content.

module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

locals {
  repositories = toset(var.repositories)

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the most recent release images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = var.release_images_to_keep
        }
        action = { type = "expire" }
      },
    ]
  })

  pull_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SpokeAccountsPullOnly"
      Effect    = "Allow"
      Principal = { AWS = [for k in sort(keys(var.spoke_account_ids)) : "arn:aws:iam::${var.spoke_account_ids[k]}:root"] }
      Action = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      Condition = { StringEquals = { "aws:PrincipalOrgID" = var.organization_id } }
    }]
  })
}

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name = "${var.project}/${each.key}"
  # A release tag can never be moved to a different image.
  image_tag_mutability = "IMMUTABLE"
  # Never delete a repository that still holds images.
  force_delete = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  tags = module.tags.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = local.repositories

  repository = aws_ecr_repository.this[each.key].name
  policy     = local.lifecycle_policy
}

resource "aws_ecr_repository_policy" "this" {
  for_each = local.repositories

  repository = aws_ecr_repository.this[each.key].name
  policy     = local.pull_policy
}
