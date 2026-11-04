# Kubernetes layer of the PROD cluster (sunshine-prod). Used with its own state:
#   terraform init -backend-config="bucket=..." -backend-config="key=prod/platform-k8s.tfstate"
#   terraform apply -var-file=prod.tfvars
environment        = "prod"
platform_state_key = "prod/platform.tfstate"

# One environment; Argo CD in THIS cluster follows env/prod. Developers can look
# (viewer) but not restart anything - only admins act in prod.
app_envs = {
  prod = { hostname = "prod", branch = "env/prod", dashboard = true, developer_access = false }
}
