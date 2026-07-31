# Clearing Course Finder

A UK-only, fully serverless web application that helps students find undergraduate
courses in UCAS Clearing, ranked by graduate outcomes, with an accuracy-first
results page. All infrastructure is defined in Terraform.

## Architecture

- **Region strategy:** a primary application region for data, compute, API and
  CDN; the CloudFront-scoped WAF in `us-east-1` (an AWS platform requirement);
  and an end-to-end canary in a second region.
- **Core:** DynamoDB (reference tables + TTL caches), Node.js 22 Lambdas on
  arm64 (Graviton), an HTTP API, and a CloudFront + S3 static site fronted by
  Origin Access Control. AWS WAF provides GB-only geo-restriction, per-IP rate
  limiting, and managed rule groups.
- **Optional full scope:** CloudWatch observability, Results-Day autoscaling,
  and a Grafana analytics dashboard.
- **Monitoring:** a synthetic canary exercises the live site every minute and
  alarms on 4xx/5xx via SNS; a CloudWatch overview dashboard summarises health.
- **Optional custom domain:** ACM certificate + Route 53 alias, off by default
  and additive.

## Accuracy principles

- Show the student's **exact UCAS Tariff** (letter profile and points total),
  with an in-app explanation of how points are calculated.
- **Never display a fabricated course entry requirement.** Direct students to
  confirm the real requirement on UCAS or with the university.
- Show only **verified** figures: graduate prospects with a source link, and
  salary as a clearly-labelled national subject median.

## Deploy (summary)

1. Build the Lambda packages.
2. `terraform init` -> `terraform plan` (review) -> `terraform apply`.
3. Publish the static frontend and seed the reference data.

See `DEPLOY-RUNBOOK.md` in the repository for the full procedure, including the
kill switch and teardown.

## Operational controls

- **Instant kill switch:** disable the CloudFront distribution (reversible).
- **WAF block:** flip the WebACL default action via a Terraform variable.
- **Full teardown:** a single command removes every resource.

## Notes

No account identifiers, domains, or personal data are stored in this repository
or wiki. Environment-specific values live only in local, git-ignored files
(`terraform.tfvars`, Terraform state) on the operator's machine.
