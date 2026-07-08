#!/usr/bin/env zsh
# ensure-coverage-precondition.zsh — the pre-push coverage-report guard (#602).
#
# The bootstrap-shipped `coverage-floor` pre-push hook enforces a 90%-on-new-code
# floor via `diff-cover`, which needs a coverage report (coverage.xml / JaCoCo
# XML / lcov) on disk. A push flow that eagerly produces that report BEFORE every
# push runs the whole test suite even for a diff with zero covered-language lines
# — pure wasted work (the observed ai-doc-organizer run executed 167 unit tests
# just to generate a vacuous coverage.xml for a workflow-only change, #602).
#
# This is the guard the push flow calls FIRST, so it only builds a report when
# one is actually needed:
#
#   • Diff has NO covered-language files → the coverage-floor hook skips (it is
#     `files:`-guarded since #379), so no report is required. Exit 0, print that,
#     and the caller pushes WITHOUT running any tests.
#   • Diff HAS covered-language files → the floor still applies. If the report is
#     already on disk, exit 0. If it is missing, exit 1 with the remedy — the
#     caller generates the report (runs the suite) and retries. Behaviour here is
#     unchanged from before this guard existed.
#
# It is a pure CHECK: it never runs tests and never mutates anything — it only
# inspects the diff + the report path and reports what the caller must do. (The
# separate stale-hook migration for pre-#379 repos lives in
# reconcile-precommit-hooks.zsh.)
#
# Usage:
#   ensure-coverage-precondition.zsh --lang <python|java|swift> \
#     [--compare-branch <ref>] [--report <path>]
#
#   --lang            covered-language selector (sets the source globs, the
#                     default report path, and the remedy message).
#   --compare-branch  base to diff against (default: origin/HEAD, else
#                     origin/main) — matches the hook's origin/<default> compare.
#   --report          override the report path the language default assumes.
#
# Exit codes:
#   0  no report needed (no covered-language files) OR report already present
#   1  covered-language files present but the report is missing (run the suite)
#   2  usage error

emulate -L zsh
setopt nounset pipefail

local lang="" compare="" report=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --lang|--compare-branch|--report)
    # A value-taking flag must actually have a value — a bare trailing `--lang`
    # would `shift 2` past $# (a zsh error that leaves $# unchanged) and spin the
    # loop forever. Guard it into a clean usage error instead.
    [[ $# -ge 2 ]] || { print -u2 -- "missing value for $1"; exit 2; }
    case "$1" in
    --lang) lang="$2" ;;
    --compare-branch) compare="$2" ;;
    --report) report="$2" ;;
    esac
    shift 2 ;;
  --) shift; break ;;
  *) print -u2 -- "unknown argument: $1"; exit 2 ;;
  esac
done

# Per-language contract: source globs, default report, remedy to produce it.
local -a globs
local default_report remedy
case "$lang" in
python)
  globs=('*.py')
  default_report="coverage.xml"
  remedy="run pytest --cov --cov-report=xml" ;;
java)
  # `.kt` (Kotlin source) but NOT `.kts` build scripts — a git pathspec of
  # `*.kt` ends at `.kt`, so `build.gradle.kts` (ending `.kts`) never matches.
  globs=('*.java' '*.kt')
  default_report="build/reports/jacoco/test/jacocoTestReport.xml"
  remedy="run ./gradlew test jacocoTestReport" ;;
swift)
  globs=('*.swift')
  default_report="coverage.lcov"
  remedy="run swift test --enable-code-coverage, then llvm-cov export -format=lcov > coverage.lcov" ;;
*)
  print -u2 -- "usage: ensure-coverage-precondition.zsh --lang <python|java|swift> [--compare-branch <ref>] [--report <path>]"
  exit 2 ;;
esac
[[ -n "$report" ]] || report="$default_report"

# Compare branch: honour --compare-branch, else the remote default head, else
# origin/main — the same origin/<default> the pre-push hook diffs against.
if [[ -z "$compare" ]]; then
  compare="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null)"
  [[ -n "$compare" ]] || compare="origin/main"
fi

# A ref that doesn't resolve would make `git diff` exit 128 with EMPTY stdout,
# which would masquerade as "no covered-language files" and wave the push through
# without a report. Fail loudly instead so the caller fixes the base rather than
# hitting a cryptic diff-cover rejection downstream.
if ! git rev-parse --verify --quiet "${compare}^{commit}" >/dev/null 2>&1; then
  print -u2 -- "ensure-coverage-precondition: compare ref '${compare}' does not resolve — pass --compare-branch <ref> (e.g. origin/main)."
  exit 2
fi

# Covered-language files added/changed by this branch since it forked off base.
# `<base>...HEAD` (three-dot) diffs against the merge-base, so a stale local
# base ref still reports only this branch's own changes. `--diff-filter=d` drops
# pure deletions: a removed .py adds no new coverable lines, so the floor has
# nothing to measure and the report isn't needed (matching the skipped hook).
local changed
changed="$(git diff --name-only --diff-filter=d "${compare}...HEAD" -- $globs)"

if [[ -z "$changed" ]]; then
  print -- "ensure-coverage-precondition: no covered-language files (${(j:, :)globs}) in the diff vs ${compare} — coverage report not required, no test run needed."
  exit 0
fi

if [[ -f "$report" ]]; then
  print -- "ensure-coverage-precondition: covered-language files present and ${report} found — coverage floor applies, report ready to push."
  exit 0
fi

print -u2 -- "ensure-coverage-precondition: covered-language files present but ${report} is missing — ${remedy}, then retry the push."
exit 1
