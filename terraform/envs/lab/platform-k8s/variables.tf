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
