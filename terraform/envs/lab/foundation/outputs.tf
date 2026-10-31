output "zone_id" {
  value = module.dns.zone_id
}

output "name_servers" {
  value = module.dns.name_servers
}

output "certificate_arn" {
  value = module.dns.certificate_arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "cognito_user_pool_id" {
  value = try(aws_cognito_user_pool.lab[0].id, null)
}

output "cognito_hosted_ui" {
  value = try("https://${aws_cognito_user_pool_domain.lab[0].domain}.auth.${var.region}.amazoncognito.com", null)
}
