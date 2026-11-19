output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "frontend_subnet_ids" {
  value = local.frontend_subnet_ids
}

output "backend_subnet_ids" {
  value = local.backend_subnet_ids
}

output "backend_subnet_cidrs" {
  description = "The database's security group lets these ranges in, and nothing else."
  value       = local.backend_cidrs
}

output "database_subnet_ids" {
  value = module.vpc.database_subnets
}

output "database_subnet_group" {
  value = module.vpc.database_subnet_group_name
}
