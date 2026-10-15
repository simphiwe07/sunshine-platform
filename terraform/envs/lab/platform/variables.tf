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

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "enable_nat_gateway" {
  type    = bool
  default = true
}

variable "enable_flow_logs" {
  type    = bool
  default = false
}

variable "enable_database" {
  description = "Create RDS on lab-up (adds ~6 min to up/down and ~$0.02/hr)."
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "Hosted zone + wildcard cert created by the foundation stack."
  type        = string
  default     = "simptechit.click"
}

variable "enable_app" {
  description = "Create the ECS Fargate service behind an HTTPS ALB (~$0.04/hr)."
  type        = bool
  default     = true
}

variable "app_subdomain" {
  type    = string
  default = "app"
}

variable "app_image_tag" {
  description = "Deploy this image tag (a git SHA) instead of the newest one - e.g. to roll back."
  type        = string
  default     = null
}

variable "enable_ecs_exec" {
  description = "Allow shell access to tasks via ECS Exec. Also makes the root filesystem writable."
  type        = bool
  default     = false
}
