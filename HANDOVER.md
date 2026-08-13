# Handover - Clearing Course Finder (next cycle)

This document lets a new engineer take the project forward for the next Clearing
cycle. It is deliberately free of account IDs, bucket names, EIPs and other
runtime specifics - those live in the private ops notes and `terraform.tfvars`
(git-ignored), and in Isengard for the AWS account. Read this alongside
[ARCHITECTURE.md](ARCHITECTURE.md), [DEPLOY-RUNBOOK.md](DEPLOY-RUNBOOK.md) and
[CHANGELOG.md](CHANGELOG.md) (the authoritative record of what shipped).

## 1. What this is

A UK-only, fully serverless UCAS Clearing course finder. A student enters their
qualifications and interests; the app ranks universities and, for the
universities we can parse, shows live per-course Clearing listings. It is
Terraform end to end, deployed to a single AWS account, fronted by CloudFront +
WAF (GB geo-restriction), with a second-region canary.

**Core product rule (non-negotiable): never show a student anything fabricated
or ambiguous.** Every displayed figure is verified or clearly labelled as an
estimate. This rule drove most of the engineering decisions below - keep it.

## 2. Where everything lives

- **Repo:** this repository (`clearing-course-finder`), `main` only (GitHub
  Flow; short-lived `feature/*` -> PR -> `main`). Release tags are semver.
- **AWS account / region:** see the private ops notes / Isengard. Primary region
  in `terraform.tfvars`; CloudFront-scoped WAF + ACM in us-east-1; canary in a
  second region.
- **Config:** `terraform/terraform.tfvars` (git-ignored) holds `name_prefix`,
  `custom_domain`, `admin_email`, etc.
- **Key code:**
  - `terraform/` - all infrastructure (modules: data, compute, api, cdn, waf,
    canary, scraper-schedule, **course-ingest**, dashboard, + optional full-scope).
  - `lambda/` - Node.js 22 handlers (SearchCourses is the main one).
  - `scripts/ingest_live_courses.py` - the verified per-university course parsers
    **and** the `handler` used by the CourseIngest Lambda (one copy of the logic).
  - `scripts/discover_live_courses.py` / `scripts/recheck_status.py` - read-only
    discovery + status-sweep tooling.
  - `scripts/seed.py` - university + subject reference data (the source of truth
    for `clearingStatus`, `clearingPage`, `participatesInClearing`).
  - `frontend/` - vanilla HTML/CSS/JS SPA. Deploy with
    `scripts/deploy_frontend.py` (content-hashed assets - never bare `aws s3 cp`).

## 3. Current state at end of this cycle

- Live per-course data for **8 universities** (see CHANGELOG for the list and
  counts): Manchester, Lincoln, Reading (partial), UCL, Lancaster, Leeds,
  Loughborough, Liverpool. Lincoln + Loughborough carry real per-course
  open/closed status.
- **CourseIngest Lambda** (Python 3.12) re-runs those parsers every 2h via
  EventBridge Scheduler (retry + DLQ, kill-switch aware) until end of August,
  with a safety floor that skips a write rather than overwrite good data with a
  broken/empty parse.
- **SearchCourses** filters live courses to the searched subject server-side and
  caps the payload (keeps responses well under DynamoDB's 400KB cache limit).
- CI runs on every PR (fmt/validate, secret scan, JS check). Terraform state is
  reconciled (`plan` clean at handover).

## 4. How to operate it

- **Deploy infra:** `python3 scripts/build_lambdas.py` then
  `terraform apply` (see DEPLOY-RUNBOOK.md). Credentials are vended per-session
  (short-lived); an unattended process cannot self-vend admin credentials.
- **Deploy frontend:** `python3 scripts/deploy_frontend.py --bucket <site-bucket>
  --distribution-id <dist-id>`.
- **Refresh course data manually:** `python3 scripts/ingest_live_courses.py`
  (writes to DynamoDB) or `--dry-run` to just parse + print counts.
- **Kill switch:** `./kill.sh` (CloudFront off), or `terraform apply -var
  kill_switch=true` (WAF block + disables the course-ingest schedule), or
  `./teardown.sh` (full A-Z destroy).
- **Monitoring:** canary + CloudWatch alarm -> SNS email; overview dashboard;
  Grafana dashboards (on a shared box - do NOT touch other teams' dashboards).
  CourseIngest emits `CourseIngestWritten/Skipped/Errors` metrics.

## 5. Known issues & risks (read before Results Day)

1. **Status staleness is the #1 student-safety risk.** Every `clearingStatus`
   is set from `seed.py` and the daily scraper **never overwrites it**. If a
   university closes/fills mid-cycle it can still show as available - this
   happened with KCL this year and was only caught by a user report. Mitigation
   in place: amber "confirm with the university" labelling. Real fix: see roadmap.
2. **Only a minority of universities are parseable.** The rest are JS/React
   (need a headless browser), AJAX-paginated, or hard-block the scraper (403).
   See the page-type reference in section 7.
3. **Terraform state is local** (no S3 backend / lock) - risk of loss/corruption
   and blocks CI/CD. Migrate to a locked S3 backend early.
4. **Out-of-band deploys cause drift.** During the busy day, Lambda code + data
   were pushed via CLI, which drifts from Terraform state - reconcile with a full
   `apply` afterwards. A real CD pipeline (designed, not built) removes this.
5. **Bespoke parsers are fragile** - they break silently when a university
   changes its markup. The CourseIngest safety floor stops a break from wiping
   data, but add alarms on `CourseIngestSkipped`.
6. **No live UCAS feed** - the whole app is a shortlisting aid, capped at
   university-level truth except where we scrape course lists.

## 6. Roadmap for next cycle (priority order)

1. **Integrate the UCAS Clearing vacancy feed.** The single highest-leverage
   change - authoritative, course-level, live data for *all* universities,
   replacing every brittle scraper. Investigate access/cost in the quiet months.
2. **Fix status staleness at the root:** where a real per-course list exists
   (Lincoln/Loughborough model), auto-update status from it; show "last verified"
   prominently; add a "report this is closed" path.
3. **Extend CourseIngest** (already built this year) to more universities,
   including a **headless-browser** ingester for the JS-driven ones, and add a
   **residential proxy** for the 403-blocked ones.
4. **Per-university strategy registry:** categorise each university once
   (static / AJAX / JS / blocked / feed) with its correct course-list URL, so
   nobody rediscovers it live. Many stored `clearingPage` URLs are landing pages.
5. **Migrate Terraform state to S3 + DynamoDB lock, then build CD** (GitHub OIDC
   -> scoped roles; design already sketched). Stop out-of-band CLI deploys.
6. **Start before Results Day.** Build and test parsers in the weeks before; on
   the day, just run the pipeline and watch the dashboards.

## 7. University page-type reference (hard-won - saves days)

| Type | Behaviour | Universities (this cycle) |
|---|---|---|
| Static HTML, full + per-course status | Best case - parse directly | Lincoln; Loughborough (via JSON feed) |
| Static HTML list | Parseable, no per-course status | Manchester, UCL, Lancaster, Leeds, Liverpool |
| AJAX / paginated | Only page 1 in static HTML | Reading (Sitecore `InClearing`, ~297 total, 10 static) |
| JS / React / InstantSearch | Not parseable by plain fetch - needs a browser | Southampton, Brunel, Surrey, UEA, Newcastle's stored URL |
| Hard-blocked (403/429) | Anti-bot - needs a residential proxy | Cardiff, City, Dundee, Hertfordshire, Leicester |
| Non-participating | Shown with a Red "does not take part" badge, ranked last | Cambridge, Oxford, LSE, St Andrews, Imperial |
| Bad stored URL | Fix in seed.py | Heriot-Watt (was a single course page), Coventry (DNS), QUB (404) |

Gotchas that cost time this year: a run of `[A-Z][0-9]{3}` "UCAS codes" was
actually **SVG path coordinates** (Newcastle) - always verify a parse count
against the real page, never trust a raw regex signal. And **always re-verify
subagent-produced counts centrally** before ingesting.

## 8. Principles to keep

- Never fabricate or estimate silently - verify counts against the source; label
  everything with its source + fetch time; only ingest unambiguous data.
- Keep work on this stack only; keep the repo in sync (CHANGELOG + push) after
  every change; run the secret scan before every push.
- Prefer Terraform for all infra; `apply` builds A-Z, `destroy` removes A-Z; a
  kill switch is mandatory.
