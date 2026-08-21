#!/usr/bin/env python3
"""Import a SonarQube quality-gate report and stamp it with this build's context.

In this demo the report is a canned file under sonar/ (see the README for why). In a real
pipeline you would either:

  * run the Sonar scanner and use `kosli attest sonar`, which pulls the quality gate result
    straight from SonarQube Cloud / Server, or
  * fetch api/qualitygates/project_status from your SonarQube server and attest the response
    with the same custom attestation type used here.

Either way the *evaluation* happens in Kosli, from the jq rules on the attestation type.

Usage:
    python3 scripts/sonar_attestation.py --variant pass --commit "$GITHUB_SHA" \
        --out sonar-quality-gate.json
"""

import argparse
import datetime as dt
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", choices=["pass", "fail"], default="pass")
    parser.add_argument("--commit", default="unknown")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--out", default="sonar-quality-gate.json")
    args = parser.parse_args()

    source = HERE / "sonar" / f"quality-gate-{args.variant}.json"
    report = json.loads(source.read_text(encoding="utf-8"))

    report["analysis"]["revision"] = args.commit
    report["analysis"]["date"] = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+0000")
    report["project"]["branch"] = args.branch

    out = pathlib.Path(args.out)
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    status = report["projectStatus"]["status"]
    failing = [c["metricKey"] for c in report["projectStatus"]["conditions"] if c["status"] != "OK"]
    print(f"imported {source.name}: quality gate {status}")
    if failing:
        print("failing conditions: " + ", ".join(failing))
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
