#!/usr/bin/env python3
"""demangle-swift-regions.py — make Swift-mangled function names in a regions
array readable, for PR / commit-subject legibility (#464).

Reads a regions JSON array on stdin (`[{file, name, ...}, ...]`); for each entry
whose `name` is a Swift-mangled symbol (`$s` / `_$s` prefix — the SwiftPM /
llvm-cov case), replaces it with the demangled simplified form, e.g.
`$s4DemoAAV7coveredyS2iF` -> `Demo.covered(_:)`, via
`xcrun swift-demangle -simplified -compact`. Non-mangled names (xccov already
yields readable names) pass through untouched. Best-effort: on any failure
(no xcrun, non-zero exit, output/line mismatch) the original names are kept.
Stdout: the updated regions JSON.

Kept OUT of parse-swift-coverage.py on purpose — that parser is hermetic and
toolchain-free. This demangle runs only in the gather, where the Swift toolchain
is already present (coverage was just measured), so the parser's tests stay
deterministic. Stdlib only.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys


def _is_mangled(name: str) -> bool:
    return name.startswith("$s") or name.startswith("_$s")


def main() -> int:
    try:
        regions = json.load(sys.stdin)
    except ValueError:
        return 0  # unreadable input — emit nothing; the caller keeps the original
    if not isinstance(regions, list):
        print(json.dumps(regions))
        return 0

    idx = [
        i
        for i, r in enumerate(regions)
        if isinstance(r, dict) and isinstance(r.get("name"), str) and _is_mangled(r["name"])
    ]
    if idx and shutil.which("xcrun"):
        names = [regions[i]["name"] for i in idx]
        try:
            out = subprocess.run(
                ["xcrun", "swift-demangle", "-simplified", "-compact", *names],
                capture_output=True,
                text=True,
                timeout=30,
            )
            lines = out.stdout.splitlines()
            if out.returncode == 0 and len(lines) == len(names):
                for i, line in zip(idx, lines):
                    demangled = line.strip()
                    if demangled:
                        regions[i]["name"] = demangled
        except (OSError, subprocess.SubprocessError):
            pass  # keep raw names

    print(json.dumps(regions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
