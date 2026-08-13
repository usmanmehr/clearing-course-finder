#!/usr/bin/env python3
"""Package each Lambda as a zip (index.mjs + shared.mjs). No node/npm needed;
handlers use only the AWS SDK v3 bundled in the Node.js 22 runtime."""
import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LAMBDA_DIR = os.path.join(ROOT, "lambda")
SHARED = os.path.join(LAMBDA_DIR, "shared", "shared.mjs")
# shared.mjs re-exports the pure grading/matching logic from grading.mjs via
# a relative import, so both files must ship together in every zip that
# includes shared.mjs - grading.mjs alone in the zip is not enough.
GRADING = os.path.join(LAMBDA_DIR, "shared", "grading.mjs")
OUT = os.path.join(ROOT, "build")
FUNCTIONS = ["SearchCourses", "GetSubjects", "GetUniversities", "GetScholarships",
             "GenerateExport", "DailyScraper", "WarmUp", "ScheduleManager"]
# Health is standalone (no shared.mjs dependency - deliberately does not use
# checkOriginSecret, see lambda/Health/index.mjs for why), so it is zipped
# without shared.mjs rather than via the FUNCTIONS loop.
# CostReporter is also standalone - it's not API-facing (EventBridge-only,
# like WarmUp/ScheduleManager) and only needs the Cost Explorer + CloudWatch
# SDK clients, no shared.mjs helpers.
STANDALONE_FUNCTIONS = ["Health", "CostReporter"]


def build():
    os.makedirs(OUT, exist_ok=True)
    for fn in FUNCTIONS:
        src = os.path.join(LAMBDA_DIR, fn, "index.mjs")
        zip_path = os.path.join(OUT, fn + ".zip")
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
            z.write(src, "index.mjs")
            z.write(SHARED, "shared.mjs")
            z.write(GRADING, "grading.mjs")
        print("Built %s (%d bytes)" % (zip_path, os.path.getsize(zip_path)))
    for fn in STANDALONE_FUNCTIONS:
        src = os.path.join(LAMBDA_DIR, fn, "index.mjs")
        zip_path = os.path.join(OUT, fn + ".zip")
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
            z.write(src, "index.mjs")
        print("Built %s (%d bytes)" % (zip_path, os.path.getsize(zip_path)))

    # CourseIngest is a PYTHON 3.12 Lambda that reuses the verified scrapers in
    # scripts/ingest_live_courses.py (handler = ingest_live_courses.handler).
    # Packaging the exact same file used by the CLI means there is no second,
    # unverified copy of the parsing logic. boto3 is in the Lambda runtime.
    ci_src = os.path.join(ROOT, "scripts", "ingest_live_courses.py")
    ci_zip = os.path.join(OUT, "CourseIngest.zip")
    with zipfile.ZipFile(ci_zip, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(ci_src, "ingest_live_courses.py")
    print("Built %s (%d bytes)" % (ci_zip, os.path.getsize(ci_zip)))


if __name__ == "__main__":
    build()
