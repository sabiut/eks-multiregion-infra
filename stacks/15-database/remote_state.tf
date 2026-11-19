# Outputs of other stacks, read from their state files.

data "terraform_remote_state" "network" {
  count   = var.state_bucket == "" ? 0 : 1
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.region}/10-network.tfstate"
    region = var.state_region
  }
}

# Only in a replica region: the primary region's database stack.
data "terraform_remote_state" "primary" {
  count   = var.state_bucket != "" && var.primary_region != "" ? 1 : 0
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.primary_region}/15-database.tfstate"
    region = var.state_region
  }
}

locals {
  # Placeholders let `terraform validate` and a first plan run before the network exists.
  network = try(data.terraform_remote_state.network[0].outputs, {
    vpc_id                = "vpc-PLANONLY0000000"
    backend_subnet_cidrs  = ["10.0.64.0/20", "10.0.80.0/20", "10.0.96.0/20"]
    database_subnet_group = "planonly"
  })
  primary = try(data.terraform_remote_state.primary[0].outputs, {
    db_arn        = "arn:aws:rds:${var.primary_region}:000000000000:db:planonly"
    db_secret_arn = "arn:aws:secretsmanager:${var.primary_region}:000000000000:secret:planonly"
  })
}
