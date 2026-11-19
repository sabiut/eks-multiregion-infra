variable "environment" {
  type = string
}

variable "regions" {
  description = "Region => traffic dial (0-100): the share of the traffic that would normally reach the region that is let through. With every region at 100, each user goes to the nearest healthy region."
  type        = map(number)
}

variable "ingress_stack" {
  description = "namespace/name of the Ingress whose load balancer receives the traffic."
  type        = string
  default     = "demo/demo-web"
}
