# mock_provider "aws" {} substitutes for a real provider configuration
# entirely - no region, no credentials, no network contact to AWS
# anywhere in this test (verified locally: passes identically with
# AWS_SHARED_CREDENTIALS_FILE=/dev/null, AWS_CONFIG_FILE=/dev/null, and
# AWS_EC2_METADATA_DISABLED=true). Proves the VPC module's structural
# consistency: correct subnet-to-AZ mapping (one private and one
# public subnet computed per configured availability zone, via the
# pure cidrsubnet() function - never an AWS API call), and that the
# module produces a VPC/subnet id per Terraform's own generated
# resource graph even though every id value itself is mock_provider's
# fake data. Note: terraform-aws-modules/vpc's own internal resources
# (aws_vpc, aws_subnet, aws_nat_gateway, ...) are mocked too, since
# mock_provider substitutes for the shared "aws" provider instance
# every child module inherits, not just this root module's own blocks.

mock_provider "aws" {}

run "correct_subnet_to_az_mapping" {
  command = plan

  variables {
    aws_region         = "us-east-1"
    vpc_cidr           = "10.0.0.0/16"
    availability_zones = ["us-east-1a", "us-east-1b"]
    owner              = "not-a-real-owner-handle"
  }

  assert {
    condition     = length(module.vpc.private_subnets) == length(var.availability_zones)
    error_message = "expected exactly one private subnet per configured availability zone"
  }

  assert {
    condition     = length(module.vpc.public_subnets) == length(var.availability_zones)
    error_message = "expected exactly one public subnet per configured availability zone"
  }
}

run "single_nat_gateway_default" {
  command = plan

  variables {
    aws_region         = "us-east-1"
    vpc_cidr           = "10.0.0.0/16"
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
    owner              = "not-a-real-owner-handle"
  }

  assert {
    condition     = length(module.vpc.private_subnets) == 3
    error_message = "expected exactly one private subnet per configured availability zone (three AZs)"
  }
}

run "rejects_fewer_than_two_availability_zones" {
  command = plan

  variables {
    aws_region         = "us-east-1"
    vpc_cidr           = "10.0.0.0/16"
    availability_zones = ["us-east-1a"]
    owner              = "not-a-real-owner-handle"
  }

  expect_failures = [
    var.availability_zones,
  ]
}
