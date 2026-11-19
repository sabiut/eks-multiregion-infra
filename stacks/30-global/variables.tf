variable "environment" {
  type = string
}

variable "regions" {
  description = "Regions registered with the accelerator => traffic dial (0-100). List only regions whose database accepts writes: on a health failover the accelerator ignores the dial, so a standby must be left out, not set to 0."
  type        = map(number)
}

variable "ingress_stack" {
  description = "namespace/name of the Ingress whose load balancer receives the traffic."
  type        = string
  default     = "demo/demo-web"
}
