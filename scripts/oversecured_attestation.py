#!/usr/bin/env python3
"""Turn an Oversecured scan report into attestation data for Kosli.

The script only *reports facts* - whether the scan is acceptable is decided by the jq
evaluation rules on the `oversecured` custom attestation type in Kosli.

`header` is copied verbatim, because the rules read `.header.scan.status` and
`.header.severityCounts`. Everything else is reduced to one line per finding: the full
report goes to the Evidence Vault as an attachment, and is far too large to attest.

Usage:
    python3 scripts/oversecured_attestation.py \
        --report oversecured/report-pass.json \
        --report-url "$RUN_URL" \
        --out oversecured.json
"""

import argparse
import json
import sys


def finding(vulnerability: dict) -> dict:
    category = vulnerability.get("category") or {}
    return {
        "id": vulnerability.get("id", ""),
        "hash": vulnerability.get("hash", ""),
        "severity": category.get("severity", "unknown"),
        "title": category.get("descriptionTitle", ""),
        "files": sorted({block.get("file", "") for block in vulnerability.get("code") or []}),
        "false_positive": bool(vulnerability.get("falsePositive")),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", default="oversecured/report-pass.json")
    parser.add_argument("--report-url", default="")
    parser.add_argument("--out", default="oversecured.json")
    args = parser.parse_args()

    try:
        with open(args.report, encoding="utf-8") as handle:
            report = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"could not read Oversecured report {args.report}: {exc}", file=sys.stderr)
        return 1

    header = report.get("header")
    if not isinstance(header, dict):
        print(f"{args.report} has no header object - is it an Oversecured report?", file=sys.stderr)
        return 1

    findings = [finding(v) for v in report.get("vulnerabilities") or []]

    data = {
        "header": header,
        "report_url": args.report_url,
        "findings": sorted(findings, key=lambda f: (f["severity"], f["title"])),
    }

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")

    scan = header.get("scan") or {}
    app = header.get("app") or {}
    counts = header.get("severityCounts") or {}
    print(f"{app.get('name', '?')} ({app.get('platform', '?')}): scan {scan.get('status', '?')}, "
          f"{len(findings)} findings")
    for severity in ("critical", "high", "medium", "low"):
        print(f"  {severity}: {counts.get(severity, 0)}")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
