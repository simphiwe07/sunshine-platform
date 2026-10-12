variable "domain_name" {
  description = "Domain (or delegated subdomain) the lab serves from, e.g. lab.yourdomain.com."
  type        = string
}

variable "create_zone" {
  description = "true = create the public hosted zone. false = look up an existing one (e.g. auto-created when you register the domain in Route 53)."
  type        = bool
  default     = true
}

variable "validate_certificate" {
  description = "Wait for ACM DNS validation. Only set true once the zone's NS records are delegated, or apply will hang."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
