#!/usr/bin/env python3
"""Change-risk gate for Terraform plans.

Reads `terraform show -json` output for one or more roots and blocks when:
  * more than --max-destroy resources are destroyed or replaced (summed across roots), or
  * any change touches a resource tagged critical (a "critical" key with a truthy value
    anywhere in before/after, including JSON-encoded strings such as jsonencode(var.tags),
    or "critical" in a tags/labels list).

Prints a markdown report on stdout. Exit 0 = pass / overridden / report-only, 1 = blocked.
Usage: risk-check.py [--max-destroy N] [--override] [--report-only] root=plan.json ...
"""
import argparse
import json
import sys

FALSY = (None, False, 0, "", "0", "false", "False", "no")


def has_critical(obj, depth=0):
    if depth > 20:
        return False
    if isinstance(obj, str):
        s = obj.strip()
        if s[:1] in ("{", "["):
            try:
                return has_critical(json.loads(s), depth + 1)
            except ValueError:
                return False
        return False
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "critical" and v not in FALSY:
                return True
            if k in ("tags", "labels") and isinstance(v, list) and "critical" in v:
                return True
            if has_critical(v, depth + 1):
                return True
        return False
    if isinstance(obj, list):
        return any(has_critical(x, depth + 1) for x in obj)
    return False


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--max-destroy", type=int, default=2)
    p.add_argument("--override", action="store_true")
    p.add_argument("--report-only", action="store_true")
    p.add_argument("plans", nargs="+", metavar="root=plan.json")
    a = p.parse_args()

    destroyed, rows, critical = 0, [], 0
    for spec in a.plans:
        root, path = spec.split("=", 1)
        with open(path) as f:
            plan = json.load(f)
        for rc in plan.get("resource_changes", []):
            actions = rc["change"]["actions"]
            if actions in (["no-op"], ["read"]):
                continue
            destructive = "delete" in actions
            crit = has_critical(rc["change"].get("before")) or has_critical(rc["change"].get("after"))
            destroyed += destructive
            critical += crit
            if destructive or crit:
                kind = "replace" if len(actions) == 2 else actions[0]
                rows.append(f"| `{root}` | `{rc['address']}` | {kind} | {'yes' if crit else ''} |")

    reasons = []
    if destroyed > a.max_destroy:
        reasons.append(f"{destroyed} resources destroyed or replaced (limit {a.max_destroy})")
    if critical:
        reasons.append(f"{critical} change(s) touch resources tagged `critical`")

    if not reasons:
        verdict = "PASS"
    elif a.override:
        verdict = "OVERRIDDEN by the `override-risk` label"
    elif a.report_only:
        verdict = "WOULD BLOCK (report only on `main`; enforced on the PR)"
    else:
        verdict = "<b>BLOCKED</b>: add the `override-risk` label to proceed"

    print(f"### Change risk: {verdict}\n")
    for r in reasons:
        print(f"- {r}")
    if rows:
        print(f"\n<details><summary>{len(rows)} destructive or critical change(s)</summary>\n")
        print("| root | address | action | critical |\n|---|---|---|---|")
        print("\n".join(rows))
        print("\n</details>")
    print()
    return 1 if reasons and not (a.override or a.report_only) else 0


if __name__ == "__main__":
    sys.exit(main())
