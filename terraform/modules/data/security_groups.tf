# Security group chaining:
#   app SG  - attached to workloads (ECS tasks, EKS pods/nodes) in later phases
#   db SG   - accepts 5432 ONLY from the app SG; no CIDR-based rules at all
#
# Rules are standalone resources (not inline), so each rule is its own
# Terraform object. Note: rules added in the console are then NOT detected
# as drift - review SGs with AWS Config or Access Analyzer as well.

resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:Attached to ECS/EKS workloads in phases 4-5
  name        = "${var.name}-app"
  description = "Application workloads that may reach the data tier"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-app" })
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Workloads may call out (via NAT / endpoints)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "PostgreSQL - reachable only from the app security group"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from app tier"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}

# No egress rule on the DB SG: RDS never initiates connections.
