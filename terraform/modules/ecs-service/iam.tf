# Two roles, two jobs:
#   execution role - used by the ECS agent BEFORE the app starts: pull the image,
#                    write logs, fetch the secrets listed in the task definition.
#   task role      - used by the APP at runtime (AWS SDK): S3 bucket, ECS Exec.
# The app never gets the execution role's permissions and vice versa.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Confused-deputy protection: only ECS acting for THIS account may assume.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# ---------- execution role ----------

resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution"
  description        = "ECS agent: pull image, write logs, inject secrets"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  statement {
    sid     = "ReadInjectedSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    # Strip any ":json-key::" suffix - the policy needs the bare secret ARN.
    resources = distinct([for arn in values(var.secrets) : join(":", slice(split(":", arn), 0, 7))])
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  name   = "read-injected-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

# ---------- task role ----------

resource "aws_iam_role" "task" {
  name               = "${var.name}-ecs-task"
  description        = "Application runtime permissions"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "task" {
  count = var.app_bucket_arn != null || var.enable_execute_command ? 1 : 0

  dynamic "statement" {
    for_each = var.app_bucket_arn != null ? [1] : []

    content {
      sid       = "ListAppBucket"
      actions   = ["s3:ListBucket"]
      resources = [var.app_bucket_arn]
    }
  }

  dynamic "statement" {
    for_each = var.app_bucket_arn != null ? [1] : []

    content {
      sid       = "ReadWriteAppObjects"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${var.app_bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []

    content {
      sid = "EcsExecSessionChannels"

      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      # These actions do not support resource-level permissions.
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  #checkov:skip=CKV_AWS_290:ssmmessages actions have no resource-level permissions
  #checkov:skip=CKV_AWS_355:ssmmessages actions have no resource-level permissions
  count = var.app_bucket_arn != null || var.enable_execute_command ? 1 : 0

  name   = "app-runtime"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task[0].json
}
