#!/usr/bin/env bash
#
# kill.sh - INSTANT kill switch for the UK Clearing Advisor 2027 stack.
#
# Primary mechanism: disable the CloudFront distribution. Setting Enabled=false
# takes the public site dark within seconds (CloudFront stops serving and
# returns errors at the edge) WITHOUT destroying any data - DynamoDB tables,
# Lambdas, and the API all stay intact. Re-enabling with --restore brings the
# site straight back. Use teardown.sh only when you actually want to delete
# infrastructure and data.
#
# Assumptions:
#   - The AWS CLI is installed and configured with credentials that can call
#     cloudfront:GetDistributionConfig and cloudfront:UpdateDistribution.
#   - CloudFront is a global service, so no --region is needed (and none is
#     passed); the distribution lives in the same account as this stack.
#   - The distribution id is supplied via --distribution-id or the CF_DIST_ID
#     environment variable. (Get it from `terraform output` or the console.)
#   - jq is available for JSON manipulation of the distribution config.
#
# Usage:
#   ./kill.sh --distribution-id E123ABC456DEF          # disable (site dark)
#   CF_DIST_ID=E123ABC456DEF ./kill.sh                 # same, via env
#   ./kill.sh --distribution-id E123ABC456DEF --restore  # re-enable
#   ./kill.sh --distribution-id E123ABC456DEF --yes      # skip confirmation
#
set -euo pipefail

DIST_ID="${CF_DIST_ID:-}"
RESTORE=false
ASSUME_YES=false

usage() {
  cat >&2 <<'EOF'
Usage: kill.sh [--distribution-id ID] [--restore] [--yes]

  --distribution-id ID  CloudFront distribution id (or set CF_DIST_ID).
  --restore             Re-enable the distribution instead of disabling it.
  --yes                 Skip the typed confirmation prompt.
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution-id) DIST_ID="${2:-}"; shift 2 ;;
    --distribution-id=*) DIST_ID="${1#*=}"; shift ;;
    --restore) RESTORE=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$DIST_ID" ]]; then
  echo "ERROR: no distribution id. Pass --distribution-id or set CF_DIST_ID." >&2
  exit 2
fi

for tool in aws jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found on PATH." >&2
    exit 2
  fi
done

if [[ "$RESTORE" == true ]]; then
  TARGET_ENABLED=true
  ACTION_DESC="RE-ENABLE (restore) the site"
  CONFIRM_WORD="RESTORE"
else
  TARGET_ENABLED=false
  ACTION_DESC="DISABLE the site (go dark)"
  CONFIRM_WORD="KILL"
fi

echo "Distribution : $DIST_ID"
echo "Action       : $ACTION_DESC"
echo "Data impact  : NONE - this only toggles CloudFront Enabled; no data is deleted."
echo

if [[ "$ASSUME_YES" != true ]]; then
  printf "Type '%s' to confirm: " "$CONFIRM_WORD"
  read -r reply
  if [[ "$reply" != "$CONFIRM_WORD" ]]; then
    echo "Aborted - confirmation did not match." >&2
    exit 1
  fi
fi

# Fetch current config + ETag. update-distribution requires the full config
# object and the matching If-Match ETag for optimistic concurrency.
echo "Fetching current distribution config..."
CONFIG_JSON="$(aws cloudfront get-distribution-config --id "$DIST_ID" --output json)"
ETAG="$(echo "$CONFIG_JSON" | jq -r '.ETag')"
CURRENT_ENABLED="$(echo "$CONFIG_JSON" | jq -r '.DistributionConfig.Enabled')"

if [[ "$CURRENT_ENABLED" == "$TARGET_ENABLED" ]]; then
  echo "No change needed - distribution is already Enabled=$CURRENT_ENABLED."
  exit 0
fi

# Extract the DistributionConfig and flip Enabled to the target value.
NEW_CONFIG="$(echo "$CONFIG_JSON" \
  | jq --argjson en "$TARGET_ENABLED" '.DistributionConfig | .Enabled = $en')"

echo "Applying Enabled=$TARGET_ENABLED ..."
aws cloudfront update-distribution \
  --id "$DIST_ID" \
  --if-match "$ETAG" \
  --distribution-config "$NEW_CONFIG" \
  --output json >/dev/null

echo
if [[ "$TARGET_ENABLED" == false ]]; then
  echo "DONE: distribution $DIST_ID is now DISABLED. The site will go dark at"
  echo "the edge within seconds to a couple of minutes as the change deploys."
  echo "Run with --restore to bring it back. No data was touched."
else
  echo "DONE: distribution $DIST_ID is now ENABLED. The site is coming back"
  echo "online as the change deploys to the edge."
fi
