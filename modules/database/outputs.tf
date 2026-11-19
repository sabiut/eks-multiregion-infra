output "arn" {
  description = "A replica in another region names its source by this."
  value       = local.instance.arn
}

output "host" {
  value = local.instance.address
}

output "port" {
  value = local.instance.port
}

output "database_name" {
  value = var.database_name
}

output "master_secret_arn" {
  description = "Secrets Manager secret holding the master username and password. Empty for a replica: it uses its source's credentials."
  value       = local.is_replica ? "" : aws_secretsmanager_secret.master[0].arn
}

output "role" {
  value = local.is_replica ? "replica" : "primary"
}
