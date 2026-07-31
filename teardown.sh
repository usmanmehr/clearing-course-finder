#!/usr/bin/env bash
#
# teardown.sh - FULL, IRREVERSIBLE teardown of the UK Clearing Advisor 2027 stack.
#
# This runs `terraform destroy` against terraform/ and DELETES EVERYTHING the
# stack created, including the DynamoDB tables and all seeded/collected data.
# This is NOT the kill switch. If you only want the site to go dark without
# losing data, use kill.sh instead.
#
# The DynamoDB tables are protected by DynamoDB deletion protection in normal
# operation (deletion_protection_enabled). This script first applies
# kill_switch=true to disable that protection, then destroys - which is
# precisely why this is destructive and irreversible.
#
# Assumptions:
#   - Run from the project root (this script cd's into terraform/).
#   - Terraform is initialised (backend configured) and the AWS credentials in
#     the environment have permission to destroy the stack's resources.
#   - Any extra terraform variables you normally pass (via terraform.tfvars or
#     -var) are picked up as usual; this script only forces kill_switch=true.
#
# Usage:
#   ./teardown.sh            # prompts for typed 'DESTROY' confirmation
#   ./teardown.sh --yes      # skip the prompt (use with extreme care)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"
ASSUME_YES=false

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=true ;;
    -h|--help)
      echo "Usage: teardown.sh [--yes]" >&2
      exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v terraform >/dev/null 2>&1; then
  echo "ERROR: terraform not found on PATH." >&2
  exit 2
fi

if [[ ! -d "$TF_DIR" ]]; then
  echo "ERROR: terraform directory not found at $TF_DIR" >&2
  exit 2
fi

cat >&2 <<'EOF'
==============================================================================
  WARNING: FULL TEARDOWN - THIS IS IRREVERSIBLE
==============================================================================
  This will run `terraform destroy` and PERMANENTLY DELETE the entire
  UK Clearing Advisor 2027 stack, INCLUDING the DynamoDB tables and ALL data
  in them. The prevent_destroy guard on the tables will be lifted via
  -var 'kill_switch=true'. There is NO undo and NO automatic backup.

  If you only want to take the site offline without losing data, STOP NOW
  and run ./kill.sh instead.
==============================================================================
EOF
echo >&2

if [[ "$ASSUME_YES" != true ]]; then
  printf "Type 'DESTROY' to permanently delete the stack and its data: "
  read -r reply
  if [[ "$reply" != "DESTROY" ]]; then
    echo "Aborted - confirmation did not match." >&2
    exit 1
  fi
fi

cd "$TF_DIR"
# Deletion protection defaults off (protect_data=false), so a single destroy
# removes everything A-Z. Force protect_data=false in case a prod-style override
# is set locally.
echo "Running terraform destroy in $TF_DIR ..."
terraform destroy -var 'protect_data=false' -auto-approve

echo
echo "Teardown complete. The stack and its data have been destroyed."
