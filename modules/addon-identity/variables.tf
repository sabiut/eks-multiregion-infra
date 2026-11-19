variable "cluster_name" {
  type = string
}

variable "iam_prefix" {
  description = "Short prefix for IAM role names, unique per cluster."
  type        = string
}

variable "velero_bucket_arn" {
  description = "Bucket Velero writes backups to."
  type        = string
}

variable "vault_kms_key_arn" {
  description = "KMS key Vault uses to unseal itself."
  type        = string
}

variable "enable_cluster_autoscaler" {
  description = "Create the Cluster Autoscaler role. Off in clusters that run Karpenter."
  type        = bool
  default     = false
}
