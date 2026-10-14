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

variable "github_repository_ids" {
  description = "Owner and repo numeric IDs. Required for repos created after 2026-07-15, whose OIDC sub claim embeds them. Get them with: gh api repos/OWNER/REPO --jq '{owner_id: .owner.id, repo_id: .id}'"

  type = object({
    owner_id = number
    repo_id  = number
  })
  default = null
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

variable "account_access_reference_role" {
  description = "Existing role assignable via Account Access Manager whose trust policy is reused for human roles."
  type        = string
  default     = "AccountFullAccessRole"
}
