# Root wiring. Terraform's dependency graph enforces ordering; no deploy.sh.
#
# Dependency flow (no cycles):
#   aws_eip.canary (eu-west-2)  ->  waf.canary_allow_ip
#   data -> compute -> api -> cdn ;  waf -> cdn
#   cdn -> canary (site/api URL) ;  compute.origin_secret -> cdn (origin header)
# The api<->cdn cycle is avoided by NOT feeding the CloudFront domain back into
# API CORS (the SPA is same-origin via CloudFront).

data "aws_caller_identity" "current" {}

locals {
  full_count   = var.enable_full ? 1 : 0
  canary_count = var.enable_canary ? 1 : 0

  # Deterministic exports bucket name, shared by compute (env) and cdn (creates it).
  exports_bucket_name = "${var.name_prefix}-exports-${data.aws_caller_identity.current.account_id}"
  metrics_namespace   = "ClearingAdvisor2027"
}

# ---------------- Core (eu-west-1) ----------------

module "data" {
  source       = "./modules/data"
  name_prefix  = var.name_prefix
  protect_data = var.protect_data
}

module "compute" {
  source              = "./modules/compute"
  name_prefix         = var.name_prefix
  lambda_architecture = var.lambda_architecture
  table_names         = module.data.table_names
  table_arns          = module.data.table_arns
  exports_bucket      = local.exports_bucket_name
  metrics_namespace   = local.metrics_namespace
}

module "api" {
  source                   = "./modules/api"
  name_prefix              = var.name_prefix
  search_courses_alias_arn = module.compute.search_courses_alias_arn
  lambda_invoke_arns       = module.compute.lambda_invoke_arns
  # allow_origin omitted - same-origin via CloudFront (breaks api<->cdn cycle).
}

# Canary EIP allocated at root (eu-west-2) so the WAF can allowlist it without
# creating a cycle through the canary module.
resource "aws_eip" "canary" {
  count    = local.canary_count
  provider = aws.eu_west_2
  domain   = "vpc"
  tags     = { Name = "${var.name_prefix}-canary-eip" }
}

module "waf" {
  source = "./modules/waf"
  providers = {
    aws = aws.us_east_1
  }
  name_prefix     = var.name_prefix
  crs_count_mode  = var.waf_crs_count_mode
  kill_switch     = var.kill_switch
  canary_enabled  = var.enable_canary
  canary_allow_ip = var.enable_canary ? aws_eip.canary[0].public_ip : null
}

module "cdn" {
  source = "./modules/cdn"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  name_prefix    = var.name_prefix
  api_endpoint   = module.api.api_endpoint
  web_acl_arn    = module.waf.web_acl_arn
  origin_secret  = module.compute.origin_secret_value
  custom_domain  = var.custom_domain
  hosted_zone_id = var.custom_domain != null ? data.aws_route53_zone.main[0].zone_id : null
}

data "aws_route53_zone" "main" {
  count        = var.custom_domain != null ? 1 : 0
  name         = var.dns_zone_name
  private_zone = false
}

# Overview CloudWatch dashboard (core - always deployed, 2027-named).
module "dashboard" {
  source            = "./modules/dashboard"
  name_prefix       = var.name_prefix
  region            = var.aws_region
  canary_region     = var.canary_region
  api_id            = module.api.api_id
  metrics_namespace = "${local.metrics_namespace}/Canary"
}

module "canary" {
  source = "./modules/canary"
  count  = local.canary_count
  providers = {
    aws = aws.eu_west_2
  }
  name_prefix        = var.name_prefix
  instance_type      = var.canary_instance_type
  eip_public_ip      = aws_eip.canary[0].public_ip
  eip_allocation_id  = aws_eip.canary[0].id
  site_url           = "https://${module.cdn.distribution_domain_name}"
  api_url            = "https://${module.cdn.distribution_domain_name}/api"
  metrics_namespace  = "${local.metrics_namespace}/Canary"
  canary_region_hint = var.canary_region
  admin_email        = var.admin_email
}

# ---------------- Full (enable_full = true) ----------------

module "observability" {
  source      = "./modules/observability"
  count       = local.full_count
  name_prefix = var.name_prefix
  admin_email = var.admin_email
}

module "scaling" {
  source      = "./modules/scaling"
  count       = local.full_count
  name_prefix = var.name_prefix
  api_id      = module.api.api_id
}

module "grafana" {
  source       = "./modules/grafana"
  count        = local.full_count
  name_prefix  = var.name_prefix
  vpc_id       = var.grafana_vpc_id
  subnet_id    = var.grafana_subnet_id
  allowed_cidr = var.grafana_allowed_cidr
}

module "grafana_front" {
  source = "./modules/grafana-front"
  count  = local.full_count
  providers = {
    aws = aws.us_east_1
  }
  name_prefix    = var.name_prefix
  grafana_origin = try(module.grafana[0].instance_public_dns, null)
  allowed_cidr   = var.grafana_allowed_cidr
}

module "patching" {
  source              = "./modules/patching"
  count               = local.full_count
  name_prefix         = var.name_prefix
  grafana_instance_id = try(module.grafana[0].instance_id, null)
}
