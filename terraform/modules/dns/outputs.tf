output "zone_id" {
  value = local.zone_id
}

output "name_servers" {
  description = "Delegate the domain to these at your registrar (or parent zone)."
  value       = local.name_servers
}

output "certificate_arn" {
  description = "Wildcard cert ARN. Only usable on a listener once validated."
  value       = try(aws_acm_certificate_validation.this[0].certificate_arn, aws_acm_certificate.this.arn)
}

output "certificate_validated" {
  value = var.validate_certificate
}
