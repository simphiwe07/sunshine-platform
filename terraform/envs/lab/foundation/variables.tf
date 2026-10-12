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

variable "domain_name" {
  description = "Domain or delegated subdomain for the lab."
  type        = string

  validation {
    condition     = !strcontains(var.domain_name, "example.")
    error_message = "Set domain_name in terraform.tfvars to a domain you own."
  }
}

variable "create_zone" {
  description = "false if Route 53 already created the zone (domain registered in Route 53)."
  type        = bool
  default     = true
}

variable "validate_certificate" {
  description = "Flip to true after NS delegation is live."
  type        = bool
  default     = false
}
