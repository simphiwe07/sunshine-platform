# PostgreSQL on RDS in the isolated database subnets.
#
# The master password is generated, stored and rotated by Secrets Manager
# (manage_master_user_password). It never appears in Terraform code, state,
# plan output or CI logs - apps read it from the secret at runtime.

resource "aws_db_subnet_group" "this" {
  count = var.enable_database ? 1 : 0

  name        = var.name
  description = "Isolated database subnets"
  subnet_ids  = var.database_subnet_ids

  tags = var.tags
}

resource "aws_db_parameter_group" "this" {
  count = var.enable_database ? 1 : 0

  name        = "${var.name}-pg${var.engine_version}"
  family      = "postgres${var.engine_version}"
  description = "Enforce TLS and log slow queries"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # ms
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_157:Single-AZ in the lab for cost; enable multi_az in production
  #checkov:skip=CKV_AWS_293:Deletion protection off - the platform stack is destroyed nightly
  #checkov:skip=CKV_AWS_118:Enhanced monitoring adds CloudWatch cost; not needed for the lab
  #checkov:skip=CKV_AWS_129:Log exports to CloudWatch cost per GB; enable in production
  #checkov:skip=CKV_AWS_353:Performance Insights off for cost in the lab
  #checkov:skip=CKV_AWS_354:Performance Insights off, so no PI KMS key
  #checkov:skip=CKV2_AWS_60:No snapshots kept for an ephemeral lab DB
  #checkov:skip=CKV2_AWS_30:Query logging handled via log_min_duration_statement parameter
  count = var.enable_database ? 1 : 0

  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name                     = var.database_name
  username                    = var.master_username
  manage_master_user_password = true

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true # AWS-managed aws/rds key (free)

  db_subnet_group_name   = aws_db_subnet_group.this[0].name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this[0].name
  publicly_accessible    = false
  multi_az               = var.multi_az

  iam_database_authentication_enabled = true
  auto_minor_version_upgrade          = true
  copy_tags_to_snapshot               = true

  backup_retention_period = var.backup_retention_days
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:30-sun:04:30"

  deletion_protection       = !var.ephemeral
  skip_final_snapshot       = var.ephemeral
  final_snapshot_identifier = var.ephemeral ? null : "${var.name}-final"
  apply_immediately         = var.ephemeral

  tags = merge(var.tags, { Name = var.name })
}
