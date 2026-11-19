# Read by stacks 15-database and 20-eks through their remote state data source.

output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "frontend_subnet_ids" {
  value = module.network.frontend_subnet_ids
}

output "backend_subnet_ids" {
  value = module.network.backend_subnet_ids
}

output "backend_subnet_cidrs" {
  value = module.network.backend_subnet_cidrs
}

output "database_subnet_ids" {
  value = module.network.database_subnet_ids
}

output "database_subnet_group" {
  value = module.network.database_subnet_group
}
