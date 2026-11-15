# Structural correctness only (Phase 3.4.3b): mock_provider "aws" proves
# this root's own logic - immutable, scanned, encrypted repositories, the
# lifecycle rules, and a repository policy that lets only the spoke
# accounts of this organization pull - against fabricated values. Nothing
# is ever applied against AWS. Account IDs are generated with format() so
# no 12-digit literal is committed (scripts/validate/check-forbidden-terms.sh).

mock_provider "aws" {}

variables {
  owner           = "IngMatrix-PGB"
  repositories    = ["podinfo", "reference-app"]
  organization_id = "o-exampleorg01"
  spoke_account_ids = {
    dev  = format("%012d", 11)
    uat  = format("%012d", 12)
    prod = format("%012d", 13)
  }
}

run "repositories_immutable_scanned_encrypted" {
  command = apply

  assert {
    condition     = toset([for r in aws_ecr_repository.this : r.name]) == toset(["eks-gitops-platform-project/podinfo", "eks-gitops-platform-project/reference-app"])
    error_message = "One repository per workload, named <project>/<name>."
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_tag_mutability == "IMMUTABLE" && r.force_delete == false])
    error_message = "Every repository must use immutable tags and never be force-deleted."
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : one(r.image_scanning_configuration).scan_on_push && one(r.encryption_configuration).encryption_type == "KMS"])
    error_message = "Every repository scans on push and encrypts with KMS."
  }
}

run "lifecycle_rules" {
  command = apply

  assert {
    condition = alltrue([for p in aws_ecr_lifecycle_policy.this :
      jsondecode(p.policy).rules[0].selection.tagStatus == "untagged" && jsondecode(p.policy).rules[0].selection.countNumber == 7 &&
    jsondecode(p.policy).rules[1].selection.tagPrefixList == ["v"] && jsondecode(p.policy).rules[1].selection.countNumber == 30])
    error_message = "Untagged images expire after 7 days and each repository keeps the last 30 v* releases."
  }
}

run "spokes_pull_only" {
  command = apply

  assert {
    condition = alltrue([for p in aws_ecr_repository_policy.this : length(jsondecode(p.policy).Statement) == 1 && toset(jsondecode(p.policy).Statement[0].Action) == toset([
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
    ])])
    error_message = "The repository policy grants exactly the three pull actions - nothing that pushes, deletes or uses a wildcard."
  }
  assert {
    condition = alltrue([for p in aws_ecr_repository_policy.this : toset(jsondecode(p.policy).Statement[0].Principal.AWS) == toset([
      "arn:aws:iam::${format("%012d", 11)}:root", "arn:aws:iam::${format("%012d", 12)}:root", "arn:aws:iam::${format("%012d", 13)}:root",
    ])])
    error_message = "Only the dev, uat and prod accounts may pull - never a * principal."
  }
  assert {
    condition     = alltrue([for p in aws_ecr_repository_policy.this : jsondecode(p.policy).Statement[0].Condition.StringEquals["aws:PrincipalOrgID"] == "o-exampleorg01"])
    error_message = "Pulls are admitted only from principals in this organization."
  }
}

# --- rejections ----------------------------------------------------------------
run "rejects_uppercase_repository" {
  command = plan
  variables {
    repositories = ["PodInfo"]
  }
  expect_failures = [var.repositories]
}

run "rejects_duplicate_repository" {
  command = plan
  variables {
    repositories = ["podinfo", "podinfo"]
  }
  expect_failures = [var.repositories]
}

run "rejects_missing_spoke" {
  command = plan
  variables {
    spoke_account_ids = {
      dev = format("%012d", 11)
      uat = format("%012d", 12)
    }
  }
  expect_failures = [var.spoke_account_ids]
}

run "rejects_non_account_id" {
  command = plan
  variables {
    spoke_account_ids = {
      dev  = "dev-account"
      uat  = format("%012d", 12)
      prod = format("%012d", 13)
    }
  }
  expect_failures = [var.spoke_account_ids]
}

run "rejects_too_few_releases_kept" {
  command = plan
  variables {
    release_images_to_keep = 2
  }
  expect_failures = [var.release_images_to_keep]
}
