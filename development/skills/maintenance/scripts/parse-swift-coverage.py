#!/usr/bin/env python3
"""parse-swift-coverage.py — aggregate Swift code-coverage into per-source-file
LINE coverage, keyed by repo-relative source path.

Accepts EITHER coverage JSON format, auto-detected by shape:
  - Xcode xccov   (xcrun xccov view --report --json Result.xcresult) — has
    top-level "targets".
  - llvm-cov export / SwiftPM `swift test --show-codecov-path` — has top-level
    "data".

Usage:   parse-swift-coverage.py <coverage.json> [<coverage2.json> ...]
stdout:  {"overall": <0..100|null>, "by_module": {...}, "regions": [...]}

Run from the repo root (the caller cd's there). Absolute file paths are made
repo-relative so keys match the `component` paths the dispatcher floors
against. Files outside the repo (SDK/toolchain) and build/vendor artifacts
(.build, DerivedData, Pods, Carthage, checkouts, .swiftpm) are dropped from
by_module so the figure reflects the project's own source. The regions list
carries all functions (file paths are relativized when possible; external/temp
paths are kept as-is for dispatcher lookup). Stdlib only.
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


def _region_file(path: str, root: str) -> str:
    """Return a repo-relative path when the file lies inside the repo, else the
    raw path. Never returns None — regions always carry a usable file key."""
    rel = relativize(path, root)
    return rel if rel is not None else path


def _compute_line_pct(segments, start_line, end_line):
    """Percentage of lines in [start_line, end_line] that are covered.

    segments: list of [line, col, count, hasCount, isRegionEntry, isGapRegion]
    from an llvm-cov files[].segments array. A line is executable when a
    non-gap segment with hasCount=true is active there; covered when count > 0.
    """
    segs = sorted(segments, key=lambda s: (s[0], s[1]))
    executable = set()
    covered = set()

    for i, seg in enumerate(segs):
        seg_line = seg[0]
        count = seg[2]
        has_count = bool(seg[3])
        is_gap = bool(seg[5])

        if not has_count or is_gap:
            continue

        # Determine the first line of the next segment.
        if i + 1 < len(segs):
            next_line = segs[i + 1][0]
        else:
            next_line = end_line  # last segment: active through end_line

        # Active line range (exclusive upper bound):
        # - If next starts on a later line, the segment spans seg_line..(next_line-1).
        # - If next starts on the same line, the segment covers only some columns of
        #   seg_line — but for LINE coverage we still count seg_line as touched.
        if next_line > seg_line:
            span_end = next_line  # exclusive
        else:
            span_end = seg_line + 1  # same-line transition: just seg_line

        active_start = max(seg_line, start_line)
        active_end = min(span_end, end_line + 1)  # exclusive

        for line in range(active_start, active_end):
            executable.add(line)
            if count > 0:
                covered.add(line)

    total = len(executable)
    if total == 0:
        return 0.0
    return round(100.0 * len(covered) / total, 1)


def regions_from_xccov(doc, root):
    """Per-function regions from an xccov report.

    Returns list of {file, name, start_line, end_line, pct}.
    end_line: next function's lineNumber - 1; last function uses
    lineNumber + max(executableLines - 1, 0).
    pct: 100 * coveredLines / executableLines (0 when executableLines == 0).
    """
    regions = []
    for target in doc.get("targets", []):
        for f in target.get("files", []):
            raw_path = f.get("path") or f.get("name", "")
            file_key = _region_file(raw_path, root)
            functions = sorted(
                f.get("functions", []),
                key=lambda fn: fn.get("lineNumber", 0),
            )
            for i, fn in enumerate(functions):
                name = fn.get("name", "")
                start_line = int(fn.get("lineNumber", 0))
                exec_lines = int(fn.get("executableLines", 0))
                covered_lines = int(fn.get("coveredLines", 0))
                if i + 1 < len(functions):
                    end_line = int(functions[i + 1].get("lineNumber", start_line + 1)) - 1
                else:
                    end_line = start_line + max(exec_lines - 1, 0)
                end_line = max(end_line, start_line)
                pct = round(100.0 * covered_lines / exec_lines, 1) if exec_lines else 0.0
                regions.append({
                    "file": file_key,
                    "name": name,
                    "start_line": start_line,
                    "end_line": end_line,
                    "pct": pct,
                })
    return regions


def regions_from_llvm(doc, root):
    """Per-function regions from an llvm-cov export.

    Returns list of {file, name, start_line, end_line, pct}.
    start/end_line: min/max of the function's llvm region line boundaries.
    pct: derived from the file's segment data over [start_line, end_line].
    """
    # Build filename -> segments map for pct computation.
    file_segments = {}
    for data in doc.get("data", []):
        for f in data.get("files", []):
            fname = f.get("filename", "")
            existing = file_segments.setdefault(fname, [])
            existing.extend(f.get("segments", []))

    regions = []
    for data in doc.get("data", []):
        for fn in data.get("functions", []):
            name = fn.get("name", "")
            filenames = fn.get("filenames", [])
            fn_regions = fn.get("regions", [])
            if not filenames or not fn_regions:
                continue
            raw_path = filenames[0]
            file_key = _region_file(raw_path, root)
            # region format: [startLine, startCol, endLine, endCol, count, ...]
            start_line = min(r[0] for r in fn_regions)
            end_line = max(r[2] for r in fn_regions)
            segs = file_segments.get(raw_path, [])
            pct = _compute_line_pct(segs, start_line, end_line)
            regions.append({
                "file": file_key,
                "name": name,
                "start_line": start_line,
                "end_line": end_line,
                "pct": pct,
            })
    return regions


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
    all_regions: list[dict] = []

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
            all_regions.extend(regions_from_xccov(doc, root))
        elif "data" in doc:
            items = _llvm_items(doc)
            all_regions.extend(regions_from_llvm(doc, root))
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
    print(json.dumps({"overall": overall, "by_module": by_module, "regions": all_regions}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
