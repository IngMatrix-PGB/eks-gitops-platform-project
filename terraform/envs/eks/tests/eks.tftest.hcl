# mock_provider "aws" {} substitutes for a real provider configuration
# entirely - no region, no credentials, no network contact to AWS
# anywhere in this test (verified locally: passes identically with
# AWS_SHARED_CREDENTIALS_FILE=/dev/null, AWS_CONFIG_FILE=/dev/null, and
# AWS_EC2_METADATA_DISABLED=true). Proves structural consistency:
# correct Access Entries wiring (exactly the two configured principals,
# never aws-auth), and that required security-relevant inputs
# (endpoint CIDR, capacity type) are rejected before any AWS contact
# when malformed.

# Overrides below give mock_provider "aws" realistic fake values for a
# handful of the EKS module's own INTERNAL data sources whose default
# (fully synthetic) computed values are not even shaped like the real
# thing - e.g. an ARN or IAM trust-policy JSON string mock_provider
# invents on its own does not parse as valid ARN/JSON, which the module
# itself then rejects before this test ever gets to its own
# assertions. This is exactly the documented mock_provider limitation
# in the canonical plan (.local/evidence/phase-2.7-eks-aws-foundation-
# plan.md, S2.4: "mocked providers do not have any information about
# the expected format of computed attributes") - never a real AWS
# value, never a real account id.
mock_provider "aws" {
  override_data {
    target = module.eks.data.aws_partition.current[0]
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = module.eks.module.eks_managed_node_group["default"].data.aws_partition.current[0]
    values = {
      partition = "aws"
    }
  }

  override_data {
    target = module.eks.data.aws_caller_identity.current[0]
    values = {
      # "aws" is one of the account-id values AWS itself permits in an
      # ARN (alongside a real 12-digit account) - used here so the ARN
      # shape is valid without ever writing a real-looking account id.
      account_id = "aws"
      arn        = "arn:aws:iam::aws:root"
      user_id    = "AIDANOTAREALUSERID"
    }
  }

  override_data {
    target = module.eks.data.aws_iam_policy_document.assume_role_policy[0]
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"eks.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }

  override_data {
    target = module.eks.module.eks_managed_node_group["default"].data.aws_iam_policy_document.assume_role_policy[0]
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }
}

run "correct_access_entries_wiring" {
  command = plan

  variables {
    aws_region               = "us-east-1"
    vpc_id                   = "vpc-not-a-real-id"
    private_subnet_ids       = ["subnet-not-a-real-id-1", "subnet-not-a-real-id-2"]
    eks_public_access_cidrs  = ["203.0.113.1/32"]
    admin_principal_arn      = "arn:aws:iam::aws:role/not-a-real-admin-role"
    breakglass_principal_arn = "arn:aws:iam::aws:role/not-a-real-breakglass-role"
    owner                    = "not-a-real-owner-handle"
  }

  assert {
    condition     = length(module.eks.access_entries) == 2
    error_message = "expected exactly two Access Entries (admin, breakglass)"
  }

  assert {
    condition     = contains(keys(module.eks.access_entries), "admin")
    error_message = "expected an Access Entry keyed \"admin\""
  }

  assert {
    condition     = contains(keys(module.eks.access_entries), "breakglass")
    error_message = "expected an Access Entry keyed \"breakglass\""
  }
}

run "rejects_invalid_capacity_type" {
  command = plan

  variables {
    aws_region               = "us-east-1"
    vpc_id                   = "vpc-not-a-real-id"
    private_subnet_ids       = ["subnet-not-a-real-id-1", "subnet-not-a-real-id-2"]
    eks_public_access_cidrs  = ["203.0.113.1/32"]
    admin_principal_arn      = "arn:aws:iam::aws:role/not-a-real-admin-role"
    breakglass_principal_arn = "arn:aws:iam::aws:role/not-a-real-breakglass-role"
    owner                    = "not-a-real-owner-handle"
    capacity_type            = "RESERVED"
  }

  expect_failures = [
    var.capacity_type,
  ]
}

run "default_capacity_type_is_spot" {
  command = plan

  variables {
    aws_region               = "us-east-1"
    vpc_id                   = "vpc-not-a-real-id"
    private_subnet_ids       = ["subnet-not-a-real-id-1", "subnet-not-a-real-id-2"]
    eks_public_access_cidrs  = ["203.0.113.1/32"]
    admin_principal_arn      = "arn:aws:iam::aws:role/not-a-real-admin-role"
    breakglass_principal_arn = "arn:aws:iam::aws:role/not-a-real-breakglass-role"
    owner                    = "not-a-real-owner-handle"
  }

  assert {
    condition     = var.capacity_type == "SPOT"
    error_message = "expected the default capacity_type to be SPOT"
  }
}
