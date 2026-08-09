# End-to-end canary: a t3.micro in eu-west-2 that hits the live CloudFront URL
# every 5 minutes and alarms on 403/429/5xx. Its EIP is allowlisted in the app WAF
# (see root main.tf -> waf.canary_allow_ip) so it bypasses the GB geo-block and
# sees REAL errors, not geo-403s.
#
# The instance is admin-managed via SSM (no inbound SSH). The e2e script is
# authored in ../../../canary/e2e_check.py and installed by user-data on a
# systemd timer.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

variable "name_prefix" { type = string }
variable "instance_type" { type = string }
variable "eip_public_ip" { type = string }
variable "eip_allocation_id" { type = string }
variable "site_url" { type = string }
variable "api_url" { type = string }
variable "metrics_namespace" {
  type    = string
  default = "ClearingAdvisor2027/Canary"
}
variable "admin_email" {
  type    = string
  default = null
}

data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- IAM: SSM managed + CloudWatch metrics/logs ---
resource "aws_iam_role" "canary" {
  name = "${var.name_prefix}-canary-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.canary.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "canary_metrics" {
  name = "canary-metrics"
  role = aws_iam_role.canary.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["cloudwatch:PutMetricData"]
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = var.metrics_namespace } }
    }]
  })
}

resource "aws_iam_instance_profile" "canary" {
  name = "${var.name_prefix}-canary-profile"
  role = aws_iam_role.canary.name
}

# --- Security group: no inbound; egress 80/443/53 out for tests + SSM ---
resource "aws_security_group" "canary" {
  name        = "${var.name_prefix}-canary-sg"
  description = "Canary egress only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "HTTPS out (site under test, SSM, CloudWatch)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "HTTP out (redirect checks)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  e2e_script = file("${path.module}/../../../canary/e2e_check.py")

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    dnf install -y python3 awscli || dnf install -y python3
    mkdir -p /opt/canary
    cat > /opt/canary/e2e_check.py <<'PYEOF'
    ${local.e2e_script}
    PYEOF
    cat > /opt/canary/canary.env <<ENVEOF
    CANARY_SITE_URL=${var.site_url}
    CANARY_API_URL=${var.api_url}
    AWS_DEFAULT_REGION=${var.canary_region_hint}
    ENVEOF
    cat > /etc/systemd/system/canary.service <<'SVCEOF'
    [Unit]
    Description=Clearing Advisor 2027 e2e canary
    [Service]
    EnvironmentFile=/opt/canary/canary.env
    ExecStart=/usr/bin/python3 /opt/canary/e2e_check.py
    SVCEOF
    cat > /etc/systemd/system/canary.timer <<'TMREOF'
    [Unit]
    Description=Run e2e canary every 5 minutes
    [Timer]
    OnBootSec=60
    OnUnitActiveSec=300
    [Install]
    WantedBy=timers.target
    TMREOF
    systemctl daemon-reload
    systemctl enable --now canary.timer
  EOF
}

# canary_region_hint injected so the env file gets the right region for the CLI.
variable "canary_region_hint" {
  type    = string
  default = "eu-west-2"
}

resource "aws_instance" "canary" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  iam_instance_profile        = aws_iam_instance_profile.canary.name
  vpc_security_group_ids      = [aws_security_group.canary.id]
  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  tags = { Name = "${var.name_prefix}-canary" }
}

resource "aws_eip_association" "canary" {
  instance_id   = aws_instance.canary.id
  allocation_id = var.eip_allocation_id
}

# --- Alerting ---
resource "aws_sns_topic" "canary" {
  name              = "${var.name_prefix}-canary-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.admin_email == null ? 0 : 1
  topic_arn = aws_sns_topic.canary.arn
  protocol  = "email"
  endpoint  = var.admin_email
}

resource "aws_cloudwatch_metric_alarm" "http_errors" {
  alarm_name          = "${var.name_prefix}-canary-http-errors"
  namespace           = var.metrics_namespace
  metric_name         = "HttpErrors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching" # canary silent = also a problem
  alarm_actions       = [aws_sns_topic.canary.arn]
  ok_actions          = [aws_sns_topic.canary.arn]
}

output "public_ip" { value = var.eip_public_ip }
output "instance_id" { value = aws_instance.canary.id }
output "alerts_topic_arn" { value = aws_sns_topic.canary.arn }
