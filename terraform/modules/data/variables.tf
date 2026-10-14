variable "name" {
  description = "Name prefix for all data-tier resources."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "database_subnet_ids" {
  description = "Isolated subnets (no internet route) for the DB subnet group. Must span 2+ AZs."
  type        = list(string)

  validation {
    condition     = length(var.database_subnet_ids) >= 2
    error_message = "RDS needs subnets in at least two Availability Zones."
  }
}

# ---------- database ----------

variable "enable_database" {
  description = "Create the RDS instance. Turn off to keep lab-up fast and cheap when you don't need it."
  type        = bool
  default     = true
}

variable "engine_version" {
  description = "PostgreSQL major version. Minor versions are picked and upgraded by AWS."
  type        = string
  default     = "17"
}

variable "instance_class" {
  description = "Burstable Graviton class - cheapest option for a lab."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage_gb" {
  type    = number
  default = 20
}

variable "max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling. 0 disables autoscaling."
  type        = number
  default     = 50
}

variable "database_name" {
  type    = string
  default = "app"
}

variable "master_username" {
  type    = string
  default = "app_admin"
}

variable "multi_az" {
  description = "Standby replica in a second AZ. Doubles cost - keep false in the lab."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  type    = number
  default = 1
}

variable "ephemeral" {
  description = "Lab mode: no deletion protection, no final snapshot, bucket emptied on destroy."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
