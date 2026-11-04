# Read what the platform stack built (cluster name, VPC, DB endpoint, bucket).
# Read-only access to its state; this stack never changes platform resources.
data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.platform_state_key # lab/platform.tfstate, or prod/platform.tfstate
    region = var.region
  }
}

locals {
  platform     = data.terraform_remote_state.platform.outputs
  cluster_name = local.platform.eks_cluster_name
  db_enabled   = try(local.platform.db_address, null) != null

  app_namespaces = { for env, cfg in var.app_envs : env => "${var.project}-${env}" }
  app_hosts      = { for env, cfg in var.app_envs : env => "${cfg.hostname}.${var.domain_name}" }
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

# Public subnets = where the ALB/NLB network interfaces live. Their CIDRs are
# the only sources the app's NetworkPolicy lets in.
data "aws_subnet" "public" {
  for_each = toset(local.platform.public_subnet_ids)
  id       = each.value
}

data "aws_acm_certificate" "wildcard" {
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

data "aws_ecr_repository" "app" {
  count = var.image_repository == "" ? 1 : 0
  name  = "${var.project}-app"
}

locals {
  image_repository = var.image_repository != "" ? var.image_repository : data.aws_ecr_repository.app[0].repository_url
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

# ---------- node autoscaling ----------
# Pending pods (no node has room) -> Cluster Autoscaler raises the managed node
# group's desired size (Terraform ignores desired_size, so they don't fight);
# underused nodes are drained (PDBs respected) and removed after a few minutes.

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 300
  atomic     = true

  values = [yamlencode({
    cloudProvider = "aws"
    awsRegion     = var.region # no instance metadata from pods (hop limit 1)
    autoDiscovery = { clusterName = local.cluster_name }
    image         = { tag = var.cluster_autoscaler_image_tag }
    rbac = {
      serviceAccount = { create = true, name = "cluster-autoscaler" } # Pod Identity match
    }
    extraArgs = {
      expander                      = "least-waste"
      "balance-similar-node-groups" = true
      "skip-nodes-with-system-pods" = false
      # Lab timings (defaults are 10m): see scale-down within one session.
      "scale-down-unneeded-time"   = "3m"
      "scale-down-delay-after-add" = "3m"
    }
  })]

  depends_on = [helm_release.lb_controller]
}

# ---------- monitoring ----------

resource "kubernetes_namespace_v1" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  # No Pod Security "restricted" here: node-exporter needs host network/PID
  # access to read node metrics - an explicit, documented exception.
  metadata {
    name = "monitoring"
  }
}

# Never the chart's well-known default password. Stored in the encrypted state
# bucket and in a Kubernetes Secret; read it with kubectl (see runbook).
resource "random_password" "grafana_admin" {
  count = var.enable_monitoring ? 1 : 0

  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin[0].result
  }
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_monitoring ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace_v1.monitoring[0].metadata[0].name
  wait       = true
  timeout    = 900
  atomic     = true

  values = [yamlencode({
    # EKS runs these control-plane components for us and doesn't expose their
    # metrics endpoints - scraping them would only produce "target down".
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }

    alertmanager = { enabled = false } # alerting + runbooks come in phase 7

    prometheus = {
      prometheusSpec = {
        retention = "6h" # lab: no persistent volume, data lives as long as the pod
        # Pick up ServiceMonitors from every namespace, not just this release's.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { memory = "1536Mi" }
        }
      }
    }

    grafana = {
      admin = {
        existingSecret = kubernetes_secret_v1.grafana_admin[0].metadata[0].name
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }
      # Load dashboard ConfigMaps (label grafana_dashboard=1) from all namespaces,
      # so the app ships its own dashboard.
      sidecar = { dashboards = { searchNamespace = "ALL" } }
    }
  })]

  depends_on = [helm_release.lb_controller]
}

# ---------- the app ----------

resource "kubernetes_namespace_v1" "app" {
  for_each = local.app_namespaces # one per environment: sunshine-dev, sunshine-staging (prod: own account)

  metadata {
    name = each.value

    # Pod Security Admission "restricted": the API server rejects pods that run
    # as root, allow privilege escalation, keep Linux capabilities, etc.
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      # LB controller injects a readiness gate: a pod only counts as Ready once
      # the ALB reports its target healthy. Rollouts and node drains (PDB) then
      # wait for the load balancer, not just the kubelet - found in the 1.37
      # upgrade drill (20 x 502/504 while nodes were drained without it).
      "elbv2.k8s.aws/pod-readiness-gate-inject" = "enabled"
      "sunshine/environment"                    = each.key
    }
  }
}

# The app itself is deployed by Argo CD from Git - see argocd.tf.
