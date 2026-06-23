#!/usr/bin/env python3
"""parse-swift-coverage.py — aggregate Swift code-coverage into per-source-file
LINE coverage, keyed by repo-relative source path.

Accepts EITHER coverage JSON format, auto-detected by shape:
  - Xcode xccov   (xcrun xccov view --report --json Result.xcresult) — has
    top-level "targets".
  - llvm-cov export / SwiftPM `swift test --show-codecov-path` — has top-level
    "data".

Usage:   parse-swift-coverage.py <coverage.json> [<coverage2.json> ...]
stdout:  {"overall": <0..100|null>, "by_module": {"Sources/App/Foo.swift": 92.0, ...}}

Run from the repo root (the caller cd's there). Absolute file paths are made
repo-relative so keys match the `component` paths the dispatcher floors
against. Files outside the repo (SDK/toolchain) and build/vendor artifacts
(.build, DerivedData, Pods, Carthage, checkouts, .swiftpm) are dropped, so the
figure reflects the project's own source. Stdlib only.
"""
from __future__ import annotations

import json
import os
import sys

# Path segments that mark a non-source file: build output or vendored deps.
_SKIP_SEGMENTS = (".build", "DerivedData", "Pods", "Carthage", "checkouts", ".swiftpm")


def relativize(path: str, root: str) -> str | None:
    """Map an absolute coverage path to a repo-relative source path, or None
    when it isn't the project's own source (outside the repo, or a build/vendor
    artifact)."""
    if not path:
        return None
    # realpath both sides so a symlinked root (e.g. macOS /var -> /private/var)
    # doesn't spuriously make an in-repo file look outside the repo.
    rel = os.path.relpath(os.path.realpath(path), root)
    if rel.startswith(".."):
        return None  # outside the repo (SDK, toolchain, sibling checkout)
    if any(seg in _SKIP_SEGMENTS for seg in rel.split(os.sep)):
        return None  # build output / vendored dependency
    return rel


def _xccov_items(doc: dict):
    """(path, covered, executable) triples from an xccov report."""
    for target in doc.get("targets", []):
        for f in target.get("files", []):
            yield (
                f.get("path") or f.get("name", ""),
                int(f.get("coveredLines", 0)),
                int(f.get("executableLines", 0)),
            )


def _llvm_items(doc: dict):
    """(path, covered, executable) triples from an llvm-cov export."""
    for data in doc.get("data", []):
        for f in data.get("files", []):
            lines = f.get("summary", {}).get("lines", {})
            yield (
                f.get("filename", ""),
                int(lines.get("covered", 0)),
                int(lines.get("count", 0)),
            )


def main() -> int:
    root = os.path.realpath(os.getcwd())
    # Accumulate covered/executable per file (a file can appear under multiple
    # targets / data blocks).
    acc: dict[str, list[int]] = {}

    for path in sys.argv[1:]:
        try:
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(doc, dict):
            continue
        if "targets" in doc:
            items = _xccov_items(doc)
        elif "data" in doc:
            items = _llvm_items(doc)
        else:
            items = iter(())
        for raw_path, covered, executable in items:
            key = relativize(raw_path, root)
            if key is None:
                continue
            bucket = acc.setdefault(key, [0, 0])
            bucket[0] += covered
            bucket[1] += executable

    by_module: dict[str, float] = {}
    tot_covered = tot_exec = 0
    for key, (covered, executable) in acc.items():
        tot_covered += covered
        tot_exec += executable
        by_module[key] = round(100.0 * covered / executable, 1) if executable else 100.0

    overall = round(100.0 * tot_covered / tot_exec, 1) if tot_exec else None
    print(json.dumps({"overall": overall, "by_module": by_module}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
