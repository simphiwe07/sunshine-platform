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
