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

variable "platform_state_key" {
  description = "State of the platform stack this cluster belongs to (lab = non-prod cluster, prod = prod cluster)."
  type        = string
  default     = "lab/platform.tfstate"
}

variable "cognito_pool_name" {
  description = "Cognito user pool (foundation stack) the ALB signs users in with."
  type        = string
  default     = "sunshine-lab"
}

variable "state_bucket" {
  description = "Terraform state bucket (read the platform stack's outputs). CI sets TF_VAR_state_bucket."
  type        = string
}

variable "domain_name" {
  type    = string
  default = "simptechit.click"
}

variable "app_envs" {
  description = "Environments on this cluster: one namespace (sunshine-<env>), hostname and Argo CD Application each. Argo CD follows the env's pointer branch, which only CI moves."
  type = map(object({
    hostname         = string                # <hostname>.<domain_name>
    branch           = string                # pointer branch Argo CD deploys from
    dashboard        = optional(bool, false) # Grafana dashboard (one env per cluster, or they collide)
    developer_access = optional(bool, true)  # Kubernetes "developer" persona may restart pods here
  }))
  default = {
    dev     = { hostname = "dev", branch = "env/dev", dashboard = true }
    staging = { hostname = "staging", branch = "env/staging" }
  }
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

variable "argocd_chart_version" {
  description = "argo-cd chart 10.10.x = Argo CD v3.5."
  type        = string
  default     = "10.10.2"
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.7"
}

variable "image_repository" {
  description = "Where the app image comes from. Empty = this account's ECR repo. The prod account sets the non-prod repo: images are built once, there, and pulled cross-account."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "owner/repo Argo CD reads the app chart and its version from."
  type        = string
  default     = "simphiwe07/sunshine-platform"
}
