# ---------- sign-in: ALB + Cognito (OIDC) ----------
# The user pool lives in the foundation stack; look it up by name (data sources,
# not remote state - same decoupling as the zone and certificate).
#
#   browser -> ALB: no session cookie -> 302 to the Cognito hosted UI
#   Cognito -> ALB /oauth2/idpresponse (authorization code) -> ALB swaps the code
#   for tokens (with the client secret, which only the ALB and Cognito know)
#   ALB -> pod: request + x-amzn-oidc-data (user claims, signed by the ALB)
#               + x-amzn-oidc-accesstoken (Cognito access token: groups)

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_cognito_user_pools" "lab" {
  count = var.enable_auth ? 1 : 0
  name  = "${var.project}-${var.environment}"
}

locals {
  user_pool_id = var.enable_auth ? one(data.aws_cognito_user_pools.lab[0].ids) : null
}

data "aws_cognito_user_pool" "lab" {
  count        = var.enable_auth ? 1 : 0
  user_pool_id = local.user_pool_id
}

data "aws_cognito_user_pool_clients" "lab" {
  count        = var.enable_auth ? 1 : 0
  user_pool_id = local.user_pool_id
}

locals {
  cognito_domain = try("${data.aws_cognito_user_pool.lab[0].domain}.auth.${var.region}.amazoncognito.com", "")
  alb_client_id = try(
    data.aws_cognito_user_pool_clients.lab[0].client_ids[index(data.aws_cognito_user_pool_clients.lab[0].client_names, "alb")],
    "",
  )

  # Same attributes whether auth is on or off (a conditional between two
  # different object types is a Terraform error).
  auth_values = {
    enabled          = var.enable_auth
    userPoolArn      = try(data.aws_cognito_user_pool.lab[0].arn, "")
    userPoolClientId = local.alb_client_id
    userPoolDomain   = try(data.aws_cognito_user_pool.lab[0].domain, "")
    # The app re-verifies what the ALB forwards (defence in depth):
    issuer = var.enable_auth ? "https://cognito-idp.${var.region}.amazonaws.com/${local.user_pool_id}" : ""
    # The ALB signing x-amzn-oidc-data must be OURS. LB controller names an
    # IngressGroup's ALB k8s-<group>-<hash>.
    signerPrefix = "arn:${data.aws_partition.current.partition}:elasticloadbalancing:${var.region}:${data.aws_caller_identity.current.account_id}:loadbalancer/app/k8s-sunshine-"
    # ALB auth has no logout of its own: the app expires the ALB cookie, then
    # sends the browser here to end the Cognito session too.
    logoutUrl = var.enable_auth ? "https://${local.cognito_domain}/logout?client_id=${local.alb_client_id}&logout_uri=${urlencode("https://${local.app_host}/")}" : ""
  }
}
