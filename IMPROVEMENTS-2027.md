# 2027 Improvements & Backlog

Tracked, file-cited backlog for the 2027 cycle. Combines the reproduction
guide's Section 6 ("Areas for Improvement") with the open findings from the
2026 code review. Each item notes whether the Terraform re-platform resolves it
by construction, or whether it still needs deliberate work.

Grading: **[TF-fixes]** resolved by the migration itself | **[do-in-2027]**
must be actively built | **[decide]** needs a product/owner decision.

## Deploy-blockers carried from the 2026 review

| ID | Item | Status in 2027 plan |
|----|------|---------------------|
| C1 | Origin-verify secret defaulted to `change-me`, stored as plaintext Lambda env var (`./reference/2026-cloudformation/cdn.yaml`, `compute.yaml`, `grafana.yaml`) | **[do-in-2027]** Source from Secrets Manager; required TF variable with no default. Longer term, migrate to CloudFront OAC / signed origin so there is no shared secret at all (see A below). |
| H4 | Lambda `live` alias did not advance on deploys (`AWS::Lambda::Version` only republishes on its own prop change) | **[TF-fixes]** `aws_lambda_function{ publish = true }` + `aws_lambda_alias` tracks the published version automatically. |

## High-severity findings (2026 review)

| ID | Item | Status |
|----|------|--------|
| H2 | Plaintext HTTP CloudFront-to-Grafana origin (`./reference/2026-cloudformation/grafana-front.yaml`, `OriginProtocolPolicy: http-only`) | **[do-in-2027]** Guide's scoped fix: Let's Encrypt cert (DNS-01) on the real domain, flip origin to `https-only`. Implement in the `grafana`/`grafana-front` modules. |
| H3 | WAF `CommonRuleSet` in `Count` mode - never blocks (`./reference/2026-cloudformation/waf.yaml`) | **[do-in-2027]** Ship the `waf` module with CRS in Block mode, gated by a `waf_crs_count_mode` variable defaulting to false, after a staging count-mode soak. |
| H-lambda1 | `GetUniversities` / `GetScholarships` return raw DynamoDB items, no field projection | **[do-in-2027]** Handler-layer fix (reuse `./lambda/`); enforce a `toPublicX()` DTO mapper per entity. Not an IaC change. |
| H-lambda2 | `checkOriginSecret()` fails open if env var unset (`./lambda/shared/shared.mjs`) | **[do-in-2027]** Fail closed when environment is production; pairs with C1. Handler change. |
| H-fe1/2/3 | Frontend `innerHTML`/`insertAdjacentHTML` with no escaping; unsanitised `href` values (`./frontend/app.js`) | **[do-in-2027]** Add a shared `escapeHtml()` + `https:`-scheme validation. Frontend change, not IaC. |

## Section 6 backlog (reproduction guide)

1. **[do-in-2027]** No DLQ / Lambda Destinations on async functions (`DailyScraper`,
   `CostReporter`). Add `on_failure` Destination or an SQS DLQ in the `compute`
   module before Results Day.
2. **[do-in-2027]** Inconsistent DynamoDB retention - only 4 of 8 tables have
   `Retain`; `RateLimitsTable` lacks PITR. The `data` module sets
   `deletion_protection`/PITR consistently; `ChangeLogTable` (audit) gets both.
3. **[do-in-2027]** H2 plaintext Grafana origin (see High table above).
4. **[decide]** WAF `CommonRuleSet` stuck in `Count` with no revisit date -
   set a revisit date or move to Block (see H3).
5. **[do-in-2027]** No AWS Budgets alarm. Add `aws_budgets_budget` wired to the
   SNS alerts topic in the `observability` module.
6. **[do-in-2027]** Test coverage effectively zero outside grading arithmetic.
   Start with `checkOriginSecret()` and rate-limiting. Handler/test change.
7. **[TF-fixes]/[do-in-2027]** No Graviton adoption. `compute` module defaults
   Lambda `architectures = ["arm64"]`; set the Grafana instance to `t4g.small`
   in the `grafana` module. Low effort - no native deps anywhere.
8. **[TF-fixes]** Version/alias naming drift in `compute.yaml` - removed by
   native Terraform Lambda versioning (same root cause as H4).
9. **[do-in-2027]** `SearchCourses` never load-tested at 512 MB. Not an IaC
   item - schedule a load test against Results-Day-scale concurrency.

## New for 2027 (architectural, from the rewrite discussion)

- **A. Kill the shared-header-secret trust model.** Replace `X-Origin-Verify`
  with CloudFront Origin Access Control + a private origin (or a Lambda
  authorizer), so `execute-api` is not publicly reachable and there is no secret
  to leak, rotate, or forget. **[decide]** - this changes the documented 2026
  security model (guide Section 2, items 2-3, 7) and needs explicit sign-off
  before implementing. Until then the scaffold keeps the origin-verify approach
  but sources the secret from Secrets Manager (never a literal default).

## Guardrails

Nothing in this backlog has been implemented or deployed. This file is planning
only.
