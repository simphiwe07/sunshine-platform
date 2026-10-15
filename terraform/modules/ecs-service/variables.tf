variable "name" {
  description = "Name prefix for the cluster, ALB, service and roles."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Subnets for the internet-facing ALB (2+ AZs)."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB needs subnets in at least two Availability Zones."
  }
}

variable "private_subnet_ids" {
  description = "Subnets for the Fargate tasks. Tasks get no public IP; egress goes through NAT."
  type        = list(string)
}

# ---------- edge ----------

variable "hostname" {
  description = "FQDN served by this service, e.g. app.simptechit.click."
  type        = string
}

variable "zone_id" {
  description = "Route 53 hosted zone that gets the alias record for hostname."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate covering hostname (the foundation wildcard cert)."
  type        = string
}

variable "ssl_policy" {
  description = "TLS 1.3 + 1.2 only."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

# ---------- container ----------

variable "container_image" {
  description = "Image to run. Phase 4 uses a public image; phase 4b swaps in our own from ECR."
  type        = string
  default     = "public.ecr.aws/docker/library/nginx:stable-alpine"
}

variable "container_port" {
  type    = number
  default = 80
}

variable "health_check_path" {
  type    = string
  default = "/"
}

variable "cpu" {
  description = "Task CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory in MiB."
  type        = number
  default     = 512
}

variable "environment" {
  description = "Plain environment variables for the container."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Env var name => Secrets Manager ARN (optionally ARN:json-key::). Injected by ECS at task start; the execution role may read only these ARNs."
  type        = map(string)
  default     = {}
}

variable "extra_security_group_ids" {
  description = "Extra SGs for the tasks, e.g. the data-tier app SG that the DB accepts."
  type        = list(string)
  default     = []
}

variable "app_bucket_arn" {
  description = "S3 bucket the task role may read/write. null = no S3 access."
  type        = string
  default     = null
}

# ---------- capacity ----------

variable "min_count" {
  description = "Minimum (and initial) number of tasks."
  type        = number
  default     = 2
}

variable "max_count" {
  type    = number
  default = 4
}

variable "cpu_target_percent" {
  description = "Target-tracking autoscaling on average service CPU."
  type        = number
  default     = 60
}

variable "on_demand_base" {
  description = "Tasks always placed on regular Fargate. Everything above runs on Fargate Spot (~70% cheaper, 2-minute interruption notice)."
  type        = number
  default     = 1
}

variable "enable_execute_command" {
  description = "ECS Exec: shell into running containers via SSM, no SSH or bastion."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
