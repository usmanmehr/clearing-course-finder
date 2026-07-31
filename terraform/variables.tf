variable "aws_region" {
  description = "Primary region for application + data resources."
  type        = string
  default     = "eu-west-1"
}

variable "canary_region" {
  description = "Region for the end-to-end canary EC2 instance."
  type        = string
  default     = "eu-west-2"
}

variable "name_prefix" {
  description = "Prefix for all resource names. Distinct from 2026 so both stacks can coexist."
  type        = string
  default     = "uk-clearing-advisor-2027"
}

variable "enable_full" {
  description = "Deploy the full scope (observability, scaling, grafana, grafana-front, patching) in addition to core."
  type        = bool
  default     = false
}

variable "enable_canary" {
  description = "Deploy the t3.micro end-to-end canary in canary_region."
  type        = bool
  default     = true
}

variable "canary_instance_type" {
  description = "Instance type for the canary."
  type        = string
  default     = "t3.micro"
}

variable "lambda_architecture" {
  description = "Lambda CPU architecture. arm64 (Graviton) preferred - no native deps."
  type        = string
  default     = "arm64"
}

variable "waf_crs_count_mode" {
  description = "Run the WAF Core Rule Set in Count mode instead of Block. Default false = Block."
  type        = bool
  default     = false
}

variable "kill_switch" {
  description = "Master kill switch. When true, the WAF WebACL default action becomes BLOCK (site goes dark, infra retained). Instant runtime kill without teardown is also available via kill.sh (disables the CloudFront distribution)."
  type        = bool
  default     = false
}

variable "protect_data" {
  description = "Enable DynamoDB deletion protection on persistent tables. Default false so `terraform destroy` removes everything A-Z (disposable test stack). Set true for a production deploy."
  type        = bool
  default     = false
}

variable "custom_domain" {
  description = "Optional custom domain to serve the site on (e.g. clearing.example.com). Null = CloudFront default URL only. Additive - does not touch other records in the zone."
  type        = string
  default     = null
}

variable "dns_zone_name" {
  description = "Route53 public hosted zone name for custom_domain (e.g. example.com). Required when custom_domain is set."
  type        = string
  default     = null
}

# --- Full-scope inputs (required only when enable_full = true) ---

variable "admin_email" {
  description = "Destination for CloudWatch alarm + canary alert emails."
  type        = string
  default     = null
}

variable "grafana_vpc_id" {
  type    = string
  default = null
}

variable "grafana_subnet_id" {
  type    = string
  default = null
}

variable "grafana_allowed_cidr" {
  type    = string
  default = null

  validation {
    condition     = var.grafana_allowed_cidr == null || var.grafana_allowed_cidr != "0.0.0.0/0"
    error_message = "grafana_allowed_cidr must not be 0.0.0.0/0."
  }
}

# Origin-verify secret is generated (random_password) and stored in Secrets
# Manager by the compute module - never a variable with a default.
