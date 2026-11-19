# Stack 15: the database tier for one region. Everything is in modules/database.
#
# Sydney holds the primary. Singapore holds a cross-region read replica of it, so apply
# Sydney first. The backend in Singapore can read but not write until the replica is promoted.

locals {
  name       = "${var.environment}-${var.region}"
  is_replica = var.primary_region != ""
}

module "database" {
  source = "../../modules/database"

  name          = local.name
  vpc_id        = local.network.vpc_id
  subnet_group  = local.network.database_subnet_group
  allowed_cidrs = local.network.backend_subnet_cidrs

  replicate_source_arn = local.is_replica ? local.primary.db_arn : ""
  multi_az             = var.multi_az
  fenced               = var.fenced
  deletion_protection  = var.deletion_protection
}
