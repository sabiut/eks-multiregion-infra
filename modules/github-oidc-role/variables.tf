variable "name" {
  description = "IAM role name."
  type        = string
}

variable "oidc_provider_arn" {
  description = "The account's GitHub OIDC provider."
  type        = string
}

variable "subjects" {
  description = "Allowed 'sub' claims, for example repo:owner/name:environment:production."
  type        = list(string)
}

variable "managed_policy_arns" {
  description = "AWS-managed policies to attach."
  type        = list(string)
  default     = []
}

variable "inline_policy" {
  description = "Optional inline policy: a list of IAM statements (Effect, Action, Resource)."
  type        = any
  default     = null
}
