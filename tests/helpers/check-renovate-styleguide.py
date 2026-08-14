#!/usr/bin/env python3
"""Assert renovate.json actually keeps the API styleguide pin fresh (#689 AC 7).

Two checks, selected by argv[1]:

  manager   — exactly one customManager covers the shipped shim, and its
              matchStrings regex really matches the shim's current content,
              capturing an exact `styleguide-vX.Y.Z` tag. Also checks the
              versioning regex both orders styleguide tags and excludes
              unrelated ones (this repo also carries a `docs-latest` tag).

  grouping  — the packageRule that ends up governing the pin does NOT put it in
              the batched `github-actions` group.

Why a script rather than inline bats: Renovate regexes are JS-flavoured
(`(?<name>…)`), Python's `re` wants `(?P<name>…)`, and doing that translation
inside a bats heredoc made the quoting unreadable. Executing the shipped regex
is the point — a manager whose pattern silently stops matching produces no PR,
and "no PR" is not an error Renovate reports anywhere. The pin would then sit at
its original version forever, in every bootstrapped repo, with CI fully green.

Exits 0 and prints a marker on success; exits 1 with a diagnostic on failure.
"""

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SHIM_PATH = "development/skills/bootstrap/templates/common/.spectral.yaml"
DEP = "timo-jakob/timos-claude-code-plugins"


def js_to_py(pattern: str) -> str:
    """Renovate uses JS named groups; Python's re spells them differently."""
    return pattern.replace("(?<", "(?P<")


def load_config() -> dict:
    return json.loads((REPO_ROOT / "renovate.json").read_text())


def check_manager() -> None:
    cfg = load_config()
    managers = [
        m
        for m in cfg.get("customManagers", [])
        if any(
            re.search(fp.strip("/"), SHIM_PATH)
            for fp in m.get("managerFilePatterns", [])
        )
    ]
    if len(managers) != 1:
        sys.exit(
            f"expected exactly 1 customManager covering {SHIM_PATH}, found {len(managers)}"
        )
    manager = managers[0]

    shim = (REPO_ROOT / SHIM_PATH).read_text()
    match = re.search(js_to_py(manager["matchStrings"][0]), shim)
    if not match:
        sys.exit("the manager's matchStrings does not match the shipped shim")

    current = match.group("currentValue")
    if not re.fullmatch(r"styleguide-v\d+\.\d+\.\d+", current):
        sys.exit(f"currentValue is not an exact styleguide tag: {current}")

    if manager.get("datasourceTemplate") != "github-tags":
        sys.exit(f"unexpected datasource: {manager.get('datasourceTemplate')}")

    versioning = js_to_py(manager["versioningTemplate"].removeprefix("regex:"))
    if not re.match(versioning, "styleguide-v1.2.10"):
        sys.exit("versioning regex does not parse a styleguide tag")
    if re.match(versioning, "docs-latest"):
        sys.exit("versioning regex does not exclude non-styleguide tags")

    print("ok")


def check_grouping() -> None:
    rules = load_config()["packageRules"]

    def applies(rule: dict) -> bool:
        if "custom.regex" not in rule.get("matchManagers", []):
            return False
        names = rule.get("matchDepNames")
        return names is None or DEP in names

    # Later packageRules override earlier ones, so the LAST match is the winner.
    winner = None
    for rule in rules:
        if applies(rule):
            winner = rule

    if winner is None:
        sys.exit("no packageRule governs the styleguide pin")
    if winner.get("groupName") == "github-actions":
        sys.exit("the styleguide pin resolves into the github-actions group")

    print(winner.get("groupName", "<ungrouped>"))


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("manager", "grouping"):
        sys.exit("usage: check-renovate-styleguide.py <manager|grouping>")
    {"manager": check_manager, "grouping": check_grouping}[sys.argv[1]]()
