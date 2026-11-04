# ---------- people: Kubernetes RBAC for the persona groups ----------
# The eks module maps IAM roles to these groups (access entries):
#
#   persona     IAM role                      Kubernetes groups         can
#   viewer      sunshine-lab-eks-viewer       sunshine:viewers          read everything except Secrets
#   developer   sunshine-lab-eks-developer    + sunshine:developers     + restart/roll back the app, delete its pods
#                                                                       (dev + staging namespaces; not in prod)
#   admin       AccountFullAccessRole         (EKS access policy)       cluster-admin
#
# Deliberately NOT for developers: Secrets (DB password), exec/port-forward
# into pods (bypasses the ALB sign-in), RBAC, other namespaces.

locals {
  viewer_group    = "sunshine:viewers"    # keep in sync with var.personas in the eks module
  developer_group = "sunshine:developers" # ditto
}

# Built-in "view": read most objects in every namespace, never Secrets or RBAC.
resource "kubernetes_cluster_role_binding_v1" "viewers" {
  metadata {
    name = "sunshine-viewers"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  subject {
    kind      = "Group"
    name      = local.viewer_group
    api_group = "rbac.authorization.k8s.io"
  }
}

# Day-2 operations on the app, in the app namespaces where developers have
# access (dev + staging; never prod - there only admins act).
resource "kubernetes_role_v1" "developer" {
  for_each = { for env, cfg in var.app_envs : env => cfg if cfg.developer_access }

  metadata {
    name      = "sunshine-developer"
    namespace = kubernetes_namespace_v1.app[each.key].metadata[0].name
  }

  # kubectl rollout restart / undo = patch the Deployment
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "patch"]
  }

  # Bounce one stuck pod (the ReplicaSet replaces it)
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["delete"]
  }
}

resource "kubernetes_role_binding_v1" "developers" {
  for_each = kubernetes_role_v1.developer

  metadata {
    name      = "sunshine-developers"
    namespace = each.value.metadata[0].namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = local.developer_group
    api_group = "rbac.authorization.k8s.io"
  }
}
