# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]
- CI/process: adopted GitHub Flow (main + short-lived feature/* branches; develop
  removed), added a CI-on-PR workflow (.github/workflows/ci.yml: terraform
  fmt/validate, secret scan, JS syntax check - no AWS creds), and switched release
  tags to semver (v1.0.0). Branch protection not enforced (GitHub Free private repo).
- CI: bumped GitHub Actions to Node-24 majors (actions/checkout@v7, setup-python@v7,
  setup-node@v7, hashicorp/setup-terraform@v4) to clear Node-20 deprecation warnings.
- Fix: study-field clear (x) button was not appearing. Switched visibility from the
  fragile hidden-attribute toggle to an explicit .is-visible CSS class (display:none
  default, inline-flex when shown). Deployed app.js?v=d41be83dbc, styles.css?v=1aecd4a1ff.
- Added a clear (x) button to the "What do you want to study?" field - appears
  when the field has text, resets it and refocuses for a fresh search. Other form
  behaviour preserved. Deployed app.js?v=4e900afa65, styles.css?v=8675975909.
- Subject dropdown in the qualifications field is now sorted alphabetically
  (case-insensitive, display-only; validation/fuzzy matching unchanged). Deployed app.js?v=9b6ed81efc.
- Fixed subject-autocomplete bug: the "What do you want to study?" field and the
  "Your qualifications" subject fields share one <datalist id="subject-list">, and
  typing in the study field re-fetched a server-filtered list into that shared
  datalist - narrowing the qualifications dropdown to just the typed subject. The
  study-field handler no longer re-fetches/narrows the datalist; the full list is
  loaded once and the browser filters it natively, so the qualifications field
  always shows all valid subjects. Deployed app.js?v=55ee072bfd.
- CI fixes (first Actions run on main): `terraform fmt` on modules/scraper-schedule/main.tf
  (misaligned map), and reworded IMPROVEMENTS-2027.md to drop the literal weak-secret
  string that the guardrail secret-scan (correctly) flags anywhere it appears.
- Fixed stale-asset caching (was serving old app.js from browser cache, which
  silently disabled subject-input validation): added scripts/deploy_frontend.py
  which content-hashes app.js/styles.css, rewrites HTML refs to `/app.js?v=<hash>`,
  uploads hashed assets with `Cache-Control: public, max-age=31536000, immutable`
  and HTML with `no-cache`, then invalidates CloudFront. New content = new URL =
  guaranteed-fresh in the browser, no hard-refresh needed. Deployed (app.js?v=35ba5e380b,
  styles.css?v=87205f3ebc). Repo HTML keeps plain refs; the ?v is injected at deploy time.
- Tag normalisation: provider default_tags now applied via a shared local across
  all three regions (eu-west-1, us-east-1, eu-west-2) - Project=uk-clearing-advisor,
  Environment=nonprod, Cycle=2027, ManagedBy=terraform. Standardised on ManagedBy
  and dropped the duplicate IaC key. Added Component=canary to the canary resources
  (instance, security group, IAM role + instance profile, SNS topic, alarm). Added
  two tag-based Resource Groups (one per region, eu-west-1 + eu-west-2) querying
  Project=uk-clearing-advisor + Cycle=2027. Plan: 4 add, 61 change, 2 destroy - the
  destroys/replacement being the canary instance (pending user_data change) whose
  EIP reassociates. APPLIED 2026-08-09: canary replaced (i-059082c...), EIP
  13.134.182.146 reassociated, 61 resources retagged, both resource groups created
  (eu-west-1: 36 resources, eu-west-2: 9); terraform plan converged to No changes.
  Resource-group descriptions use only AWS-permitted characters (no parentheses).
- Kept the 2026 live domain (clearing.mehrs.net) out of the repo: genericised the
  LIVE-2026-site dashboard title to "UK Clearing Advisor - LIVE 2026 site".
- Versioned the Grafana dashboards in-repo under grafana/: added
  2027-stack-demand-dashboard.json and live-2026-site-demand-dashboard.json
  (captured as-deployed from the box) plus a grafana/README.md inventory. The
  freshness dashboard was already tracked. No account IDs/secrets included.
- FAQ: corrected the scraper-frequency wording to match the phased schedule (was "once a day"), and de-yeared the header pill to "Clearing".
- Canary cadence reduced from every 1 minute to every 5 minutes (systemd timer
  OnUnitActiveSec 60 -> 300). The canary only exercises the app's own endpoints
  (/, /faq.html, /api/health, /api/search); it does NOT fetch university pages -
  those are fetched solely by DailyScraper on its own schedule.
- Grafana "2027 stack demand" dashboard: synthetic monitoring-canary traffic
  (User-Agent ClearingAdvisor2027-Canary/1.0) is now excluded from every demand
  panel and shown in a dedicated canary panel, so real student usage stats are
  not polluted. (Dashboard lives on the Grafana box; no app code change - the
  search log already records userAgent.)
- Non-participating universities: added a participatesInClearing flag. Cambridge,
  Oxford, LSE, St Andrews and Imperial do not take part in UCAS Clearing. They are
  now SHOWN in results with an explicit Red "Does not take part in UCAS Clearing"
  badge and a note to apply via the main UCAS cycle (not silently hidden), demoted
  to the bottom of the ranking so they never appear as available options, and
  skipped by the scraper. Flag seeded in scripts/seed.py and applied to the live
  table; their stale scraper status was cleared.
- Scraper anti-blocking: DailyScraper now sends realistic browser navigation
  headers (Chrome User-Agent + Accept/Accept-Language/Sec-Fetch/sec-ch-ua)
  instead of a bot User-Agent, clearing User-Agent-based 403 blocks on several
  university sites (blocked count dropped 8 -> 5).
- Corrected 10 stale university clearing-page URLs (were returning 404) to their
  current official paths; 9 now resolve 200 (Coventry intermittently times out
  from the scraper's egress). Applied to the live universities table and the
  seed source (scripts/seed.py). Non-participating universities (Cambridge, LSE,
  St Andrews, Imperial) were left unchanged pending a "does not take part in
  Clearing" data treatment rather than a misleading URL.
- Added a Grafana dashboard model, grafana/scraper-freshness-dashboard.json, for
  monitoring scraper freshness and health (Lambda invocation history, duration,
  DLQ depth, and a Logs Insights table of recent "scrape complete" runs).
  Import-ready (templated CloudWatch datasource); built on AWS/Lambda + SQS
  metrics and scraper logs. No account IDs or secrets included.

### Fixed
- Homepage: corrected the stale Results Day date in the sources note from
  "August 2027" to "August 2026" to match the actual Clearing cycle and
  scraper schedule.

### Changed
- FAQ contact email set to feedback@mehrs.net (was a placeholder).

### Added
- Phased scraper schedule (EventBridge Scheduler) that triggers the
  clearing-page checker, replacing the previously unscheduled function:
  - up to 11 Aug: every 30 minutes
  - 12-13 Aug (peak Clearing days): every 10 minutes
  - 14-31 Aug: four times per day
  - 1 Sep onwards: paused until the next cycle
  Implemented as time-bounded schedules; the scraper logic is unchanged.
- Homepage freshness stat now reflects the real automated cadence (and the
  actual "checked N ago" time where available), replacing a static "Hourly"
  claim that no longer matched the schedule.
- Scraper schedules now have a retry policy (3 attempts) and a dedicated SQS
  dead-letter queue, so an undeliverable scheduled trigger is retried and then
  captured rather than silently lost.
- Results page: removed the per-card "Clearing page checked X ago" timestamp and
  the per-card status note; consolidated them into a single prominent disclaimer
  at the top showing one global "last checked" time plus the caveat that status
  is university-level (not course-level) and must be confirmed with the university.
- Hero banner made more compact: condensed the headline, lede, and the four
  selling points (all four kept), with reduced font sizes, spacing, and padding
  so it no longer dominates the page. Colour scheme unchanged.
- Dropped the year from the visible "Clearing 2027" labels (hero eyebrow, header
  pill) and page metadata - now reads "UCAS Clearing" / "Clearing".
- Qualifications form: the subject field now validates against the predefined
  subject list - non-matching free-text is rejected (inline error, submission
  blocked), close typos get a "did you mean X?" fuzzy suggestion, and the
  canonical spelling is submitted. Autocomplete/typeahead retained.

## [0.1.0] - Initial release

### Added
- Terraform infrastructure for a UK-only, fully serverless UCAS Clearing course
  finder:
  - DynamoDB tables (reference + TTL caches), Node.js 22 Lambdas on arm64
    (Graviton), an HTTP API, and a CloudFront + S3 static site fronted by
    Origin Access Control.
  - AWS WAF: GB-only geo-restriction, per-IP rate limiting, and managed rule
    groups (Core Rule Set in block mode, plus known-bad-inputs and SQLi).
  - Optional full scope: CloudWatch observability, Results-Day autoscaling, and
    a Grafana analytics dashboard.
  - An end-to-end synthetic canary (t3.micro in a second region) that exercises
    the live site every minute and alarms on 4xx/5xx via SNS.
  - A CloudWatch overview dashboard.
  - Optional custom-domain support (ACM certificate + Route 53 alias), off by
    default and additive.
  - A two-layer kill switch (instant CloudFront disable; WAF default-block) and
    a one-command teardown.

### Accuracy
- Results show the student's exact UCAS Tariff as both a letter profile and a
  points total, with an in-FAQ explanation of how points are calculated.
- Removed the estimated per-university "typical offer" grade band. It was
  derived from the institution's overall tier rather than a course's real
  published requirement, so it was replaced with an explicit "confirm the
  entry requirements with the university" message.
- Reframed the Clearing status indicator as an unconfirmed, last-known signal
  rather than a definitive statement.
- Graduate prospects are shown only where verified (with a source link); salary
  is shown as a national subject median and clearly labelled as such.

### Security
- Least-privilege, per-function IAM scoped to exact table ARNs.
- Encryption at rest (DynamoDB; KMS on the exports bucket), TLS-only bucket
  policies, and native Lambda versioning.
- The origin-verify secret is generated at deploy time and stored in Secrets
  Manager; no secrets are committed to the repository.
