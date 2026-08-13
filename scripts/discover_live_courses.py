#!/usr/bin/env python3
"""UK Clearing Advisor - live Clearing course DISCOVERY sweep (Option B).

Attempts to retrieve live, per-course Clearing listings for every PARTICIPATING
university in the system, EXCLUDING Reading (0109) and Southampton (0127),
which were handled separately. It fetches each university's stored clearingPage
and classifies whether that page exposes a reliably parseable, SERVER-RENDERED
structured course list (like Manchester's), logging a clear success/failure
line for each.

ACCURACY (product rule #1 - nothing fabricated/ambiguous shown to students):
  * This is a DISCOVERY + classification pass. By default it writes NOTHING.
  * A university is only marked an INGEST CANDIDATE when its page yields an
    unambiguous structured list (many UCAS codes and/or many repeated course
    blocks in server-rendered HTML) - never on a weak heuristic.
  * Pages that are landing pages, JS/AJAX-driven, blocked (403/429) or
    unreachable are logged as such and skipped. No course is invented.

It does NOT touch Reading or Southampton data.
"""
import argparse
import re
import sys
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

DEFAULT_TABLE = "uk-clearing-advisor-2027-universities"
EXCLUDE = {"0109", "0127"}  # Reading, Southampton - handled separately

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
HEADERS = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-GB,en;q=0.9",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
}
FETCH_TIMEOUT = 20

# UCAS course-code shapes: 4-char alphanumeric like T701, VV14, RRK5, 1G23.
# Deliberately strict + deduped to avoid counting incidental strings.
UCAS_RE = re.compile(r"\b(?:[A-Z]{1,3}[0-9]{1,3}[A-Z]?[0-9]?|[0-9][A-Z][0-9]{2})\b")


def fetch(url):
    target = url if re.match(r"^https?://", url) else "https://" + url
    req = urllib.request.Request(target, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as r:
            body = r.read().decode("utf-8", "replace")
            return r.status, body, None
    except urllib.error.HTTPError as e:
        return e.code, "", "HTTP %s" % e.code
    except Exception as e:  # noqa: BLE001 - timeout, DNS, TLS, URLError
        return None, "", "%s: %s" % (type(e).__name__, str(e)[:80])


def classify(status, body):
    """Return (state, candidate, signals) for a fetched page."""
    if status is None:
        return "unreachable", False, {}
    if status in (403, 429):
        return "blocked", False, {}
    if status >= 400:
        return "unreachable", False, {}
    # Structured-list signals (server-rendered only - this is the raw HTML).
    ucas = len(set(m.group(0) for m in UCAS_RE.finditer(body)))
    # Repeated course blocks: the largest count of any class token containing
    # "course" (e.g. class="course", "course-item", "course-list-item").
    block_counts = {}
    for m in re.finditer(r'class="([^"]*\bcourse[a-z-]*\b[^"]*)"', body, re.I):
        block_counts[m.group(1)] = block_counts.get(m.group(1), 0) + 1
    max_blocks = max(block_counts.values()) if block_counts else 0
    # Course detail links.
    course_links = len(re.findall(r'href="[^"]*course[^"]*"', body, re.I))
    signals = {"ucas": ucas, "blocks": max_blocks, "courseLinks": course_links}
    # Conservative candidate rule: a real, parseable per-course list almost
    # always shows MANY UCAS codes, or many repeated course blocks. One or two
    # of either is just navigation/marketing, not a list.
    candidate = ucas >= 15 or max_blocks >= 15
    return "ok", candidate, signals


def main():
    ap = argparse.ArgumentParser(description="Discover live Clearing course lists across universities.")
    ap.add_argument("--table", default=DEFAULT_TABLE)
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    import boto3
    table = boto3.resource("dynamodb").Table(args.table)
    resp = table.scan(ProjectionExpression="providerCode, universityName, clearingPage, participatesInClearing")
    unis = resp.get("Items", [])
    while "LastEvaluatedKey" in resp:
        resp = table.scan(ProjectionExpression="providerCode, universityName, clearingPage, participatesInClearing",
                          ExclusiveStartKey=resp["LastEvaluatedKey"])
        unis.extend(resp.get("Items", []))

    todo = [u for u in unis
            if u.get("participatesInClearing", True) is not False
            and u.get("providerCode") not in EXCLUDE
            and u.get("clearingPage")]
    todo.sort(key=lambda u: u.get("universityName", ""))

    print("Discovery sweep: %d participating universities (excluding Reading, Southampton)"
          % len(todo))
    print("Started %s\n" % datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))

    results = {}

    def work(u):
        status, body, err = fetch(u["clearingPage"])
        state, candidate, signals = classify(status, body)
        return u, status, err, state, candidate, signals

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = [ex.submit(work, u) for u in todo]
        for f in as_completed(futs):
            u, status, err, state, candidate, signals = f.result()
            results[u["providerCode"]] = (u, status, err, state, candidate, signals)

    # Ordered report.
    hdr = "%-6s %-40s %-7s %-12s %-30s %s"
    print(hdr % ("CODE", "UNIVERSITY", "HTTP", "STATE", "SIGNALS", "RESULT"))
    print("-" * 110)
    counts = {"candidate": 0, "ok_nolist": 0, "blocked": 0, "unreachable": 0}
    candidates = []
    for u in todo:
        code = u["providerCode"]
        _, status, err, state, candidate, signals = results[code]
        if state == "blocked":
            counts["blocked"] += 1
            result = "BLOCKED (anti-bot 403/429) - try in a browser"
        elif state == "unreachable":
            counts["unreachable"] += 1
            result = "UNREACHABLE (%s)" % (err or "error")
        elif candidate:
            counts["candidate"] += 1
            candidates.append(code)
            result = "INGEST CANDIDATE - structured list found"
        else:
            counts["ok_nolist"] += 1
            result = "no structured list (landing/JS-driven)"
        sig = "ucas=%s blocks=%s links=%s" % (
            signals.get("ucas", "-"), signals.get("blocks", "-"), signals.get("courseLinks", "-"))
        print(hdr % (code, (u.get("universityName") or "")[:40],
                     str(status or "-"), state, sig, result))

    print("\nSUMMARY")
    print("  Ingest candidates (structured list) : %d" % counts["candidate"])
    print("  Reachable, no structured list       : %d" % counts["ok_nolist"])
    print("  Blocked (403/429)                   : %d" % counts["blocked"])
    print("  Unreachable / error                 : %d" % counts["unreachable"])
    print("  Total attempted                     : %d" % len(todo))
    if candidates:
        print("\n  Candidate provider codes: %s" % ", ".join(candidates))
        print("  (Each still needs a verified bespoke parser before ingestion -")
        print("   a strong signal is NOT a guarantee of a clean parse.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
