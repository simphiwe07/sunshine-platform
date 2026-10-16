data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
}

# ---------- control plane ----------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Created up front so retention applies (EKS would otherwise create it with "never expire").
resource "aws_cloudwatch_log_group" "cluster" {
  #checkov:skip=CKV_AWS_158:Default CloudWatch encryption instead of a CMK ($1/month) in the lab
  #checkov:skip=CKV_AWS_338:7-day retention is enough for a nightly-destroyed lab
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_39:Public endpoint needed by GitHub-hosted runners (no fixed IPs); every call is still IAM-authenticated
  #checkov:skip=CKV_AWS_38:Same as above - restrict public_access_cidrs when runners have fixed egress IPs
  #checkov:skip=CKV_AWS_58:EKS envelope-encrypts all Kubernetes API data by default; a customer KMS key adds $1/month per lab-up
  #checkov:skip=CKV_AWS_37:audit + authenticator logs only; api/controllerManager/scheduler are high-volume and billed
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true # nodes talk to the API inside the VPC
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  # EKS access entries instead of the aws-auth ConfigMap: access is managed
  # through the EKS API (and Terraform), so a bad ConfigMap edit can't lock
  # everyone out. Nobody gets implicit admin - every principal is listed below.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  # Never slip into extended support (6x the control-plane price) silently:
  # with STANDARD, EKS auto-upgrades a cluster at end of standard support.
  upgrade_policy {
    support_type = "STANDARD"
  }

  enabled_cluster_log_types = ["audit", "authenticator"]

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ---------- who can use the cluster ----------

locals {
  access = merge(
    { for arn in var.admin_role_arns : arn => "AmazonEKSClusterAdminPolicy" },
    { for arn in var.admin_view_role_arns : arn => "AmazonEKSAdminViewPolicy" },
    { for arn in var.view_role_arns : arn => "AmazonEKSViewPolicy" },
  )
}

resource "aws_eks_access_entry" "this" {
  for_each = local.access

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.key
  type          = "STANDARD"
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.access

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.this[each.key].principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/${each.value}"

  access_scope {
    type = "cluster"
  }
}
