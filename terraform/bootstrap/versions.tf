terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Step 1: first apply runs with LOCAL state (this block commented out).
  # Step 2: uncomment, then run:
  #   terraform init -migrate-state -backend-config="bucket=<state_bucket output>"
  #
  backend "s3" {
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true
    encrypt      = true
  }
}
