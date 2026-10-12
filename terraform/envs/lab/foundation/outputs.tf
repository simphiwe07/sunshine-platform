output "zone_id" {
  value = module.dns.zone_id
}

output "name_servers" {
  value = module.dns.name_servers
}

output "certificate_arn" {
  value = module.dns.certificate_arn
}
