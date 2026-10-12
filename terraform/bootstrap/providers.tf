provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.prefix
      Environment = "shared"
      Stack       = "bootstrap"
      ManagedBy   = "terraform"
      Repository  = var.github_repository
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}
