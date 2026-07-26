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
# The last tests pin the premise the entire sweep rests on: a FALSE helper call
# on a non-final line really does fail a bats test on every platform, where
# `[[ ]]` only does so on bash >= 4 — inert on the bash 3.2 macOS ships. That
# platform split IS the argument for the ban, so the premise tests assert the
# causal link (bats tracks this shell's errexit) rather than either outcome.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO_ROOT/tests/assertions.bash"
}

# Echoes `inert` when THIS platform's bash exempts a failing `[[ ]]` from
# errexit (bash 3.2, macOS `/bin/bash`), `caught` when errexit fires (bash >= 4).
#
# The probe uses `env bash`, which is exactly what bats' own shebang resolves to,
# so the probe and the fixture runs below are judging the same shell. Asserting
# against this rather than against a hardcoded outcome is the point: it pins the
# CAUSAL claim — bats' handling of a mid-body `[[ ]]` is nothing but this shell's
# errexit behaviour — instead of a claim that is only true on one platform.
#
# A named function is not scanned by the #1011 lint (calling it is a simple
# command errexit catches), and `[ ... ]` is never flagged in any case.
bracket_errexit_here() {
  local out
  out="$(env bash -c 'set -e; [[ "a" == "b" ]]; printf REACHED' 2>/dev/null || true)"
  if [ "$out" = "REACHED" ]; then printf 'inert'; else printf 'caught'; fi
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

@test "the premise itself: a mid-body [[ ]] tracks this bash's errexit (#1011)" {
  # The empirical claim that licenses this whole change — converting 285
  # assertions and banning a legal idiom repo-wide — is asserted in four file
  # headers, and it is PLATFORM-SPECIFIC: bash 3.2 (macOS) exempts a failing
  # `[[ ]]` from errexit, bash >= 4 does not. bats does not enter into it; 1.10.0
  # through 1.14.0 behave identically on a given bash.
  #
  # So pin the causal link rather than either outcome. Hardcoding `ok` was a
  # macOS-only claim that reds the `bats (ubuntu-latest)` leg; hardcoding
  # `not ok` would red macOS. This form is true on both AND still fires the
  # alarm if bats ever stops tracking plain errexit here.
  local fixture="$BATS_TEST_TMPDIR/premise-bracket.bats"

  printf '@test "false [[ ]] mid-body" {\n  [[ "abc" == "zzz" ]]\n  true\n}\n' >"$fixture"
  run bats "$fixture"
  if [ "$(bracket_errexit_here)" = "inert" ]; then
    [ "$status" -eq 0 ]        # bash 3.2: the false assertion is ignored
    contains "$output" "ok 1"
    lacks "$output" "not ok"
  else
    [ "$status" -ne 0 ]        # bash >= 4: errexit fires, as it does for `[ ]`
    contains "$output" "not ok 1"
  fi

  # The two claims below hold on EVERY bash, so they are asserted unconditionally
  # — and together they are what makes the ban survive the platform split:
  # `[ ]` is always enforced (so it needs no ban), and a trailing `[[ ]]` is safe
  # only by accident of position (so a positional exemption would be a trap).
  printf '@test "false [ ] mid-body" {\n  [ "abc" = "zzz" ]\n  true\n}\n' >"$fixture"
  run bats "$fixture"
  [ "$status" -ne 0 ]
  contains "$output" "not ok 1"

  printf '@test "false [[ ]] as the LAST line" {\n  run true\n  [[ "abc" == "zzz" ]]\n}\n' >"$fixture"
  run bats "$fixture"
  [ "$status" -ne 0 ]
  contains "$output" "not ok 1"
}

@test "the probe agrees with a direct reading of this shell's bash (#1011)" {
  # Guards the guard: if `bracket_errexit_here` ever returned a constant, the
  # branch above would silently stop testing anything on one platform. Cross-check
  # it against the bash MAJOR VERSION, which is the documented discriminator
  # (3.2 exempts `[[ ]]` from errexit; 4.0 onward does not).
  local probe major
  probe="$(bracket_errexit_here)"
  major="$(env bash -c 'printf %s "${BASH_VERSINFO[0]}"')"

  if [ "$major" -lt 4 ]; then
    [ "$probe" = "inert" ]
  else
    [ "$probe" = "caught" ]
  fi
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
  # reaches; both drive scoping decisions in the lint. They differ in kind, and
  # the split is why the lint scopes the way it does:
  #   * setup() is the SAME errexit question as a test body, so it follows the
  #     platform — scanned for exactly the reason a test body is.
  #   * the `&&` tail is the POSIX AND-list exemption, which holds on EVERY bash
  #     (verified on 3.2.57 and 5.2) — so no positional or platform reasoning
  #     rescues it, and the lint flags it regardless.
  local fixture="$BATS_TEST_TMPDIR/premise-scope.bats"

  printf 'setup() {\n  [[ "abc" == "zzz" ]]\n  true\n}\n@test "x" {\n  true\n}\n' >"$fixture"
  run bats "$fixture"
  if [ "$(bracket_errexit_here)" = "inert" ]; then
    [ "$status" -eq 0 ]
    contains "$output" "ok 1"
  else
    [ "$status" -ne 0 ]
    contains "$output" "not ok 1"
  fi

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
