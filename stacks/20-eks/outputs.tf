# These outputs are the handoff from Terraform to Ansible. The pipeline writes them to a JSON
# file and the Ansible playbooks read it (ansible/inventories/group_vars/aws.yml).

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "region" {
  value = var.region
}

output "account_id" {
  value = local.account_id
}

output "vpc_id" {
  value = local.network.vpc_id
}

output "vpc_cidr" {
  value = local.network.vpc_cidr
}

output "kubernetes_version" {
  value = module.cluster.cluster_version
}

output "autoscaler" {
  value = var.autoscaler
}

output "karpenter_queue" {
  value = local.use_karpenter ? module.karpenter[0].queue_name : ""
}

output "karpenter_node_role" {
  value = local.use_karpenter ? module.karpenter[0].node_role_name : ""
}

output "velero_bucket" {
  value = module.velero_bucket.name
}

output "vault_kms_alias" {
  value = module.vault_unseal.alias_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.cluster.cluster_name} --alias ${module.cluster.cluster_name}"
}

# ---- The database tier, passed through from stack 15-database ----

output "db_host" {
  value = local.database.db_host
}

output "db_port" {
  value = local.database.db_port
}

output "db_name" {
  value = local.database.db_name
}

output "db_role" {
  value = local.database.db_role
}

output "db_secret_arn" {
  value = local.database.db_secret_arn
}

output "db_secret_region" {
  value = local.database.db_secret_region
}
