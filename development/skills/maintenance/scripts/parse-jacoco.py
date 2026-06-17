#!/usr/bin/env python3
"""parse-jacoco.py — aggregate JaCoCo XML report(s) into per-source-file
LINE coverage, keyed by repo-relative source path.

Usage:   parse-jacoco.py <report.xml> [<report2.xml> ...]
stdout:  {"overall": <0..100|null>, "by_module": {"src/main/java/.../Foo.java": 92.0, ...}}

Run from the repo root (the caller cd's there). Keys are resolved to the
actual source path on disk so they match SonarCloud `component` paths the
dispatcher floors against; falls back to "<package>/<file>" when the source
isn't found (e.g. generated sources).

Stdlib only — no third-party deps, so it runs anywhere python3 does.
"""
from __future__ import annotations

import glob
import json
import os
import sys
from xml.etree import ElementTree as ET

# Conventional Gradle source roots, checked in order before a broader search.
_SRC_ROOTS = ("src/main/java", "src/main/kotlin")


def resolve(pkg: str, fname: str) -> str:
    """Map a JaCoCo (package, sourcefile) to a repo-relative path on disk."""
    rel = f"{pkg}/{fname}"
    for root in _SRC_ROOTS:
        cand = f"{root}/{rel}"
        if os.path.exists(cand):
            return cand
    # Multi-module / non-standard layout: search anywhere under the tree.
    for root in _SRC_ROOTS:
        hits = glob.glob(f"**/{root}/{rel}", recursive=True)
        if hits:
            return hits[0]
    return rel  # generated source or unusual layout — keep the JaCoCo path


def main() -> int:
    missed: dict[str, int] = {}
    covered: dict[str, int] = {}

    for path in sys.argv[1:]:
        try:
            root = ET.parse(path).getroot()
        except (ET.ParseError, OSError):
            continue
        for package in root.findall("package"):
            pkg = package.get("name", "")
            for sf in package.findall("sourcefile"):
                fname = sf.get("name", "")
                key = resolve(pkg, fname)
                for counter in sf.findall("counter"):
                    if counter.get("type") != "LINE":
                        continue
                    missed[key] = missed.get(key, 0) + int(counter.get("missed", 0))
                    covered[key] = covered.get(key, 0) + int(counter.get("covered", 0))

    by_module: dict[str, float] = {}
    tot_missed = tot_covered = 0
    for key in missed:
        m, c = missed[key], covered[key]
        tot_missed += m
        tot_covered += c
        denom = m + c
        by_module[key] = round(100.0 * c / denom, 1) if denom else 100.0

    total = tot_missed + tot_covered
    overall = round(100.0 * tot_covered / total, 1) if total else None
    print(json.dumps({"overall": overall, "by_module": by_module}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
