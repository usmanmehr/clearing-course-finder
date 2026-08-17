# AI Rebuild Prompt - UK Clearing Advisor (Clearing Course Finder)

> **Purpose of this file.** This is a single, self-contained specification that
> an AI coding agent can follow to recreate the entire Clearing Course Finder
> project from scratch. It describes the product, principles, architecture, tech
> stack, every feature, the data model, all Lambdas and scripts, the Terraform
> infrastructure, the data flows, and the operational setup. Account-specific
> values (AWS account id, domain, EIPs) are intentionally shown as
> `<PLACEHOLDERS>` - the rebuild target supplies its own.

---

## 0. One-paragraph brief

Build a **UK-only, fully serverless UCAS Clearing course finder**. A prospective
student enters their qualifications (A-levels and/or BTECs) and a subject
interest; the app returns a ranked shortlist of universities (by graduate
employability, salary, ranking, or a balanced score), each with its Clearing
contact details and - for universities that publish a machine-readable course
list - the **live per-course Clearing listings** (with per-course open/closed
status where the source exposes it). Everything is defined in **Terraform**,
deployed to a single AWS account, fronted by CloudFront + AWS WAF (GB
geo-restriction), and monitored by a second-region synthetic canary. It is a
**seasonal** system: built to `terraform apply` A-Z, run through the August
Clearing window, then `terraform destroy` A-Z to ~£0 cost until the next cycle.

---

## 1. Product principles (these drive every design decision - keep them)

1. **Never show a student anything fabricated or ambiguous.** Every displayed
   figure is either verified or clearly labelled as an unconfirmed estimate.
   This is the #1 rule.
2. **University-level vs course-level honesty.** Without a live UCAS Clearing
   feed the app is fundamentally a *shortlisting aid*. University-level Clearing
   status is shown with an amber badge worded "at our last update - confirm with
   the university", never as asserted fact. Where real per-course data is
   scraped, it carries its **source URL + fetch timestamp** and a "confirm with
   the university" caveat.
3. **Show the student's real UCAS tariff** as "AAB - 136 UCAS points" (letter
   profile + points) for A-level entries; points-only for BTEC/mixed. A FAQ page
   explains the calculation with worked examples.
4. **Do not display a fabricated course entry requirement.** The app explicitly
   says it does not hold the course's real requirement and points to UCAS / the
   university. (An earlier "typical offer" band derived from institution tier was
   removed because students misread it as a published requirement.)
5. **Single global freshness disclaimer** on results (most-recent check time +
   the university-level-not-course-level caveat), not noisy per-card timestamps.
6. **Accessibility and no-DOM-injection:** all user/scraped strings are escaped
   before insertion into the DOM.

---

## 2. Tech stack

| Layer | Choice |
|---|---|
| IaC | **Terraform** (>= 1.5; pinned 1.9.8). Multi-region via provider aliases. One state, one apply. |
| Compute | **AWS Lambda** - Node.js 22 (arm64) for the app handlers; **Python 3.12** for the scheduled course-ingest Lambda. |
| API | **HTTP API Gateway** (`/api/*`), same-origin via CloudFront. |
| Data | **DynamoDB** (on-demand, SSE, PITR) - reference tables + TTL caches. |
| Edge | **CloudFront** (GB geo-restriction) + **AWS WAF** (managed rules in block mode, rate limiting) + private **S3** via Origin Access Control. |
| Secrets | **Secrets Manager** (CloudFront<->API origin-verify secret, generated at deploy). |
| Frontend | **Vanilla HTML/CSS/JS** SPA (no framework, no build step). |
| Scheduling | **EventBridge Scheduler** (retry policy + SQS DLQ on every schedule). |
| Monitoring | Synthetic **EC2 canary** (second region), CloudWatch alarms -> SNS email, CloudWatch dashboard, optional **Grafana**. |
| Tooling | **Python 3** scripts (packaging, seeding, deploy, scraping, secret scan). |
| CI | **GitHub Actions** (fmt/validate, secret scan, JS syntax check - no AWS creds). |
| VCS | GitHub, **GitHub Flow** (main + short-lived `feature/*`), semver tags. |

No Node/npm is required to build - the Node Lambdas use only the AWS SDK v3
bundled in the Node 22 runtime (zero external deps). The Python Lambda uses only
the standard library + boto3 (present in the Lambda runtime).

---

## 3. Regions & high-level architecture

```
UK student browser
      │ HTTPS (GB only)
      ▼
CloudFront distribution ──(attached)── AWS WAF WebACL  [us-east-1: WAF + ACM cert]
      │  /*  → private S3 static site (Origin Access Control)
      │  /api/* (+ X-Origin-Verify header) → HTTP API Gateway
      ▼
API Gateway → Lambda functions (Node.js 22, arm64)  [primary region: eu-west-1]
                     │
                     ▼
                DynamoDB (reference tables + TTL caches)
                Secrets Manager (origin-verify secret)

EventBridge Scheduler → DailyScraper Lambda   → DynamoDB   (reachability + drift flags)
EventBridge Scheduler → CourseIngest Lambda   → DynamoDB   (live per-course listings)

Second region (eu-west-2): EC2 canary (WAF-allowlisted EIP) → hits CloudFront every 5 min
                           → CloudWatch metrics → alarm → SNS email
Optional: Grafana EC2 + CloudWatch dashboards
```

- **Primary region** (e.g. `eu-west-1`): data, compute, API, CDN origin, schedulers.
- **us-east-1**: the CloudFront-scoped WAF WebACL and the ACM certificate (AWS
  platform requirement for CloudFront).
- **Second region** (e.g. `eu-west-2`): the end-to-end canary EC2 instance.
- The `api ↔ cdn` dependency cycle is avoided by making the SPA same-origin
  (it calls `/api/*` through CloudFront; CORS is not fed the CloudFront domain).

---

## 4. Data model (DynamoDB) - key schemas matter, verify them

All tables prefixed `<prefix>-` (e.g. `uk-clearing-advisor-2027-`). On-demand
billing, SSE, PITR; deletion protection gated on a `protect_data` variable.

| Table (env var) | Key schema | Purpose |
|---|---|---|
| `universities` (`CONTACTS_TABLE`) | PK `providerCode` (S) | One item per university: contacts, status, live courses |
| `subject-defaults` (`DEFAULTS_TABLE`) | PK `subjectGroup` | National subject medians (salary, prospects) |
| `scholarships` | PK per data.yaml | Scholarship reference data |
| `clearing-cache` | PK `cacheKey` + SK `provider`, TTL `expiresAt` | Scraper state / cache |
| `query-cache` | PK `queryId`, TTL `ttl` | 30-min stored search results for export/share |
| `rate-limits` | PK `limitKey` + SK `windowStart`, TTL `ttl` | Per-IP rate-limit counters |
| `changelog` | PK `changeDate` + SK `changeTimestamp`, TTL | Scraper-detected page changes |

**University item shape** (the important one):
```
providerCode (e.g. "0094"), universityName, ucasInstitutionCode, region,
location, russellGroup(bool), highFliersRank, ibTier, clearingPhone,
clearingEmail, clearingPage(url), hotlineOpens, clearingStatus
("Open"|"Closed"|"Opens ..."|"Not listed"), accommodationGuarantee, notes,
graduateProspects(%), graduateProspectsSource/Url, participatesInClearing(bool),
# set by DailyScraper on every run:
clearingPageStatus ("ok"|"blocked"|"unreachable"), lastAutomatedCheck,
possibleStatusChange(bool, advisory - never overwrites clearingStatus),
# set by CourseIngest when a live course list is parseable:
liveCourses [ {title, degree, ucasCode, url, status?("open"|"closed"),
              tariff?, type?, aLevel?, btec?, ib?, entry?} ],
liveCoursesCount(int), liveCoursesSource(url), liveCoursesFetchedAt(ISO),
liveCoursesPartial(bool), liveCoursesPartialNote
```

**Non-participating universities** (Cambridge, Oxford, LSE, St Andrews,
Imperial) carry `participatesInClearing=false`: shown in results with a **red
"Does not take part in UCAS Clearing" badge**, ranked last (score forced to -1),
no Clearing CTA, and skipped by the scraper.

---

## 5. Lambda functions (Node.js 22 unless noted)

| Function | Trigger | Purpose |
|---|---|---|
| **SearchCourses** | `POST /api/search` | Core. Validates input, converts grades to UCAS points, resolves the subject interest, filters + ranks universities, attaches per-university `liveCourses` **scoped to the searched subject and capped** (see §6), stores results (30-min TTL) for export, emits metrics. Published version + `live` alias. |
| **GetSubjects** | `GET /api/subjects` | Returns the valid subject list for the autocomplete/validation. |
| **GetUniversities** | GET | University reference lookups. |
| **GetScholarships** | GET | Scholarship reference data. |
| **GenerateExport** | GET | PDF/XLSX export of a stored query result. |
| **Health** | `GET /api/health` | Health check (does a `GetItem` on the universities table - scope its IAM to that table only). |
| **WarmUp** | direct invoke (token `__WARMUP__`) | Keeps SearchCourses warm; bypasses origin-secret check. |
| **DailyScraper** | EventBridge Scheduler | Reachability checker: fetches each participating university's `clearingPage` with realistic Chrome headers, classifies `ok`/`blocked`(403/429)/`unreachable`, sets advisory `possibleStatusChange` on drift (never overwrites `clearingStatus`), writes `changelog`. Bounded concurrency, browser headers to clear UA-based 403s. |
| **CostReporter** | EventBridge | Cost Explorer summary (non-API). |
| **ScheduleManager** | EventBridge | Schedule housekeeping. |
| **CourseIngest** (**Python 3.12**) | EventBridge Scheduler (every 2h during Clearing) | Re-runs the verified per-university course parsers and writes `liveCourses` to DynamoDB with a fresh `fetchedAt`. **Safety floor:** reads the stored count first and SKIPS the write (keeping last-good data, emits `CourseIngestSkipped`) if a fresh parse returns 0 or collapses below 40% of the stored count - so a markup change or a Lambda-IP block can never wipe live data on an unattended run. Reuses `scripts/ingest_live_courses.py` (handler `ingest_live_courses.handler`) so there is only one copy of the parsing logic. |

Shared helpers live in `lambda/shared/` (`shared.mjs` - grades, subject resolve,
IP masking, rate limiting, origin-secret check, metrics, JSON responses;
`grading.mjs` - qualification/tariff logic). Every function gets the 2027 table
names as env vars so it can never fall back to a wrong table.

### SearchCourses request/response contract
- Request: `{ subjects:[{subject,grade,type?}], courseInterest?, priority?
  ("salary"|"employability"|"ranking"|"balanced"), location?, russellGroupOnly?,
  studyMode?, minSalary?, minEmployability?, limit?, website(honeypot - must be
  empty), cfTurnstileToken? }`.
- Anti-abuse pipeline (in order): WarmUp bypass → **origin-secret check**
  (`X-Origin-Verify` header must equal `API_ORIGIN_SECRET`; blocks direct
  execute-api calls that skip CloudFront/WAF) → **honeypot** (non-empty
  `website` → 200 empty) → validation → **rate limiting** (per IP: 30/min,
  700/hour via the rate-limits table).
- Validation: 1..10 subjects; each has subject name + grade; total
  A-level-equivalent **slots >= 2** (a BTEC Extended Diploma = 3 slots, so a
  single BTEC passes like 3 A-levels); subject names length-checked.
- Ranking: normalise salary (national subject median), graduate prospects
  (per-university, verified only), and rank (HighFliers) 0..1, weight by
  priority. Non-participating universities forced below all real results.
- Response includes: `results[]`, `salaryContext`, `userTariffPoints`,
  `userTariffGrades` (A-level letter profile or null), `resolvedCourseInterest`,
  `totalMatches`, `queryId`, `dataFreshness`, `estimatedData:true`, a `notice`.

---

## 6. Live per-course listings (the distinctive feature)

Some universities publish a machine-readable Clearing course list; most do not.
The project scrapes only the parseable ones and labels everything.

### Ingestion (`scripts/ingest_live_courses.py`)
- A `SITES` registry maps `providerCode -> {name, url, source_url?, parser,
  partial, partial_note}`. Each site has a **bespoke, deterministic parser**
  (stdlib regex/`html.parser`; no bs4) returning a list of course dicts.
- **Never estimate counts.** Counts come from the parse; verify against the live
  page before trusting them. (A real incident: an initial "297 courses" claim
  for one university was wrong - only 10 were server-rendered - caught by
  programmatic verification. Another: a run of `[A-Z][0-9]{3}` "UCAS codes" were
  actually SVG path coordinates - a false positive. Always verify.)
- CLI: `--dry-run` (fetch+parse+print counts, no write), `--only <codes>`.
- Also exposes a Lambda `handler(event, context)` used by the CourseIngest
  Lambda, with the **safety floor** described in §5 and concurrent fetches.

### University page-type taxonomy (hard-won - saves days on rebuild)
| Type | Handling | Examples (2026 cycle) |
|---|---|---|
| Static HTML, full + per-course open/closed status | Best case; parse directly | Lincoln (119), Loughborough (274, via a JSON feed) |
| Static HTML list | Parseable, no per-course status | Manchester (132), UCL (245), Lancaster (361), Leeds (308), Liverpool (28) |
| AJAX / paginated | Only page 1 in static HTML → mark `partial` | Reading (Sitecore; ~10 of ~297 server-rendered) |
| JS / React / Next.js | Not parseable by plain fetch (needs a headless browser) | Southampton, Brunel, Surrey, UEA, Newcastle's stored URL |
| Hard-blocked (403/429) | Needs a residential proxy | Cardiff, City, Dundee, Hertfordshire, Leicester |
| Bad stored URL | Fix the stored `clearingPage` | Heriot-Watt (was a single course page), Coventry (DNS), QUB (404) |

### Serving live courses (SearchCourses, server-side)
- Attaching a university's **entire** list to every result caused multi-MB
  responses and risked breaching DynamoDB's 400KB query-cache item limit. So
  SearchCourses **filters each list to the searched subject over the full stored
  list, then caps at 60**, returning `liveCourses` (scoped), `liveCoursesMatched`
  (null if no subject searched, 0 if none matched), `liveCoursesCount` (grand
  total), `liveCoursesTruncated`. Worst-case (no subject, limit 50) response
  stays ~134KB.

### Rendering (frontend)
- An expandable "View N live Clearing courses" block per card with: the source
  link + "fetched <time>" + "confirm with the university" caveat; a per-course
  **Open/Closed pill** where published (closed courses shown, muted, not hidden);
  entry-requirement / tariff lines where available; accurate labels
  ("N matching '<subject>'", "none match - see live page", "showing X of TOTAL");
  a partial-list banner for AJAX-only sources.

### Supporting scripts
- `scripts/discover_live_courses.py` - **read-only** sweep across all
  participating universities: fetch each `clearingPage`, classify
  ingest-candidate / no-structured-list / blocked / unreachable. Writes nothing.
- `scripts/recheck_status.py` - **read-only** sweep comparing each stored
  `clearingStatus` against OPEN/CLOSED text signals on the live page; flags
  likely-stale entries. Advisory only (JS pages hide status; false positives
  like "phone lines now closed" happen) - never auto-writes.

---

## 7. Frontend (vanilla SPA)

- `frontend/index.html` (search form), `faq.html`, `app.js`, `styles.css`,
  `geo-blocked.html`, `robots.txt`, `sitemap.xml`.
- Features: qualifications form (A-level + BTEC types, add/remove rows);
  subject **autocomplete via a shared `<datalist>`** (loaded once at init - do
  NOT re-fetch a server-filtered list into the shared datalist on keystroke, or
  it narrows the other fields); subject **validation** against the valid list
  with fuzzy "did you mean X?"; alphabetically-sorted subject dropdown; a
  **clear (x) button** on the study field (visibility toggled via an
  `.is-visible` CSS class, not the `hidden` attribute); results cards with
  ranking stats, amber status badge, single global freshness disclaimer, a
  prominent **"View live Clearing courses →" CTA** deep-linking the university's
  live page, and the expandable live-courses block (§6); PDF/XLSX export;
  compact hero.
- **Cache anchor pattern (critical):** `index.html`/`faq.html` are served
  `Cache-Control: no-cache`; JS/CSS are referenced with a **content-hash version
  query** (`app.js?v=<hash>`) and uploaded `public, max-age=31536000, immutable`.
  New content = new URL the browser has never cached = guaranteed fresh, no
  hard-refresh. Implemented by `scripts/deploy_frontend.py` (hashes assets,
  rewrites HTML refs at deploy time, sets headers, invalidates CloudFront). Never
  deploy with a bare `aws s3 cp`.

---

## 8. Terraform (infrastructure) layout & conventions

```
terraform/
  versions.tf, providers.tf (aws primary + aws.us_east_1 + aws.eu_west_2 aliases),
  variables.tf (no secret defaults - required vars fail plan), main.tf (module
  wiring: core always; full behind enable_full), outputs.tf, backend.tf,
  terraform.tfvars(.example)
  modules/
    data           DynamoDB tables (keys/TTL per table), PITR, protect_data gate
    compute        Node Lambdas (for_each), per-function IAM, log groups,
                   published version + live alias, async DLQ, origin secret
    api            HTTP API Gateway + routes (/api/* prefix) + integrations
    cdn            CloudFront + OAC + S3 buckets (force_destroy=true) + response
                   headers + optional ACM/Route53 alias
    waf            WAF WebACL (us-east-1): GB geo, rate limit, managed rules,
                   canary IP allowlist, kill_switch → default BLOCK
    canary         EC2 canary (2nd region), user_data_replace_on_change=true
    dashboard      CloudWatch overview dashboard
    scraper-schedule  EventBridge Scheduler phases → DailyScraper (retry + DLQ)
    course-ingest  Python 3.12 CourseIngest Lambda + IAM + schedule (retry+DLQ,
                   kill-switch aware, every 2h until end-of-cycle)
    observability, scaling, grafana, grafana-front, patching  (enable_full)
```

Conventions to honour:
- **Tags** via provider `default_tags` (a shared local): `Project`,
  `Environment` (values `prod`/`nonprod`/`dev`), `Cycle`, `ManagedBy=terraform`;
  `Component=<x>` on logical groupings (e.g. `Component=canary`). Tag in source,
  never by CLI. Two tag-based **Resource Groups** (one per region).
- **Kill switch is mandatory**: `kill.sh` (disable CloudFront), or
  `terraform apply -var kill_switch=true` (WAF default BLOCK + disables the
  course-ingest schedule), or `teardown.sh` (full destroy).
- **A-Z lifecycle:** `apply` builds everything, `destroy` removes everything with
  no manual steps. **All S3 buckets set `force_destroy=true`** (without it,
  `BucketNotEmpty` stalls the destroy). DynamoDB deletion protection gated on
  `protect_data` (off for the disposable test stack).
- **EventBridge Scheduler** targets always have a **retry policy + SQS DLQ**.
- **When a Lambda's `source_code_hash = filebase64sha256(build/<zip>)`**, CI must
  build the zips before `terraform validate` (build/ is gitignored). Single
  (non-`for_each`) Lambda resources are evaluated at validate time.
- Route53/ACM changes must be **additive only** on a shared zone.

---

## 9. Scripts (`scripts/`)

| Script | Role |
|---|---|
| `build_lambdas.py` | Zips each Lambda (Node fns bundle `index.mjs`+`shared.mjs`+`grading.mjs`; standalone fns; the Python `CourseIngest.zip` = `ingest_live_courses.py`). Stdlib only. |
| `seed.py` | Seeds the universities + subject-defaults tables via the AWS CLI (no boto3 dependency). Table names from CLI args/env, defaulting to the 2027 names - never the 2026 tables. Expected: 44 universities, 46 subject defaults. Source of truth for `clearingStatus`/`clearingPage`/`participatesInClearing`. |
| `deploy_frontend.py` | The canonical frontend deploy (content-hash + cache headers + CloudFront invalidation - see §7). |
| `ingest_live_courses.py` | The per-university parsers + the CourseIngest Lambda handler + safety floor (§6). |
| `discover_live_courses.py` | Read-only ingest-candidate discovery sweep (§6). |
| `recheck_status.py` | Read-only stale-status sweep (§6). |
| `check_sensitive_content.py` | Secret/PII guardrail scan (AWS key IDs, private-key headers, weak-placeholder strings). Run before every push; also the CI secret-scan job. |
| `hooks/pre-commit` | Local guardrail hook. |

---

## 10. Data flows

**A. Student search:** browser → CloudFront (GB geo, WAF) → `/api/search` (with
`X-Origin-Verify`) → SearchCourses → scan reference tables (no caching - Clearing
changes hourly) → filter/rank → attach subject-scoped, capped `liveCourses` →
store results (30-min TTL) → JSON response → frontend renders cards + live-course
blocks.

**B. Reachability scrape (DailyScraper):** EventBridge Scheduler (phased: every
30 min pre-peak, every 10 min on peak days, 4x/day after, none off-season) →
fetch each `clearingPage` with browser headers → classify ok/blocked/unreachable
→ set `clearingPageStatus`/`lastAutomatedCheck`, advisory `possibleStatusChange`,
write `changelog`. Never overwrites `clearingStatus`.

**C. Live course refresh (CourseIngest):** EventBridge Scheduler (every 2h during
Clearing) → for each parseable site: fetch + parse → safety-floor check vs stored
count → write `liveCourses` + fresh `fetchedAt` (or skip + emit metric) →
SearchCourses serves it on the next request.

**D. Canary:** systemd timer (every 5 min) on the 2nd-region EC2 (WAF-allowlisted
EIP) → hits app endpoints only (`/`, `/faq.html`, `/api/health`, `/api/search`) →
publishes `HttpErrors`/`MaxLatency` → CloudWatch alarm → SNS email. Uses a
distinct User-Agent so canary traffic is excluded from demand dashboards. Must
NOT fetch external university pages.

---

## 11. Operational setup

- **Deploy sequence:** `python3 scripts/build_lambdas.py` → `terraform init` →
  `terraform plan` (review) → `terraform apply` → `python3
  scripts/deploy_frontend.py --bucket <site-bucket> --distribution-id <dist-id>`
  → `python3 scripts/seed.py` (table names via env).
- **Verify** from the canary (site is GB-only): `/`, `/faq.html`, `/api/health`,
  `/api/search` all 200.
- **Credentials:** deploy needs Admin AWS creds vended per session (short-lived;
  not automatable) - deploy/teardown are hands-on runs.
- **CI (GitHub Actions, no AWS creds):** three jobs - `terraform fmt -check` +
  `init -backend=false` + `validate` (build the Lambda zips first!); the secret
  scan (`check_sensitive_content.py --all`); `node --check` on JS/mjs. Action
  pins target Node-24 runners (`checkout@v7`, `setup-python@v7`, `setup-node@v7`,
  `setup-terraform@v4`).
- **VCS:** GitHub Flow (main + short-lived `feature/*` → PR). Semver tags on main
  (`v1.0.0`, ...). Public repo enables free branch protection. Keep a CHANGELOG;
  run the secret scan before every push.
- **Seasonal lifecycle:** run through the August window, then `./teardown.sh`
  (A-Z destroy to ~£0). Rebuild next cycle from this spec / HANDOVER.md.

---

## 12. Known constraints & prioritised roadmap (build these in if you can)

1. **Status staleness is the #1 student-safety risk.** `clearingStatus` is
   seeded once and the scraper never overwrites it, so a university that closes
   mid-cycle can still show as available (this happened; only a user report
   caught it). The real fix: **integrate the live UCAS Clearing vacancy feed**
   (authoritative, course-level, for all universities - replaces every scraper).
   Failing that: auto-update status from the per-course lists we already parse
   (Lincoln/Loughborough model); a "report this is closed" path; prominent
   "last verified".
2. **Only a minority of universities are parseable.** Add a headless-browser
   ingester for the JS/React sites and a residential proxy for the 403-blocked
   ones; keep a **per-university strategy registry** (static/AJAX/JS/blocked/feed
   + correct course-list URL) so nothing is rediscovered live.
3. **Terraform state should move to an S3 backend + DynamoDB lock**, then add a
   **CD pipeline** (GitHub OIDC → scoped IAM roles; build → apply → deploy
   frontend → canary smoke test; `production` environment approval gate).
4. **Do the scraper/parser work before Results Day**, not live under pressure.

---

## 13. Recreate-from-scratch checklist for the AI agent

1. Scaffold the Terraform root + modules in §8; parameterise the name prefix,
   region, custom domain, and `admin_email`. No secret defaults.
2. Implement the DynamoDB tables in §4 with the **exact** key schemas/TTLs.
3. Vendor the Node Lambdas (§5) + `shared/`; implement SearchCourses' contract,
   anti-abuse pipeline, ranking, and the subject-scoped/capped `liveCourses`
   attachment (§6). Publish version + `live` alias.
4. Implement DailyScraper (reachability + drift, browser headers, never
   overwrites status) and the Python CourseIngest Lambda + safety floor.
5. Build the vanilla SPA (§7) with the cache-anchor deploy pattern.
6. Implement the scripts in §9 (parsers are per-site and must be verified against
   live pages - never estimate counts).
7. Wire WAF (GB geo + rate limit + managed rules), CloudFront + OAC, the canary,
   schedulers (retry + DLQ), tags + resource groups, the kill switch, and
   `force_destroy=true` on all S3 buckets.
8. Add CI (build zips before validate), GitHub Flow, semver, secret scan.
9. `apply` A-Z, seed, verify from the canary, then confirm `destroy` removes
   everything A-Z with no blockers.

**Above all: keep the product principles in §1. Verify every number against its
source. Label or omit anything unconfirmed. Never show a student fabricated or
ambiguous Clearing data.**
