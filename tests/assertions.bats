#!/usr/bin/env bats
#
# Behavioural tests for tests/assertions.bash (#1011) — the five shared
# assertion helpers that the 285 swept assertions (across 41 suite files) now
# depend on.
#
# WHY THIS FILE EXISTS: every call site in the suite is a TRUE assertion, so a
# helper that regressed to "always succeed" would keep the whole suite green
# while silently disabling every assertion built on it — the same false
# confidence #1011 set out to remove, one level down. So each helper is pinned
# in BOTH directions: it must succeed on a match AND fail on a non-match.
#
# The last test pins the premise the entire sweep rests on: a FALSE helper call
# on a non-final line really does fail a bats test, where `[[ ]]` does not.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO_ROOT/tests/assertions.bash"
}

# --- contains / lacks -------------------------------------------------------

@test "contains: true for a substring, false otherwise (#1011)" {
  contains "hello world" "lo wo"
  contains "hello world" "hello"
  contains "hello world" "d"
  run contains "hello world" "zzz"
  [ "$status" -eq 1 ]
}

@test "lacks: true when absent, false when present (#1011)" {
  lacks "hello world" "zzz"
  run lacks "hello world" "lo wo"
  [ "$status" -eq 1 ]
}

@test "contains/lacks match LITERALLY, never as a glob (#1011)" {
  # `[worktree]` would be a character class under `case`-glob matching — the
  # exact semantic drift the literal implementation exists to prevent.
  contains "a [worktree] b" "[worktree]"
  lacks "a worktree b" "[worktree]"
  contains "a*b" "*"
  lacks "abc" "*"
  lacks "abc" "a?c"
  contains "a.c" "."
  lacks "abc" "."
}

@test "the literal helpers work on a MULTI-LINE haystack (#1011)" {
  # Nearly every call site passes bats' multi-line $output/$stderr. A
  # reimplementation that became line-oriented (the grep-pipe temptation that
  # produced the first `matches` draft) would weaken hundreds of assertions
  # while this file stayed green.
  local multi
  multi="$(printf 'first\nsecond\nthird')"
  contains "$multi" "second"
  lacks "$multi" "fourth"
  starts_with "$multi" "first"
  ends_with "$multi" "third"
  run starts_with "$multi" "second"
  [ "$status" -eq 1 ]
  run ends_with "$multi" "second"
  [ "$status" -eq 1 ]
}

# --- starts_with / ends_with ------------------------------------------------

@test "starts_with: anchored at the front, literal (#1011)" {
  starts_with "hello world" "hello"
  run starts_with "hello world" "world"
  [ "$status" -eq 1 ]
  starts_with "[x] y" "[x]"
  run starts_with "axc" "a?c"
  [ "$status" -eq 1 ]
}

@test "ends_with: anchored at the end, literal (#1011)" {
  ends_with "hello world" "world"
  run ends_with "hello world" "hello"
  [ "$status" -eq 1 ]
  ends_with "y [x]" "[x]"
  run ends_with "axc" "a?c"
  [ "$status" -eq 1 ]
}

# --- matches ----------------------------------------------------------------

@test "matches: extended regex, succeeds and fails as expected (#1011)" {
  matches "deadbeef" '^[0-9a-f]+$'
  run matches "not-hex" '^[0-9a-f]+$'
  [ "$status" -eq 1 ]
}

@test "matches anchors the WHOLE value, not a single line (#1011)" {
  # The regression this pins: an implementation piping through `grep -qE` is
  # line-oriented, so an anchored pattern would pass on multi-line output —
  # silently weakening every "the script prints ONLY the id" assertion.
  matches "abc" '^abc$'
  run matches "warning: noise
abc" '^abc$'
  [ "$status" -eq 1 ]
}

# --- misuse guards ----------------------------------------------------------

@test "every helper rejects a one-argument call with exit 2 (#1011)" {
  # Without this guard a dropped argument makes lacks/starts_with/ends_with/
  # matches succeed unconditionally — a vacuous assertion.
  local h
  for h in contains lacks starts_with ends_with matches; do
    run "$h" "haystack"
    [ "$status" -eq 2 ]
    contains "$output" "expected 2 arguments"
  done
}

@test "every helper rejects an empty needle with exit 2 (#1011)" {
  local h
  for h in contains lacks starts_with ends_with matches; do
    run "$h" "haystack" ""
    [ "$status" -eq 2 ]
    contains "$output" "must be non-empty"
  done
}

@test "misuse (2) is distinct from a genuine mismatch (1) (#1011)" {
  # Pinning $status is what separates the two; see the next test for why the
  # obvious `run !` shorthand cannot.
  run contains "haystack" "absent"
  [ "$status" -eq 1 ]
  run contains "haystack"
  [ "$status" -eq 2 ]
  run contains "h" "a" "b"
  [ "$status" -eq 2 ]
}

@test "bats' 'run !' cannot tell misuse from mismatch — pin the status (#1011)" {
  # A documented limitation, pinned so it cannot be forgotten: bats' `run !`
  # accepts ANY non-zero status, so a dropped-argument typo (exit 2) satisfies
  # it and the assertion passes vacuously — the defect class this file removes.
  run ! contains "haystack"
  [ "$status" -eq 2 ]

  # The sanctioned negative form rejects the same misuse.
  run contains "haystack"
  [ "$status" -ne 1 ]
}

# --- the premise the whole sweep rests on -----------------------------------

@test "a FALSE helper call on a non-final line really fails a bats test (#1011)" {
  # This is the claim that licenses converting 285 `[[ ]]` assertions: unlike
  # `[[ ]]`, a helper call is a simple command errexit catches mid-body. The
  # fixture is built with printf because bats' own parser reacts to a column-0
  # `@test` line even inside a heredoc.
  cp "$LIB" "$BATS_TEST_TMPDIR/assertions.bash"
  local fixture="$BATS_TEST_TMPDIR/premise.bats"
  printf 'load assertions\n@test "false helper mid-body" {\n  contains "abc" "zzz"\n  true\n}\n' \
    >"$fixture"
  run bats "$fixture"
  [ "$status" -ne 0 ]
  contains "$output" "not ok 1"
}

@test "the premise itself: a FALSE [[ ]] mid-body reports ok, [ ] does not (#1011)" {
  # The empirical claim that licenses this whole change — converting 285
  # assertions and banning a legal idiom repo-wide — is asserted in three file
  # headers and was verified by hand on bats 1.14.0. Pin it, so that if a future
  # bats starts catching mid-body `[[ ]]`, we find out here rather than keeping
  # a ban on an idiom that is no longer broken.
  local fixture="$BATS_TEST_TMPDIR/premise-bracket.bats"

  printf '@test "false [[ ]] mid-body" {\n  [[ "abc" == "zzz" ]]\n  true\n}\n' >"$fixture"
  run bats "$fixture"
  [ "$status" -eq 0 ]          # INERT: the false assertion is ignored
  contains "$output" "ok 1"
  lacks "$output" "not ok"

  printf '@test "false [ ] mid-body" {\n  [ "abc" = "zzz" ]\n  true\n}\n' >"$fixture"
  run bats "$fixture"
  [ "$status" -ne 0 ]          # the contrast: `[ ]` fails correctly
  contains "$output" "not ok 1"

  printf '@test "false [[ ]] as the LAST line" {\n  run true\n  [[ "abc" == "zzz" ]]\n}\n' >"$fixture"
  run bats "$fixture"
  [ "$status" -ne 0 ]          # safe only by accident of position
  contains "$output" "not ok 1"
}

@test "an && tail neutralises a HELPER call too — the documented hazard is real (#1011)" {
  # assertions.bash warns that `a && b` swallows a failing `a`, because the
  # AND-list errexit exemption applies to a function call exactly as it does to
  # `[[ ]]`. Pin it, so the warning is empirically true rather than folklore —
  # no lint catches this shape (follow-up), so the docs are the only defence.
  cp "$LIB" "$BATS_TEST_TMPDIR/assertions.bash"
  local fixture="$BATS_TEST_TMPDIR/andtail.bats"
  printf 'load assertions\n@test "helper and-list tail" {\n  contains "abc" "zzz" && true\n  true\n}\n' \
    >"$fixture"
  run bats "$fixture"
  [ "$status" -eq 0 ]
  contains "$output" "ok 1"
}

@test "the premise holds in setup() and behind an && tail too (#1011)" {
  # Two further claims the detector header makes about WHERE the inertness
  # reaches; both drive scoping decisions in the lint.
  local fixture="$BATS_TEST_TMPDIR/premise-scope.bats"

  printf 'setup() {\n  [[ "abc" == "zzz" ]]\n  true\n}\n@test "x" {\n  true\n}\n' >"$fixture"
  run bats "$fixture"
  [ "$status" -eq 0 ]
  contains "$output" "ok 1"

  printf '@test "and-list tail" {\n  [[ "abc" == "zzz" ]] && true\n  true\n}\n' >"$fixture"
  run bats "$fixture"
  [ "$status" -eq 0 ]
  contains "$output" "ok 1"
}

@test "control: the same fixture with a TRUE helper call passes (#1011)" {
  # Proves the previous test failed for the asserted reason, not because the
  # fixture was malformed or the load failed.
  cp "$LIB" "$BATS_TEST_TMPDIR/assertions.bash"
  local fixture="$BATS_TEST_TMPDIR/control.bats"
  printf 'load assertions\n@test "true helper mid-body" {\n  contains "abc" "bc"\n  true\n}\n' \
    >"$fixture"
  run bats "$fixture"
  [ "$status" -eq 0 ]
  contains "$output" "ok 1"
  lacks "$output" "not ok"
}
