#!/usr/bin/env python3
"""Deploy the UK Clearing Advisor 2027 frontend with content-versioned assets.

Why: browsers were serving a stale app.js because the HTML referenced
/app.js and /styles.css with no version and the objects had no Cache-Control,
so a returning browser kept old JS even after a CloudFront invalidation. This
script makes the HTML the cache anchor:

  - JS/CSS are content-hashed and referenced as `/app.js?v=<hash>`; the hashed
    assets are uploaded with a long, immutable Cache-Control. New content =>
    new hash => new URL the browser has never cached => guaranteed fresh.
  - HTML is uploaded with `Cache-Control: no-cache` so the browser always
    revalidates it and therefore always sees the current `?v=<hash>` refs.
  - A CloudFront invalidation is issued for the HTML + asset base paths so the
    edge is fresh for the current deploy too.

The repo's index.html/faq.html keep plain `/app.js` refs; the `?v=<hash>` is
injected at deploy time only (source stays clean, deploy is always correct).

Bucket + distribution id resolve from CLI args, then env (SITE_BUCKET /
CF_DIST_ID), then `terraform output`.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRONTEND = os.path.join(ROOT, "frontend")

VERSIONED_ASSETS = ["app.js", "styles.css"]  # content-hashed
HTML_FILES = ["index.html", "faq.html", "geo-blocked.html"]
PLAIN_FILES = ["robots.txt", "sitemap.xml"]

IMMUTABLE = "public, max-age=31536000, immutable"
NO_CACHE = "no-cache"
CONTENT_TYPES = {
    ".js": "application/javascript", ".css": "text/css", ".html": "text/html",
    ".txt": "text/plain", ".xml": "application/xml",
}


def sh(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def content_type(path):
    return CONTENT_TYPES.get(os.path.splitext(path)[1], "application/octet-stream")


def short_hash(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()[:10]


def resolve(args):
    bucket = args.bucket or os.environ.get("SITE_BUCKET")
    dist = args.distribution_id or os.environ.get("CF_DIST_ID")
    if not (bucket and dist):
        tfdir = os.path.join(ROOT, "terraform")
        try:
            outs = json.loads(sh("terraform", f"-chdir={tfdir}", "output", "-json"))
            bucket = bucket or outs.get("site_bucket", {}).get("value")
            dist = dist or outs.get("cloudfront_distribution_id", {}).get("value")
        except Exception:
            pass
    if not (bucket and dist):
        sys.exit("Could not resolve bucket/distribution id. Pass --bucket and "
                 "--distribution-id, or set SITE_BUCKET / CF_DIST_ID.")
    return bucket, dist


def upload(local, bucket, key, cache, region):
    sh("aws", "s3", "cp", local, f"s3://{bucket}/{key}", "--region", region,
       "--content-type", content_type(local), "--cache-control", cache)
    print(f"  uploaded {key}  ({cache})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bucket")
    ap.add_argument("--distribution-id")
    ap.add_argument("--region", default="eu-west-1")
    args = ap.parse_args()
    bucket, dist = resolve(args)
    print(f"Deploying frontend -> s3://{bucket} (CloudFront {dist})")

    # 1) hash + upload versioned assets (immutable long cache)
    versions = {}
    for name in VERSIONED_ASSETS:
        p = os.path.join(FRONTEND, name)
        if not os.path.exists(p):
            continue
        versions[name] = short_hash(p)
        upload(p, bucket, name, IMMUTABLE, args.region)
    print("  asset versions:", versions)

    # 2) rewrite HTML refs -> ?v=<hash>, upload with no-cache
    with tempfile.TemporaryDirectory() as tmp:
        for name in HTML_FILES:
            p = os.path.join(FRONTEND, name)
            if not os.path.exists(p):
                continue
            html = open(p, encoding="utf-8").read()
            for asset, h in versions.items():
                html = html.replace(f'"/{asset}"', f'"/{asset}?v={h}"')
            out = os.path.join(tmp, name)
            open(out, "w", encoding="utf-8").write(html)
            upload(out, bucket, name, NO_CACHE, args.region)

    # 3) other static files (short cache)
    for name in PLAIN_FILES:
        p = os.path.join(FRONTEND, name)
        if os.path.exists(p):
            upload(p, bucket, name, "public, max-age=3600", args.region)

    # 4) invalidate HTML + asset base paths (assets also busted by ?v, but this
    #    keeps the edge fresh for this deploy)
    paths = ["/", "/index.html", "/faq.html", "/geo-blocked.html",
             "/app.js", "/styles.css"]
    cid = sh("aws", "cloudfront", "create-invalidation", "--distribution-id", dist,
             "--paths", *paths, "--query", "Invalidation.Id", "--output", "text")
    print(f"  CloudFront invalidation: {cid}")
    print("Done.")


if __name__ == "__main__":
    main()
