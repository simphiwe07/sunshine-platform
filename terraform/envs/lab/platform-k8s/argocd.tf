# ---------- GitOps: Argo CD deploys each environment from its pointer branch ----------
#
#   develop        --CI: build/scan/push, tag image <sha>--> moves env/dev
#   release/x.y    --CI: reuse image (same app/), tag <sha>--> moves env/staging
#   main (release) --CI: same image staging tested + approval--> moves env/prod
#
#   Argo CD here follows env/dev + env/staging (prod: Argo CD in the prod
#   account follows env/prod). imageTag = $ARGOCD_APP_REVISION = the commit the
#   pointer is on; CI tagged that commit's image BEFORE moving the pointer.
#
#   who owns what
#   Terraform  platform, Argo CD, the Applications + ENVIRONMENT settings
#              (certificate, sign-in, WAF, database, hostnames, subnets)
#   Git        the chart and the app; env/<name> = what runs where (history =
#              deployment log; rollback = move the pointer back)
#   Argo CD    keeps each namespace equal to its pointer: sync, self-heal, prune

locals {
  gitops_repo = "https://github.com/${var.github_repository}"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600
  atomic           = true

  values = concat([yamlencode({
    configs = {
      cm = {
        # Check Git every ~1 min instead of 3 (lab feedback). Production: a
        # GitHub webhook to argocd-server makes syncs near-instant.
        "timeout.reconciliation"        = "60s"
        "timeout.reconciliation.jitter" = "10s"
      }
    }
    # No SSO (Dex) or notifications in the lab: admin via port-forward only.
    dex           = { enabled = false }
    notifications = { enabled = false }
  })], local.admin_ui_enabled ? [yamlencode(local.argocd_admin_ui_values)] : []) # admin_ui.tf

  depends_on = [helm_release.lb_controller]
}

resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = "argocd"
  wait       = true

  values = [yamlencode({
    # A project = a fence: these apps may only come from our repo, only land in
    # the app namespaces, and may create no cluster-wide objects (no CRDs,
    # ClusterRoles, ...): clusterResourceWhitelist is empty.
    projects = {
      sunshine = {
        namespace   = "argocd"
        description = "sunshine-app: our repo -> app namespaces only"
        finalizers  = ["resources-finalizer.argocd.argoproj.io"]
        sourceRepos = [local.gitops_repo]
        destinations = [for ns in values(local.app_namespaces) : {
          server    = "https://kubernetes.default.svc"
          namespace = ns
        }]
      }
    }

    applications = {
      for env, cfg in var.app_envs : "sunshine-app-${env}" => {
        namespace = "argocd"
        project   = "sunshine"
        # Deleting the Application deletes what it deployed (Ingress -> ALB rules).
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = local.gitops_repo
          targetRevision = cfg.branch # env/<name>: moved only by CI, after the image exists
          path           = "deploy/charts/sunshine-app"
          helm = {
            releaseName = "sunshine-app"
            # The commit being deployed picks its own image (tag = commit SHA).
            parameters = [{ name = "imageTag", value = "$ARGOCD_APP_REVISION" }]
            valuesObject = {
              imageRepository   = local.image_repository
              region            = var.region
              bucket            = local.platform.app_bucket_name
              loadBalancerCidrs = sort([for s in data.aws_subnet.public : s.cidr_block])
              ingress = {
                host           = local.app_hosts[env]
                certificateArn = data.aws_acm_certificate.wildcard.arn
                wafAclArn      = try(aws_wafv2_web_acl.app[0].arn, "")
              }
              nlb = {
                enabled        = false # one ALB (IngressGroup) serves every environment's host
                host           = ""
                certificateArn = data.aws_acm_certificate.wildcard.arn
              }
              metrics = {
                enabled   = var.enable_monitoring
                dashboard = cfg.dashboard
              }
              auth = merge(local.auth_values, { logoutUrl = local.auth_logout_urls[env] })
              database = {
                # Non-prod: dev + staging share the account's RDS instance.
                # Prod runs in its own account with its own database.
                enabled   = local.db_enabled
                host      = try(local.platform.db_address, "")
                name      = try(local.platform.db_name, "")
                secretArn = try(local.platform.db_master_secret_arn, "")
              }
            }
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = kubernetes_namespace_v1.app[env].metadata[0].name
        }
        syncPolicy = {
          automated = {
            prune    = true # removed from Git -> removed from the cluster
            selfHeal = true # changed by hand -> changed back
          }
          syncOptions = ["CreateNamespace=false", "PruneLast=true"]
          retry = {
            limit   = 5
            backoff = { duration = "10s", factor = 2, maxDuration = "3m" }
          }
        }
        revisionHistoryLimit = 10
      }
    }
  })]

  # Install order = what the app needs first; destroy order = the reverse, so
  # the Application (and with it the Ingress -> ALB) goes while the LB
  # controller and Argo CD still run.
  depends_on = [
    helm_release.argocd,
    helm_release.lb_controller,
    helm_release.external_dns,
    helm_release.external_secrets,
    helm_release.kube_prometheus_stack, # ServiceMonitor CRD
  ]
}

# Until now Terraform installed the app as a Helm release. Forget it WITHOUT
# uninstalling: Argo CD adopts the same objects (same names and labels), so the
# switch causes no downtime and keeps the ALB. Needs Terraform >= 1.7.
removed {
  from = helm_release.app

  lifecycle {
    destroy = false
  }
}
