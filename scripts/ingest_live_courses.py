#!/usr/bin/env python3
"""UK Clearing Advisor - live Clearing course ingestion (Option B pilot).

Fetches per-course Clearing listings from universities that publish a
machine-readable, SERVER-RENDERED course list, parses them deterministically,
and writes them onto that university's item in the universities DynamoDB
table as a `liveCourses` list plus provenance fields:

    liveCourses           list of {title, degree, ucasCode, url, ...}
    liveCoursesCount      int  (len of liveCourses actually captured)
    liveCoursesSource     str  (the exact page URL scraped)
    liveCoursesFetchedAt  str  (ISO-8601 UTC timestamp of this fetch)
    liveCoursesPartial    bool (True when the page's full list is NOT fully
                                server-rendered and only a subset was captured)
    liveCoursesPartialNote str (student-facing explanation when partial)

DECISION / ACCURACY (see the product's #1 rule - nothing fabricated or
ambiguous shown to students):
  * Only SERVER-RENDERED, structurally-parsed courses are written. No course
    is invented, and counts are taken from the parse, never estimated.
  * Universities whose full list is JavaScript/AJAX-driven (e.g. Reading's
    Sitecore `InClearing` endpoint, Southampton's vacancy search) are captured
    only to the extent their page serves real HTML; the rest is flagged
    `liveCoursesPartial=True` with a note, and the live-page link stays the
    authoritative source in the UI.
  * Clearing vacancies change hour-to-hour on Results Day; every write carries
    a fetchedAt timestamp so the UI can show "fetched <time> - confirm with
    the university".

Reproducible: re-running re-fetches and overwrites with a fresh timestamp.
No boto3 list-marshalling surprises - uses the boto3 resource (Table) API.
"""
import argparse
import html
import json
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

DEFAULT_TABLE = "uk-clearing-advisor-2027-universities"

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
HEADERS = {
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-GB,en;q=0.9",
}
FETCH_TIMEOUT = 25


def fetch(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as r:
        return r.read().decode("utf-8", "replace")


def clean(text):
    """Strip tags, unescape entities, collapse whitespace."""
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


# ---------------------------------------------------------------------------
# Manchester - fully server-rendered <ul class="course-list undergraduate">.
# Each <li id="UID"><a href="../course/?uid=UID">
#   <div class="title">NAME<span class="screenreader"> BA</span></div>
#   <div class="degree">BA</div>
#   <div class="ucas"><div class="ucas-code">CODE</div></div></a></li>
# ---------------------------------------------------------------------------
MANCHESTER_URL = "https://www.manchester.ac.uk/study/undergraduate/applying/clearing/home/"


def parse_manchester(page_html):
    # Isolate the undergraduate list so a (separate) international/postgraduate
    # list can never leak in.
    m = re.search(r'<ul class="course-list undergraduate">(.*?)</ul>',
                  page_html, re.DOTALL)
    if not m:
        raise RuntimeError("Manchester: undergraduate course-list container not found")
    block = m.group(1)
    courses = []
    for li in re.finditer(r"<li\b[^>]*>(.*?)</li>", block, re.DOTALL):
        inner = li.group(1)
        href = re.search(r'href="([^"]+)"', inner)
        title_div = re.search(r'<div class="title">(.*?)</div>', inner, re.DOTALL)
        degree_div = re.search(r'<div class="degree">(.*?)</div>', inner, re.DOTALL)
        ucas_div = re.search(r'<div class="ucas-code">(.*?)</div>', inner, re.DOTALL)
        if not title_div:
            continue
        # Remove the screenreader span (it duplicates the degree) before cleaning.
        title_html = re.sub(r'<span class="screenreader">.*?</span>', "",
                            title_div.group(1), flags=re.DOTALL)
        title = clean(title_html)
        if not title:
            continue
        course = {"title": title}
        if degree_div:
            deg = clean(degree_div.group(1))
            if deg:
                course["degree"] = deg
        if ucas_div:
            code = clean(ucas_div.group(1))
            if code:
                course["ucasCode"] = code
        if href:
            course["url"] = urllib.parse.urljoin(MANCHESTER_URL, href.group(1))
        courses.append(course)
    return courses


# ---------------------------------------------------------------------------
# Reading - only page 1 (10 courses) is server-rendered; the full ~297 come
# from the Sitecore /api/sitecore/Clearing/InClearing AJAX endpoint (not a
# stable public contract). We capture ONLY the server-rendered <div class=
# "course"> blocks and mark the result partial.
#   <div class="course"><span class="type">..</span>
#     <h3 class="course-title"><a href="..">NAME (BSc)</a></h3>
#     <div class="requirements">
#       <div class="a-level-offer"><span>..</span><span class="value">BCC</span></div>
#       <div class="btec-requirements">..<span class="value">DDM</span></div>
#       <div class="ib-requirments">..<span class="value"> 26 points</span></div>
#       <div class="additional-requirements">..<span class="value">..</span></div>
# ---------------------------------------------------------------------------
READING_URL = "https://www.reading.ac.uk/clearing/available-courses"


def _reading_value(block, cls):
    m = re.search(r'<div class="%s">(.*?)</div>\s*</div>' % re.escape(cls),
                  block, re.DOTALL)
    if not m:
        m = re.search(r'<div class="%s">(.*?)</div>' % re.escape(cls),
                      block, re.DOTALL)
    if not m:
        return None
    val = re.search(r'<span class="value">(.*?)</span>', m.group(1), re.DOTALL)
    return clean(val.group(1)) if val else None


def parse_reading(page_html):
    courses = []
    for cm in re.finditer(r'<div class="course">(.*?)</div>\s*</div>\s*</div>',
                          page_html, re.DOTALL):
        block = cm.group(1)
        title_a = re.search(r'<h3 class="course-title">\s*<a href="([^"]*)"[^>]*>(.*?)</a>',
                            block, re.DOTALL)
        if not title_a:
            continue
        title = clean(title_a.group(2))
        if not title:
            continue
        course = {"title": title,
                  "url": urllib.parse.urljoin(READING_URL, title_a.group(1))}
        type_m = re.search(r'<span class="type">(.*?)</span>', block, re.DOTALL)
        if type_m:
            t = clean(type_m.group(1))
            if t:
                course["type"] = t
        for key, cls in (("aLevel", "a-level-offer"),
                         ("btec", "btec-requirements"),
                         ("ib", "ib-requirments"),
                         ("additional", "additional-requirements")):
            v = _reading_value(block, cls)
            if v:
                course[key] = v
        courses.append(course)
    return courses


# ---------------------------------------------------------------------------
SITES = {
    "0094": {  # University of Manchester
        "name": "University of Manchester",
        "url": MANCHESTER_URL,
        "parser": parse_manchester,
        "partial": False,
        "partial_note": None,
    },
    "0109": {  # University of Reading
        "name": "University of Reading",
        "url": READING_URL,
        "parser": parse_reading,
        "partial": True,
        "partial_note": ("A sample of Reading's Clearing courses is shown here. "
                         "Reading publishes its full course list via a live "
                         "search on its own page - open it for every available "
                         "course."),
    },
}


def write_ddb(table_name, provider_code, site, courses, fetched_at):
    import boto3
    from decimal import Decimal  # noqa: F401 (kept for clarity if numbers added)
    table = boto3.resource("dynamodb").Table(table_name)
    expr_names = {
        "#lc": "liveCourses", "#cnt": "liveCoursesCount",
        "#src": "liveCoursesSource", "#at": "liveCoursesFetchedAt",
        "#part": "liveCoursesPartial",
    }
    expr_vals = {
        ":lc": courses, ":cnt": len(courses),
        ":src": site["url"], ":at": fetched_at,
        ":part": bool(site["partial"]),
    }
    set_parts = ["#lc = :lc", "#cnt = :cnt", "#src = :src",
                 "#at = :at", "#part = :part"]
    if site["partial"] and site["partial_note"]:
        expr_names["#pn"] = "liveCoursesPartialNote"
        expr_vals[":pn"] = site["partial_note"]
        set_parts.append("#pn = :pn")
    table.update_item(
        Key={"providerCode": provider_code},
        UpdateExpression="SET " + ", ".join(set_parts),
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_vals,
    )


def main():
    ap = argparse.ArgumentParser(description="Ingest live Clearing course listings.")
    ap.add_argument("--table", default=DEFAULT_TABLE)
    ap.add_argument("--only", help="comma-separated provider codes (default: all)")
    ap.add_argument("--dry-run", action="store_true",
                    help="fetch + parse + print counts; do NOT write to DynamoDB")
    args = ap.parse_args()

    codes = [c.strip() for c in args.only.split(",")] if args.only else list(SITES)
    fetched_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    overall_ok = True

    for code in codes:
        site = SITES.get(code)
        if not site:
            print("SKIP %s: no parser configured" % code)
            continue
        try:
            page = fetch(site["url"])
            courses = site["parser"](page)
        except Exception as e:  # noqa: BLE001
            overall_ok = False
            print("ERROR %s (%s): %s: %s" % (code, site["name"],
                                             type(e).__name__, e))
            continue
        print("%s  %s  ->  %d courses parsed  (partial=%s)  from %s"
              % (code, site["name"], len(courses), site["partial"], site["url"]))
        # Show first/last as a sanity check (verify, never estimate).
        if courses:
            print("   first: %s" % json.dumps(courses[0], ensure_ascii=False))
            print("   last : %s" % json.dumps(courses[-1], ensure_ascii=False))
        if not courses:
            overall_ok = False
            print("   WARNING: 0 courses parsed - not writing (page markup may have changed)")
            continue
        if args.dry_run:
            print("   [dry-run] not written")
            continue
        try:
            write_ddb(args.table, code, site, courses, fetched_at)
            print("   written to %s at %s" % (args.table, fetched_at))
        except Exception as e:  # noqa: BLE001
            overall_ok = False
            print("   ERROR writing to DynamoDB: %s: %s" % (type(e).__name__, e))

    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
