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
    """Renovate uses JS named groups; Python's re spells them differently.

    Guarded against lookbehinds: a blind `(?<` -> `(?P<` rewrite corrupts
    `(?<=...)` / `(?<!...)` into the uncompilable `(?P<=` / `(?P<!`, turning a
    coverage assertion into a traceback that reads like a config error.
    """
    return re.sub(r"\(\?<(?![=!])", "(?P<", pattern)


def load_config() -> dict:
    return json.loads((REPO_ROOT / "renovate.json").read_text())


def styleguide_manager(cfg: dict) -> dict:
    """The single customManager covering the shipped shim."""
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
    return managers[0]


def check_manager() -> None:
    manager = styleguide_manager(load_config())

    # Every matchStrings entry must match the shim, not just the first: an entry
    # that silently stops matching produces no PR, and "no PR" is not an error
    # Renovate reports anywhere.
    shim = (REPO_ROOT / SHIM_PATH).read_text()
    for i, pattern in enumerate(manager["matchStrings"]):
        match = re.search(js_to_py(pattern), shim)
        if not match:
            sys.exit(f"matchStrings[{i}] does not match the shipped shim")
        current = match.group("currentValue")
        if not re.fullmatch(r"styleguide-v\d+\.\d+\.\d+", current):
            sys.exit(f"matchStrings[{i}] currentValue is not an exact tag: {current}")

    if manager.get("datasourceTemplate") != "github-tags":
        sys.exit(f"unexpected datasource: {manager.get('datasourceTemplate')}")

    # Binds the manager to the packageRule that keeps it out of the batched
    # GitHub Actions PR. Without this, renaming depNameTemplate leaves BOTH
    # checks green while the pin silently rejoins that batch.
    if manager.get("depNameTemplate") != DEP:
        sys.exit(f"unexpected depNameTemplate: {manager.get('depNameTemplate')}")

    versioning = js_to_py(manager["versioningTemplate"].removeprefix("regex:"))
    parsed = re.match(versioning, "styleguide-v1.2.10")
    if not parsed:
        sys.exit("versioning regex does not parse a styleguide tag")
    # Parsing is not ordering: Renovate needs the named components to compare
    # versions, so a regex that matched but captured nothing would sort nothing.
    if not {"major", "minor", "patch"} <= set(parsed.groupdict()):
        sys.exit("versioning regex does not expose major/minor/patch groups")
    if re.match(versioning, "docs-latest"):
        sys.exit("versioning regex does not exclude non-styleguide tags")

    # The pin must be bumped everywhere it is quoted, or the repo-wide sweep in
    # tests/api-styleguide-ruleset.bats reds every bump PR on arrival.
    for site in ("styleguide/spectral/ruleset.yaml", "docs/how-to/adopt-the-api-styleguide.md"):
        text = (REPO_ROOT / site).read_text()
        if "cdn.jsdelivr.net" not in text:
            continue
        if not any(re.search(fp.strip("/"), site) for fp in manager["managerFilePatterns"]):
            sys.exit(f"{site} quotes the pin but no managerFilePatterns entry covers it")

    print("ok")


def check_grouping() -> None:
    cfg = load_config()
    rules = cfg["packageRules"]
    # Derive the dep from the manager rather than the constant, so the two halves
    # of renovate.json cannot drift apart with both checks green.
    dep = styleguide_manager(cfg).get("depNameTemplate", DEP)

    # Selectors this model understands. Anything else means the config grew a
    # narrowing key the model cannot evaluate — fail loudly rather than silently
    # skipping a rule that might capture the pin.
    known = {"matchManagers", "matchDepNames", "description", "groupName",
             "groupSlug", "commitMessageTopic"}

    def applies(rule: dict) -> bool:
        unknown = set(rule) - known
        if unknown:
            sys.exit(f"unmodelled packageRule selector(s): {sorted(unknown)}")
        managers = rule.get("matchManagers")
        # A rule with NO matchManagers matches EVERY dependency in Renovate,
        # including the pin — treating it as non-applying would let a
        # `{"groupName": "github-actions"}` catch-all sweep the pin back in
        # while this check still printed "api-styleguide".
        if managers is not None and "custom.regex" not in managers:
            return False
        names = rule.get("matchDepNames")
        return names is None or dep in names

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
