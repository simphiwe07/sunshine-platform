# One managed node group on Spot. Managed = EKS handles the ASG, AMI updates and
# graceful rolling replacement (cordon, drain respecting PodDisruptionBudgets).

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  # Worker: join the cluster. CNI: assign VPC IPs to pods. PullOnly: pull images,
  # nothing else in ECR. SSM: Session Manager shell instead of SSH keys.
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "nodes" {
  name_prefix            = "${var.name}-nodes-"
  description            = "EKS nodes: IMDSv2 only, hop limit 1, encrypted gp3"
  update_default_version = true

  # When a launch template sets SGs, EKS no longer adds the cluster SG itself.
  # cluster SG = node<->control plane traffic; extra SGs = e.g. database access.
  vpc_security_group_ids = concat(
    [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id],
    var.node_security_group_ids,
  )

  # Hop limit 1: pods cannot reach the node's instance metadata (and so cannot
  # borrow the node role). Pods get AWS access only through Pod Identity.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-node" })
  }

  tags = var.tags
}

resource "aws_eks_node_group" "spot" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-spot"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  # Staged upgrades: bump kubernetes_version with node_kubernetes_version pinned
  # to the old value (control plane first), then unpin to roll the nodes.
  version = coalesce(var.node_kubernetes_version, aws_eks_cluster.this.version)

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = var.capacity_type
  instance_types = var.instance_types

  scaling_config {
    min_size     = var.node_min
    desired_size = var.node_desired
    max_size     = var.node_max
  }

  # Rolling replacement one node at a time; each drain honours PDBs.
  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  labels = {
    "sunshine/pool" = "spot"
  }

  # Cluster autoscaling (if added later) owns desired_size.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = var.tags

  # The CNI must exist before nodes join, or they come up NotReady.
  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.before_nodes,
  ]
}
