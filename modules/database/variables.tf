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

variable "fenced" {
  description = "The write fence used during failover: the database refuses writes, and its security group accepts no new connection."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Refuse to delete the instance. Off in the lab, on in production and on a promoted database."
  type        = bool
  default     = false
}

variable "password_version" {
  description = "Raise by one to generate and set a new master password."
  type        = number
  default     = 1
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
