variable "name" {
  description = "Instance identifier, and prefix for the security group."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_group" {
  description = "DB subnet group made of the database subnets (from the network module)."
  type        = string
}

variable "allowed_cidrs" {
  description = "Address ranges that may connect: the backend subnets."
  type        = list(string)
}

variable "replicate_source_arn" {
  description = "Empty: create a primary. An RDS instance ARN: create a read replica of it."
  type        = string
  default     = ""
}

variable "database_name" {
  type    = string
  default = "demo"
}

variable "engine_version" {
  description = "PostgreSQL major version. RDS picks the newest minor version."
  type        = string
  default     = "17"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "multi_az" {
  type    = bool
  default = false
}
