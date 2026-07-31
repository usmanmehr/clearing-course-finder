# SSM Patch Baseline for the Grafana EC2 instance.
# STUB - full scope (optional). TODO(2027): port from ../../../reference/2026-cloudformation/patching.yaml.
#
# 2027 note: in 2026 the "Patch Group" instance tag had to be applied manually
# because CFN could not tag an instance defined in another stack. In Terraform,
# tag the instance from the grafana module directly (pass the tag there) so this
# manual step disappears.

variable "name_prefix" { type = string }
variable "grafana_instance_id" { type = string }

# TODO(2027): aws_ssm_patch_baseline + aws_ssm_patch_group + maintenance window.
# Tie the patch group to the tag set on the instance in the grafana module.
