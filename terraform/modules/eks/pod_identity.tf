# EKS Pod Identity: an IAM role per Kubernetes service account. The pod-identity
# agent hands each pod short-lived credentials for ITS role only - no node-role
# sharing, no long-lived keys, no OIDC provider to manage (unlike IRSA).

locals {
  pod_identities = merge(
    {
      lb-controller = { namespace = "kube-system", service_account = "aws-load-balancer-controller" }
      external-dns  = { namespace = "external-dns", service_account = "external-dns" }

      cluster-autoscaler = { namespace = "kube-system", service_account = "cluster-autoscaler" }
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

# One role for the app, linked to its service account in EVERY app namespace
# of this cluster (dev + staging share the non-prod bucket; prod has its own
# account and bucket).
resource "aws_iam_role" "app" {
  name               = "${var.name}-pod-app"
  description        = "Pod Identity: sunshine-app in ${join(", ", var.app_namespaces)}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
  tags               = var.tags
}

moved {
  from = aws_iam_role.pod["app"]
  to   = aws_iam_role.app
}

resource "aws_eks_pod_identity_association" "app" {
  for_each = toset(var.app_namespaces)

  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.value
  service_account = "sunshine-app"
  role_arn        = aws_iam_role.app.arn
  tags            = var.tags
}

resource "aws_iam_role_policy" "app" {
  name   = "app-bucket"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

# ---------- Cluster Autoscaler: resize THIS cluster's node groups only ----------
# Managed node groups tag their Auto Scaling group with
# k8s.io/cluster-autoscaler/<cluster>=owned; the write actions are scoped to it.

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid = "DiscoverNodeGroups"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
    ]

    resources = ["*"] # describe/list calls have no resource-level permissions
  }

  statement {
    sid       = "ReadOwnNodeGroups"
    actions   = ["eks:DescribeNodegroup"]
    resources = ["arn:${local.partition}:eks:*:${local.account_id}:nodegroup/${aws_eks_cluster.this.name}/*/*"]
  }

  statement {
    sid = "ResizeOwnNodeGroups"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]

    # Managed node group ASGs are named eks-<nodegroup>-<uuid>; the tag condition
    # below additionally pins them to THIS cluster.
    resources = ["arn:${local.partition}:autoscaling:*:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/eks-*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${aws_eks_cluster.this.name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  #checkov:skip=CKV_AWS_355:Only describe calls without resource-level permissions use "*"
  name   = "resize-own-node-groups"
  role   = aws_iam_role.pod["cluster-autoscaler"].id
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}

