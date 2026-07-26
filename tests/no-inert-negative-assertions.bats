#!/usr/bin/env bats
#
# Suite lint (#829): a bare `!`-negated assertion — `! grep …`, `! echo … | grep`,
# `! test …` — on a non-final line of a bats `@test` is exempt from errexit
# (POSIX ignores errexit for a pipeline beginning with `!`), so it passes
# silently even when its condition is false: a dead assertion giving false
# confidence against exactly the regression it targets (see #817, #829, #831,
# #862). The family standardized on the position-independent `run ! …` form
# (bats ≥ 1.5.0) — or a `refute_*` helper — both of which return the negative
# result as a bare command that errexit catches regardless of position.
#
# This guard scans the suite and fails if any bare `!`-negated line reappears, so
# the inert idiom cannot creep back in. `run ! …` (the line starts with `run`)
# and `refute_*` helper calls (no leading `!`) are the sanctioned forms and are
# not matched. For a negative SUBSTRING check the sanctioned form is `lacks`
# from tests/assertions.bash (#1011).
#
# SCOPE (corrected in #1011): this guard covers the bare-`!` form ONLY. It does
# NOT clear `[[ ! -f … ]]` — an earlier version of this comment cited that form
# as a benign non-match, which read as a safety claim it was never entitled to
# make. A `[[ ]]` assertion is inert for its own reason (bash 3.2 does not apply
# errexit to it) and is guarded separately by
# tests/no-inert-bracket-assertions.bats.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TESTS_DIR="$REPO_ROOT/tests"
  SELF="$(basename "$BATS_TEST_FILENAME")"
  # A line whose first non-space token is `!` followed by whitespace — the
  # errexit-exempt bare negation. `run ! …` starts with `run`, so it does not
  # match. `[[ ! -f … ]]` does not match either, but that is a scope boundary,
  # NOT an all-clear: it is inert too, and #1011's sibling guard catches it.
  PATTERN='^[[:space:]]*![[:space:]]'
}

@test "no bare '! ' negative assertion survives in any tests/*.bats (#829)" {
  local offenders
  # This file names the pattern in prose/fixtures, so exclude it from its own scan.
  offenders="$(grep -rnE "$PATTERN" --include='*.bats' "$TESTS_DIR" | grep -v "/$SELF:" || true)"
  if [ -n "$offenders" ]; then
    printf 'Inert bare-negation assertion(s) found — convert each to `run ! …`:\n%s\n' \
      "$offenders" >&2
    return 1
  fi
}

@test "the guard's detection actually catches a planted bare negation (self-test, #829)" {
  # Prove the lint is not vacuous: a planted bad file IS flagged by the pattern.
  local fixture="$BATS_TEST_TMPDIR/planted.bats"
  printf '@test "x" {\n  ! grep -q forbidden "$f"\n  true\n}\n' >"$fixture"
  run grep -nE "$PATTERN" "$fixture"
  [ "$status" -eq 0 ]
  contains "$output" '! grep -q forbidden'
}
