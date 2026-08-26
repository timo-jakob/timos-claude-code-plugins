#!/usr/bin/env bats
#
# Behavioral tests for record-grant.zsh (#1576): the writer half of the human
# grant ceiling. It turns "the human granted +3" into a fact on disk
# (`<work-dir>/.max-rounds`) that `resolve-story-loop.zsh --resume` adopts, so a
# conductor whose context compacts cannot resume under the old ceiling — the
# #1558 failure this story exists for.
#
# The reader half (adoption, the four refusal arms, the fresh-run clear, the
# adoption order against #1434, and the end-to-end write-then-resume) lives in
# tests/resolve-story-loop.bats. It is deliberately NOT in
# resolve-story-loop-step.bats, which is the gate's wall-clock floor.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/record-grant.zsh"
  W="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$W"
  ST="$W/status.json"
}

# a status JSON with the two fields the writer reads
seed_status() {   # seed_status <max_rounds> <closing_sweep_granted>
  printf '{"status":"BUDGET_EXHAUSTED","rounds":%s,"max_rounds":%s,"closing_sweep_granted":%s}\n' \
    "$1" "$1" "$2" > "$ST"
}

# The loop's own sidecar slack, read from source so a retune moves the fixtures
# with it. Fails loudly rather than yielding an empty string.
sidecar_slack() {
  local v
  v=$(sed -n 's/^typeset -gr MAX_ROUNDS_SIDECAR_SLACK=\([0-9]*\)$/\1/p' "$REPO_ROOT/development/skills/resolve-issue/scripts/resolve-story-loop.zsh")
  [ -n "$v" ] || { echo "could not read MAX_ROUNDS_SIDECAR_SLACK" >&2; return 1; }
  printf '%s' "$v"
}

@test "#1576 a happy grant exits 0, writes .max-rounds and prints ONLY the ceiling" {
  seed_status 5 false
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  # stdout is the ceiling and nothing else — the conductor echoes it to the
  # human, and a stray diagnostic on stdout would be read as part of the number
  [ "$output" = "8" ]
  [ "$(cat "$W/.max-rounds")" = "8" ]
}

@test "#1576 base+delta: a plain BUDGET_EXHAUSTED at 5 plus 3 is 8" {
  seed_status 5 false
  run zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  [ "$(cat "$W/.max-rounds")" = "8" ]
}

@test "#1576 base+delta: a GRANTED closing sweep is already one past max_rounds, so 5+3 is 9" {
  # reference/interactive.md step 5 says so in prose ("already one past
  # max_rounds"); taking .max_rounds alone would silently buy one round fewer
  # than the human was told they were getting.
  seed_status 5 true
  run zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  [ "$(cat "$W/.max-rounds")" = "9" ]
}

@test "#1576 base+delta: a REPEAT grant compounds off the existing sidecar (8 + 3 = 11)" {
  # The base is max(existing sidecar, status-derived). Recomputing from the
  # command line would make every later grant a no-op at 8, silently capping a
  # run the human kept extending.
  seed_status 5 false
  printf '8\n' > "$W/.max-rounds"
  run zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  [ "$(cat "$W/.max-rounds")" = "11" ]
}

@test "#1576 non-vacuity: without the existing-sidecar base the repeat case would read 8" {
  # Pins that the previous test is really exercising the compounding branch:
  # the SAME invocation with no sidecar present yields 8, not 11.
  seed_status 5 false
  run zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  [ "$(cat "$W/.max-rounds")" = "8" ]
}

@test "#1576 a garbage existing sidecar is ignored, not fatal, and the status JSON becomes the base" {
  seed_status 5 false
  printf 'eight\n' > "$W/.max-rounds"
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  contains "$stderr" "ignoring an unreadable ceiling"
  [ "$(cat "$W/.max-rounds")" = "8" ]
}

@test "#1576 an older status JSON with no closing_sweep_granted key reads as no grant" {
  # `// false` is the correct reading of a file that predates #1434, not an
  # error — the writer must stay usable against an older work-dir.
  printf '{"status":"BUDGET_EXHAUSTED","max_rounds":5}\n' > "$ST"
  run zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  [ "$(cat "$W/.max-rounds")" = "8" ]
}

@test "#1576 --add must be a positive integer: usage exit 2 and NO file written" {
  seed_status 5 false
  local bad
  for bad in three 0 -1 '' 99999999999999999999; do
    run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add "$bad"
    [ "$status" -eq 2 ]
    # a refused invocation must never leave a ceiling behind
    [ ! -e "$W/.max-rounds" ]
  done
}

@test "#1576 a missing required flag is exit 2, and an unknown flag is exit 2" {
  seed_status 5 false
  run --separate-stderr zsh "$S" --status "$ST" --add 3
  [ "$status" -eq 2 ]
  contains "$stderr" "--work-dir is required"

  run --separate-stderr zsh "$S" --work-dir "$W" --add 3
  [ "$status" -eq 2 ]
  contains "$stderr" "--status is required"

  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST"
  [ "$status" -eq 2 ]
  contains "$stderr" "--add is required"

  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3 --bogus
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown flag"

  [ ! -e "$W/.max-rounds" ]
}

@test "#1576 a --work-dir that is not a directory is exit 2" {
  seed_status 5 false
  run --separate-stderr zsh "$S" --work-dir "$BATS_TEST_TMPDIR/nope" --status "$ST" --add 3
  [ "$status" -eq 2 ]
  contains "$stderr" "not a directory"
}

@test "#1576 a missing or unusable status JSON is exit 1, not a silent default" {
  # 1 (internal), not 2 (usage): the invocation was well-formed, the input was
  # not. A default here would mint a ceiling from a number nobody supplied.
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$BATS_TEST_TMPDIR/absent.json" --add 3
  [ "$status" -eq 1 ]
  contains "$stderr" "status file missing or empty"

  printf '{"status":"BUDGET_EXHAUSTED"}\n' > "$ST"
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 1 ]
  contains "$stderr" "no usable max_rounds"
  [ ! -e "$W/.max-rounds" ]
}

@test "#1576 --help prints the signature and exits 0" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "--work-dir DIR --status FILE --add N"
}

@test "#1576 the delta is EXPLICIT: the writer never reads the cumulative grants counter" {
  # AC 3. The conductor's counter is cumulative and stateless, so two
  # invocations at the same count are indistinguishable and no delta can be
  # inferred from it. Pinned as a needle so a later "convenience" reading of
  # that flag cannot creep in.
  run grep -c -- '--grants' "$S"
  [ "$output" = "0" ]
}

@test "#1576 non-vacuity: the grants needle would catch the flag if it were read" {
  # Without this, a renamed flag (or a grep that silently errors) would leave
  # the assertion above passing for the wrong reason.
  local fake="$BATS_TEST_TMPDIR/fake.zsh"
  printf '#!/usr/bin/env zsh\n# reads --grants\n' > "$fake"
  run grep -c -- '--grants' "$fake"
  [ "$output" = "1" ]
}

@test "#1576 a STALE LOWER sidecar never lowers the base — the rule is max(), not assignment" {
  # The compounding branch is a max(): a smaller sidecar left in a re-used
  # work-dir (or a hand-edit) must not drag the grant DOWN. An unconditional
  # `base=$existing` would write 6 here instead of 8, silently buying two
  # rounds fewer than the human was told they were getting.
  seed_status 5 false
  printf '3\n' > "$W/.max-rounds"
  run zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  [ "$(cat "$W/.max-rounds")" = "8" ]
}

@test "#1576 the base prefers effective_max_rounds — the ceiling actually in force" {
  # A status JSON that carries the #1576 key is authoritative: it already
  # counts any grant AND the #1434 sweep round, so the increment lands on what
  # the human was just told the run was working under.
  printf '{"status":"BUDGET_EXHAUSTED","max_rounds":5,"effective_max_rounds":9,"closing_sweep_granted":true}\n' > "$ST"
  run zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  [ "$(cat "$W/.max-rounds")" = "12" ]
}

@test "#1576 non-vacuity: without effective_max_rounds the same fixture falls back to max_rounds+1" {
  # Pins that the test above really exercises the preferred path: drop the key
  # and the fallback reconstructs 5+1, giving 9 rather than 12.
  printf '{"status":"BUDGET_EXHAUSTED","max_rounds":5,"closing_sweep_granted":true}\n' > "$ST"
  run zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  [ "$(cat "$W/.max-rounds")" = "9" ]
}

@test "#1576 a DANGLING value flag is a usage error, never an infinite loop" {
  # `shift 2` with fewer than two positionals leaves the parameters UNCHANGED
  # in zsh, so an unguarded parser re-enters the same arm forever and HANGS the
  # conductor's tool call. The reachable shape is an unquoted empty variable:
  # `--add $N` with N unset leaves `--add` as the last word.
  seed_status 5 false
  # Wrap in a timeout WHERE ONE EXISTS, so a regression fails the test instead
  # of hanging the suite. macOS ships neither `timeout` nor `gtimeout` by
  # default, so the wrapper is optional — the assertions below are the contract
  # either way.
  local -a TO=()
  if command -v timeout >/dev/null 2>&1; then TO=(timeout 10)
  elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 10)
  fi
  local flag
  for flag in --work-dir --status --add; do
    run --separate-stderr "${TO[@]}" zsh "$S" --work-dir "$W" --status "$ST" "$flag"
    printf 'dangling: %s\n' "$flag" >&2
    # 124 would be a timeout killing a hung parser — the regression this pins
    [ "$status" -eq 2 ]
    contains "$stderr" "requires a value"
  done
  [ ! -e "$W/.max-rounds" ]
}

@test "#1576 a flag where a value belongs is refused, not silently consumed" {
  seed_status 5 false
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add --work-dir "$W"
  [ "$status" -eq 2 ]
  contains "$stderr" "requires a value"
  [ ! -e "$W/.max-rounds" ]
}

@test "#1576 a stray positional argument is a usage error" {
  seed_status 5 false
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3 4
  [ "$status" -eq 2 ]
  contains "$stderr" "unexpected argument"
  [ ! -e "$W/.max-rounds" ]
}

@test "#1576 MALFORMED status JSON is diagnosed as invalid, not as a missing key" {
  # The two exit-1 arms send the operator to different remedies: 'invalid JSON'
  # means the file is corrupt, 'no usable max_rounds' means it is well-formed
  # but wrong. Collapsing them would misdirect.
  printf '{"max_rounds": 5\n' > "$ST"
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 1 ]
  contains "$stderr" "invalid status JSON"
  [ ! -e "$W/.max-rounds" ]
}

@test "#1576 a failed write exits 1, writes no ceiling and leaves no temp debris" {
  # The header contracts `1 internal (… a write that failed)`. An exit 0 here
  # would have the conductor echo an empty ceiling to the human and resume
  # under the old one — #1558's loss, failing silently instead of loudly.
  [ "$(id -u)" -ne 0 ] || skip "runs as root: chmod a-w cannot make the work-dir unwritable"
  seed_status 5 false
  chmod 555 "$W"
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  chmod 755 "$W"
  [ "$status" -eq 1 ]
  contains "$stderr" "could not write"
  [ ! -e "$W/.max-rounds" ]
  # the atomic-write contract's cleanup half
  run bash -c 'ls "$1"/.max-rounds.tmp.* 2>/dev/null | wc -l' _ "$W"
  [ "$(echo "$output" | tr -d '[:space:]')" = "0" ]
}

@test "#1576 a successful write leaves no temp debris either" {
  seed_status 5 false
  run zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  run bash -c 'ls "$1"/.max-rounds.tmp.* 2>/dev/null | wc -l' _ "$W"
  [ "$(echo "$output" | tr -d '[:space:]')" = "0" ]
}

@test "#1576 a zero-byte sidecar is treated as absent by the writer, not as garbage" {
  # Both ends gate on `-s`, so an empty file left by a truncated write must
  # simply not participate — no diagnostic, and the status JSON is the base.
  seed_status 5 false
  : > "$W/.max-rounds"
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  lacks "$stderr" "ignoring an unreadable ceiling"
  [ "$(cat "$W/.max-rounds")" = "8" ]
}

@test "#1576 the --add width boundary is pinned at 18 digits, both sides" {
  seed_status 5 false
  # 19 digits: refused
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 9999999999999999999
  [ "$status" -eq 2 ]
  contains "$stderr" "at most 18 digits"
  [ ! -e "$W/.max-rounds" ]
  # 18 digits: accepted (the boundary is inclusive)
  run zsh "$S" --work-dir "$W" --status "$ST" --add 999999999999999999
  [ "$status" -eq 0 ]
}

@test "#1576 an over-wide max_rounds in the status JSON is refused, not adopted" {
  printf '{"status":"BUDGET_EXHAUSTED","max_rounds":9999999999999999999}\n' > "$ST"
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 1 ]
  contains "$stderr" "no usable max_rounds"
  [ ! -e "$W/.max-rounds" ]
}

@test "#1576 the positive-integer arm and the required arm are DISTINCT diagnostics" {
  # `--add ''` is an EXPLICITLY empty value — the `--add "$VAR"` shape with VAR
  # unset — so it lands on its own arm rather than on 'is required', which would
  # read as though the flag was never passed. A non-numeric value lands on
  # 'must be a positive integer'. The earlier loop asserted only the shared exit
  # code, so none of the three messages was actually exercised.
  seed_status 5 false
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add ''
  [ "$status" -eq 2 ]
  contains "$stderr" "requires a value (got an empty one)"

  local bad
  for bad in three 0 -1; do
    run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add "$bad"
    printf 'case: %s\n' "$bad" >&2
    [ "$status" -eq 2 ]
    contains "$stderr" "must be a positive integer"
  done
  [ ! -e "$W/.max-rounds" ]
}

@test "#1576 jq missing is the typed exit-1 diagnostic, not a raw zsh error" {
  local BIN="$BATS_TEST_TMPDIR/emptybin"
  mkdir -p "$BIN"
  # zsh itself must still be reachable; jq must not be
  ln -sf "$(command -v zsh)" "$BIN/zsh"
  seed_status 5 false
  run --separate-stderr env PATH="$BIN" zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 1 ]
  contains "$stderr" "jq is required"
  [ ! -e "$W/.max-rounds" ]
}

@test "#1576 the writer CLAMPS a ceiling the loop would reduce, and says so" {
  # "Never echo a ceiling the loop would not honour." The writer reads
  # MAX_ROUNDS_SIDECAR_SLACK out of the loop and bounds what it writes AND
  # echoes, so the number the human is told is the number that will be in force.
  local slack cap
  slack=$(sidecar_slack)
  [ -n "$slack" ]
  cap=$(( 5 + slack ))
  seed_status 5 false
  # an existing sidecar already at the cap, plus another +3, would overshoot
  printf '%s\n' "$cap" > "$W/.max-rounds"
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  contains "$stderr" "clamping the new ceiling to the loop's soft cap"
  # BOTH the echoed value and the written file are the cap — not base+add
  [ "$output" = "$cap" ]
  [ "$(cat "$W/.max-rounds")" = "$cap" ]
}

@test "#1576 non-vacuity: just below the cap the writer does NOT clamp" {
  # Without this the clamp could fire unconditionally (or the cap be computed
  # wrongly) and the assertion above would still pass.
  local slack cap
  slack=$(sidecar_slack)
  cap=$(( 5 + slack ))
  seed_status 5 false
  printf '%s\n' "$(( cap - 3 ))" > "$W/.max-rounds"
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  lacks "$stderr" "clamping the new ceiling"
  [ "$(cat "$W/.max-rounds")" = "$cap" ]
}

@test "#1576 an OVER-WIDE existing sidecar is refused by the width guard, not overflowed" {
  # The guard is two-part (`<->` AND 18 digits); the garbage case above exercises
  # only the first. A 19-digit value is all digits, so dropping the width half
  # would take it into the numeric branch and overflow zsh's 64-bit arithmetic
  # to a negative number, silently losing to the status-JSON base with no
  # diagnostic telling the operator the work-dir holds a corrupt ceiling.
  seed_status 5 false
  printf '9999999999999999999\n' > "$W/.max-rounds"
  run --separate-stderr zsh "$S" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  contains "$stderr" "ignoring an unreadable ceiling"
  [ "$(cat "$W/.max-rounds")" = "8" ]
}

@test "#1576 the writer survives without the loop beside it, and says the cap is unenforced" {
  # The slack is read from the sibling script; if it cannot be read the writer
  # must still record the grant (the loop enforces its own cap) — but never
  # silently, since an unreadable constant disables the one guard that keeps
  # this script from echoing a number the loop will reduce.
  local lonely="$BATS_TEST_TMPDIR/lonely"
  mkdir -p "$lonely"
  cp "$S" "$lonely/record-grant.zsh"
  seed_status 5 false
  run --separate-stderr zsh "$lonely/record-grant.zsh" --work-dir "$W" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  [ "$(cat "$W/.max-rounds")" = "8" ]
  contains "$stderr" "could not read MAX_ROUNDS_SIDECAR_SLACK"
}
