# Results-Day provisioned-concurrency scale up/down.
# STUB - full scope. TODO(2027): port from ../../../reference/2026-cloudformation/scaling.yaml.
#
# 2027 improvement: the scaling role's apigateway permission is scoped to THIS
# API id, not account-wide (2026 review M7 granted /apis/*/stages/*).

variable "name_prefix" { type = string }
variable "api_id" { type = string }

data "aws_region" "current" {}

resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-schedule-manager-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "apigw-scoped"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["apigateway:PATCH", "apigateway:GET"]
      # Scoped to this API only (was /apis/*/stages/* in 2026).
      Resource = "arn:aws:apigateway:${data.aws_region.current.name}::/apis/${var.api_id}/stages/*"
    }]
  })
}

# TODO(2027): EventBridge schedules + provisioned-concurrency config +
# ScheduleManager wiring from scaling.yaml.
