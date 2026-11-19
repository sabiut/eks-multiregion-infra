# The database tier: PostgreSQL on RDS, in the database subnets.
#
# Two modes:
#   primary   a new database. Terraform generates the master password and puts it in
#             Secrets Manager. The password is "ephemeral" and passed through write-only
#             arguments, so it is never stored in Terraform state, in a plan or in Git.
#             (RDS can manage the password itself, manage_master_user_password, but AWS does
#             not allow a read replica of an instance that uses it. See "Limitations" under
#             "Password management with Amazon RDS and AWS Secrets Manager".)
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

# THE WRITE FENCE, part 2 of 2: with fenced = true there is no rule at all, so no NEW
# connection can be made. This alone is not a fence: AWS keeps already-established
# connections open after a rule is removed (connection tracking). Part 1, the parameter
# group below, is what stops writes on connections that are already open.
resource "aws_vpc_security_group_ingress_rule" "from_backend" {
  for_each = var.fenced ? toset([]) : toset(var.allowed_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "PostgreSQL from a backend subnet"
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

locals {
  is_replica      = var.replicate_source_arn != ""
  master_username = "dbadmin"
}

# Generated fresh in memory on every run and never saved. It is only sent to AWS when
# password_version changes, so raising that number rotates the password.
ephemeral "random_password" "master" {
  count   = local.is_replica ? 0 : 1
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "master" {
  count = local.is_replica ? 0 : 1

  name        = "${var.name}/database-master"
  description = "Master credentials for the ${var.name} database"
  # LAB PROFILE: delete at once, so the name can be reused after a destroy. Production: 7 to 30.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "master" {
  count = local.is_replica ? 0 : 1

  secret_id = aws_secretsmanager_secret.master[0].id
  secret_string_wo = jsonencode({
    username = local.master_username
    password = ephemeral.random_password.master[0].result
  })
  secret_string_wo_version = var.password_version
}

# THE WRITE FENCE, part 1 of 2: with fenced = true the database itself refuses writes.
# default_transaction_read_only makes every transaction read-only, including on sessions
# that are already connected, and however the client reached the database. Replication to
# the other region is not a client transaction and carries on, so the replica can still
# catch up before it is promoted. The parameter is dynamic: no restart.
resource "aws_db_parameter_group" "this" {
  name        = var.name
  family      = "postgres${var.engine_version}"
  description = "Parameters for ${var.name}, including the write fence"

  parameter {
    name         = "default_transaction_read_only"
    value        = var.fenced ? "1" : "0"
    apply_method = "immediate"
  }
}

# One resource for both modes, on purpose. A promoted replica and a primary are the same
# kind of object, so changing this region from replica to primary must be an update of the
# instance that is already there. With two separate resources (one for each mode), the same
# change would delete the promoted database and create an empty one.
resource "aws_db_instance" "this" {
  identifier     = var.name
  instance_class = var.instance_class

  # ---- replica only ----
  # Removing replicate_source_db from an existing replica promotes it in place.
  replicate_source_db = local.is_replica ? var.replicate_source_arn : null
  # A cross-region replica of an encrypted database needs a KMS key in its own region.
  kms_key_id = local.is_replica ? data.aws_kms_alias.rds[0].target_key_arn : null

  # ---- primary only (a replica copies these from its source) ----
  engine              = local.is_replica ? null : "postgres"
  engine_version      = local.is_replica ? null : var.engine_version
  allocated_storage   = local.is_replica ? null : 20
  storage_type        = local.is_replica ? null : "gp3"
  db_name             = local.is_replica ? null : var.database_name
  username            = local.is_replica ? null : local.master_username
  password_wo         = local.is_replica ? null : ephemeral.random_password.master[0].result
  password_wo_version = local.is_replica ? null : var.password_version
  # Automated backups must be on for the instance to have read replicas.
  backup_retention_period = local.is_replica ? null : 1

  parameter_group_name   = aws_db_parameter_group.this.name
  storage_encrypted      = true
  db_subnet_group_name   = var.subnet_group
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false

  # LAB PROFILE: one instance. Production: multi_az = true, so a standby in another AZ
  # takes over by itself when the instance or its AZ fails.
  multi_az = var.multi_az

  # LAB PROFILE: off, and no final snapshot, so the lab is easy to remove. Production: on.
  # The DR runbook switches it on for a database the moment it is promoted.
  deletion_protection = var.deletion_protection
  skip_final_snapshot = true
  apply_immediately   = true
}

# For a database created by the first version of this module, which used two resources.
# A primary moves to the new address by itself. A replica has to be moved by hand BEFORE
# the first plan, because Terraform allows only one "moved" source per destination:
#   terraform state mv 'module.database.aws_db_instance.replica[0]' 'module.database.aws_db_instance.this'
# Either way the upgrade plan must show the instance updated in place and 0 to destroy.
moved {
  from = aws_db_instance.primary[0]
  to   = aws_db_instance.this
}

data "aws_kms_alias" "rds" {
  count = local.is_replica ? 1 : 0
  name  = "alias/aws/rds"
}
