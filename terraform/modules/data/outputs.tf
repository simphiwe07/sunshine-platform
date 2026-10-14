output "app_security_group_id" {
  description = "Attach to workloads that need the database."
  value       = aws_security_group.app.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

output "db_endpoint" {
  description = "host:port of the PostgreSQL instance."
  value       = try(aws_db_instance.this[0].endpoint, null)
}

output "db_address" {
  value = try(aws_db_instance.this[0].address, null)
}

output "db_name" {
  value = var.database_name
}

output "db_master_secret_arn" {
  description = "Secrets Manager secret holding the master username/password (managed by RDS)."
  value       = try(aws_db_instance.this[0].master_user_secret[0].secret_arn, null)
}

output "app_bucket_name" {
  value = aws_s3_bucket.app.id
}

output "app_bucket_arn" {
  value = aws_s3_bucket.app.arn
}
