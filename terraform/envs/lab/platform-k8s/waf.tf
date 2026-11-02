# ---------- AWS WAF in front of the app's ALB ----------
# Evaluated before the ALB's listener rules (so before Cognito sign-in), in
# priority order, first terminating match wins:
#
#   0   rate limit per client IP           block (flood / brute force)
#   10  country allowlist                  count or block (var.waf_geo_action)
#   20  Amazon IP reputation list          block known-bad IPs (botnets, scanners)
#   30  known bad inputs                   block Log4Shell, ...
#   40  SQL injection                      block (the app talks to Postgres)
#   50  core rule set (OWASP-style)        block XSS, LFI, no User-Agent, ...
#   -   default                            allow
#
# The LB controller attaches it to the IngressGroup's ALB (wafv2-acl-arn).
# WAFv2 attaches to ALB, API Gateway, CloudFront, AppSync, Cognito - NOT to
# NLBs: an NLB service needs protection elsewhere (CloudFront/Shield, SGs).
# ~1,130 WCU of the 1,500 included in the base price.

locals {
  waf_name = "${var.project}-${var.environment}"

  # priority => managed rule group (AWS-maintained, versioned by AWS)
  waf_managed_groups = {
    20 = "AWSManagedRulesAmazonIpReputationList"
    30 = "AWSManagedRulesKnownBadInputsRuleSet"
    40 = "AWSManagedRulesSQLiRuleSet"
    50 = "AWSManagedRulesCommonRuleSet"
  }
}

resource "aws_wafv2_web_acl" "app" {
  #checkov:skip=CKV_AWS_192:Log4Shell is blocked by AWSManagedRulesKnownBadInputsRuleSet (priority 30), added via a dynamic block checkov does not expand
  count = var.enable_waf ? 1 : 0

  name  = local.waf_name
  scope = "REGIONAL" # ALB; CLOUDFRONT scope lives in us-east-1

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        aggregate_key_type    = "IP" # client IP as the ALB sees it (no CDN in front)
        limit                 = var.waf_rate_limit
        evaluation_window_sec = 60 # short window: blocks start (and lift) within ~1 min
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "geo-allowlist"
    priority = 10

    # Count = log + label only, the request still goes through. Roll out new
    # blocking rules in count first, read the logs, then switch to block.
    action {
      dynamic "count" {
        for_each = var.waf_geo_action == "count" ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = var.waf_geo_action == "block" ? [1] : []
        content {}
      }
    }

    statement {
      not_statement {
        statement {
          geo_match_statement {
            country_codes = var.waf_allowed_countries
          }
        }
      }
    }

    # Lets later rules (or log queries) act on "out of market" requests.
    rule_label {
      name = "geo:out-of-market"
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "geo-allowlist"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.waf_managed_groups

    content {
      name     = rule.value
      priority = rule.key

      # none = use each managed rule's own action (block); count {} would
      # downgrade the whole group to count-only, e.g. while tuning.
      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.waf_name
    sampled_requests_enabled   = true
  }
}

# ---------- WAF logs: every request, with the verdict and matching rules ----------
# The log group name MUST start with "aws-waf-logs-". All requests are kept
# (lab volume is tiny): "which countries hit us?" needs the allowed ones too.

resource "aws_cloudwatch_log_group" "waf" {
  #checkov:skip=CKV_AWS_158:Default CloudWatch encryption instead of a CMK in the lab
  #checkov:skip=CKV_AWS_338:3-day retention is enough for a nightly-destroyed lab
  count = var.enable_waf ? 1 : 0

  name              = "aws-waf-logs-${local.waf_name}"
  retention_in_days = 3
}

resource "aws_wafv2_web_acl_logging_configuration" "app" {
  count = var.enable_waf ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.app[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # Credentials never land in logs: the ALB session cookie is a bearer token.
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}
