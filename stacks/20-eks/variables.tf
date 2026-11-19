variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "kubernetes_version" {
  description = "Control plane version. Raise it one minor version at a time (see docs/upgrade-runbook.md)."
  type        = string
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
  description = "IAM users or roles mapped to the Kubernetes group 'developers'. What that group may do is decided by RBAC in the GitOps repository, not here."
  type        = list(string)
  default     = []
}

variable "autoscaler" {
  description = "Which node autoscaler this cluster runs: karpenter or cluster-autoscaler. The lab runs one of each to compare them."
  type        = string
  validation {
    condition     = contains(["karpenter", "cluster-autoscaler"], var.autoscaler)
    error_message = "autoscaler must be karpenter or cluster-autoscaler."
  }
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

variable "state_bucket" {
  description = "Terraform state bucket, used to read the network stack's outputs. Empty = plan with placeholders."
  type        = string
  default     = ""
}

variable "state_region" {
  type    = string
  default = "ap-southeast-2"
}
