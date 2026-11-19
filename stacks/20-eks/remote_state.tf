# This stack reads the network stack's outputs from its state file. That is how separate
# stacks share values without being one big Terraform project.

data "terraform_remote_state" "network" {
  count   = var.state_bucket == "" ? 0 : 1
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.region}/10-network.tfstate"
    region = var.state_region
  }
}

locals {
  # Placeholders let `terraform validate` and a first plan run before the network exists.
  network = try(data.terraform_remote_state.network[0].outputs, {
    vpc_id              = "vpc-PLANONLY0000000"
    vpc_cidr            = "10.0.0.0/16"
    frontend_subnet_ids = ["subnet-PLANONLY0000fa", "subnet-PLANONLY0000fb", "subnet-PLANONLY0000fc"]
    backend_subnet_ids  = ["subnet-PLANONLY0000ba", "subnet-PLANONLY0000bb", "subnet-PLANONLY0000bc"]
  })
}
