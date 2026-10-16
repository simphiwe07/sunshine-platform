# EKS managed add-ons. Versions come from the API for the CURRENT control-plane
# version, so bumping kubernetes_version also moves each add-on to a compatible
# release in the same apply (control plane first, then add-ons - see depends_on).

locals {
  vpc_cni_config = jsonencode({
    # Prefix delegation: each ENI slot holds a /28 (16 IPs) instead of one IP,
    # so a t3.medium runs ~110 pods instead of 17.
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
    # Enforce Kubernetes NetworkPolicy with the VPC CNI's eBPF agent.
    enableNetworkPolicy = "true"
  })

  # DaemonSets: fine with zero nodes, and nodes need them to become Ready.
  addons_before_nodes = {
    "vpc-cni"                = local.vpc_cni_config
    "kube-proxy"             = null
    "eks-pod-identity-agent" = null
  }

  # Deployments: need nodes to schedule on.
  addons_after_nodes = {
    "coredns"        = null
    "metrics-server" = null # feeds the HorizontalPodAutoscaler
  }
}

data "aws_eks_addon_version" "this" {
  for_each = merge(local.addons_before_nodes, local.addons_after_nodes)

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "before_nodes" {
  for_each = local.addons_before_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  configuration_values        = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags
}

resource "aws_eks_addon" "after_nodes" {
  for_each = local.addons_after_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  configuration_values        = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags

  depends_on = [aws_eks_node_group.spot]
}
