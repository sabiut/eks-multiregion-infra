output "role_arns" {
  description = "Add-on name => IAM role ARN."
  value       = { for k, m in module.pod_identity : k => m.iam_role_arn }
}
