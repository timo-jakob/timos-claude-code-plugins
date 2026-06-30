#!/usr/bin/env python3
"""parse-python-coverage.py — per-function coverage regions from a coverage.py
JSON report, for the region-scoped coverage gate.

Usage:   parse-python-coverage.py <coverage.json>
stdout:  {"regions": [{"file", "name", "start_line", "end_line", "pct"}, ...]}

coverage.py reports per-LINE data (`files.<path>.executed_lines` /
`missing_lines`) but not per-function. This maps lines to their enclosing
function by parsing each source file with the stdlib `ast` module: every
`def` / `async def` becomes a region spanning `lineno..end_lineno`, and its
`pct` is the covered fraction of the executable lines in that span. Nested
functions produce overlapping regions; the dispatcher picks the innermost on
overlap (smallest span).

Run from the repo root (the caller cd's there) — coverage.json's file keys are
already repo-relative, so they double as the region `file` and as the source
path to read. `overall` / `by_module` are computed by the gather directly from
coverage.json; this script only adds `regions`. Stdlib only.
"""
from __future__ import annotations

import ast
import json
import os
import sys


def regions_for_file(rel_path: str, file_cov: dict, root: str) -> list[dict]:
    """Per-function regions for one source file."""
    src_path = os.path.join(root, rel_path)
    try:
        with open(src_path, encoding="utf-8") as fh:
            tree = ast.parse(fh.read())
    except (OSError, SyntaxError, ValueError):
        return []  # generated/unreadable/unparseable source — no regions

    executed = set(file_cov.get("executed_lines", []))
    missing = set(file_cov.get("missing_lines", []))

    regions = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        start = node.lineno
        end = getattr(node, "end_lineno", start) or start
        # Executable lines in the span = those coverage.py tracked (executed or
        # missing). pct = covered / executable within the span.
        span_exec = [ln for ln in range(start, end + 1) if ln in executed or ln in missing]
        total = len(span_exec)
        covered = sum(1 for ln in span_exec if ln in executed)
        pct = round(100.0 * covered / total, 1) if total else 0.0
        regions.append(
            {"file": rel_path, "name": node.name, "start_line": start, "end_line": end, "pct": pct}
        )
    return regions


def main() -> int:
    if len(sys.argv) < 2:
        print(json.dumps({"regions": []}))
        return 0
    root = os.getcwd()
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            cov = json.load(fh)
    except (OSError, ValueError):
        print(json.dumps({"regions": []}))
        return 0

    all_regions: list[dict] = []
    for rel_path, file_cov in cov.get("files", {}).items():
        if isinstance(file_cov, dict):
            all_regions.extend(regions_for_file(rel_path, file_cov, root))
    print(json.dumps({"regions": all_regions}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
