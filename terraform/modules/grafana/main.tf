# Grafana EC2, EIP, SG, Cognito, instance role.
# STUB - full scope. TODO(2027): port from ../../../reference/2026-cloudformation/grafana.yaml.
#
# 2027 improvements baked in:
#  - Graviton instance type t4g.small (2026 was t3.small; item 7).
#  - Security group egress restricted to 443 (2026 M8 was 0.0.0.0/0 all-proto).
#  - Prepare for HTTPS origin: SG accepts 443 from the CloudFront prefix list so
#    grafana-front can use https-only (H2 fix). TLS via Let's Encrypt DNS-01 in
#    UserData (guide Section 6 item 3).
#  - Consider a private subnet if H2's https path removes the need for the EIP
#    (2026 M9) - decide in 2027.

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "allowed_cidr" { type = string }

variable "instance_type" {
  type    = string
  default = "t4g.small" # Graviton
}

resource "aws_security_group" "grafana" {
  name   = "${var.name_prefix}-grafana-sg"
  vpc_id = var.vpc_id

  # Ingress: 443 from CloudFront prefix list + admin fallback CIDR.
  # TODO(2027): add ingress rules with the CloudFront managed prefix list id
  # and var.allowed_cidr (443). 2026 accepted only port 80 from CloudFront.

  egress {
    description = "HTTPS out only (package repos, Cognito, AWS APIs)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# TODO(2027): aws_instance (arm64 AMI for t4g), aws_eip, Cognito user pool
# (AllowAdminCreateUserOnly), instance role, and UserData that provisions
# Grafana + a Let's Encrypt cert. Reuse the Secrets Manager admin password
# pattern (ClearingAdvisor-GrafanaAdmin).

output "instance_id" {
  value = null # TODO(2027): aws_instance.grafana.id
}

output "instance_public_dns" {
  value = null # TODO(2027): aws_instance.grafana.public_dns
}
