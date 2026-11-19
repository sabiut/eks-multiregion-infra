variable "name" {
  description = "Bucket name. Must be globally unique, so callers add the account ID."
  type        = string
}

variable "sse_algorithm" {
  description = "AES256 (S3-managed keys) or aws:kms (the AWS-managed KMS key for S3)."
  type        = string
  default     = "AES256"
}

variable "force_destroy" {
  description = "Let Terraform delete the bucket even when it holds objects. Right for a lab only."
  type        = bool
  default     = true
}
