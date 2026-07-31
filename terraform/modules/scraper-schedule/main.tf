# Phased scraper schedule using EventBridge Scheduler (supports start/end date
# windows, which classic EventBridge rules do not). Each phase is a separate
# schedule bounded to its window; after the last window ends there is no
# schedule, so no refreshes occur (phase 4) until re-deployed for the next cycle.
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

# Role EventBridge Scheduler assumes to invoke the scraper Lambda.
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
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [var.target_lambda_arn, "${var.target_lambda_arn}:*"]
    }]
  })
}

# Phase 1: now .. 11 Aug -> every 30 minutes.
resource "aws_scheduler_schedule" "phase1_30min" {
  name  = "${var.name_prefix}-scrape-p1-30min"
  state = "ENABLED"
  flexible_time_window {
    mode = "OFF"
  }
  schedule_expression          = "rate(30 minutes)"
  schedule_expression_timezone = var.timezone
  end_date                     = "2026-08-11T23:00:00Z"
  target {
    arn      = var.target_lambda_arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

# Phase 2: 12 Aug .. 13 Aug (peak) -> every 10 minutes.
resource "aws_scheduler_schedule" "phase2_10min" {
  name  = "${var.name_prefix}-scrape-p2-peak-10min"
  state = "ENABLED"
  flexible_time_window {
    mode = "OFF"
  }
  schedule_expression          = "rate(10 minutes)"
  schedule_expression_timezone = var.timezone
  start_date                   = "2026-08-11T23:00:00Z"
  end_date                     = "2026-08-13T23:00:00Z"
  target {
    arn      = var.target_lambda_arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

# Phase 3: 14 Aug .. 31 Aug -> 4x/day (00, 06, 12, 18 UK time).
resource "aws_scheduler_schedule" "phase3_4xday" {
  name  = "${var.name_prefix}-scrape-p3-4xday"
  state = "ENABLED"
  flexible_time_window {
    mode = "OFF"
  }
  schedule_expression          = "cron(0 0,6,12,18 * * ? *)"
  schedule_expression_timezone = var.timezone
  start_date                   = "2026-08-13T23:00:00Z"
  end_date                     = "2026-08-31T23:00:00Z"
  target {
    arn      = var.target_lambda_arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

output "schedule_names" {
  value = [
    aws_scheduler_schedule.phase1_30min.name,
    aws_scheduler_schedule.phase2_10min.name,
    aws_scheduler_schedule.phase3_4xday.name,
  ]
}
