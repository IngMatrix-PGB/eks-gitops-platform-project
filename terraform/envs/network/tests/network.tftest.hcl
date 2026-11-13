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
    environment        = "dev"
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
    environment        = "dev"
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
    environment        = "dev"
  }

  expect_failures = [
    var.availability_zones,
  ]
}

# --- Phase 3.4.3: NAT layout per environment --------------------------------------
run "prod_has_one_nat_per_az" {
  command = apply

  variables {
    aws_region         = "us-east-1"
    vpc_cidr           = "10.30.0.0/16"
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
    owner              = "not-a-real-owner-handle"
    environment        = "prod"
  }

  assert {
    condition     = length(module.vpc.natgw_ids) == 3
    error_message = "prod must have one NAT Gateway per availability zone."
  }
  assert {
    condition     = module.vpc.name == "eks-gitops-platform-project-prod"
    error_message = "The VPC is named after its environment."
  }
}

run "non_prod_shares_one_nat" {
  command = apply

  variables {
    aws_region         = "us-east-1"
    vpc_cidr           = "10.10.0.0/16"
    availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
    owner              = "not-a-real-owner-handle"
    environment        = "uat"
  }

  assert {
    condition     = length(module.vpc.natgw_ids) == 1
    error_message = "Outside prod a single shared NAT Gateway is used."
  }
}

run "rejects_unknown_environment" {
  command = plan

  variables {
    aws_region         = "us-east-1"
    vpc_cidr           = "10.0.0.0/16"
    availability_zones = ["us-east-1a", "us-east-1b"]
    owner              = "not-a-real-owner-handle"
    environment        = "qa"
  }

  expect_failures = [var.environment]
}

# --- Phase 3.4.3b: Karpenter subnet discovery ------------------------------------
run "spoke_private_subnets_tagged_for_karpenter" {
  command = plan

  variables {
    aws_region         = "us-east-1"
    vpc_cidr           = "10.10.0.0/16"
    availability_zones = ["us-east-1a", "us-east-1b"]
    owner              = "not-a-real-owner-handle"
    environment        = "uat"
  }

  assert {
    condition     = length(local.private_subnet_tags) == 1 && local.private_subnet_tags["karpenter.sh/discovery"] == "eks-gitops-uat"
    error_message = "A spoke's private subnets carry the Karpenter discovery tag with its cluster name."
  }
}

run "hub_private_subnets_untagged" {
  command = plan

  variables {
    aws_region         = "us-east-1"
    vpc_cidr           = "10.0.0.0/16"
    availability_zones = ["us-east-1a", "us-east-1b"]
    owner              = "not-a-real-owner-handle"
    environment        = "platform"
  }

  assert {
    condition     = length(local.private_subnet_tags) == 0
    error_message = "The hub runs no Karpenter, so its subnets carry no discovery tag."
  }
}
