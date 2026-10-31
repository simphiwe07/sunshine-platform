output "vpc_id" {
  value = module.network.vpc_id
}

output "azs" {
  value = module.network.azs
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "database_subnet_ids" {
  value = module.network.database_subnet_ids
}

output "nat_public_ip" {
  value = module.network.nat_public_ip
}

output "app_security_group_id" {
  value = module.data.app_security_group_id
}

output "db_endpoint" {
  value = module.data.db_endpoint
}

output "db_master_secret_arn" {
  value = module.data.db_master_secret_arn
}

output "app_bucket_name" {
  value = module.data.app_bucket_name
}

output "app_url" {
  value = try(module.app[0].url, null)
}

output "alb_dns_name" {
  value = try(module.app[0].alb_dns_name, null)
}

output "ecs_cluster_name" {
  value = try(module.app[0].cluster_name, null)
}

output "ecs_service_name" {
  value = try(module.app[0].service_name, null)
}

output "app_version" {
  description = "Git SHA of the deployed image (the smoke test checks the live app reports it)."
  value       = try([for t in data.aws_ecr_image.app[0].image_tags : t if length(t) == 40][0], null)
}

output "vpc_cidr_block" {
  value = module.network.vpc_cidr_block
}

output "db_address" {
  value = module.data.db_address
}

output "db_name" {
  value = module.data.db_name
}

output "eks_cluster_name" {
  value = try(module.eks[0].cluster_name, null)
}

output "eks_cluster_version" {
  value = try(module.eks[0].cluster_version, null)
}

output "eks_kubeconfig_command" {
  value = try("aws eks update-kubeconfig --name ${module.eks[0].cluster_name} --region ${var.region} --profile sunshine", null)
}

output "eks_persona_role_arns" {
  description = "IAM roles for the viewer/developer personas (see docs/runbooks/identity.md)."
  value       = try(module.eks[0].persona_role_arns, {})
}
