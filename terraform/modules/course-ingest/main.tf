# Course-ingest Lambda + schedule.
#
# A Python 3.12 Lambda that re-runs the SAME verified parsers in
# scripts/ingest_live_courses.py (handler = ingest_live_courses.handler) on a
# schedule through Clearing, so the parseable universities' live course lists -
# and Lincoln/Loughborough per-course open/closed status - stay fresh and their
# liveCoursesFetchedAt timestamp keeps updating while students use the site.
#
# The handler carries a SAFETY FLOOR: if a fetch/parse returns 0 or a collapsed
# count (markup changed / site blocked the Lambda), it SKIPS the write and keeps
# the last good data, emitting a CourseIngestSkipped metric instead. So a broken
# parser can never wipe live course data on an unattended schedule.
#
# Packaging: `python3 scripts/build_lambdas.py` writes build/CourseIngest.zip.

variable "name_prefix" { type = string }
variable "lambda_architecture" { type = string }
variable "contacts_table_name" { type = string }
variable "contacts_table_arn" { type = string }
variable "metrics_namespace" { type = string }
variable "kill_switch" {
  type    = bool
  default = false
}
variable "timezone" {
  type    = string
  default = "Europe/London"
}
variable "schedule_expression" {
  type    = string
  default = "rate(2 hours)"
}
variable "schedule_end" {
  # After Clearing there is nothing to refresh; the schedule stops here until
  # re-deployed for the next cycle.
  type    = string
  default = "2026-08-31T23:00:00Z"
}

locals {
  build_dir = "${path.root}/../build"
  fn_name   = "${var.name_prefix}-CourseIngest"
}

resource "aws_cloudwatch_log_group" "ci" {
  name              = "/aws/lambda/${local.fn_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "ci" {
  name = "${var.name_prefix}-course-ingest-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "ci" {
  name = "scoped-access"
  role = aws_iam_role.ci.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.ci.arn}:*"
      },
      {
        # Read the current count (safety floor) + write refreshed liveCourses.
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = var.contacts_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "ci" {
  function_name    = local.fn_name
  role             = aws_iam_role.ci.arn
  runtime          = "python3.12"
  handler          = "ingest_live_courses.handler"
  architectures    = [var.lambda_architecture]
  memory_size      = 256
  timeout          = 180 # fetch + parse up to 8 external sites (concurrent)
  publish          = true
  filename         = "${local.build_dir}/CourseIngest.zip"
  source_code_hash = filebase64sha256("${local.build_dir}/CourseIngest.zip")

  environment {
    variables = {
      CONTACTS_TABLE    = var.contacts_table_name
      METRICS_NAMESPACE = var.metrics_namespace
    }
  }
}

# --- Schedule (EventBridge Scheduler) with retry + DLQ, kill-switch aware ---
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-course-ingest-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-course-ingest-scheduler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke-course-ingest"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.ci.arn, "${aws_lambda_function.ci.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.dlq.arn]
      },
    ]
  })
}

resource "aws_scheduler_schedule" "ci" {
  name  = "${var.name_prefix}-course-ingest"
  state = var.kill_switch ? "DISABLED" : "ENABLED"
  flexible_time_window {
    mode = "OFF"
  }
  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.timezone
  end_date                     = var.schedule_end

  target {
    arn      = aws_lambda_function.ci.arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 3600
    }
    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }
}

output "function_name" { value = aws_lambda_function.ci.function_name }
output "function_arn" { value = aws_lambda_function.ci.arn }
output "schedule_name" { value = aws_scheduler_schedule.ci.name }
output "dlq_arn" { value = aws_sqs_queue.dlq.arn }
