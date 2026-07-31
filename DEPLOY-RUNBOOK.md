# Deploy & Operate Runbook - UK Clearing Advisor 2027 (Terraform)

Reproducible deploy, verify, kill and teardown for the independent 2027 test
stack. This stack is self-contained and does not depend on the 2026 repo.

- IaC: Terraform. Primary region `eu-west-1`; CloudFront WAF in `us-east-1`
  (platform requirement); canary EC2 in `eu-west-2`.
- Resource name prefix: `uk-clearing-advisor-2027` (distinct from 2026, so both
  coexist in one account without collision).
- Access model: UK-only at the edge (CloudFront geo-restriction + WAF). The SPA
  calls `/api/*` same-origin through CloudFront; CloudFront sends a shared
  `X-Origin-Verify` header to the API origin.

## 1. Prerequisites

- Terraform >= 1.5 (`~/.local/bin/terraform` was used here; install the binary
  from releases.hashicorp.com if missing - the host had no package).
- Python 3, AWS CLI v2.
- AWS credentials for the target account with create permissions (role `Admin`
  in `<ACCOUNT_ID>` was used). In the sandbox, vend via the creds tool; the
  shared credentials file is used by the default profile (do NOT pass
  `--profile`).

## 2. Deploy (from the project root)

```bash
# 2.1 Package the Lambda zips (produces build/<Fn>.zip that compute references)
python3 scripts/build_lambdas.py

# 2.2 Terraform
cd terraform
terraform init -input=false
terraform plan  -input=false -out=/tmp/tfplan        # REVIEW before applying
terraform apply -input=false /tmp/tfplan

# 2.3 Publish the frontend (bucket name is <prefix>-site-<account-id>)
aws s3 sync ../frontend/ s3://uk-clearing-advisor-2027-site-<ACCOUNT_ID>/ \
  --delete --region eu-west-1

# 2.4 Seed reference data into the 2027 tables (NEVER the 2026 tables)
AWS_REGION=eu-west-1 \
  CONTACTS_TABLE=uk-clearing-advisor-2027-universities \
  DEFAULTS_TABLE=uk-clearing-advisor-2027-subject-defaults \
  python3 ../scripts/seed.py
```

Expected seed: 44 universities, 46 subject defaults. CloudFront takes ~5-10 min
to propagate on first create.

## 3. Verify (end-to-end, from the canary)

The site is GB-only, so verify from the canary (its EIP is allowlisted in the
WAF) rather than from a non-GB host. Run its check via SSM:

```bash
R=eu-west-2
IID=$(aws ec2 describe-instances --region $R \
  --filters "Name=tag:Name,Values=uk-clearing-advisor-2027-canary" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ssm send-command --region $R --instance-ids "$IID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["set -a; source /opt/canary/canary.env; python3 /opt/canary/e2e_check.py"]'
# then: aws ssm get-command-invocation --region $R --command-id <id> --instance-id "$IID"
```

Healthy result: `site_root`, `faq`, `health`, `api_search` all `status 200`,
`httpErrors: 0`. The canary also runs every minute via a systemd timer and
publishes `ClearingAdvisor2027/Canary` `HttpErrors` / `MaxLatency` to CloudWatch
(eu-west-2); an alarm notifies the SNS topic on errors.

## 4. Operate - kill switch & teardown

- Instant kill (reversible, no data loss) - disables the CloudFront distribution:
  ```bash
  ./kill.sh --distribution-id <dist-id>          # site dark in seconds
  ./kill.sh --distribution-id <dist-id> --restore # bring it back
  ```
- WAF block (declarative) - flips the WebACL default action to BLOCK:
  ```bash
  cd terraform && terraform apply -var kill_switch=true
  ```
- Full teardown (irreversible, deletes data) - a plain destroy removes
  everything A-Z (deletion protection defaults off for this test stack):
  ```bash
  cd terraform && terraform destroy      # or:
  ./teardown.sh                          # typed 'DESTROY' confirmation
  ```
  For a production deploy set `protect_data=true` to enable DynamoDB deletion
  protection (then disable it before destroying).

## 5. Current live deployment (as of first deploy, 2026-07-31)

| Item | Value |
|------|-------|
| Account / primary region | <ACCOUNT_ID> / eu-west-1 |
| Site URL | https://<CLOUDFRONT_DOMAIN> |
| API base | https://<CLOUDFRONT_DOMAIN>/api |
| CloudFront distribution id | <DISTRIBUTION_ID> |
| Canary IP (eu-west-2, WAF-allowlisted) | <CANARY_IP> |
| Canary alerts SNS topic | uk-clearing-advisor-2027-canary-alerts (eu-west-2) |
| CloudWatch dashboard | uk-clearing-advisor-2027-overview (eu-west-1) |

Note: `admin_email` was not set, so the canary alarm has no subscriber yet - set
`admin_email` and apply, or subscribe to the SNS topic, to receive alerts.

## 6. Gotchas fixed during the first deploy (already in the code)

These were found by deploying + verifying; the Terraform now encodes them. Keep
them in mind for any change:

1. **API routes must carry the `/api` prefix.** CloudFront forwards the full
   `/api/*` path to the API origin with no rewrite, so routes are
   `POST /api/search`, `GET /api/health`, etc. Routes without `/api` -> 404.
2. **`API_ORIGIN_SECRET` must be the secret VALUE**, injected as a Lambda env var
   equal to what CloudFront sends as `X-Origin-Verify`. Injecting only the
   Secrets Manager ARN makes origin verification fail open.
3. **Per-function IAM must match what each handler reads.** Health does a
   `GetItem` on `CONTACTS_TABLE` (universities) - scope its role to that table,
   not rate_limits, or Health self-reports 503.
4. **DynamoDB key schemas come from `reference/2026-cloudformation/data.yaml`**
   (verified, not guessed): composite keys and TTL attribute names differ per
   table (e.g. clearing-cache = cacheKey+provider/expiresAt; rate-limits =
   limitKey+windowStart/ttl; query-cache = queryId/ttl). Wrong keys -> seed and
   query failures.
5. **Lambda alias permission** uses `function_name` + `qualifier = "live"` (not
   `name:live` inline), else a perpetual replacement diff.
6. **S3 site bucket policy** must grant CloudFront OAC read (SourceArn = the
   distribution) plus a TLS-deny; without it the site returns 403.
7. **`count`/`for_each` must be known at plan** - the WAF canary allowlist is
   gated on a `canary_enabled` bool, not on the (post-apply) canary IP.
8. **Canary EC2 uses `user_data_replace_on_change = true`** so script edits
   propagate on apply (default is false - the instance keeps the old script).
9. **A-Z lifecycle**: DynamoDB deletion protection defaults off (`protect_data`),
   so `terraform apply` builds all resources and `terraform destroy` removes them
   in one command. Set `protect_data=true` for production and disable it before a
   destroy.

## 7. Isolation & safety

- Every resource is prefixed `uk-clearing-advisor-2027`; IAM roles are scoped to
  the 2027 table ARNs only; every apply reported `0 destroyed` against 2026.
- `seed.py` defaults to the 2027 table names - never run it against 2026 tables.
- Terraform state (contains the generated origin secret) is local on the deploy
  host; move to an S3 backend (`terraform/backend.tf`) for durable/shared state.

## 8. Cost

t3.micro canary runs 24/7, plus CloudFront + a WAF WebACL - small but ongoing
until `./teardown.sh`.
