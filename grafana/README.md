# Grafana dashboards

These dashboards run on the shared Grafana box (`clearing-advisor-grafana`,
eu-west-2), file-provisioned into the **Clearing Analytics** folder. They are
versioned here so they can be reviewed and re-provisioned.

| File | Dashboard title | Datasource (uid) | Region | Box provisioning path |
|------|-----------------|------------------|--------|------------------------|
| `scraper-freshness-dashboard.json` | UK Clearing Advisor - scraper freshness & health | CloudWatch (templated `${DS_CLEARING2027}` for UI import; deployed as `clearing-2027-cw`) | eu-west-1 | `dashboards-clearing-2027/scraper-freshness-health.json` |
| `2027-stack-demand-dashboard.json` | UK Clearing Advisor - 2027 stack demand | `clearing-2027-cw` (CloudWatch-Clearing2027) | eu-west-1 | `dashboards-clearing-2027/clearing-2027-demand.json` |
| `live-2026-site-demand-dashboard.json` | UK Clearing Advisor - LIVE 2026 site | `clearing-demand-cw` (CloudWatch-ClearingDemand) | eu-west-2 | `dashboards-clearing-demand/student-demand-analytics.json` |

## Notes
- The two demand dashboards are captured **as deployed** (concrete datasource
  UIDs baked in). The freshness dashboard is kept in **import-ready** form (a
  templated datasource input) so it can be imported via the Grafana UI.
- Synthetic monitoring-canary traffic (`User-Agent ClearingAdvisor2027-Canary/1.0`)
  is excluded from every demand panel and shown in a dedicated canary panel, so
  real student usage is not polluted. The signal is the `userAgent` field the
  `SearchCourses` search log already records.
- Datasources are provisioned separately on the box (instance-role auth, no
  credentials in these files). Re-provisioning a dashboard is a matter of
  dropping the JSON into the matching path above; the file provider auto-loads
  it (30s), no restart needed.
- These are Grafana-box artifacts, not part of the Terraform-managed stack.
