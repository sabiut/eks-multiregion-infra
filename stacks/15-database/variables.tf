variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "primary_region" {
  description = "Empty: this region holds the primary database. A region name: this region holds a read replica of that region's database."
  type        = string
  default     = ""
}

variable "fenced" {
  description = "true closes the database to every client. Set on the old primary during a failover (docs/dr-runbook.md)."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "state_bucket" {
  description = "Terraform state bucket, used to read other stacks' outputs. Empty = plan with placeholders."
  type        = string
  default     = ""
}

variable "state_region" {
  type    = string
  default = "ap-southeast-2"
}
