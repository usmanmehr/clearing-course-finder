# HTTP API, routes, integrations, throttling, access logs.
#
# Design: the SPA calls /api/* same-origin via CloudFront (cdn forwards to this
# API as an origin), so no browser cross-origin call is made and CORS is not
# required. Leaving CORS off also breaks the api<->cdn dependency cycle that the
# 2026 deploy.sh worked around by deploying the API twice.
#
# TODO(2027): confirm route set + throttle values against
# reference/2026-cloudformation/api.yaml.

variable "name_prefix" { type = string }
variable "search_courses_alias_arn" { type = string }
variable "lambda_invoke_arns" { type = map(string) }
variable "allow_origin" {
  description = "Optional CORS origin. Null = no CORS (same-origin via CloudFront)."
  type        = string
  default     = null
}

locals {
  # route key -> function logical name. Paths include the /api prefix because
  # CloudFront forwards the full /api/* path to this origin (no rewrite).
  routes = {
    "POST /api/search"      = "SearchCourses"
    "GET /api/subjects"     = "GetSubjects"
    "GET /api/universities" = "GetUniversities"
    "GET /api/scholarships" = "GetScholarships"
    "GET /api/export"       = "GenerateExport"
    "GET /api/health"       = "Health"
  }
  # SearchCourses is integrated via its alias ARN (provisioned-concurrency target).
  integration_arns = merge(
    var.lambda_invoke_arns,
    { SearchCourses = var.search_courses_alias_arn }
  )
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"

  dynamic "cors_configuration" {
    for_each = var.allow_origin == null ? [] : [1]
    content {
      allow_origins = ["https://${var.allow_origin}"]
      allow_methods = ["GET", "POST", "OPTIONS"]
      allow_headers = ["content-type", "x-origin-verify"]
      max_age       = 300
    }
  }
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name_prefix}-api"
  retention_in_days = 90
}

resource "aws_apigatewayv2_integration" "fn" {
  for_each               = local.routes
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = local.integration_arns[each.value]
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "fn" {
  for_each  = local.routes
  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.fn[each.key].id}"
}

# Allow API Gateway to invoke each integrated function/alias.
resource "aws_lambda_permission" "apigw" {
  for_each = local.routes

  statement_id = "AllowInvokeFrom-${replace(replace(each.key, " ", "-"), "/", "")}"
  action       = "lambda:InvokeFunction"
  principal    = "apigateway.amazonaws.com"
  # For SearchCourses attach to the "live" alias via qualifier (the provider
  # stores function_name + qualifier separately; passing "name:live" inline
  # causes a perpetual diff).
  function_name = "${var.name_prefix}-${each.value}"
  qualifier     = each.value == "SearchCourses" ? "live" : null
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"

  # Integrations reference the real function/alias ARNs, so depending on them
  # guarantees the functions + live alias exist before we attach permissions
  # (function_name above is a plain string with no implicit dependency edge).
  depends_on = [aws_apigatewayv2_integration.fn]
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 200
    throttling_rate_limit  = 100
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      route     = "$context.routeKey"
      status    = "$context.status"
    })
  }
}

output "api_id" { value = aws_apigatewayv2_api.this.id }
output "api_endpoint" { value = aws_apigatewayv2_api.this.api_endpoint }
