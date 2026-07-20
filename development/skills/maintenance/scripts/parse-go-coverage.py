#!/usr/bin/env python3
"""parse-go-coverage.py — per-file + per-function coverage from Go's first-party
coverage tooling, for the region-scoped coverage gate (Slice E, #874).

Usage:   parse-go-coverage.py <cover.out> <cover.func.txt> <module_path>
stdout:  {"overall": <float|null>, "by_module": {<rel>: <pct>, ...},
          "regions": [{"file", "name", "start_line", "end_line", "pct"}, ...]}

Two inputs, both produced by the gather where the Go toolchain lives (this
parser stays toolchain-free — it only parses text, like its python/swift
siblings):

  cover.out       — `go test ./... -coverprofile=cover.out` (per-PACKAGE
                    semantics; see the gather + the dispatcher's coverage note
                    for why per-package, not -coverpkg). Format after the
                    `mode:` header, one coverage block per line:
                        <import-path>/file.go:sL.sC,eL.eC <numStmt> <count>
                    This gives EXACT per-file statement coverage (by_module +
                    overall) with no source parsing at all — Go's advantage
                    over the line-based python/swift reports.
  cover.func.txt  — `go tool cover -func=cover.out`, one line per function:
                        <import-path>/file.go:<line>:\t<name>\t<pct>%
                    plus a trailing `total:` line. This supplies the function
                    NAMES + start lines + the authoritative per-function pct
                    (the profile has no names). end_line is derived as the next
                    function's start-1 within the same file (the last function
                    ends at the max block end-line the profile shows for it) —
                    the same next-start-minus-one approach parse-swift uses.

`module_path` is the root go.mod `module` directive; both tools print paths in
import-path form (`<module>/pkg/file.go`), so stripping the `<module>/` prefix
yields the repo-relative path the gate matches against finding components.

Generated sources (`*.pb.go`, `*.pb.gw.go` — buf output, the epic's proto-first
toolchain) are excluded from every figure: they are not hand-written code, so a
coverage gate on them is meaningless. Stdlib only.
"""
from __future__ import annotations

import json
import re
import sys


def _is_generated(rel_path: str) -> bool:
    return rel_path.endswith(".pb.go") or rel_path.endswith(".pb.gw.go")


def _rel(path: str, module_prefix: str) -> str:
    """import-path form -> repo-relative (strip the module prefix once)."""
    if module_prefix and path.startswith(module_prefix):
        return path[len(module_prefix):]
    return path


# A profile block line: path:startL.startC,endL.endC numStmt count
_BLOCK = re.compile(r"^(?P<path>.+):(?P<sl>\d+)\.\d+,(?P<el>\d+)\.\d+ (?P<n>\d+) (?P<c>\d+)$")
# A `-func` line:      path:line:\tname\tpct%
_FUNC = re.compile(r"^(?P<path>.+):(?P<line>\d+):\t(?P<name>.+)\t(?P<pct>[0-9.]+)%$")


def parse_profile(profile_path: str, module_prefix: str):
    """Return (by_module, overall, file_max_end).

    by_module: {rel_path: pct}, overall: float|None, file_max_end:
    {rel_path: max end-line seen} (used to close the last function's region).
    """
    covered: dict[str, int] = {}
    total: dict[str, int] = {}
    file_max_end: dict[str, int] = {}
    try:
        # errors="replace": a stray non-UTF-8 byte must not crash the parser
        # (its contract is valid-empty-JSON-exit-0 on bad input, not a traceback).
        with open(profile_path, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if not line or line.startswith("mode:"):
                    continue
                m = _BLOCK.match(line)
                if not m:
                    continue
                rel = _rel(m["path"], module_prefix)
                if _is_generated(rel):
                    continue
                n = int(m["n"])
                cnt = int(m["c"])
                total[rel] = total.get(rel, 0) + n
                if cnt > 0:
                    covered[rel] = covered.get(rel, 0) + n
                el = int(m["el"])
                if el > file_max_end.get(rel, 0):
                    file_max_end[rel] = el
    except OSError:
        return {}, None, {}

    by_module: dict[str, float] = {}
    tot_all = cov_all = 0
    for rel, tot in total.items():
        if tot <= 0:
            continue
        cov = covered.get(rel, 0)
        by_module[rel] = round(100.0 * cov / tot, 1)
        tot_all += tot
        cov_all += cov
    overall = round(100.0 * cov_all / tot_all, 1) if tot_all else None
    return by_module, overall, file_max_end


def parse_funcs(func_path: str, module_prefix: str, file_max_end: dict[str, int]):
    """Return regions: [{file, name, start_line, end_line, pct}, ...]."""
    # Collect per file: (start_line, name, pct), then derive end_line.
    per_file: dict[str, list[tuple[int, str, float]]] = {}
    try:
        with open(func_path, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                if not line or line.startswith("total:"):
                    continue
                m = _FUNC.match(line)
                if not m:
                    continue
                rel = _rel(m["path"], module_prefix)
                if _is_generated(rel):
                    continue
                per_file.setdefault(rel, []).append((int(m["line"]), m["name"].strip(), float(m["pct"])))
    except OSError:
        return []

    regions: list[dict] = []
    for rel, funcs in per_file.items():
        funcs.sort(key=lambda t: t[0])
        for i, (start, name, pct) in enumerate(funcs):
            if i + 1 < len(funcs):
                end = funcs[i + 1][0] - 1
            else:
                # Last function in the file: close at the max block end-line the
                # profile showed for this file (>= start), else the start line.
                end = max(file_max_end.get(rel, start), start)
            if end < start:
                end = start
            regions.append({"file": rel, "name": name, "start_line": start, "end_line": end, "pct": pct})
    return regions


def main() -> int:
    if len(sys.argv) < 4:
        print(json.dumps({"overall": None, "by_module": {}, "regions": []}))
        return 0
    profile_path, func_path, module_path = sys.argv[1], sys.argv[2], sys.argv[3]
    module_prefix = module_path.rstrip("/") + "/" if module_path else ""

    by_module, overall, file_max_end = parse_profile(profile_path, module_prefix)
    regions = parse_funcs(func_path, module_prefix, file_max_end)
    print(json.dumps({"overall": overall, "by_module": by_module, "regions": regions}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
