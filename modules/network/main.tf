# A VPC across three Availability Zones, laid out for a three-tier application.
#
#   subnets     size   route to the internet            what lives there
#   public      /24    internet gateway (in and out)    load balancer, NAT gateway
#   frontend    /20    NAT gateway (out only)           frontend nodes and pods
#   backend     /20    NAT gateway (out only)           backend and system nodes and pods
#   database    /24    none                             RDS
#
# Only the public subnets can be reached from the internet. Each tier below only needs to
# accept traffic from the tier above it; security groups and NetworkPolicies enforce that.

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  public_cidrs   = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]     # x.x.0-2.0/24
  database_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 4)] # x.x.4-6.0/24
  # The VPC CNI gives every pod a real VPC address, so the subnets that hold pods need far
  # more addresses than the node count suggests.
  frontend_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 1)] # x.x.16.0/20 ...
  backend_cidrs  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i + 4)] # x.x.64.0/20 ...
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets = local.public_cidrs

  # Frontend and backend are both "private" subnets: no way in from the internet, a NAT
  # gateway for the way out (image pulls, AWS APIs). Frontend first, then backend.
  private_subnets = concat(local.frontend_cidrs, local.backend_cidrs)
  # The names matter: Karpenter's EC2NodeClass for a tier finds that tier's subnets by
  # name ("<name>-frontend-*"), so frontend nodes can only start in frontend subnets.
  # (A separate aws_ec2_tag resource must not be used for this: the VPC module owns the
  # subnets' tags and removes any tag it did not set, on the next apply.)
  private_subnet_names = concat(
    [for az in local.azs : "${var.name}-frontend-${az}"],
    [for az in local.azs : "${var.name}-backend-${az}"],
  )

  # Database subnets get their own route table with no route to the internet at all, and a
  # DB subnet group for RDS.
  database_subnets                   = local.database_cidrs
  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # The AWS Load Balancer Controller finds subnets by these tags.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter only considers subnets carrying this tag (see the EC2NodeClass).
    "karpenter.sh/discovery" = var.cluster_name
  }
}

locals {
  frontend_subnet_ids = slice(module.vpc.private_subnets, 0, 3)
  backend_subnet_ids  = slice(module.vpc.private_subnets, 3, 6)
}
