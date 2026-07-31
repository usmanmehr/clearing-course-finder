#!/usr/bin/env python3
"""End-to-end synthetic canary for the UK Clearing Advisor 2027 stack.

This canary runs on a small always-on EC2 instance (t3.micro) in eu-west-2,
separate from the main application stack in eu-west-1, so that it exercises
the site the same way a real user's browser would - across the public
internet, through CloudFront - and keeps monitoring even if the primary
region has trouble.

It is intended to be invoked once per minute by a systemd timer (or a plain
cron entry) that is installed by the EC2 instance userdata at boot. Each run
performs a fixed set of checks, prints one JSON line per check to stdout so
CloudWatch Logs (via the CloudWatch agent) captures a structured record, then
publishes two custom CloudWatch metrics for alarming:

  Namespace : ClearingAdvisor2027/Canary   (region eu-west-2)
    HttpErrors  (Count)        - number of failing checks this run
    MaxLatency  (Milliseconds) - slowest check this run

A check counts as an error if the request times out, raises any network
error, or returns a status of 403, 429, or any 5xx - i.e. the site being
blocked, throttled, or broken all trip the alarm. The process exits non-zero
when any check fails so a timer/cron wrapper can also surface failures.

Configuration (environment variables):
  CANARY_SITE_URL - CloudFront HTTPS base URL of the site (e.g.
                    https://d123.cloudfront.net or https://clearing.example).
  CANARY_API_URL  - Base URL of the same-origin API (the /api prefix), e.g.
                    https://clearing.example/api. Falls back to
                    <CANARY_SITE_URL>/api when unset.

The canary is deliberately stdlib-only (urllib, json, subprocess) so the
t3.micro needs no pip install - only Python 3 and the AWS CLI, both present
on Amazon Linux. The AWS CLI is used to publish metrics via the instance
role; no credentials are embedded.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

TIMEOUT_SECONDS = 5
METRIC_REGION = "eu-west-2"
METRIC_NAMESPACE = "ClearingAdvisor2027/Canary"
# Statuses that count as a failure even though the HTTP call itself completed.
ERROR_STATUSES = {403, 429}
USER_AGENT = "ClearingAdvisor2027-Canary/1.0"


def _request(method, url, body=None, headers=None):
    """Perform one HTTP request and return a structured result dict.

    Never raises on a network problem: timeouts, DNS failures, resets and any
    other transport error are reported as an error result so a single run can
    surface all check outcomes and the process stays alive.
    """
    hdrs = {"User-Agent": USER_AGENT}
    if headers:
        hdrs.update(headers)
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")

    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            payload = resp.read(65536).decode("utf-8", "replace")
            latency_ms = (time.monotonic() - start) * 1000.0
            status = resp.getcode()
            return {
                "status": status,
                "latencyMs": round(latency_ms, 1),
                "body": payload,
                "error": None,
            }
    except urllib.error.HTTPError as e:
        # A well-formed HTTP response with a >=400 status. Read the body so a
        # 4xx/5xx can still be inspected; classify below.
        latency_ms = (time.monotonic() - start) * 1000.0
        try:
            payload = e.read(65536).decode("utf-8", "replace")
        except Exception:
            payload = ""
        return {
            "status": e.code,
            "latencyMs": round(latency_ms, 1),
            "body": payload,
            "error": None,
        }
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        # Timeout, connection refused, DNS failure, TLS error, etc.
        latency_ms = (time.monotonic() - start) * 1000.0
        return {
            "status": None,
            "latencyMs": round(latency_ms, 1),
            "body": "",
            "error": str(getattr(e, "reason", e)) or e.__class__.__name__,
        }


def _is_failure(result, expect_status=200, expect_body_substrings=None):
    """Decide whether a check result is a failure.

    Failure conditions:
      - transport error (no status),
      - status is 403/429 or any 5xx,
      - status is not the expected status,
      - a required body substring is missing.
    """
    if result["error"] is not None:
        return True
    status = result["status"]
    if status is None:
        return True
    if status in ERROR_STATUSES or status >= 500:
        return True
    if status != expect_status:
        return True
    if expect_body_substrings:
        body_lower = (result["body"] or "").lower()
        for needle in expect_body_substrings:
            if needle.lower() not in body_lower:
                return True
    return False


def run_check(name, method, url, expect_status=200,
              expect_body_substrings=None, body=None):
    """Run one check, emit a JSON line, and return (failed, latency_ms)."""
    result = _request(method, url, body=body)
    failed = _is_failure(result, expect_status, expect_body_substrings)
    record = {
        "check": name,
        "method": method,
        "url": url,
        "status": result["status"],
        "latencyMs": result["latencyMs"],
        "ok": not failed,
        "error": result["error"],
    }
    # One JSON line per check for CloudWatch Logs.
    print(json.dumps(record))
    return failed, result["latencyMs"]


def publish_metrics(http_errors, max_latency_ms):
    """Publish HttpErrors and MaxLatency to CloudWatch via the AWS CLI.

    Uses the instance role for auth. A failure to publish is reported but does
    not crash the canary - the JSON log lines are still emitted.
    """
    cmd = [
        "aws", "cloudwatch", "put-metric-data",
        "--region", METRIC_REGION,
        "--namespace", METRIC_NAMESPACE,
        "--metric-data",
        ("MetricName=HttpErrors,Unit=Count,Value=%d" % http_errors),
        ("MetricName=MaxLatency,Unit=Milliseconds,Value=%.1f" % max_latency_ms),
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (subprocess.SubprocessError, OSError) as e:
        print(json.dumps({"check": "publish_metrics", "ok": False,
                          "error": str(e)}))
        return
    if r.returncode != 0:
        print(json.dumps({"check": "publish_metrics", "ok": False,
                          "error": (r.stderr or "").strip()}))
    else:
        print(json.dumps({"check": "publish_metrics", "ok": True,
                          "httpErrors": http_errors,
                          "maxLatencyMs": round(max_latency_ms, 1)}))


def main():
    site_url = os.environ.get("CANARY_SITE_URL", "").rstrip("/")
    if not site_url:
        print(json.dumps({"check": "config", "ok": False,
                          "error": "CANARY_SITE_URL is not set"}))
        publish_metrics(1, 0.0)
        return 2

    api_url = os.environ.get("CANARY_API_URL", "").rstrip("/")
    if not api_url:
        api_url = site_url + "/api"

    # Realistic search payload: a candidate interested in a subject, holding
    # one A-level qualification, with a stated priority.
    search_payload = {
        "courseInterest": "Computer Science",
        "subjects": [
            {"subject": "Mathematics", "grade": "B"},
            {"subject": "Physics", "grade": "B"},
        ],
        "priority": "employability",
    }

    checks = [
        # (name, method, url, expect_status, body_substrings, body)
        ("site_root", "GET", site_url + "/", 200, None, None),
        ("faq", "GET", site_url + "/faq.html", 200, None, None),
        ("health", "GET", api_url + "/health", 200, ["status", "ok"], None),
        ("api_search", "POST", api_url + "/search", 200, None, search_payload),
    ]

    http_errors = 0
    max_latency = 0.0
    for name, method, url, expect, substrings, body in checks:
        failed, latency = run_check(
            name, method, url,
            expect_status=expect,
            expect_body_substrings=substrings,
            body=body,
        )
        if failed:
            http_errors += 1
        if latency > max_latency:
            max_latency = latency

    publish_metrics(http_errors, max_latency)
    return 1 if http_errors else 0


if __name__ == "__main__":
    sys.exit(main())
