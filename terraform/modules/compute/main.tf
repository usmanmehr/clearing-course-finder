# Lambda functions, per-function IAM, log groups, and the SearchCourses alias.
#
# 2027 improvements: native publish+alias (fixes H4 drift), arm64 (Graviton),
# SQS DLQ + on_failure for async fns, origin secret from Secrets Manager, and
# every function receives the 2027 table-name env vars so it can NEVER fall back
# to a 2026 table name (isolation fix). IAM is scoped per function to only the
# tables it uses.
#
# Packaging: run `python3 scripts/build_lambdas.py` first - it produces
# build/<Fn>.zip (index.mjs + shared bundled). Terraform references those zips.

variable "name_prefix" { type = string }
variable "lambda_architecture" { type = string }
variable "table_names" { type = map(string) } # env-var-name -> table name
variable "table_arns" { type = map(string) }  # logical key -> arn
variable "exports_bucket" { type = string }
variable "metrics_namespace" {
  type    = string
  default = "ClearingAdvisor2027"
}

locals {
  build_dir = "${path.root}/../build"

  # function -> logical table keys it may access (IAM scope).
  functions = {
    SearchCourses   = { memory = 512, async = false, tables = ["universities", "subject_defaults", "scholarships", "clearing_cache", "query_cache", "rate_limits"] }
    GetSubjects     = { memory = 128, async = false, tables = ["subject_defaults"] }
    GetUniversities = { memory = 128, async = false, tables = ["universities"] }
    GetScholarships = { memory = 128, async = false, tables = ["scholarships"] }
    GenerateExport  = { memory = 256, async = false, tables = ["query_cache"] }
    Health          = { memory = 128, async = false, tables = ["universities"] }
    WarmUp          = { memory = 128, async = false, tables = [] }
    DailyScraper    = { memory = 256, async = true, tables = ["universities", "clearing_cache", "changelog"] }
    CostReporter    = { memory = 128, async = true, tables = [] }
    ScheduleManager = { memory = 128, async = true, tables = [] }
  }
  async_functions = { for k, v in local.functions : k => v if v.async }

  # Common env for every function.
  common_env = merge(var.table_names, {
    ENVIRONMENT       = "production"
    EXPORTS_BUCKET    = var.exports_bucket
    METRICS_NAMESPACE = var.metrics_namespace
    LOG_LEVEL         = "INFO"
    # Handlers compare the X-Origin-Verify header to this value (must equal what
    # CloudFront sends). Also expose the ARN for reference.
    API_ORIGIN_SECRET = random_password.origin_secret.result
    ORIGIN_SECRET_ARN = aws_secretsmanager_secret.origin_secret.arn
    ALIAS             = "live"
  })
}

# --- Origin-verify secret (generated, stored in Secrets Manager) ---
resource "random_password" "origin_secret" {
  length  = 32
  special = false
}
resource "aws_secretsmanager_secret" "origin_secret" {
  name = "${var.name_prefix}-origin-verify"
}
resource "aws_secretsmanager_secret_version" "origin_secret" {
  secret_id     = aws_secretsmanager_secret.origin_secret.id
  secret_string = random_password.origin_secret.result
}

# --- DLQ for async functions ---
resource "aws_sqs_queue" "async_dlq" {
  name = "${var.name_prefix}-async-dlq"
}

resource "aws_cloudwatch_log_group" "fn" {
  for_each          = local.functions
  name              = "/aws/lambda/${var.name_prefix}-${each.key}"
  retention_in_days = 30
}

resource "aws_iam_role" "fn" {
  for_each = local.functions
  name     = "${var.name_prefix}-${each.key}-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "fn" {
  for_each = local.functions
  name     = "scoped-access"
  role     = aws_iam_role.fn[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.fn[each.key].arn}:*"
      }],
      length(each.value.tables) > 0 ? [{
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:BatchWriteItem"]
        Resource = flatten([for t in each.value.tables : [var.table_arns[t], "${var.table_arns[t]}/index/*"]])
      }] : [],
      each.value.async ? [{
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.async_dlq.arn
      }] : [],
    )
  })
}

resource "aws_lambda_function" "fn" {
  for_each = local.functions

  function_name    = "${var.name_prefix}-${each.key}"
  role             = aws_iam_role.fn[each.key].arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  architectures    = [var.lambda_architecture]
  memory_size      = each.value.memory
  timeout          = 15
  publish          = true # native versioning - fixes H4
  filename         = "${local.build_dir}/${each.key}.zip"
  source_code_hash = filebase64sha256("${local.build_dir}/${each.key}.zip")

  environment {
    variables = merge(local.common_env, { FUNCTION_NAME = "${var.name_prefix}-${each.key}" })
  }

  dynamic "dead_letter_config" {
    for_each = each.value.async ? [1] : []
    content { target_arn = aws_sqs_queue.async_dlq.arn }
  }
}

resource "aws_lambda_function_event_invoke_config" "async" {
  for_each      = local.async_functions
  function_name = aws_lambda_function.fn[each.key].function_name
  destination_config {
    on_failure { destination = aws_sqs_queue.async_dlq.arn }
  }
}

# SearchCourses live alias - tracks the published version automatically.
resource "aws_lambda_alias" "search_courses_live" {
  name             = "live"
  function_name    = aws_lambda_function.fn["SearchCourses"].function_name
  function_version = aws_lambda_function.fn["SearchCourses"].version
}

output "search_courses_alias_arn" { value = aws_lambda_alias.search_courses_live.arn }
output "lambda_invoke_arns" { value = { for k, f in aws_lambda_function.fn : k => f.invoke_arn } }
output "dailyscraper_arn" { value = aws_lambda_function.fn["DailyScraper"].arn }
output "origin_secret_arn" { value = aws_secretsmanager_secret.origin_secret.arn }
output "origin_secret_value" {
  value     = random_password.origin_secret.result
  sensitive = true
}
