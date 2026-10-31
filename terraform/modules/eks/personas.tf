# ---------- people: IAM role -> Kubernetes groups -> RBAC ----------
# One IAM role per persona. Its access entry puts the caller into Kubernetes
# GROUPS instead of attaching an EKS access policy; what those groups may do is
# plain Kubernetes RBAC (RoleBindings in the platform-k8s stack).
#
# Why both mechanisms exist in this cluster:
#   access policies (cluster.tf)  AWS-managed, coarse: admin / admin-view / view.
#   groups + RBAC (here)          our own rules, e.g. "restart the app's
#                                 Deployment but never read its Secrets or exec".
#
# Humans don't log in AS these roles; an admin session assumes them
# (role chaining) - in production, an Identity Center permission set per persona.

data "aws_iam_policy_document" "persona_assume" {
  statement {
    # SetSourceIdentity: role chaining from an SSO session that carries a
    # source identity fails without it.
    actions = ["sts:AssumeRole", "sts:SetSourceIdentity"]

    principals {
      type        = "AWS"
      identifiers = var.persona_trusted_role_arns
    }
  }
}

resource "aws_iam_role" "persona" {
  for_each = length(var.persona_trusted_role_arns) > 0 ? var.personas : {}

  name                 = "${var.name}-eks-${each.key}"
  description          = "EKS persona ${each.key}: Kubernetes groups ${join(", ", each.value)}"
  assume_role_policy   = data.aws_iam_policy_document.persona_assume.json
  max_session_duration = 3600
  tags                 = var.tags
}

# Just enough AWS access to build a kubeconfig. Everything inside the cluster
# is decided by Kubernetes RBAC, not by IAM.
data "aws_iam_policy_document" "persona" {
  statement {
    sid       = "DescribeThisCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.this.arn]
  }
}

resource "aws_iam_role_policy" "persona" {
  for_each = aws_iam_role.persona

  name   = "describe-cluster"
  role   = each.value.id
  policy = data.aws_iam_policy_document.persona.json
}

resource "aws_eks_access_entry" "persona" {
  for_each = aws_iam_role.persona

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.arn
  type              = "STANDARD"
  kubernetes_groups = var.personas[each.key]
  # Audit log shows "<persona>:<session name>" instead of the role ARN.
  user_name = "${each.key}:{{SessionName}}"
  tags      = var.tags
}
