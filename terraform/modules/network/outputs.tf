output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr_block" {
  value = aws_vpc.this.cidr_block
}

output "azs" {
  value = local.azs
}

output "public_subnet_ids" {
  value = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  value = [for az in local.azs : aws_subnet.private[az].id]
}

output "database_subnet_ids" {
  value = [for az in local.azs : aws_subnet.database[az].id]
}

output "private_route_table_id" {
  value = aws_route_table.private.id
}

output "nat_public_ip" {
  description = "Egress IP of the lab - useful for allow-listing."
  value       = try(aws_eip.nat[0].public_ip, null)
}
