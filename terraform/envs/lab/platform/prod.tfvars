# The PROD cluster: same stack, same account, its own VPC, database and EKS
# cluster (sunshine-prod). Used with its own state:
#   terraform init -backend-config="bucket=..." -backend-config="key=prod/platform.tfstate"
#   terraform apply -var-file=prod.tfvars
# (terraform.tfvars is loaded too - this file overrides what differs.)
environment = "prod"
vpc_cidr    = "10.30.0.0/16" # no overlap with non-prod (10.20/16): peering/VPN stays possible
app_envs    = ["prod"]       # one app namespace: sunshine-prod
enable_app  = false          # no ECS here
enable_eks  = true
eks_version = "1.37"
