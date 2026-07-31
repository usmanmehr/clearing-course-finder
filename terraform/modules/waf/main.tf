# App WAF WebACL (CLOUDFRONT scope - created in us-east-1 via provider alias).
#
# 2027: CRS Block-by-default (H3), WAF logging (M9), plus:
#  - canary_allow_ip: a priority-0 Allow rule so the eu-west-2 canary bypasses
#    the GB geo-block and can detect real 403/429/5xx (an explicit Allow
#    terminates WAF evaluation for that IP).
#  - kill_switch: flips the WebACL default action to BLOCK (site dark, reversible).

variable "name_prefix" { type = string }
variable "crs_count_mode" { type = bool }
variable "kill_switch" {
  type    = bool
  default = false
}
variable "canary_allow_ip" {
  description = "Public IP (a.b.c.d) of the canary to allowlist, or null."
  type        = string
  default     = null
}
variable "canary_enabled" {
  description = "Known-at-plan flag controlling the canary allowlist rule (the IP itself is only known post-apply)."
  type        = bool
  default     = false
}

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

resource "aws_wafv2_ip_set" "canary" {
  count              = var.canary_enabled ? 1 : 0
  name               = "${var.name_prefix}-canary-ip"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = ["${var.canary_allow_ip}/32"]
}

resource "aws_wafv2_web_acl" "app" {
  name        = "${var.name_prefix}-app-waf"
  scope       = "CLOUDFRONT"
  description = "UK Clearing Advisor 2027 app edge WAF"

  default_action {
    dynamic "allow" {
      for_each = var.kill_switch ? [] : [1]
      content {}
    }
    dynamic "block" {
      for_each = var.kill_switch ? [1] : []
      content {}
    }
  }

  # 0) Canary allowlist - explicit Allow bypasses the geo-block below.
  dynamic "rule" {
    for_each = var.canary_enabled ? [1] : []
    content {
      name     = "CanaryAllow"
      priority = 0
      action {
        allow {}
      }
      statement {
        ip_set_reference_statement {
          arn = aws_wafv2_ip_set.canary[0].arn
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "CanaryAllow"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "GeoBlockNonGB"
    priority = 1
    action {
      block {}
    }
    statement {
      not_statement {
        statement {
          geo_match_statement { country_codes = ["GB"] }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "GeoBlockNonGB"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimit"
    priority = 2
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "CommonRuleSet"
    priority = 4
    override_action {
      dynamic "count" {
        for_each = var.crs_count_mode ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = var.crs_count_mode ? [] : [1]
        content {}
      }
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "KnownBadInputs"
    priority = 5
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "SQLiRuleSet"
    priority = 6
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-app-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name_prefix}-app"
  retention_in_days = 90
}

resource "aws_wafv2_web_acl_logging_configuration" "app" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.app.arn
}

output "web_acl_arn" { value = aws_wafv2_web_acl.app.arn }
