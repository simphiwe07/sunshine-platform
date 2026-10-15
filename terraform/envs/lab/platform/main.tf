locals {
  name = "${var.project}-${var.environment}"
}

module "network" {
  source = "../../../modules/network"

  name               = local.name
  cidr_block         = var.vpc_cidr
  az_count           = var.az_count
  enable_nat_gateway = var.enable_nat_gateway
  enable_flow_logs   = var.enable_flow_logs
}

module "data" {
  source = "../../../modules/data"

  name                = local.name
  vpc_id              = module.network.vpc_id
  database_subnet_ids = module.network.database_subnet_ids
  enable_database     = var.enable_database
  ephemeral           = true
}

# Foundation owns the zone and the wildcard cert. Platform looks them up with
# data sources (not terraform_remote_state), so the stacks stay decoupled:
# platform needs only read access to Route 53/ACM, not to foundation's state.
data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

data "aws_acm_certificate" "wildcard" {
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

module "app" {
  source = "../../../modules/ecs-service"
  count  = var.enable_app ? 1 : 0

  name               = "${local.name}-app"
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  hostname        = "${var.app_subdomain}.${var.domain_name}"
  zone_id         = data.aws_route53_zone.this.zone_id
  certificate_arn = data.aws_acm_certificate.wildcard.arn

  # Tasks also carry the data-tier app SG, which is what the DB SG trusts.
  extra_security_group_ids = [module.data.app_security_group_id]
  app_bucket_arn           = module.data.app_bucket_arn

  # DB_HOST is null (and dropped) when enable_database = false.
  environment = { for k, v in { DB_HOST = module.data.db_address } : k => v if v != null }
}

# Roadmap:
#   phase 4b: own container image (ECR + build/scan/push workflow), DB secret injected
#   phase 5:  module "eks" (cluster, spot node group, LB controller, ExternalDNS)
