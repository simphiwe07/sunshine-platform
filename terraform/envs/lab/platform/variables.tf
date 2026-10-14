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
