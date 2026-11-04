output "app_url" {
  description = "First environment's URL - read by the lab-up smoke test (reachability, sign-in, WAF)."
  value       = "https://${values(local.app_hosts)[0]}"
}

output "app_urls" {
  description = "Every environment on this cluster."
  value       = { for env, host in local.app_hosts : env => "https://${host}" }
}

output "cluster_name" {
  value = local.cluster_name
}

output "grafana" {
  description = "Grafana UI (sign in with Cognito; break-glass: port-forward + local admin)."
  value = var.enable_monitoring ? (
    local.admin_ui_enabled ? "https://${local.admin_hosts["grafana"]}" : "kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
  ) : null
}

output "auth" {
  description = "Sign-in details (users: docs/runbooks/identity.md)."
  value = var.enable_auth ? {
    hosted_ui    = "https://${local.cognito_domain}"
    user_pool_id = local.user_pool_id
  } : null
}

output "waf" {
  description = "WAF web ACL and its log group (queries: docs/runbooks/waf.md)."
  value = var.enable_waf ? {
    web_acl   = aws_wafv2_web_acl.app[0].name
    log_group = aws_cloudwatch_log_group.waf[0].name
    geo       = "${var.waf_geo_action} outside ${join(",", var.waf_allowed_countries)}"
  } : null
}

output "argocd" {
  description = "Argo CD UI (sign in with Cognito; break-glass: port-forward + local admin)."
  value       = local.admin_ui_enabled ? "https://${local.admin_hosts["argocd"]}" : "kubectl -n argocd port-forward svc/argocd-server 8080:443"
}
