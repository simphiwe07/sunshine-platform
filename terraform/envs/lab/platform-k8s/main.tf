# Read what the platform stack built (cluster name, VPC, DB endpoint, bucket).
# Read-only access to its state; this stack never changes platform resources.
data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "lab/platform.tfstate"
    region = var.region
  }
}

locals {
  platform     = data.terraform_remote_state.platform.outputs
  cluster_name = local.platform.eks_cluster_name
  db_enabled   = try(local.platform.db_address, null) != null

  app_host = "${var.app_hostname}.${var.domain_name}"
  nlb_host = var.nlb_hostname == "" ? "" : "${var.nlb_hostname}.${var.domain_name}"

  chart_dir = "${path.module}/../../../../deploy/charts/sunshine-app"
  # Helm only upgrades a release when its version or values change. Hashing the
  # chart files makes a template-only change roll out too.
  chart_hash = sha1(join("", [for f in sort(fileset(local.chart_dir, "**")) : filesha1("${local.chart_dir}/${f}")]))
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

data "aws_acm_certificate" "wildcard" {
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_ecr_repository" "app" {
  name = "${var.project}-app"
}

data "aws_ecr_image" "app" {
  repository_name = data.aws_ecr_repository.app.name
  image_tag       = var.app_image_tag
  most_recent     = var.app_image_tag == null ? true : null
}

# ---------- controllers ----------
# Their AWS permissions come from Pod Identity associations created by the
# platform stack, matched on namespace + service-account name.

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 600
  atomic     = true # a failed install is rolled back instead of left behind

  # Nodes block pod access to instance metadata (hop limit 1), so the controller
  # can't auto-discover region and VPC - pass them explicitly.
  values = [yamlencode({
    clusterName  = local.cluster_name
    region       = var.region
    vpcId        = local.platform.vpc_id
    replicaCount = 2
    # Off: the mutating webhook intercepts EVERY Service creation in the cluster,
    # and while its pods aren't ready it rejects them ("no endpoints available").
    # Not needed - our NLB Service names its owner via loadBalancerClass.
    enableServiceMutatorWebhook = false
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
  })]
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.external_dns_chart_version
  namespace        = "external-dns"
  create_namespace = true
  wait             = true
  timeout          = 300
  atomic           = true

  values = [yamlencode({
    provider      = { name = "aws" }
    env           = [{ name = "AWS_DEFAULT_REGION", value = var.region }]
    sources       = ["service", "ingress"]
    domainFilters = [var.domain_name]
    # sync = also DELETE records when the Ingress/Service goes away.
    # The TXT registry marks records as "owned by this cluster", so ExternalDNS
    # never touches records it didn't create (e.g. the ECS app's alias).
    policy     = "sync"
    registry   = "txt"
    txtOwnerId = local.cluster_name
    interval   = "1m"
    serviceAccount = {
      create = true
      name   = "external-dns"
    }
  })]

  # The LB controller registers admission webhooks; install other charts only
  # once its pods are ready (wait = true), or their objects can be rejected.
  depends_on = [helm_release.lb_controller]
}

resource "helm_release" "external_secrets" {
  count = local.db_enabled ? 1 : 0

  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 300
  atomic           = true

  # CRDs (ExternalSecret, SecretStore, ...) are installed by the chart by default.
  values = [yamlencode({
    serviceAccount = {
      create = true
      name   = "external-secrets"
    }
  })]

  # The LB controller registers admission webhooks; install other charts only
  # once its pods are ready (wait = true), or their objects can be rejected.
  depends_on = [helm_release.lb_controller]
}

# ---------- the app ----------

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "sunshine"

    # Pod Security Admission "restricted": the API server rejects pods that run
    # as root, allow privilege escalation, keep Linux capabilities, etc.
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "helm_release" "app" {
  name      = "sunshine-app"
  chart     = local.chart_dir
  namespace = kubernetes_namespace_v1.app.metadata[0].name
  wait      = true
  timeout   = 600
  atomic    = true # a release that never gets healthy is rolled back by Helm

  values = [yamlencode({
    chartHash = local.chart_hash
    image     = "${data.aws_ecr_repository.app.repository_url}@${data.aws_ecr_image.app.image_digest}"
    region    = var.region
    vpcCidr   = local.platform.vpc_cidr_block
    bucket    = local.platform.app_bucket_name

    ingress = {
      host           = local.app_host
      certificateArn = data.aws_acm_certificate.wildcard.arn
    }

    nlb = {
      enabled        = local.nlb_host != ""
      host           = local.nlb_host
      certificateArn = data.aws_acm_certificate.wildcard.arn
    }

    database = {
      enabled   = local.db_enabled
      host      = try(local.platform.db_address, "")
      name      = try(local.platform.db_name, "")
      secretArn = try(local.platform.db_master_secret_arn, "")
    }
  })]

  # Destroy order matters: the app (its Ingress/Service) goes FIRST, while the
  # LB controller still runs to delete the ALB/NLB it created.
  depends_on = [
    helm_release.lb_controller,
    helm_release.external_dns,
    helm_release.external_secrets,
  ]
}
