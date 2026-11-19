variable "cluster_name" {
  type = string
}

variable "iam_prefix" {
  description = "Short prefix for IAM role names, unique per cluster."
  type        = string
}
