output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_name" {
  value = aws_eks_node_group.spot.node_group_name
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "pod_identity_role_arns" {
  value = { for k, r in aws_iam_role.pod : k => r.arn }
}
