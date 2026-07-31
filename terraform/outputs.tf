output "site_url" {
  description = "Public site URL (CloudFront)."
  value       = "https://${module.cdn.distribution_domain_name}"
}

output "site_custom_url" {
  description = "Custom-domain site URL, when configured."
  value       = var.custom_domain != null ? "https://${var.custom_domain}" : null
}

output "api_path" {
  description = "Same-origin API base (through CloudFront)."
  value       = "https://${module.cdn.distribution_domain_name}/api"
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution id - pass to kill.sh --distribution-id."
  value       = module.cdn.distribution_id
}

output "canary_public_ip" {
  description = "Canary EIP (allowlisted in the WAF)."
  value       = var.enable_canary ? aws_eip.canary[0].public_ip : null
}

output "canary_alerts_topic_arn" {
  value = var.enable_canary ? module.canary[0].alerts_topic_arn : null
}

output "kill_switch_active" {
  description = "True when the WAF default action is BLOCK (site dark)."
  value       = var.kill_switch
}

output "dashboard_url" {
  description = "CloudWatch dashboard console URL."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${module.dashboard.dashboard_name}"
}

output "grafana_url" {
  value = var.enable_full ? try(module.grafana_front[0].url, null) : null
}
