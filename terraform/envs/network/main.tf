module "tags" {
  source = "../../modules/tags"

  project     = var.project
  environment = "shared"
  owner       = var.owner
}

# VPC/subnets/NAT/S3-Gateway-endpoint. Public subnets are used only for
# the NAT Gateway; nodes and pods only ever live in the private
# subnets, with no public IP (canonical plan S7.1). AZs and CIDR are
# both explicit inputs (see variables.tf) - this module never queries
# aws_availability_zones or any other real AWS data source.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.2"

  name = "${var.project}-network"
  cidr = var.vpc_cidr
  azs  = var.availability_zones

  private_subnets = [
    for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, i)
  ]
  public_subnets = [
    for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, i + length(var.availability_zones))
  ]

  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  # VPC endpoints (S3 Gateway, and Interface endpoints for STS/ECR/
  # Secrets Manager in the "closer to production" shape) are
  # deliberately deferred out of this foundation module - the vpc
  # module's own S6.7.2 API does not expose a direct enable_s3_endpoint-
  # style flag (verified against its real, downloaded source rather
  # than assumed); adding one correctly is a distinct piece of work,
  # not guessed at here.

  tags = module.tags.tags
}
