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

# The app image lives in the foundation ECR repo. Deploy the newest push - or a
# specific tag via app_image_tag (rollback) - and reference it by DIGEST, so the
# task definition points at exact, scanned bytes, never a movable tag.
data "aws_ecr_repository" "app" {
  count = var.enable_app ? 1 : 0
  name  = "${var.project}-app"
}

data "aws_ecr_image" "app" {
  count = var.enable_app ? 1 : 0

  repository_name = data.aws_ecr_repository.app[0].name
  image_tag       = var.app_image_tag
  most_recent     = var.app_image_tag == null ? true : null
}

locals {
  # "" instead of null when enable_database = false: null can't be interpolated
  # into a string, even in a map entry that is filtered out afterwards.
  db_secret_arn = module.data.db_master_secret_arn == null ? "" : module.data.db_master_secret_arn
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

  container_image   = "${data.aws_ecr_repository.app[0].repository_url}@${data.aws_ecr_image.app[0].image_digest}"
  container_port    = 8080
  health_check_path = "/healthz" # liveness only - a DB outage must not fail every task

  # Tasks also carry the data-tier app SG, which is what the DB SG trusts.
  extra_security_group_ids = [module.data.app_security_group_id]
  app_bucket_arn           = module.data.app_bucket_arn

  # "if var.enable_database" keeps the keys known at plan time even while the
  # values (endpoint, secret ARN) are still unknown.
  environment = merge(
    {
      AWS_REGION = var.region
      APP_BUCKET = module.data.app_bucket_name
    },
    {
      for k, v in {
        DB_HOST = module.data.db_address
        DB_NAME = module.data.db_name
      } : k => v if var.enable_database
    },
  )

  # Injected by ECS from Secrets Manager at task start. The execution role may
  # read only this secret; the values never appear in Terraform state or logs.
  secrets = {
    for k, v in {
      DB_USER     = "${local.db_secret_arn}:username::"
      DB_PASSWORD = "${local.db_secret_arn}:password::"
    } : k => v if var.enable_database
  }

  enable_execute_command = var.enable_ecs_exec
}

# ---------- EKS ----------
# The cluster and everything AWS-side (IAM, node group, add-ons, Pod Identity).
# Kubernetes-side installs (Helm charts, the app) live in the platform-k8s stack:
# configuring the Helm/Kubernetes providers from a cluster created in the same
# apply is a known Terraform pitfall, so the two are applied one after another.

data "aws_iam_role" "eks_admin" {
  for_each = toset(["${var.project}-gha-apply", var.human_admin_role])
  name     = each.value
}

data "aws_iam_role" "eks_admin_view" {
  name = "${var.project}-gha-plan"
}

data "aws_iam_role" "eks_view" {
  name = "${var.project}-human-readonly"
}

module "eks" {
  source = "../../../modules/eks"
  count  = var.enable_eks ? 1 : 0

  name                    = local.name
  kubernetes_version      = var.eks_version
  node_kubernetes_version = var.eks_node_version

  private_subnet_ids      = module.network.private_subnet_ids
  node_security_group_ids = [module.data.app_security_group_id] # the DB trusts this SG

  admin_role_arns      = [for r in data.aws_iam_role.eks_admin : r.arn]
  admin_view_role_arns = [data.aws_iam_role.eks_admin_view.arn]
  view_role_arns       = [data.aws_iam_role.eks_view.arn]

  # Personas (viewer, developer) -> Kubernetes groups -> RBAC in platform-k8s.
  # The admin session may assume them, e.g. to prove least privilege.
  persona_trusted_role_arns = [data.aws_iam_role.eks_admin[var.human_admin_role].arn]

  hosted_zone_arn         = data.aws_route53_zone.this.arn
  enable_external_secrets = var.enable_database
  db_secret_arn           = module.data.db_master_secret_arn
  app_bucket_arn          = module.data.app_bucket_arn
}
