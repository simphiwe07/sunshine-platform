# Ephemeral layer: everything that costs money by the hour.
# Created with the "lab-up" workflow, destroyed by "lab-down" (manual + nightly).

terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key          = "lab/platform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Stack       = "platform"
      ManagedBy   = "terraform"
      Ephemeral   = "true"
    }
  }
}
