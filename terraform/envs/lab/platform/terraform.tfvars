vpc_cidr           = "10.20.0.0/16"
az_count           = 2
enable_nat_gateway = true
enable_flow_logs   = false
enable_database    = true

# Phase 5: run the app on EKS; ECS off to save ~$0.04/hr while EKS is on.
enable_app = false
enable_eks = true
# EKS upgrade drill: control plane and nodes on 1.37
eks_version = "1.37"
