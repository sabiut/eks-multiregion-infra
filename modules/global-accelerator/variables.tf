variable "name" {
  description = "Name of the accelerator."
  type        = string
}

variable "cluster_name_prefix" {
  description = "Clusters are named <prefix>-<region>. Used to find each cluster's load balancer."
  type        = string
}

variable "regions" {
  description = "Region => traffic dial (0-100): the share of the traffic that would normally reach the region that is let through. A region at 0 receives no traffic. Only a region whose database accepts writes should be above 0."
  type        = map(number)
}

variable "ingress_stack" {
  description = "namespace/name of the Ingress whose load balancer receives the traffic."
  type        = string
  default     = "demo/demo-web"
}
