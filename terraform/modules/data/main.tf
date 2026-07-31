# DynamoDB tables. Key schemas transcribed from
# reference/2026-cloudformation/data.yaml (verified, not guessed).
#
# Persistent (reference/audit): PITR + deletion protection (gated by kill_switch).
# Cache/ephemeral: TTL, no PITR, no deletion protection.

variable "name_prefix" { type = string }
variable "protect_data" {
  description = "Enable DynamoDB deletion protection on persistent tables. Default false so a plain `terraform destroy` removes everything A-Z (this is a disposable test stack). Set true for a real production deploy."
  type        = bool
  default     = false
}

locals {
  protect = var.protect_data
}

# ---- Persistent ----

resource "aws_dynamodb_table" "universities" { # CONTACTS_TABLE
  name         = "${var.name_prefix}-universities"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "providerCode"
  attribute {
    name = "providerCode"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
  deletion_protection_enabled = local.protect
}

resource "aws_dynamodb_table" "subject_defaults" { # SUBJECT_DEFAULTS_TABLE
  name         = "${var.name_prefix}-subject-defaults"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "subjectGroup"
  attribute {
    name = "subjectGroup"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
  deletion_protection_enabled = local.protect
}

resource "aws_dynamodb_table" "scholarships" { # SCHOLARSHIPS_TABLE
  name         = "${var.name_prefix}-scholarships"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "universityId"
  range_key    = "scholarshipId"
  attribute {
    name = "universityId"
    type = "S"
  }
  attribute {
    name = "scholarshipId"
    type = "S"
  }
  attribute {
    name = "subjectGroup"
    type = "S"
  }
  global_secondary_index {
    name            = "subjectGroup-index"
    hash_key        = "subjectGroup"
    projection_type = "ALL"
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
  deletion_protection_enabled = local.protect
}

resource "aws_dynamodb_table" "changelog" { # CHANGELOG_TABLE (audit)
  name         = "${var.name_prefix}-changelog"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "changeDate"
  range_key    = "changeTimestamp"
  attribute {
    name = "changeDate"
    type = "S"
  }
  attribute {
    name = "changeTimestamp"
    type = "S"
  }
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
  deletion_protection_enabled = local.protect
}

# ---- Cache / ephemeral ----

resource "aws_dynamodb_table" "rate_limits" { # RATE_LIMITS_TABLE
  name         = "${var.name_prefix}-rate-limits"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "limitKey"
  range_key    = "windowStart"
  attribute {
    name = "limitKey"
    type = "S"
  }
  attribute {
    name = "windowStart"
    type = "S"
  }
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "clearing_cache" { # CLEARING_CACHE_TABLE
  name         = "${var.name_prefix}-clearing-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "cacheKey"
  range_key    = "provider"
  attribute {
    name = "cacheKey"
    type = "S"
  }
  attribute {
    name = "provider"
    type = "S"
  }
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }
  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "query_cache" { # QUERY_CACHE_TABLE
  name         = "${var.name_prefix}-query-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "queryId"
  attribute {
    name = "queryId"
    type = "S"
  }
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
  server_side_encryption {
    enabled = true
  }
}

output "table_names" {
  value = {
    CONTACTS_TABLE         = aws_dynamodb_table.universities.name
    SUBJECT_DEFAULTS_TABLE = aws_dynamodb_table.subject_defaults.name
    SCHOLARSHIPS_TABLE     = aws_dynamodb_table.scholarships.name
    CHANGELOG_TABLE        = aws_dynamodb_table.changelog.name
    RATE_LIMITS_TABLE      = aws_dynamodb_table.rate_limits.name
    CLEARING_CACHE_TABLE   = aws_dynamodb_table.clearing_cache.name
    QUERY_CACHE_TABLE      = aws_dynamodb_table.query_cache.name
  }
}

output "table_arns" {
  value = {
    universities     = aws_dynamodb_table.universities.arn
    subject_defaults = aws_dynamodb_table.subject_defaults.arn
    scholarships     = aws_dynamodb_table.scholarships.arn
    changelog        = aws_dynamodb_table.changelog.arn
    rate_limits      = aws_dynamodb_table.rate_limits.arn
    clearing_cache   = aws_dynamodb_table.clearing_cache.arn
    query_cache      = aws_dynamodb_table.query_cache.arn
  }
}
