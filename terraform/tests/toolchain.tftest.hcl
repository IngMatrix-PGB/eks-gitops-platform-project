# Toolchain smoke test only - proves the offline validation mechanism
# itself (mock_provider "aws", variable validation, zero AWS contact),
# not any project infrastructure. VPC/EKS/IAM/Secrets Manager design is
# out of scope until Phase 2.7.2+ (see
# .local/evidence/phase-2.7-eks-aws-foundation-plan.md).
#
# mock_provider "aws" {} fully substitutes for a real provider
# configuration in both "plan" and "apply" run blocks below - no
# provider "aws" block, no region, no credentials exist anywhere in
# this configuration, and none are required (verified locally: this
# suite passes identically with AWS_SHARED_CREDENTIALS_FILE=/dev/null,
# AWS_CONFIG_FILE=/dev/null, and AWS_EC2_METADATA_DISABLED=true).

mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.toolchain_smoke
    values = {
      account_id = "not-a-real-account-id"
      arn        = "arn:aws:iam::not-a-real-account:user/toolchain-smoke-test"
      user_id    = "AIDATOOLCHAINSMOKETEST"
    }
  }

  override_data {
    target = data.aws_region.toolchain_smoke
    values = {
      region = "us-east-1"
    }
  }
}

run "valid_environment_staging" {
  command = plan

  variables {
    expected_environment = "staging"
  }

  assert {
    condition     = data.aws_caller_identity.toolchain_smoke.account_id == "not-a-real-account-id"
    error_message = "mock_provider did not supply the overridden fake account id - mock did not take effect"
  }

  assert {
    condition     = output.toolchain_smoke_region == "us-east-1"
    error_message = "mock_provider did not supply the overridden fake region"
  }
}

run "valid_environment_production_apply" {
  command = apply

  variables {
    expected_environment = "production"
  }

  assert {
    condition     = output.toolchain_smoke_account_id == "not-a-real-account-id"
    error_message = "apply against the mocked provider did not resolve the fake account id"
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    expected_environment = "not-a-real-environment"
  }

  expect_failures = [
    var.expected_environment,
  ]
}
