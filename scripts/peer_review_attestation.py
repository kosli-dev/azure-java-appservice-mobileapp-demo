#!/usr/bin/env python3
"""Collect peer-review facts about the pull request that produced a merge commit.

The script only *reports facts*. Whether those facts amount to a peer review is decided by
the jq evaluation rules on the `peer-review` custom attestation type in Kosli:

    .pull_request_url != null
    (.distinct_approvers >= 2) or (.independent_approval == true)

This mirrors the "never alone" code-review control Kosli ships in
https://github.com/kosli-dev/control-actions : a change is peer reviewed if two different
people approved it, or if at least one approver did not contribute commits to the branch.

Usage:
    python3 scripts/peer_review_attestation.py \
        --repo owner/name --commit "$GITHUB_SHA" --out peer-review.json
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"


def get(path: str, token: str):
    request = urllib.request.Request(
        f"{API}{path}",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "kosli-demo-peer-review",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        print(f"GitHub API {path} -> {exc.code} {exc.reason}", file=sys.stderr)
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA", ""))
    parser.add_argument("--out", default="peer-review.json")
    args = parser.parse_args()

    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        print("GITHUB_TOKEN is required", file=sys.stderr)
        return 1
    if not args.repo or not args.commit:
        print("--repo and --commit are required", file=sys.stderr)
        return 1

    data = {
        "commit": args.commit,
        "pull_request_url": None,
        "pull_request_number": None,
        "author": None,
        "approvers": [],
        "distinct_approvers": 0,
        "independent_approval": False,
        "committers": [],
        "changed_files": None,
    }

    pulls = get(f"/repos/{args.repo}/commits/{args.commit}/pulls", token) or []
    merged = [pr for pr in pulls if pr.get("merged_at")] or pulls
    if merged:
        pr = merged[0]
        number = pr["number"]
        data["pull_request_url"] = pr.get("html_url")
        data["pull_request_number"] = number
        data["author"] = (pr.get("user") or {}).get("login")
        data["changed_files"] = pr.get("changed_files")

        reviews = get(f"/repos/{args.repo}/pulls/{number}/reviews", token) or []
        approvers = []
        for review in reviews:
            if review.get("state") == "APPROVED":
                login = (review.get("user") or {}).get("login")
                if login and login not in approvers:
                    approvers.append(login)

        commits = get(f"/repos/{args.repo}/pulls/{number}/commits", token) or []
        committers = []
        for commit in commits:
            for key in ("author", "committer"):
                login = ((commit.get(key) or {}) or {}).get("login")
                if login and login not in committers:
                    committers.append(login)

        data["approvers"] = approvers
        data["distinct_approvers"] = len(approvers)
        data["committers"] = committers
        data["independent_approval"] = any(a not in committers for a in approvers)

    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")

    print(json.dumps(data, indent=2))
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
