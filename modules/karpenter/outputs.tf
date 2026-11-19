output "queue_name" {
  description = "SQS queue with interruption notices. Goes into the Karpenter Helm values."
  value       = module.karpenter.queue_name
}

output "node_role_name" {
  description = "IAM role Karpenter's nodes use. Goes into the EC2NodeClass."
  value       = module.karpenter.node_iam_role_name
}
