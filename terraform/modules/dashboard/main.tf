# Single overview CloudWatch dashboard for the 2027 stack. Cross-region widgets:
# canary metrics (eu-west-2), Lambda + API Gateway (eu-west-1), WAF (us-east-1).
# Named with the 2027 prefix so it is clearly identifiable in the console.

variable "name_prefix" { type = string }
variable "region" { type = string }        # primary (Lambda/API)
variable "canary_region" { type = string } # canary metrics
variable "api_id" { type = string }
variable "metrics_namespace" {
  type    = string
  default = "ClearingAdvisor2027/Canary"
}

locals {
  functions = [
    "SearchCourses", "GetSubjects", "GetUniversities", "GetScholarships",
    "GenerateExport", "Health", "WarmUp", "DailyScraper", "CostReporter",
    "ScheduleManager",
  ]
  waf_acl = "${var.name_prefix}-app-waf"

  lambda_errors    = [for f in local.functions : ["AWS/Lambda", "Errors", "FunctionName", "${var.name_prefix}-${f}"]]
  lambda_duration  = [for f in local.functions : ["AWS/Lambda", "Duration", "FunctionName", "${var.name_prefix}-${f}"]]
  lambda_throttles = [for f in local.functions : ["AWS/Lambda", "Throttles", "FunctionName", "${var.name_prefix}-${f}"]]
}

resource "aws_cloudwatch_dashboard" "overview" {
  dashboard_name = "${var.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 1,
        properties = { markdown = "# ${var.name_prefix} - overview  |  site + API (eu-west-1), canary (eu-west-2), WAF (us-east-1)" }
      },
      # --- Canary ---
      {
        type = "metric", x = 0, y = 1, width = 12, height = 6,
        properties = {
          title   = "Canary - HTTP errors (per run)"
          region  = var.canary_region
          view    = "timeSeries", stat = "Sum", period = 60
          metrics = [["${var.metrics_namespace}", "HttpErrors"]]
        }
      },
      {
        type = "metric", x = 12, y = 1, width = 12, height = 6,
        properties = {
          title   = "Canary - max latency (ms)"
          region  = var.canary_region
          view    = "timeSeries", stat = "Maximum", period = 60
          metrics = [["${var.metrics_namespace}", "MaxLatency"]]
        }
      },
      # --- API Gateway ---
      {
        type = "metric", x = 0, y = 7, width = 12, height = 6,
        properties = {
          title  = "API Gateway - 4xx / 5xx / count"
          region = var.region
          view   = "timeSeries", stat = "Sum", period = 60
          metrics = [
            ["AWS/ApiGateway", "4xx", "ApiId", var.api_id],
            ["AWS/ApiGateway", "5xx", "ApiId", var.api_id],
            ["AWS/ApiGateway", "Count", "ApiId", var.api_id],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 7, width = 12, height = 6,
        properties = {
          title   = "API Gateway - latency (ms)"
          region  = var.region
          view    = "timeSeries", stat = "Average", period = 60
          metrics = [["AWS/ApiGateway", "Latency", "ApiId", var.api_id]]
        }
      },
      # --- Lambda ---
      {
        type = "metric", x = 0, y = 13, width = 8, height = 6,
        properties = {
          title   = "Lambda - errors"
          region  = var.region
          view    = "timeSeries", stat = "Sum", period = 60
          metrics = local.lambda_errors
        }
      },
      {
        type = "metric", x = 8, y = 13, width = 8, height = 6,
        properties = {
          title   = "Lambda - duration (avg ms)"
          region  = var.region
          view    = "timeSeries", stat = "Average", period = 60
          metrics = local.lambda_duration
        }
      },
      {
        type = "metric", x = 16, y = 13, width = 8, height = 6,
        properties = {
          title   = "Lambda - throttles"
          region  = var.region
          view    = "timeSeries", stat = "Sum", period = 60
          metrics = local.lambda_throttles
        }
      },
      # --- WAF (CloudFront scope - metrics in us-east-1) ---
      {
        type = "metric", x = 0, y = 19, width = 24, height = 6,
        properties = {
          title  = "WAF - allowed vs blocked (CloudFront)"
          region = "us-east-1"
          view   = "timeSeries", stat = "Sum", period = 60
          metrics = [
            ["AWS/WAFV2", "AllowedRequests", "WebACL", local.waf_acl, "Rule", "ALL", "Region", "CloudFront"],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", local.waf_acl, "Rule", "ALL", "Region", "CloudFront"],
          ]
        }
      },
    ]
  })
}

output "dashboard_name" { value = aws_cloudwatch_dashboard.overview.dashboard_name }
