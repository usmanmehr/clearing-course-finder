# 2027 Rollout Plan

Adapted from the reproduction guide's Section 7 master prompt, updated for the
decision to re-platform onto **Terraform** for the 2027 cycle.

## Kickoff decision

- **IaC:** Terraform (was: CloudFormation + `deploy.sh`). Rationale in `README.md`.
- **Handler code:** unchanged - reuse `./lambda/` as-is. Only the deploy layer
  moves.
- **Regions:** unchanged - app + data in `eu-west-2`, CloudFront WAF WebACLs in
  `us-east-1` (AWS platform requirement, not a choice).
- **Scope toggle:** `enable_full` variable gates observability/scaling/grafana.

## Adapted master prompt (for the 2027 AI-assisted rollout)

```
You are assisting with the 2027 Results Day rollout of UK Clearing Advisor,
a serverless, UK-only AWS application that helps students find UCAS Clearing
courses. This is a yearly-recurring deployment with prior history - do not
treat it as greenfield. For 2027 the infrastructure is being re-platformed
from CloudFormation onto Terraform, in this standalone project (terraform/).

Before making any change:
1. Read README.md, 2027-ROLLOUT-PLAN.md and IMPROVEMENTS-2027.md.
2. Cross-reference the source of truth for behaviour: the vendored 2026
   templates in reference/2026-cloudformation/*.yaml. The Terraform must
   reproduce that behaviour unless an item in IMPROVEMENTS-2027.md explicitly
   changes it.
3. Read WELL-ARCHITECTED.md and this cycle's IMPROVEMENTS-2027.md - treat any
   unresolved item there as known technical debt, not a new discovery.

Operating rules:
- Production system serving real students during a high-traffic window. Treat
  all AWS credentials as production-scoped. Confirm before any destructive
  action (state manipulation, resource deletion, secret rotation).
- Prefer the Terraform config over ad hoc CLI changes for anything meant to
  persist. Run `terraform plan` and review it in full before every `apply`.
- Verify every claim about live behaviour with a real check against the actual
  account (a real CLI query, a real HTTP request from a UK vantage point) - not
  from `plan` output or exit codes alone.
- Never commit real account IDs, domains, or credentials. clearing.env and
  DEPLOYMENT.md remain git-ignored. terraform.tfvars is git-ignored too.
- If you repeat a fix for the same root cause twice, stop and check
  IMPROVEMENTS-2027.md - it may already be tracked with a scoped recommendation.

Your first task is: [insert specific 2027 task].
```

## First tasks (suggested order)

1. **Transcribe resource detail.** Walk every `# TODO(2027):` marker in
   `terraform/modules/*` and fill it from the matching `./reference/2026-cloudformation/*.yaml`
   resource (table names/GSIs, per-function memory + env, log retentions,
   WAF rule priorities, CloudFront behaviours).
2. **Stand up remote state.** Configure `terraform/backend.tf` (S3 bucket +
   DynamoDB lock table) in your own account. This is the only bootstrap step
   that touches AWS and it is state infrastructure, not the app.
3. **Dry run.** `terraform init && terraform plan` for core scope only
   (`enable_full = false`). Review the full plan. Do not apply yet.
4. **Migration strategy call.** Decide fresh-account deploy vs `terraform import`
   of the existing 2026 stacks. For a yearly product a clean deploy into a fresh
   account is usually simpler than importing - but confirm before choosing.
5. **Work the IMPROVEMENTS-2027.md backlog** as part of the re-platform, not as
   a follow-up (Graviton, DLQs, WAF Block mode, table retention/PITR, Budgets).

## Guardrails for this scaffold

- Nothing here has been initialised, planned, or applied.
- No credentials configured; no account contacted.
- Standalone project - self-contained; does not read from or depend on the
  2026 repo. Resources use the `uk-clearing-advisor-2027` name prefix.
