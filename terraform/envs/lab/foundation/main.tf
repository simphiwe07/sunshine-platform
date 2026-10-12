module "dns" {
  source = "../../../modules/dns"

  domain_name          = var.domain_name
  create_zone          = var.create_zone
  validate_certificate = var.validate_certificate
}
