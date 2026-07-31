# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

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
