module "tags" {
  source = "../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name

  # Destroyed last, manually, only after every other root module's own
  # state has been confirmed empty - see docs/adr/0012-network-eks-iac-
  # foundation.md's ownership/destroy ordering. force_destroy stays
  # false so an accidental `terraform destroy` here can never silently
  # delete a bucket that still holds another root module's real state.
  force_destroy = false

  tags = module.tags.tags
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
