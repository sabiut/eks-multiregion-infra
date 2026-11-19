# Stack 10: the network for one region. Everything is in modules/network.

locals {
  name = "${var.environment}-${var.region}" # also the cluster name
}

module "network" {
  source = "../../modules/network"

  name               = local.name
  cluster_name       = local.name
  vpc_cidr           = var.vpc_cidr
  single_nat_gateway = var.single_nat_gateway
}
