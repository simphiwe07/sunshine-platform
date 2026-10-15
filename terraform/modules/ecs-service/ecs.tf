resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_158:Default CloudWatch encryption instead of a CMK ($1/month) in the lab
  #checkov:skip=CKV_AWS_338:7-day retention is enough for a nightly-destroyed lab
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

resource "aws_ecs_cluster" "this" {
  #checkov:skip=CKV_AWS_65:Container Insights is billed per metric; enable for production
  #checkov:skip=CKV_AWS_224:ECS Exec session logs use defaults; add KMS + S3 logging in production
  name = var.name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc" # each task gets its own ENI + security groups
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # Fargate Spot does not support ARM64
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = var.container_image
      essential = true

      # An attacker who gets code execution cannot modify the container's files.
      # Trade-off: ECS Exec needs a writable root fs, so the two are mutually exclusive.
      readonlyRootFilesystem = !var.enable_execute_command

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = [for k, v in var.environment : { name = k, value = v }]
      secrets     = [for k, v in var.secrets : { name = k, valueFrom = v }]

      linuxParameters = {
        initProcessEnabled = true # recommended for ECS Exec (reaps zombie processes)
      }

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.region
          awslogs-stream-prefix = "app"
        }
      }
    }
  ])

  tags = var.tags
}

# ---------- service ----------

resource "aws_security_group" "service" {
  name        = "${var.name}-service"
  description = "Fargate tasks - traffic only from the ALB"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-service" })
}

resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  #checkov:skip=CKV_AWS_260:False positive - source is the ALB security group, not 0.0.0.0/0
  security_group_id            = aws_security_group.service.id
  description                  = "From the ALB only"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "service_https" {
  security_group_id = aws_security_group.service.id
  description       = "ECR, CloudWatch Logs, Secrets Manager, SSM (via NAT)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ecs_service" "this" {
  name                    = var.name
  cluster                 = aws_ecs_cluster.this.id
  task_definition         = aws_ecs_task_definition.this.arn
  desired_count           = var.min_count
  platform_version        = "LATEST"
  enable_execute_command  = var.enable_execute_command
  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  # Give new tasks time to boot before ALB health checks can kill them.
  health_check_grace_period_seconds = 30

  # Rolling deploy: start new tasks first, keep 100% healthy capacity.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # A deploy that never gets healthy is stopped and rolled back automatically.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # First `on_demand_base` tasks on regular Fargate, the rest on Spot.
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.on_demand_base
    weight            = 0
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = concat([aws_security_group.service.id], var.extra_security_group_ids)
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  # Apply fails if tasks never become healthy, instead of "succeeding" with a broken service.
  wait_for_steady_state = true

  # Autoscaling owns desired_count after creation.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_lb_listener_rule.app,
    aws_ecs_cluster_capacity_providers.this,
    aws_iam_role_policy_attachment.execution,
  ]

  tags = var.tags
}

# ---------- autoscaling ----------

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  resource_id        = aws_appautoscaling_target.this.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
