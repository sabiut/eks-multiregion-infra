output "key_arn" {
  value = aws_kms_key.this.arn
}

output "alias_name" {
  description = "Goes into Vault's seal configuration in the GitOps repository."
  value       = aws_kms_alias.this.name
}
