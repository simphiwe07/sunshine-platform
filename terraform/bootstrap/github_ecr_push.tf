# GitHub Actions: push the app image to ECR - and nothing else.
# Trusted only for the delivery branches (develop -> dev, release/* -> staging,
# main -> prod); pull requests and feature branches build and scan without any
# AWS access at all.

locals {
  app_repository_arn = "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${var.prefix}-app"
}

data "aws_iam_policy_document" "ecr_push_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike" # release/* needs a wildcard
      variable = "${local.oidc_host}:sub"
      values = [
        "${local.gh_subject}:ref:refs/heads/main",
        "${local.gh_subject}:ref:refs/heads/develop",
        "${local.gh_subject}:ref:refs/heads/release/*",
      ]
    }
  }
}

resource "aws_iam_role" "ecr_push" {
  name                 = "${var.prefix}-gha-ecr-push"
  description          = "GitHub Actions: push app images to ECR (main branch only)"
  assume_role_policy   = data.aws_iam_policy_document.ecr_push_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "RegistryLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # account-level action, no resource-level permissions
  }

  statement {
    sid = "PushToAppRepository"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImageScanFindings",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]

    resources = [local.app_repository_arn]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "push-app-image"
  role   = aws_iam_role.ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
