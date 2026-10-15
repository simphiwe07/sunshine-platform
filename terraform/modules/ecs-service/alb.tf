# Internet -> ALB (public subnets, TLS terminated here) -> tasks (private subnets).
#
# SG chain:  0.0.0.0/0 --80/443--> alb SG --container_port--> service SG
# The tasks accept traffic only from the ALB's SG, never from a CIDR.

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ALB - HTTPS in, container port out to the service only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  #checkov:skip=CKV_AWS_260:Port 80 only answers with a 301 redirect to HTTPS
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet (redirected to HTTPS)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.service.id
}

resource "aws_lb" "this" {
  #checkov:skip=CKV_AWS_150:Lab ALB is destroyed nightly; deletion protection would block lab-down
  #checkov:skip=CKV_AWS_91:Access logs skipped for cost; enable with an S3 bucket in production
  #checkov:skip=CKV2_AWS_28:WAF is added in phase 7 (hardening)
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = var.tags
}

resource "aws_lb_target_group" "this" {
  #checkov:skip=CKV_AWS_378:TLS ends at the ALB; ALB->task hop stays inside the VPC
  name                 = "${var.name}-tg"
  vpc_id               = var.vpc_id
  target_type          = "ip" # required for Fargate (awsvpc networking)
  protocol             = "HTTP"
  port                 = var.container_port
  deregistration_delay = 30 # default 300s; short drain keeps deploys and lab-down fast

  health_check {
    path                = var.health_check_path
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  # Unknown Host headers (e.g. someone hitting the raw ALB DNS name) get a 404.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }

  tags = var.tags
}

# Host-based routing: one ALB can front many services, one rule per hostname.
resource "aws_lb_listener_rule" "app" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  condition {
    host_header {
      values = [var.hostname]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = var.tags
}

resource "aws_route53_record" "app" {
  zone_id = var.zone_id
  name    = var.hostname
  type    = "A"

  # Alias record: free queries, follows the ALB's changing IPs automatically.
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
