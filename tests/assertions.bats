#!/usr/bin/env bats
#
# Behavioural tests for tests/assertions.bash (#1011) — the shared assertion
# helpers that the 285 swept assertions (across 41 suite files) now depend on.
#
# WHY THIS FILE EXISTS: every call site in the suite is a TRUE assertion, so a
# helper that regressed to "always succeed" would keep the whole suite green
# while silently disabling every assertion built on it — the same false
# confidence #1011 set out to remove, one level down. So each helper is pinned
# in BOTH directions: it must succeed on a match AND fail on a non-match.
#
# A middle section (#1067) pins the mismatch DIAGNOSTIC — needle plus a
# truncated haystack on fd 2 — which is what makes a helper failure debuggable
# from a CI log rather than a bare `not ok` naming a needle.
#
# The last tests pin the premise the entire sweep rests on: a FALSE helper call
# on a non-final line really does fail a bats test on every platform, where
# `[[ ]]` only does so on bash >= 4 — inert on the bash 3.2 macOS ships. That
# platform split IS the argument for the ban, so the premise tests assert the
# causal link (bats tracks this shell's errexit) rather than either outcome.

bats_require_minimum_version 1.5.0

load assertions
load roster

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO_ROOT/tests/assertions.bash"
  # Derived, never restated (#1067) — every public (non-underscore) top-level
  # function in the library is a helper. The misuse loops below run over this, so
  # a new helper is covered by them the moment it is defined instead of being
  # silently skipped. ONE derivation, shared via `load roster` and self-tested in
  # tests/no-inert-bracket-assertions.bats: an earlier version kept a second copy
  # here and merely claimed the two could not diverge, which made the count
  # tripwire below depend on an unverified twin.
  HELPERS="$(helper_roster_of "$LIB")"
  # `helper_roster_of` ends in `sed`, so it exits 0 even when every grep matched
  # nothing — and `for h in $HELPERS` over an empty roster iterates zero times,
  # so both misuse guards below would report green while asserting nothing.
  [ -n "$HELPERS" ]
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

# --- the roster tripwire ----------------------------------------------------

@test "adding a helper reds THIS file until the count is updated (#1067)" {
  # The misuse loops derive their roster, but the two diagnostic tests below —
  # mismatch output and success-path silence — are deliberate per-helper
  # ENUMERATIONS, because each helper reaches the shared printer through a
  # different construct (a `[ ]`, a `case` arm, a `[[ ]]`) and a missed rewiring
  # would leave exactly one of them silently mute. A derivation cannot write
  # those cases; only a human can. So pin the COUNT: a sixth helper reds this
  # test, and the red is the INSTRUCTION to go extend both enumerations — it
  # cannot verify that you did, and bumping the number alone turns it green
  # again. Without it the detector-side sync test would force `H` to be updated
  # while this file, the one that actually pins behaviour, stayed green and
  # uncovered.
  local n
  n="$(printf '%s\n' $HELPERS | wc -w | tr -d ' ')"
  if [ "$n" -ne 5 ]; then
    printf 'The helper roster changed (%s helpers: %s).\n' "$n" "$HELPERS"        >&2
    printf 'Extend the per-helper enumerations in this file — "every helper\n'    >&2
    printf 'prints needle and haystack on a mismatch" and "a matching helper\n'   >&2
    printf 'prints nothing at all" — then update this count.\n'                   >&2
    return 1
  fi
}

# --- misuse guards ----------------------------------------------------------

@test "every helper rejects a one-argument call with exit 2 (#1011)" {
  # Without this guard a dropped argument makes lacks/starts_with/ends_with/
  # matches succeed unconditionally — a vacuous assertion.
  local h
  for h in $HELPERS; do
    run "$h" "haystack"
    [ "$status" -eq 2 ]
    contains "$output" "expected 2 arguments"
  done
}

@test "every helper rejects an empty needle with exit 2 (#1011)" {
  local h
  for h in $HELPERS; do
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

# --- the mismatch diagnostic (#1067) ----------------------------------------
#
# bats prints the failing SOURCE line, so a reader always saw the needle. The
# haystack was the thing that vanished when 285 `[[ "$output" == *x* ]]`
# assertions became helper calls: `$output` was at least inspectable in context
# before. On exit 1 each helper now prints both to fd 2.
#
# fd 2 is load-bearing, not incidental: `run <helper>` call sites pin `$status`,
# and bats folds a command's stdout into `$output` — a diagnostic on stdout
# would rewrite `$output` under every one of them.

@test "every helper prints needle and haystack on a mismatch (#1067)" {
  # All five, because the printer is shared but each helper has to actually
  # route its failure through it — `starts_with`/`ends_with` do so from a `case`
  # arm, `matches` from a `[[ ]]`, and a missed rewiring would leave that helper
  # silently mute while this file stayed green.
  run --separate-stderr contains "hello world" "zzz"
  [ "$status" -eq 1 ]
  contains "$stderr" "contains: assertion failed"
  contains "$stderr" "needle:   zzz"
  contains "$stderr" "haystack: hello world"

  run --separate-stderr lacks "hello world" "hello"
  [ "$status" -eq 1 ]
  contains "$stderr" "lacks: assertion failed"
  contains "$stderr" "needle:   hello"
  contains "$stderr" "haystack: hello world"

  run --separate-stderr starts_with "hello world" "world"
  [ "$status" -eq 1 ]
  contains "$stderr" "starts_with: assertion failed"
  contains "$stderr" "needle:   world"
  contains "$stderr" "haystack: hello world"

  run --separate-stderr ends_with "hello world" "hello"
  [ "$status" -eq 1 ]
  contains "$stderr" "ends_with: assertion failed"
  contains "$stderr" "needle:   hello"
  contains "$stderr" "haystack: hello world"

  run --separate-stderr matches "not-hex" '^[0-9a-f]+$'
  [ "$status" -eq 1 ]
  contains "$stderr" "matches: assertion failed"
  contains "$stderr" 'needle:   ^[0-9a-f]+$'
  contains "$stderr" "haystack: not-hex"
}

@test "the diagnostic goes to fd 2 only — stdout stays empty (#1067)" {
  # The compatibility claim the whole change rests on. Note what actually
  # protects the existing `run <helper>; [ "$status" -eq 1 ]` sites: they pin
  # only `$status`. Plain `run` folds BOTH streams into `$output`, so the fd-2
  # split does NOT keep `$output` empty there — it keeps it empty for
  # `--separate-stderr` callers, which is what this pins.
  run --separate-stderr contains "hello world" "zzz"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "a matching helper prints nothing at all (#1067)" {
  # A diagnostic on the SUCCESS path would spam every green run — 285 call sites
  # of noise — and would show up in `$output` for any `run <helper>` that passes.
  # All five, for the same reason the mismatch test loops: the success paths are
  # three different constructs (a `[ ]`, a `case` arm, a `[[ ]]`).
  run --separate-stderr contains "hello world" "lo wo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]

  run --separate-stderr lacks "hello world" "zzz"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]

  run --separate-stderr starts_with "hello world" "hello"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]

  run --separate-stderr ends_with "hello world" "world"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]

  run --separate-stderr matches "deadbeef" '^[0-9a-f]+$'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "an uncompilable 'matches' pattern stays misuse (2), not a mismatch (#1067)" {
  # `[[ =~ ]]` returns 2 for an ERE it cannot compile (verified on bash 3.2.57)
  # and 1 for a plain non-match. Routing both through the mismatch printer would
  # make the sanctioned negative form — `run matches …; [ "$status" -eq 1 ]` —
  # PASS on a typo'd pattern that matched nothing at all: a vacuous assertion of
  # exactly the class this library exists to remove.
  run --separate-stderr matches "abc" '('
  [ "$status" -eq 2 ]
  contains "$stderr" "not a valid extended regular expression"
  lacks "$stderr" "assertion failed"

  # The control: a well-formed pattern that simply does not match is still 1.
  run --separate-stderr matches "abc" '^[0-9]+$'
  [ "$status" -eq 1 ]
  contains "$stderr" "assertion failed"
}

@test "misuse (2) reports misuse only, never a phantom mismatch (#1067)" {
  # The two diagnostics answer different questions. A dropped argument that also
  # printed "assertion failed / haystack: …" would send the reader hunting for a
  # mismatch that was never evaluated.
  run --separate-stderr contains "haystack"
  [ "$status" -eq 2 ]
  contains "$stderr" "expected 2 arguments"
  lacks "$stderr" "assertion failed"

  run --separate-stderr contains "haystack" ""
  [ "$status" -eq 2 ]
  contains "$stderr" "must be non-empty"
  lacks "$stderr" "assertion failed"
}

@test "a long haystack is truncated, and says so with the full length (#1067)" {
  # `$output` in this suite is routinely kilobytes — a whole bats run, a whole
  # dossier. An untruncated dump would bury the assertion it explains; a SILENT
  # truncation would be worse, since the reader would conclude the missing text
  # was absent from the haystack rather than cut from the report.
  local long
  long="$(printf 'a%.0s' $(seq 1 894))ZZTAIL"
  [ "${#long}" -eq 900 ]
  run --separate-stderr contains "$long" "zzz"
  [ "$status" -eq 1 ]
  contains "$stderr" "haystack truncated at 400 of 900 characters"

  # The truncation is REAL and agrees with the number it ANNOUNCES. Asserting
  # only that stderr is shorter than the haystack would be satisfied by an
  # 800-character slice still claiming "truncated at 400" — a divergence the
  # reader has no way to detect, and the one thing a truncation notice must
  # never do. So pin the emitted line exactly: `  haystack: ` (12) + 400.
  contains "$stderr" "haystack: aaaa"
  lacks "$stderr" "ZZTAIL"
  [ "${#stderr_lines[2]}" -eq 412 ]

  # A short haystack is printed whole, with no truncation notice.
  run --separate-stderr contains "short" "zzz"
  [ "$status" -eq 1 ]
  contains "$stderr" "haystack: short"
  lacks "$stderr" "truncated"

  # The boundary itself: `-gt` not `-ge`. An off-by-one would announce the
  # nonsense "truncated at 400 of 400 characters", which neither case above can
  # see.
  local exact over
  exact="$(printf 'b%.0s' $(seq 1 400))"
  run --separate-stderr contains "$exact" "zzz"
  [ "$status" -eq 1 ]
  lacks "$stderr" "truncated"

  over="$(printf 'c%.0s' $(seq 1 401))"
  run --separate-stderr contains "$over" "zzz"
  [ "$status" -eq 1 ]
  contains "$stderr" "haystack truncated at 400 of 401 characters"
}

@test "the diagnostic survives a multi-line haystack (#1067)" {
  # Every real call site passes bats' multi-line `$output`; a printer that
  # collapsed or dropped after the first line would be useless where it matters
  # most.
  local multi
  multi="$(printf 'first\nsecond\nthird')"
  run --separate-stderr contains "$multi" "fourth"
  [ "$status" -eq 1 ]
  contains "$stderr" "haystack: first"
  contains "$stderr" "third"
}

@test "a needle containing a printf conversion is printed literally (#1067)" {
  # The needle is a printf ARGUMENT, never its format. Interpolating it would
  # corrupt the report for exactly the assertions that most need one.
  run --separate-stderr contains "hello" '%s %d %%'
  [ "$status" -eq 1 ]
  contains "$stderr" "needle:   %s %d %%"
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

  # ...and the #1067 diagnostic reaches the REPORT, which is the claim that
  # justifies it. Every other diagnostic test captures fd 2 directly, proving
  # only that the helper writes it — not that a reader of a failing CI log sees
  # it. This is the end-to-end version.
  contains "$output" "contains: assertion failed"
  contains "$output" "haystack: abc"
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
  # `[[ ]]`. Pin it, so the warning is empirically true rather than folklore.
  # This test is the EVIDENCE the lint rests on: #1067 turned the warning into
  # the `and-tail` rule of tests/find-inert-bracket-assertions.zsh, and a rule
  # that flags a shape nobody has proved inert is just a style preference.
  cp "$LIB" "$BATS_TEST_TMPDIR/assertions.bash"
  local fixture="$BATS_TEST_TMPDIR/andtail.bats"
  printf 'load assertions\n@test "helper and-list tail" {\n  contains "abc" "zzz" && true\n  true\n}\n' \
    >"$fixture"
  run bats "$fixture"
  [ "$status" -eq 0 ]
  contains "$output" "ok 1"
  lacks "$output" "not ok"
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
    lacks "$output" "not ok"
  else
    [ "$status" -ne 0 ]
    contains "$output" "not ok 1"
  fi

  printf '@test "and-list tail" {\n  [[ "abc" == "zzz" ]] && true\n  true\n}\n' >"$fixture"
  run bats "$fixture"
  [ "$status" -eq 0 ]
  contains "$output" "ok 1"
  lacks "$output" "not ok"
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
