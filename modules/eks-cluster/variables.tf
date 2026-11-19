variable "name" {
  description = "Cluster name."
  type        = string
}

variable "iam_prefix" {
  description = "Short prefix for IAM role names, unique per cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Control plane version. Raise it one minor version at a time (see docs/upgrade-runbook.md)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets for the control plane's network interfaces and the system nodes: the backend subnets."
  type        = list(string)
}

variable "tier_node_groups" {
  description = "Tier name => subnet IDs. One managed node group per entry, labelled tier=<name>. Empty in Karpenter clusters."
  type        = map(list(string))
  default     = {}
}

variable "tier_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "public_access_cidrs" {
  description = "Who may reach the public API endpoint. IAM authentication still applies."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_principal_arns" {
  description = "IAM users or roles that get cluster admin through an access entry."
  type        = list(string)
  default     = []
}

variable "developer_principal_arns" {
  description = "IAM users or roles mapped to the Kubernetes group 'developers'."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}
