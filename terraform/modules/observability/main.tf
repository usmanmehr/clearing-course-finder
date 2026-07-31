# Observability: SNS alerts, CloudWatch alarms, log metric filters, dashboards.
# STUB - full scope. TODO(2027): port alarms/filters/dashboards from
# ../../../reference/2026-cloudformation/observability.yaml.
#
# 2027 improvements baked in:
#  - SNS topic encrypted with KMS (2026 L11: topic was unencrypted).
#  - AWS Budgets alarm wired to the alerts topic (Section 6 item 5: none existed).
#  - MetricFilter transformations must NOT set both Dimensions and DefaultValue
#    together (guide Section 5 CFN trap) - watch for the equivalent here.

variable "name_prefix" { type = string }
variable "admin_email" { type = string }

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

# Budgets alarm (Section 6 item 5).
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = "50" # TODO(2027): set a real threshold
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }
}

# TODO(2027): aws_cloudwatch_metric_alarm x N, aws_cloudwatch_log_metric_filter
# x N, aws_cloudwatch_dashboard - transcribe from observability.yaml.

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
