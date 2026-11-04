# ---------- admin UIs: Argo CD + Grafana on real URLs, behind sign-in ----------
#
#   browser -> WAF -> ALB (Cognito sign-in, like the app) -> Argo CD / Grafana
#                                                            \-> OIDC login with
#   the same Cognito pool: silent (the Cognito session exists already); the ID
#   token's "cognito:groups" decides the role in the tool:
#
#   Cognito group   Argo CD                                   Grafana
#   admin           admin                                     Admin
#   developer       get + sync apps (non-prod) / read (prod)  Editor
#   viewer          read-only                                 Viewer
#   (none)          no access                                 Viewer
#
# Both share the app's ALB (IngressGroup "sunshine"): one load balancer, one
# WAF, one certificate. Break-glass: the local admin users + port-forward still
# work if Cognito is down.

locals {
  admin_ui_enabled = var.enable_auth && var.enable_admin_ui
  admin_hosts      = { for tool, h in var.admin_ui_hosts : tool => "${h}.${var.domain_name}" }

  # Load-balancer-level settings must be identical on every Ingress in the
  # group (the LB controller rejects conflicts) - same values as the app chart.
  admin_ingress_annotations = {
    for k, v in {
      "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/group.name"               = "sunshine"
      "alb.ingress.kubernetes.io/group.order"              = "30"
      "alb.ingress.kubernetes.io/listen-ports"             = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
      "alb.ingress.kubernetes.io/ssl-redirect"             = "443"
      "alb.ingress.kubernetes.io/certificate-arn"          = data.aws_acm_certificate.wildcard.arn
      "alb.ingress.kubernetes.io/ssl-policy"               = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      "alb.ingress.kubernetes.io/load-balancer-attributes" = "routing.http.drop_invalid_header_fields.enabled=true"
      "alb.ingress.kubernetes.io/wafv2-acl-arn"            = try(aws_wafv2_web_acl.app[0].arn, "")
      # The ALB's own sign-in in front - anonymous requests never reach the tools.
      "alb.ingress.kubernetes.io/auth-type"                       = "cognito"
      "alb.ingress.kubernetes.io/auth-idp-cognito"                = jsonencode({ userPoolARN = local.auth_values.userPoolArn, userPoolClientID = local.auth_values.userPoolClientId, userPoolDomain = local.auth_values.userPoolDomain })
      "alb.ingress.kubernetes.io/auth-on-unauthenticated-request" = "authenticate"
      "alb.ingress.kubernetes.io/auth-scope"                      = "openid email"
      "alb.ingress.kubernetes.io/auth-session-cookie"             = "AWSELBAuthSessionCookie"
      "alb.ingress.kubernetes.io/auth-session-timeout"            = "28800"
    } : k => v if v != "" # no WAF annotation when WAF is off
  }

  cognito_issuer = local.auth_values.issuer
  admin_ui_client_ids = local.admin_ui_enabled ? {
    for tool in ["argocd", "grafana"] : tool => data.aws_cognito_user_pool_clients.lab[0].client_ids[
      index(data.aws_cognito_user_pool_clients.lab[0].client_names, tool)
    ]
  } : {}
}

data "aws_cognito_user_pool_client" "admin_ui" {
  for_each = local.admin_ui_client_ids

  user_pool_id = local.user_pool_id
  client_id    = each.value
}

# ---------- Argo CD ----------

# Argo CD resolves "$argocd-oidc:clientSecret" in oidc.config from this Secret;
# it must carry the part-of label to be readable.
resource "kubernetes_secret_v1" "argocd_oidc" {
  count = local.admin_ui_enabled ? 1 : 0

  metadata {
    name      = "argocd-oidc"
    namespace = "argocd"
    labels    = { "app.kubernetes.io/part-of" = "argocd" }
  }

  data = {
    clientSecret = data.aws_cognito_user_pool_client.admin_ui["argocd"].client_secret
  }

  depends_on = [helm_release.argocd] # the chart creates the namespace
}

locals {
  argocd_admin_ui_values = {
    global = { domain = local.admin_hosts["argocd"] }
    configs = {
      # TLS ends at the ALB; ALB -> pod is plain HTTP inside the VPC.
      params = { "server.insecure" = true }
      cm = {
        url = "https://${local.admin_hosts["argocd"]}"
        "oidc.config" = yamlencode({
          name            = "Cognito"
          issuer          = local.cognito_issuer
          clientID        = try(local.admin_ui_client_ids["argocd"], "")
          clientSecret    = "$argocd-oidc:clientSecret"
          requestedScopes = ["openid", "email", "profile"]
        })
      }
      rbac = {
        "policy.default" = "" # signed in but in no known group: no access
        scopes           = "[cognito:groups, email]"
        "policy.csv" = join("\n", [
          "p, role:developer, applications, get, sunshine/*, allow",
          "p, role:developer, applications, sync, sunshine/*, allow",
          "p, role:developer, logs, get, sunshine/*, allow",
          "g, admin, role:admin",
          "g, developer, ${var.argocd_developer_can_sync ? "role:developer" : "role:readonly"}",
          "g, viewer, role:readonly",
        ])
      }
    }
    server = {
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        hostname         = local.admin_hosts["argocd"]
        path             = "/"
        pathType         = "Prefix"
        tls              = false # the ALB terminates TLS (wildcard certificate)
        annotations      = merge(local.admin_ingress_annotations, { "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz" })
      }
    }
  }

  # ---------- Grafana (inside kube-prometheus-stack) ----------
  cognito_base_url = "https://${local.cognito_domain}/oauth2"
  grafana_admin_ui_values = {
    grafana = {
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        hosts            = [local.admin_hosts["grafana"]]
        path             = "/"
        pathType         = "Prefix"
        annotations      = merge(local.admin_ingress_annotations, { "alb.ingress.kubernetes.io/healthcheck-path" = "/api/health" })
      }
      envValueFrom = {
        GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = { secretKeyRef = { name = "grafana-oidc", key = "clientSecret" } }
      }
      "grafana.ini" = {
        server = { root_url = "https://${local.admin_hosts["grafana"]}" }
        auth   = { oauth_auto_login = true } # straight to Cognito (break-glass: /login?disableAutoLogin)
        "auth.generic_oauth" = {
          enabled              = true
          name                 = "Cognito"
          client_id            = try(local.admin_ui_client_ids["grafana"], "")
          scopes               = "openid email profile"
          auth_url             = "${local.cognito_base_url}/authorize"
          token_url            = "${local.cognito_base_url}/token"
          api_url              = "${local.cognito_base_url}/userInfo"
          use_pkce             = true
          allow_sign_up        = true
          email_attribute_path = "email"
          login_attribute_path = "email"
          # `[]` default: a user in no group has no cognito:groups claim at all,
          # and contains(null, ...) is an error -> failed login instead of Viewer.
          role_attribute_path   = "contains(\"cognito:groups\" || `[]`, 'admin') && 'Admin' || contains(\"cognito:groups\" || `[]`, 'developer') && 'Editor' || 'Viewer'"
          role_attribute_strict = false
        }
      }
    }
  }
}

resource "kubernetes_secret_v1" "grafana_oidc" {
  count = local.admin_ui_enabled && var.enable_monitoring ? 1 : 0

  metadata {
    name      = "grafana-oidc"
    namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name
  }

  data = {
    clientSecret = data.aws_cognito_user_pool_client.admin_ui["grafana"].client_secret
  }
}
