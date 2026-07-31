# Grafana front-door: WAF + CloudFront (CLOUDFRONT scope - us-east-1).
# STUB - full scope. TODO(2027): port from ../../../reference/2026-cloudformation/grafana-front.yaml.
#
# 2027 improvement (H2): the CloudFront-to-origin hop is HTTPS, not plaintext
# HTTP. Set origin_protocol_policy = "https-only" against port 443 once the
# Grafana instance serves a valid (Let's Encrypt) cert. This is the single most
# important carried-over security fix - do not ship this module http-only.

variable "name_prefix" { type = string }
variable "grafana_origin" { type = string }
variable "allowed_cidr" { type = string }

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

# TODO(2027): aws_wafv2_web_acl (GB OR admin CIDR), aws_cloudfront_distribution
# with:
#
#   custom_origin_config {
#     origin_protocol_policy = "https-only"   # H2 fix - NOT http-only
#     https_port             = 443
#     origin_ssl_protocols   = ["TLSv1.2"]
#   }
#
# plus the X-Origin-Verify secret header and the GB/admin-CIDR WAF.

output "url" {
  value = null # TODO(2027): "https://${aws_cloudfront_distribution.grafana.domain_name}"
}
