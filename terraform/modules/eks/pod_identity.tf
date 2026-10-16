# EKS Pod Identity: an IAM role per Kubernetes service account. The pod-identity
# agent hands each pod short-lived credentials for ITS role only - no node-role
# sharing, no long-lived keys, no OIDC provider to manage (unlike IRSA).

locals {
  pod_identities = merge(
    {
      lb-controller = { namespace = "kube-system", service_account = "aws-load-balancer-controller" }
      external-dns  = { namespace = "external-dns", service_account = "external-dns" }
      app           = { namespace = "sunshine", service_account = "sunshine-app" }
    },
    # A known boolean, not "db_secret_arn != null": the ARN is unknown until the
    # database exists, and for_each keys must be known at plan time.
    var.enable_external_secrets ? {
      external-secrets = { namespace = "external-secrets", service_account = "external-secrets" }
    } : {},
  )
}

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "pod" {
  for_each = local.pod_identities

  name               = "${var.name}-pod-${each.key}"
  description        = "Pod Identity: ${each.value.namespace}/${each.value.service_account}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = var.tags
}

resource "aws_eks_pod_identity_association" "this" {
  for_each = local.pod_identities

  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.pod[each.key].arn
  tags            = var.tags
}

# ---------- AWS Load Balancer Controller ----------
# The official policy for the exact controller release, fetched at plan time and
# pinned to the release tag, so the permissions always match the controller.

data "http" "lb_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.lb_controller_version}/docs/install/iam_policy.json"

  lifecycle {
    postcondition {
      condition = (
        self.status_code == 200
        && can(jsondecode(self.response_body).Statement)
        && strcontains(self.response_body, "elasticloadbalancing:CreateLoadBalancer")
      )
      error_message = "Could not fetch a valid AWS Load Balancer Controller IAM policy for ${var.lb_controller_version}."
    }
  }
}

resource "aws_iam_policy" "lb_controller" {
  name        = "${var.name}-lb-controller"
  description = "AWS Load Balancer Controller ${var.lb_controller_version} (official policy)"
  policy      = data.http.lb_controller_policy.response_body
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.pod["lb-controller"].name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# ---------- ExternalDNS: records in ONE hosted zone ----------

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid = "ManageRecordsInLabZone"

    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResources",
    ]

    resources = [var.hosted_zone_arn]
  }

  statement {
    sid       = "FindZones"
    actions   = ["route53:ListHostedZones"]
    resources = ["*"] # account-level list call, no resource-level permissions
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "route53-lab-zone"
  role   = aws_iam_role.pod["external-dns"].id
  policy = data.aws_iam_policy_document.external_dns.json
}

# ---------- External Secrets: read ONE secret ----------

data "aws_iam_policy_document" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  statement {
    sid       = "ReadDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  name   = "read-db-secret"
  role   = aws_iam_role.pod["external-secrets"].id
  policy = data.aws_iam_policy_document.external_secrets[0].json
}

# ---------- the app: its own bucket only (same as the ECS task role) ----------

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ListAppBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.app_bucket_arn]
  }

  statement {
    sid       = "ReadWriteAppObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.app_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "app-bucket"
  role   = aws_iam_role.pod["app"].id
  policy = data.aws_iam_policy_document.app.json
}
