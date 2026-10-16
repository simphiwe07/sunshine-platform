variable "name" {
  description = "Cluster name, also the prefix for its roles and node group."
  type        = string
}

variable "kubernetes_version" {
  description = "Control plane version. Upgrade one minor version at a time."
  type        = string
  default     = "1.36"
}

variable "node_kubernetes_version" {
  description = "Node group version. null = same as the control plane. Pin it to the old version to upgrade the control plane first, then nodes."
  type        = string
  default     = null
}

variable "private_subnet_ids" {
  description = "Control plane ENIs and nodes go here (2+ AZs)."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS needs subnets in at least two Availability Zones."
  }
}

variable "public_access_cidrs" {
  description = "Who can reach the public API endpoint (still IAM-authenticated). GitHub-hosted runners have no fixed IPs, so the lab allows all."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_security_group_ids" {
  description = "Extra SGs for the nodes, e.g. the data-tier app SG that the database trusts."
  type        = list(string)
  default     = []
}

# ---------- nodes ----------

variable "instance_types" {
  description = "Several similar types = several Spot pools; losing one pool does not take out every node."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium", "m6a.large"]
}

variable "capacity_type" {
  type    = string
  default = "SPOT"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.capacity_type)
    error_message = "capacity_type must be SPOT or ON_DEMAND."
  }
}

variable "node_min" {
  type    = number
  default = 2
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "node_max" {
  type    = number
  default = 4
}

# ---------- access ----------

variable "admin_role_arns" {
  description = "IAM roles mapped to cluster-admin (EKS access entries, no aws-auth ConfigMap)."
  type        = list(string)
}

variable "admin_view_role_arns" {
  description = "Read everything including Secrets - the CI plan role needs this to diff Helm releases."
  type        = list(string)
  default     = []
}

variable "view_role_arns" {
  description = "Read-only, no Secrets (Kubernetes 'view')."
  type        = list(string)
  default     = []
}

# ---------- workload identities ----------

variable "hosted_zone_arn" {
  description = "Zone ExternalDNS may change."
  type        = string
}

variable "enable_external_secrets" {
  description = "Create the External Secrets identity (needs db_secret_arn). A plain bool so for_each keys are known at plan time."
  type        = bool
  default     = true
}

variable "db_secret_arn" {
  description = "Secret External Secrets may read."
  type        = string
  default     = null
}

variable "app_bucket_arn" {
  description = "Bucket the app's service account may read/write."
  type        = string
}

variable "lb_controller_version" {
  description = "AWS Load Balancer Controller release whose official IAM policy is used. Keep in sync with the Helm chart in platform-k8s."
  type        = string
  default     = "v3.5.0"
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
