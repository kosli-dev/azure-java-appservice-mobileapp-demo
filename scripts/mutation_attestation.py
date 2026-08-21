#!/usr/bin/env python3
"""Turn a PIT (pitest) XML report into attestation data for Kosli.

The script only *reports facts* - whether the mutation score is acceptable is decided by
the jq evaluation rules on the `mutation-testing` custom attestation type in Kosli.

Usage:
    python3 scripts/mutation_attestation.py \
        --report target/pit-reports/mutations.xml \
        --threshold 85 \
        --report-url "$RUN_URL" \
        --out mutation-testing.json
"""

import argparse
import json
import sys
import xml.etree.ElementTree as ET

KILLED_STATUSES = {"KILLED", "TIMED_OUT"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", default="target/pit-reports/mutations.xml")
    parser.add_argument("--threshold", type=float, default=85.0)
    parser.add_argument("--report-url", default="")
    parser.add_argument("--out", default="mutation-testing.json")
    args = parser.parse_args()

    try:
        root = ET.parse(args.report).getroot()
    except (OSError, ET.ParseError) as exc:
        print(f"could not read PIT report {args.report}: {exc}", file=sys.stderr)
        return 1

    counts: dict[str, int] = {}
    survivors = []
    for mutation in root.iter("mutation"):
        status = (mutation.get("status") or "UNKNOWN").upper()
        counts[status] = counts.get(status, 0) + 1
        if status in {"SURVIVED", "NO_COVERAGE"}:
            survivors.append(
                {
                    "class": (mutation.findtext("mutatedClass") or "").strip(),
                    "method": (mutation.findtext("mutatedMethod") or "").strip(),
                    "line": int((mutation.findtext("lineNumber") or "0").strip() or 0),
                    "mutator": (mutation.findtext("mutator") or "").rsplit(".", 1)[-1],
                    "status": status,
                    "description": (mutation.findtext("description") or "").strip(),
                }
            )

    total = sum(counts.values())
    killed = counts.get("KILLED", 0) + counts.get("TIMED_OUT", 0)
    score = round(killed / total * 100, 1) if total else 0.0

    data = {
        "tool": "pitest",
        "total_mutations": total,
        "killed": counts.get("KILLED", 0),
        "timed_out": counts.get("TIMED_OUT", 0),
        "survived": counts.get("SURVIVED", 0),
        "no_coverage": counts.get("NO_COVERAGE", 0),
        "mutation_score": score,
        "threshold": args.threshold,
        "report_url": args.report_url,
        # Kept short on purpose - the full HTML report goes to the Evidence Vault as an attachment.
        "surviving_mutants": sorted(survivors, key=lambda m: (m["class"], m["line"]))[:25],
    }

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")

    verdict = "meets" if score >= args.threshold else "BELOW"
    print(f"mutation score {score}% {verdict} threshold {args.threshold}% ({killed}/{total} mutants killed)")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
