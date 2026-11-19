# Read by stack 20-eks, which passes them on to Ansible. Ansible copies the connection
# details into Vault, and the backend pods read them from there.

output "db_arn" {
  value = module.database.arn
}

output "db_host" {
  value = module.database.host
}

output "db_port" {
  value = module.database.port
}

output "db_name" {
  value = module.database.database_name
}

output "db_role" {
  value = module.database.role
}

# A replica has no secret of its own: it uses the primary's, which lives in the primary's region.
output "db_secret_arn" {
  value = local.is_replica ? local.primary.db_secret_arn : module.database.master_secret_arn
}

output "db_secret_region" {
  value = local.is_replica ? var.primary_region : var.region
}
