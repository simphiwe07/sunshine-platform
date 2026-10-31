variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "project" {
  type    = string
  default = "sunshine"
}

variable "environment" {
  type    = string
  default = "lab"
}

variable "state_bucket" {
  description = "Terraform state bucket (read the platform stack's outputs). CI sets TF_VAR_state_bucket."
  type        = string
}

variable "domain_name" {
  type    = string
  default = "simptechit.click"
}

variable "app_hostname" {
  description = "Subdomain for the app behind the ALB (Ingress)."
  type        = string
  default     = "eks"
}

variable "nlb_hostname" {
  description = "Subdomain for the same app behind an NLB (Service type LoadBalancer). Empty = no NLB."
  type        = string
  default     = "nlb"
}

variable "app_image_tag" {
  description = "Deploy this image tag (git SHA) instead of the newest one - e.g. to roll back."
  type        = string
  default     = null
}

# Chart versions are pinned: an upgrade is a reviewed PR, not a surprise.
variable "lb_controller_chart_version" {
  description = "Keep in sync with lb_controller_version (IAM policy) in the eks module."
  type        = string
  default     = "3.5.0"
}

variable "external_dns_chart_version" {
  type    = string
  default = "1.22.0"
}

variable "external_secrets_chart_version" {
  type    = string
  default = "2.12.0"
}

variable "enable_monitoring" {
  description = "kube-prometheus-stack (Prometheus + Grafana) and app metrics/dashboard."
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_chart_version" {
  type    = string
  default = "92.16.1"
}

variable "cluster_autoscaler_chart_version" {
  type    = string
  default = "9.59.0"
}

variable "cluster_autoscaler_image_tag" {
  description = "Should match the cluster's minor version. v1.37.0 was not yet published at build time (k8s.io PR #10146), so v1.36.1 runs one minor behind - bump when available."
  type        = string
  default     = "v1.36.1"
}

variable "enable_auth" {
  description = "Require Cognito sign-in at the ALB (pool from the foundation stack). /healthz and /readyz stay public."
  type        = bool
  default     = true
}

variable "enable_waf" {
  description = "AWS WAF web ACL on the app's ALB (managed rules, rate limit, geo allowlist, logs)."
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "Max requests per client IP per 60 s before WAF blocks it. Raise for load tests from one IP (the k6 drill sends ~40 req/s)."
  type        = number
  default     = 300

  validation {
    condition     = var.waf_rate_limit >= 10
    error_message = "WAF rate-based rules need a limit of at least 10."
  }
}

variable "waf_allowed_countries" {
  description = "ISO country codes the app serves. Everything else matches the geo rule."
  type        = list(string)
  default     = ["ZA"]
}

variable "waf_geo_action" {
  description = "count = log + label out-of-market requests; block = reject them. GitHub-hosted runners are in the US: in block mode the post-deploy smoke test is blocked too."
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.waf_geo_action)
    error_message = "waf_geo_action must be count or block."
  }
}
