# UK Clearing Advisor - 2027 Cycle (Terraform)

This is the **2027 Results Day** project - a standalone directory, fully
independent of the 2026 repository. It re-platforms the infrastructure onto
**Terraform** and vendors its own copies of everything it needs (`lambda/`,
`frontend/`, `scripts/`), plus the original 2026 CloudFormation templates under
`reference/2026-cloudformation/` for historical reference only. Nothing here
reads from, writes to, or depends on the 2026 repo, and its AWS resources use a
distinct `uk-clearing-advisor-2027` name prefix so it can be deployed alongside
2026 without collision.

> Status: **scaffold only.** No `terraform init`, no `plan`, no `apply` has been
> run. Nothing has been deployed. No AWS account has been touched. This is
> planning + infrastructure-as-code source only.

## Why Terraform for 2027

Grounded in the 2026 code review and the reproduction guide's Section 6 backlog:

- **Native Lambda versioning fixes H4.** The 2026 `AWS::Lambda::Version` +
  manual alias pattern silently failed to advance the `live` alias on code
  deploys. `aws_lambda_function` + `publish = true` + `aws_lambda_alias` tracks
  the published version automatically - the drift class disappears.
- **Typed cross-stack references replace `deploy.sh` ordering.** Terraform's
  dependency graph handles the ordering the 300-line bash script encoded by
  hand (including the API-deploys-twice CORS chicken-and-egg).
- **No `REPLACE_*` placeholder defaults.** Required variables with no default
  fail `plan`, not silently at runtime.
- **One state, one `apply`.** Multi-region (eu-west-2 app + us-east-1 CloudFront
  WAF) is handled with a provider alias, not two separate deploy paths.

## Scope split (unchanged from 2026)

- **Core**: `data`, `compute`, `api`, `waf`, `cdn` - public site + API.
- **Full** (`enable_full = true`): adds `observability`, `scaling`, `grafana`,
  `grafana-front`, `patching`.

## Layout

```
terraform/            Root Terraform config + per-stack modules
  versions.tf         Terraform + provider version pins
  providers.tf        aws (eu-west-2) + aws.us_east_1 alias for CloudFront WAF
  variables.tf        Input variables (no secret defaults)
  main.tf             Module wiring (core always; full behind enable_full)
  outputs.tf          Site URL, API endpoint, etc.
  backend.tf          Remote state config (commented - configure before use)
  terraform.tfvars.example   Copy to terraform.tfvars and fill in
  modules/            data, compute, api, waf, cdn, observability, scaling,
                      grafana, grafana-front, patching
lambda/               Node.js handlers (vendored copy - the deploy source)
frontend/             Static site (vendored copy - synced to S3 by the cdn module)
scripts/              build_lambdas.py, seed.py (vendored deploy tooling)
reference/            2026-cloudformation/*.yaml - historical reference only,
                      not required to build or deploy
2027-ROLLOUT-PLAN.md  Kickoff, adapted master prompt, first tasks
IMPROVEMENTS-2027.md  Section 6 backlog + 2026 review findings as a tracked,
                      file-cited checklist (with what the TF migration resolves)
```

## What this scaffold deliberately does NOT do

- It does not reproduce every resource detail 1:1 from the 2026 templates.
  Places where exact values (table GSIs, per-function memory, log retentions)
  must be transcribed from `reference/2026-cloudformation/*.yaml` are marked
  `# TODO(2027):`.
- It vendors the Lambda handler code in `lambda/` but does not modify it - the
  2026 handlers are reused as-is; only the deployment layer is re-platformed.
- It does not configure remote state or credentials.

## Before anyone runs this

1. Read `2027-ROLLOUT-PLAN.md` and `IMPROVEMENTS-2027.md`.
2. Fill every `# TODO(2027):` marker against `./reference/2026-cloudformation/*.yaml` and live state.
3. Configure `terraform/backend.tf` (S3 + DynamoDB lock) in your own account.
4. `terraform init && terraform plan` and review the plan in full before any
   `apply`. Treat all credentials as production-scoped (Results Day).
