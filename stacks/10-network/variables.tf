variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  description = "Each region gets its own range so the two VPCs could be peered later."
  type        = string
}

variable "single_nat_gateway" {
  description = "true: one NAT gateway for the whole VPC (cheap, lab). false: one per AZ (production)."
  type        = bool
  default     = true
}
