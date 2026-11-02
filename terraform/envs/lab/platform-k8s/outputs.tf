output "app_url" {
  description = "App behind the ALB (Ingress). Read by the lab-up smoke test."
  value       = "https://${local.app_host}"
}

output "nlb_url" {
  value = local.nlb_host == "" ? null : "https://${local.nlb_host}"
}

output "app_version" {
  description = "Git SHA of the deployed image."
  value       = try([for t in data.aws_ecr_image.app.image_tags : t if length(t) == 40][0], null)
}

output "cluster_name" {
  value = local.cluster_name
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
