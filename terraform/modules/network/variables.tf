variable "name" {
  description = "Name prefix for all network resources."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. Must be a /16; subnets are carved from it."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.cidr_block, 0)) && try(tonumber(split("/", var.cidr_block)[1]) == 16, false)
    error_message = "cidr_block must be a valid /16 CIDR."
  }
}

variable "az_count" {
  description = "Number of Availability Zones (2 or 3)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "enable_nat_gateway" {
  description = "Single NAT gateway for private-subnet egress (~$0.045/hr + data). Off = private subnets have no internet."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs (costs per GB ingested)."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "CloudWatch retention for flow logs."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Extra tags for every resource (provider default_tags still apply)."
  type        = map(string)
  default     = {}
}
