# Persistent, near-free layer: hosted zone ($0.50/month) + ACM cert (free).
# Applied on merge to main; never torn down nightly.

terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket is passed at init: -backend-config="bucket=$TF_STATE_BUCKET"
  backend "s3" {
    key          = "lab/foundation.tfstate"
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
      Stack       = "foundation"
      ManagedBy   = "terraform"
    }
  }
}
