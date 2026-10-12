variable "region" {
  description = "Home region for state, trail and CI roles."
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Short name used to prefix every resource."
  type        = string
  default     = "sunshine"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.prefix))
    error_message = "prefix must be 3-21 chars: lowercase letters, digits, hyphens."
  }
}

variable "github_repository" {
  description = "GitHub repo allowed to assume the CI roles, as owner/repo."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/repo."
  }
}

variable "github_environment" {
  description = "GitHub environment whose jobs may assume the apply role."
  type        = string
  default     = "lab"
}

variable "alert_email" {
  description = "Email address for budget alerts."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly spend (before credits) that triggers alerts."
  type        = number
  default     = 25
}

variable "daily_budget_usd" {
  description = "Daily spend (before credits) that triggers an alert - catches a lab left running overnight."
  type        = number
  default     = 4
}
