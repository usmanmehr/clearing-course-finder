# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]
- FAQ: corrected the scraper-frequency wording to match the phased schedule (was "once a day"), and de-yeared the header pill to "Clearing".
- Non-participating universities: added a participatesInClearing flag. Cambridge,
  Oxford, LSE, St Andrews and Imperial do not take part in UCAS Clearing, so they
  are now excluded from Clearing results (SearchCourses) and skipped by the
  scraper (DailyScraper) instead of being shown with a misleading "opens on
  Results Day" status. Flag seeded in scripts/seed.py and applied to the live
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
