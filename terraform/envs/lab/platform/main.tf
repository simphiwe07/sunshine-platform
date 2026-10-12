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

# Roadmap - each phase adds a module call here:
#   phase 3: module "data"  (RDS Postgres, S3 app bucket, Secrets Manager)
#   phase 4: module "ecs"   (Fargate service behind ALB)
#   phase 5: module "eks"   (cluster, spot node group, LB controller, ExternalDNS)
# Foundation outputs (zone, cert) are read with data sources, not remote state,
# so the two stacks stay decoupled.
