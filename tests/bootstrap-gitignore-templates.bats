#!/usr/bin/env bats
#
# Contract tests for the bootstrap gitignore language templates (#909): every
# template must ignore the review loop's own output paths — `.review/` (the
# per-round findings JSON) and `.claude/telemetry/` (#566) — so a second or
# resumed loop run on a bootstrapped repo never sees prior-run artifacts as
# untracked story files. The dispatch-side exclusion (review-dispatch.zsh) is
# defense in depth for un-bootstrapped repos; these templates are the fix at
# the source. The template set is discovered from the filesystem so a future
# language template is covered the day it is added, not when someone remembers
# to extend a hardcoded list.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$REPO_ROOT/development/skills/bootstrap/templates/languages"
}

@test "every language gitignore template ignores .review/" {
  local found=0
  for f in "$T"/*/gitignore; do
    [ -f "$f" ] || continue
    found=1
    grep -qx '\.review/' "$f" || { echo "missing .review/ in $f"; return 1; }
  done
  [ "$found" -eq 1 ]   # a mis-pathed template dir must fail, not pass vacuously
}

@test "every language gitignore template ignores .claude/telemetry/" {
  local found=0
  for f in "$T"/*/gitignore; do
    [ -f "$f" ] || continue
    found=1
    grep -qx '\.claude/telemetry/' "$f" || { echo "missing .claude/telemetry/ in $f"; return 1; }
  done
  [ "$found" -eq 1 ]
}
