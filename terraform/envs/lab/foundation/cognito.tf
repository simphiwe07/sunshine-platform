# Sign-in for the apps: a Cognito user pool the ALB authenticates against
# (OIDC authorization-code flow). Lives in the persistent foundation stack, so
# users, groups and MFA enrolments survive the nightly lab-down. Lite tier:
# free up to 10,000 monthly active users, no cost while idle.
#
# Groups mirror the Kubernetes personas (viewer / developer / admin): one role
# model, enforced in the app (Cognito groups) and in the cluster (IAM -> RBAC).

locals {
  auth_callback_urls = [for h in var.auth_app_hostnames : "https://${h}.${var.domain_name}/oauth2/idpresponse"]
  auth_logout_urls   = [for h in var.auth_app_hostnames : "https://${h}.${var.domain_name}/"]
}

resource "aws_cognito_user_pool" "lab" {
  count = var.enable_cognito ? 1 : 0

  name                = "${var.project}-${var.environment}"
  user_pool_tier      = "LITE"
  deletion_protection = "ACTIVE" # users and MFA enrolments are the one thing here you can't recreate

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # No self sign-up: an admin creates every user (invite-only lab).
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = 14
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  # TOTP (authenticator app) required for everyone; enrolment happens on the
  # first sign-in. No SMS: costs money and is the weakest second factor.
  mfa_configuration = "ON"

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_domain" "lab" {
  count = var.enable_cognito ? 1 : 0

  # Prefix domain: <prefix>.auth.<region>.amazoncognito.com. A custom domain
  # (auth.simptechit.click) needs an ACM cert in us-east-1 - not worth it here.
  domain                = var.auth_domain_prefix
  user_pool_id          = aws_cognito_user_pool.lab[0].id
  managed_login_version = 1 # classic hosted UI (the Lite tier's sign-in pages)
}

resource "aws_cognito_user_group" "persona" {
  for_each = var.enable_cognito ? {
    viewer    = { precedence = 30, description = "Read-only: can sign in and view the app." }
    developer = { precedence = 20, description = "Viewer + developer features." }
    admin     = { precedence = 10, description = "Everything, including /admin." }
  } : {}

  user_pool_id = aws_cognito_user_pool.lab[0].id
  name         = each.key
  precedence   = each.value.precedence
  description  = each.value.description
}

# The client the ALB uses. It needs a secret (confidential client); the ALB
# reads it from Cognito itself, so the secret never appears in Kubernetes.
resource "aws_cognito_user_pool_client" "alb" {
  count = var.enable_cognito ? 1 : 0

  name            = "alb"
  user_pool_id    = aws_cognito_user_pool.lab[0].id
  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"] # authorization code; never implicit
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = local.auth_callback_urls # the ALB's fixed /oauth2/idpresponse
  logout_urls                          = local.auth_logout_urls

  explicit_auth_flows           = ["ALLOW_REFRESH_TOKEN_AUTH"] # no password APIs: hosted UI only
  prevent_user_existence_errors = "ENABLED"                    # "wrong user or password", never "no such user"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 12

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }
}
