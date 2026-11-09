#!/usr/bin/env python3
"""Makes the checkboxes of the pinned Roadmap issue match the real state of each issue.

A box is ticked if and only if its issue is closed.

    scripts/sync-roadmap.py            fix the boxes
    scripts/sync-roadmap.py --check    change nothing, exit 1 if a box is wrong

It needs the gh tool. Log in with `gh auth login`, or set GH_TOKEN.
"""
import json
import os
import re
import subprocess
import sys

REPO = os.environ.get("GITHUB_REPOSITORY", "chaitanya-ramji/trashpanda")
TRACKING_TITLE = "Roadmap"
LINE = re.compile(r"^- \[( |x)\] #(\d+)(.*)$", re.M)


def rewrite(body, closed):
    """Returns the body with every box set from `closed` (a set of issue numbers), and the list of changes."""
    changes = []

    def fix(m):
        number = int(m.group(2))
        wanted = "x" if number in closed else " "
        if m.group(1) != wanted:
            changes.append((number, m.group(1), wanted))
        return f"- [{wanted}] #{number}{m.group(3)}"

    return LINE.sub(fix, body), changes


def gh(*args, stdin=None):
    result = subprocess.run(["gh", *args], capture_output=True, text=True, input=stdin)
    if result.returncode != 0:
        sys.exit(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()}")
    return result.stdout


def main():
    check = "--check" in sys.argv
    issues = json.loads(gh("issue", "list", "--repo", REPO, "--state", "all", "--limit", "500",
                           "--json", "number,state,title"))
    closed = {i["number"] for i in issues if i["state"] == "CLOSED"}
    tracking = [i for i in issues if i["title"] == TRACKING_TITLE]
    if len(tracking) != 1:
        sys.exit(f"Expected one issue titled '{TRACKING_TITLE}', found {len(tracking)}")
    number = tracking[0]["number"]

    body = gh("api", f"repos/{REPO}/issues/{number}", "--jq", ".body")
    new_body, changes = rewrite(body, closed)
    if not changes:
        print(f"Roadmap #{number}: all boxes are correct.")
        return 0
    for n, old, new in changes:
        print(f"  #{n}: [{old}] -> [{new}]")
    if check:
        print(f"Roadmap #{number}: {len(changes)} box(es) are wrong.")
        return 1
    gh("issue", "edit", str(number), "--repo", REPO, "--body-file", "-", stdin=new_body)
    print(f"Roadmap #{number}: fixed {len(changes)} box(es).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
