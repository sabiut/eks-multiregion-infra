# The database tier: PostgreSQL on RDS, in the database subnets.
#
# Two modes:
#   primary   a new database. AWS generates the master password and keeps it in Secrets
#             Manager (manage_master_user_password), so it is never in Terraform state or Git.
#   replica   a read-only copy of a primary in another region, kept up to date by RDS. In a
#             disaster it is promoted to a standalone, writable database (docs/dr-runbook.md).

# Only the backend tier may connect: the rule names the backend subnets' address ranges.
# Frontend pods, system pods and anything outside the VPC cannot open a connection.
resource "aws_security_group" "this" {
  name        = "${var.name}-database"
  description = "PostgreSQL from the backend subnets only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-database" }
}

resource "aws_vpc_security_group_ingress_rule" "from_backend" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL from a backend subnet"
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

locals {
  is_replica = var.replicate_source_arn != ""
}

resource "aws_db_instance" "primary" {
  count = local.is_replica ? 0 : 1

  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = var.database_name
  username                    = "dbadmin"
  manage_master_user_password = true

  db_subnet_group_name   = var.subnet_group
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false

  # LAB PROFILE: one instance. Production: multi_az = true, so a standby in another AZ
  # takes over by itself when the instance or its AZ fails.
  multi_az = var.multi_az

  # Automated backups must be on for the instance to have read replicas.
  backup_retention_period = 1

  # LAB PROFILE: easy to delete. Production: deletion_protection = true and a final snapshot.
  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately   = true
}

# A cross-region replica of an encrypted database needs a KMS key in its own region.
data "aws_kms_alias" "rds" {
  count = local.is_replica ? 1 : 0
  name  = "alias/aws/rds"
}

resource "aws_db_instance" "replica" {
  count = local.is_replica ? 1 : 0

  identifier          = var.name
  replicate_source_db = var.replicate_source_arn
  instance_class      = var.instance_class

  storage_encrypted = true
  kms_key_id        = data.aws_kms_alias.rds[0].target_key_arn

  db_subnet_group_name   = var.subnet_group
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false

  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately   = true
}

locals {
  instance = local.is_replica ? aws_db_instance.replica[0] : aws_db_instance.primary[0]
}
