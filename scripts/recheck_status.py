#!/usr/bin/env python3
"""UK Clearing Advisor - stored clearingStatus re-check sweep (READ-ONLY).

For every participating university, fetch its stored clearingPage and look for
OPEN / CLOSED text signals, then compare against the stored clearingStatus to
surface entries whose stored status may be STALE (e.g. stored "Open" but the
page reads as closed, like King's College London did).

IMPORTANT - this is advisory only, NOT authoritative:
  * Many university Clearing pages are JavaScript/AJAX-driven, so the real
    status is not in the static HTML this fetches. A missing "closed" signal
    does NOT mean the course is open. Treat every flag as "worth a human
    check", never as ground truth.
  * Writes NOTHING. It only reports. Any status change is a deliberate,
    verified follow-up (update seed.py + the live item), as done for KCL.
"""
import argparse
import re
import sys
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

DEFAULT_TABLE = "uk-clearing-advisor-2027-universities"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
HEADERS = {"User-Agent": UA,
           "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
           "Accept-Language": "en-GB,en;q=0.9"}
FETCH_TIMEOUT = 20

# Signals - deliberately require "clearing" proximity to cut false positives.
CLOSED_RE = re.compile(
    r"clearing[^.]{0,40}(?:is\s+)?(?:now\s+)?closed"
    r"|closed\s+for\s+clearing"
    r"|no\s+(?:clearing\s+)?vacancies"
    r"|not\s+(?:currently\s+)?(?:taking|accepting)"
    r"|fully\s+(?:booked|subscribed)"
    r"|places\s+(?:have\s+)?(?:been\s+)?filled"
    r"|clearing\s+has\s+(?:now\s+)?closed"
    r"|no\s+longer\s+(?:available|accepting|taking)\s+(?:in\s+)?clearing", re.I)
OPEN_RE = re.compile(
    r"clearing\s+(?:is\s+)?(?:now\s+)?open"
    r"|open\s+for\s+clearing"
    r"|now\s+open"
    r"|vacancies\s+available"
    r"|apply\s+(?:now|today)[^.]{0,30}clearing", re.I)


def fetch(url):
    target = url if re.match(r"^https?://", url) else "https://" + url
    req = urllib.request.Request(target, headers=HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as r:
            return r.status, r.read().decode("utf-8", "replace"), None
    except urllib.error.HTTPError as e:
        return e.code, "", "HTTP %s" % e.code
    except Exception as e:  # noqa: BLE001
        return None, "", "%s" % type(e).__name__


def signals(status, body):
    if status is None:
        return "unreachable", False, False
    if status in (403, 429):
        return "blocked", False, False
    if status >= 400:
        return "unreachable", False, False
    txt = re.sub(r"<[^>]+>", " ", body)
    txt = re.sub(r"\s+", " ", txt)
    return "ok", bool(CLOSED_RE.search(txt)), bool(OPEN_RE.search(txt))


def verdict(stored, state, closed_hint, open_hint):
    s = (stored or "").strip().lower()
    stored_open_ish = s not in ("closed",)  # anything not explicitly closed
    if state == "blocked":
        return "UNVERIFIABLE (blocked)"
    if state == "unreachable":
        return "UNVERIFIABLE (page error)"
    if closed_hint and stored_open_ish:
        return "** STALE? stored '%s' but page reads CLOSED **" % (stored or "?")
    if open_hint and s == "closed":
        return "** STALE? stored 'Closed' but page reads OPEN **"
    if closed_hint and s == "closed":
        return "consistent (closed)"
    if open_hint:
        return "consistent (open signal)"
    return "no signal in static HTML (JS-driven? can't tell)"


def main():
    ap = argparse.ArgumentParser(description="Read-only clearingStatus re-check sweep.")
    ap.add_argument("--table", default=DEFAULT_TABLE)
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    import boto3
    table = boto3.resource("dynamodb").Table(args.table)
    resp = table.scan(ProjectionExpression="providerCode, universityName, clearingStatus, clearingPage, participatesInClearing")
    unis = resp.get("Items", [])
    while "LastEvaluatedKey" in resp:
        resp = table.scan(ProjectionExpression="providerCode, universityName, clearingStatus, clearingPage, participatesInClearing",
                          ExclusiveStartKey=resp["LastEvaluatedKey"])
        unis.extend(resp.get("Items", []))

    todo = [u for u in unis
            if u.get("participatesInClearing", True) is not False and u.get("clearingPage")]
    todo.sort(key=lambda u: u.get("universityName", ""))
    print("Status re-check: %d participating universities" % len(todo))
    print("Started %s (READ-ONLY - writes nothing)\n"
          % datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))

    def work(u):
        st, body, err = fetch(u["clearingPage"])
        state, closed_h, open_h = signals(st, body)
        return u, st, state, closed_h, open_h

    res = {}
    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        for f in as_completed([ex.submit(work, u) for u in todo]):
            u, st, state, ch, oh = f.result()
            res[u["providerCode"]] = (u, st, state, ch, oh)

    hdr = "%-7s %-38s %-10s %-6s %s"
    print(hdr % ("CODE", "UNIVERSITY", "STORED", "HTTP", "VERDICT"))
    print("-" * 108)
    stale, unverifiable = [], 0
    for u in todo:
        code = u["providerCode"]
        _, st, state, ch, oh = res[code]
        v = verdict(u.get("clearingStatus"), state, ch, oh)
        if v.startswith("**"):
            stale.append((code, u.get("universityName"), u.get("clearingStatus"), v))
        if v.startswith("UNVERIFIABLE"):
            unverifiable += 1
        print(hdr % (code, (u.get("universityName") or "")[:38],
                     (u.get("clearingStatus") or "?")[:10], str(st or "-"), v))

    print("\nSUMMARY")
    print("  Likely STALE (needs human check): %d" % len(stale))
    for code, name, stored, v in stale:
        print("    - %s %s (stored '%s')" % (code, name, stored))
    print("  Unverifiable (blocked/error)    : %d" % unverifiable)
    print("  Total checked                   : %d" % len(todo))
    print("\n  NOTE: 'no signal in static HTML' is NOT 'open' - JS-driven pages")
    print("  hide their status from this check. Confirm high-stakes cases by hand.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
