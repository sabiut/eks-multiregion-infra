output "arns" {
  description = "Repository ARNs, one per region."
  value       = [for r in aws_ecr_repository.this : r.arn]
}
