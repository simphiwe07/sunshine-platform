# ---------- GitOps: Argo CD deploys the app from Git ----------
#
#   who owns what
#   Terraform  the platform (controllers, monitoring, WAF) + Argo CD itself +
#              the Application object, carrying the ENVIRONMENT settings it
#              knows (certificate, sign-in, WAF, database, subnets)
#   Git        the app VERSION: deploy/charts/sunshine-app/values-lab.yaml
#              (image digest) + the chart - a PR is a deploy, a revert a rollback
#   Argo CD    keeps the cluster equal to Git: polls the repo, syncs changes,
#              puts back anything changed by hand (self-heal), deletes what was
#              removed from Git (prune)
#
# Precedence in the Application (high -> low): valuesObject (Terraform) >
# valueFiles (values-lab.yaml in Git) > chart defaults. The image is ONLY in
# Git, so a Terraform apply never changes the running version.

locals {
  gitops_repo   = "https://github.com/${var.github_repository}"
  gitops_values = yamldecode(file("${path.module}/../../../../deploy/charts/sunshine-app/values-lab.yaml"))
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

  values = [yamlencode({
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
  })]

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
    # A project per team/app = a fence: this app may only come from our repo
    # and only land in its namespace, and may create no cluster-wide objects
    # (no CRDs, ClusterRoles, ...): clusterResourceWhitelist is empty.
    projects = {
      sunshine = {
        namespace   = "argocd"
        description = "sunshine-app: our repo -> namespace sunshine only"
        finalizers  = ["resources-finalizer.argocd.argoproj.io"]
        sourceRepos = [local.gitops_repo]
        destinations = [{
          server    = "https://kubernetes.default.svc"
          namespace = kubernetes_namespace_v1.app.metadata[0].name
        }]
      }
    }

    applications = {
      # Name = Helm release name = app.kubernetes.io/instance label, the same
      # as when Terraform deployed it, so Argo CD adopts the running objects
      # (Deployment selectors are immutable) instead of replacing them.
      sunshine-app = {
        namespace = "argocd"
        project   = "sunshine"
        # Deleting the Application deletes what it deployed (Ingress -> ALB).
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = local.gitops_repo
          targetRevision = var.gitops_revision
          path           = "deploy/charts/sunshine-app"
          helm = {
            releaseName = "sunshine-app"
            valueFiles  = ["values-lab.yaml"]
            valuesObject = {
              region            = var.region
              bucket            = local.platform.app_bucket_name
              loadBalancerCidrs = sort([for s in data.aws_subnet.public : s.cidr_block])
              ingress = {
                host           = local.app_host
                certificateArn = data.aws_acm_certificate.wildcard.arn
                wafAclArn      = try(aws_wafv2_web_acl.app[0].arn, "")
              }
              nlb = {
                enabled        = local.nlb_host != ""
                host           = local.nlb_host
                certificateArn = data.aws_acm_certificate.wildcard.arn
              }
              metrics = { enabled = var.enable_monitoring }
              auth    = local.auth_values
              database = {
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
          namespace = kubernetes_namespace_v1.app.metadata[0].name
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
