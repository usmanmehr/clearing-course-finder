# Phased scraper schedule using EventBridge Scheduler (supports start/end date
# windows, which classic EventBridge rules do not). Each phase is a separate
# schedule bounded to its window; after the last window ends there is no
# schedule, so no refreshes occur (phase 4) until re-deployed for the next cycle.
#
# Every phase has a retry policy and a dead-letter queue: if a scheduled
# invocation cannot be delivered to the Lambda (throttling, transient error)
# it is retried, then sent to the DLQ so no trigger is silently lost.
#
# Boundaries are aligned to UK local midnight (BST = UTC+1 in August), so the
# UTC instants below are 23:00 the previous day.
#
#  1. now .. 11 Aug (incl)     -> every 30 minutes   (ends 2026-08-11T23:00:00Z = 12 Aug 00:00 BST)
#  2. 12 Aug .. 13 Aug (peak)  -> every 10 minutes    (2026-08-11T23:00:00Z .. 2026-08-13T23:00:00Z)
#  3. 14 Aug .. 31 Aug         -> 4x/day (00,06,12,18) (2026-08-13T23:00:00Z .. 2026-08-31T23:00:00Z)
#  4. 1 Sep onwards            -> no schedule = no refreshes until re-deployed next July

variable "name_prefix" { type = string }
variable "target_lambda_arn" { type = string }
variable "timezone" {
  type    = string
  default = "Europe/London"
}
variable "max_retry_attempts" {
  type    = number
  default = 3
}
variable "max_event_age_seconds" {
  type    = number
  default = 3600
}

# Dead-letter queue for undeliverable scheduled invocations.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-scraper-schedule-dlq"
  message_retention_seconds = 1209600 # 14 days
}

# Role EventBridge Scheduler assumes to invoke the scraper Lambda + write to DLQ.
resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-scraper-scheduler-role"
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
  name = "invoke-scraper"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [var.target_lambda_arn, "${var.target_lambda_arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.dlq.arn]
      },
    ]
  })
}

locals {
  phases = {
    "p1-30min" = { expr = "rate(30 minutes)", start = null, end = "2026-08-11T23:00:00Z" }
    "p2-peak-10min" = { expr = "rate(10 minutes)", start = "2026-08-11T23:00:00Z", end = "2026-08-13T23:00:00Z" }
    "p3-4xday" = { expr = "cron(0 0,6,12,18 * * ? *)", start = "2026-08-13T23:00:00Z", end = "2026-08-31T23:00:00Z" }
  }
}

resource "aws_scheduler_schedule" "scrape" {
  for_each = local.phases

  name  = "${var.name_prefix}-scrape-${each.key}"
  state = "ENABLED"
  flexible_time_window {
    mode = "OFF"
  }
  schedule_expression          = each.value.expr
  schedule_expression_timezone = var.timezone
  start_date                   = each.value.start
  end_date                     = each.value.end

  target {
    arn      = var.target_lambda_arn
    role_arn = aws_iam_role.scheduler.arn

    retry_policy {
      maximum_retry_attempts       = var.max_retry_attempts
      maximum_event_age_in_seconds = var.max_event_age_seconds
    }
    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }
}

output "schedule_names" {
  value = [for s in aws_scheduler_schedule.scrape : s.name]
}

output "dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}
