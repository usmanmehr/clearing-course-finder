# CloudFront + S3 (site + exports) + OAC + security headers.
#
# 2027 posture vs 2026:
#  - Both buckets get an explicit Deny for aws:SecureTransport=false (2026 M5).
#  - Exports bucket uses SSE-KMS, not SSE-S3 (2026 M5); holds user-derived data.
#  - Strong response-headers policy (CSP/HSTS/frame-deny) kept from 2026 (a
#    genuine strength) and applied via Terraform.
#  - GB-only geo-restriction retained.
#  - API served as a second origin behind OAC so the site and API share one
#    origin - the path toward retiring the shared origin secret (item A).
#
# TODO(2027): transcribe cache behaviours, the exact CSP string, and the
# exports lifecycle from ../../../reference/2026-cloudformation/cdn.yaml.

variable "name_prefix" { type = string }
variable "api_endpoint" { type = string }
variable "web_acl_arn" { type = string }
variable "origin_secret" {
  description = "Shared X-Origin-Verify secret CloudFront sends to the API origin. TODO(2027): retire in favour of OAC/private origin (IMPROVEMENTS item A)."
  type        = string
  sensitive   = true
}
variable "custom_domain" {
  description = "Optional custom domain (e.g. clearing.example.com). Null = CloudFront default domain only."
  type        = string
  default     = null
}
variable "hosted_zone_id" {
  description = "Route53 hosted zone id for the custom domain (required when custom_domain is set)."
  type        = string
  default     = null
}

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

locals {
  has_domain = var.custom_domain != null
}

data "aws_caller_identity" "current" {}

locals {
  site_bucket    = "${var.name_prefix}-site-${data.aws_caller_identity.current.account_id}"
  exports_bucket = "${var.name_prefix}-exports-${data.aws_caller_identity.current.account_id}"
}

# --- Site bucket (private; served via OAC) ---
resource "aws_s3_bucket" "site" {
  bucket = local.site_bucket
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Exports bucket (user query exports) ---
resource "aws_kms_key" "exports" {
  description         = "${var.name_prefix} exports encryption"
  enable_key_rotation = true
}

resource "aws_s3_bucket" "exports" {
  bucket = local.exports_bucket
}

resource "aws_s3_bucket_server_side_encryption_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.exports.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "exports" {
  bucket                  = aws_s3_bucket.exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id
  rule {
    id     = "expire-exports"
    status = "Enabled"
    filter {}
    expiration {
      days = 1 # S3 granularity is whole days; presigned URL enforces the real short TTL
    }
  }
}

# --- Bucket policies: OAC read (site) + TLS-deny (both) (2026 M5) ---
data "aws_iam_policy_document" "site" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "exports" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.exports.arn, "${aws_s3_bucket.exports.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json
}

resource "aws_s3_bucket_policy" "exports" {
  bucket = aws_s3_bucket.exports.id
  policy = data.aws_iam_policy_document.exports.json
}

# --- Origin Access Control ---
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name_prefix}-site-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# --- Security headers (strong CSP retained from 2026) ---
resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${var.name_prefix}-security-headers"

  security_headers_config {
    content_security_policy {
      override                = true
      content_security_policy = "default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
      # TODO(2027): copy the exact CSP from cdn.yaml if it differs.
    }
    strict_transport_security {
      override                   = true
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
    }
    frame_options {
      override     = true
      frame_option = "DENY"
    }
    content_type_options {
      override = true
    }
  }
}

# --- Distribution ---
# TODO(2027): fully specify default_cache_behavior + the /api behaviour, the
# GB geo-restriction, ACM cert, and aliases from cdn.yaml. Skeleton below.
resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  default_root_object = "index.html"
  web_acl_id          = var.web_acl_arn

  origin {
    origin_id                = "site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  origin {
    origin_id   = "api"
    domain_name = replace(replace(var.api_endpoint, "https://", ""), "/", "")
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_secret
    }
  }

  default_cache_behavior {
    target_origin_id           = "site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
    # TODO(2027): cache_policy_id / origin_request_policy_id.
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  # API path - forward to the HTTP API origin, uncached.
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "api"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
    forwarded_values {
      query_string = true
      headers      = ["Content-Type"]
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["GB"]
    }
  }

  aliases = local.has_domain ? [var.custom_domain] : null

  viewer_certificate {
    cloudfront_default_certificate = local.has_domain ? null : true
    acm_certificate_arn            = local.has_domain ? aws_acm_certificate_validation.cdn[0].certificate_arn : null
    ssl_support_method             = local.has_domain ? "sni-only" : null
    minimum_protocol_version       = local.has_domain ? "TLSv1.2_2021" : null
  }
}

# --- Custom domain: ACM cert (us-east-1, required for CloudFront) + DNS validation + alias ---
resource "aws_acm_certificate" "cdn" {
  count             = local.has_domain ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = var.custom_domain
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.has_domain ? {
    for dvo in aws_acm_certificate.cdn[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}
  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cdn" {
  count                   = local.has_domain ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cdn[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# Alias A record -> the CloudFront distribution (additive; does not touch clearing.example.com).
resource "aws_route53_record" "alias" {
  count   = local.has_domain ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.custom_domain
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "distribution_id" {
  value = aws_cloudfront_distribution.this.id
}
