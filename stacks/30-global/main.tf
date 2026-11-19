# Stack 30: one front door, in front of whichever region is live. Everything is in modules/global-accelerator.
# Run it last: it looks up the load balancers the clusters create.

module "front_door" {
  source = "../../modules/global-accelerator"

  name                = "${var.environment}-demo"
  cluster_name_prefix = var.environment
  regions             = var.regions
  ingress_stack       = var.ingress_stack
}
