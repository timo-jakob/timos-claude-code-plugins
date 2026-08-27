#!/usr/bin/env bats
#
# Behavioral tests for resolve-story-loop.zsh (#562): the local, pre-push review
# loop's state machine (epic #557). The agentic steps (panel + fix) are injected
# as hook commands, so every exit state is driven deterministically. Detection
# is stubbed via DETECT_STACK_BIN (review-dispatch's seam); git runs for real.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/resolve-story-loop.zsh"

  STUB="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "$DETECT_LANGS_JSON"\n' > "$STUB"
  chmod +x "$STUB"

  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
  echo "print(1)" > "$R/app.py"   # the story's diff (in-scope file)

  CRIT='[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"T","description":"d","reviewer":"r"}]'
}

# a test that chmods a dir read-only must not leave it un-removable if an
# assertion aborts mid-way — bats' rm -rf of the tmpdir would then fail and
# bury the real failure. Restore write perms always.
teardown() {
  chmod -R u+rwX "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# run the loop against a python repo with the given hook flags
loop() {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" "$@"
}

# The driving fixtures for each terminal status, defined ONCE so the
# state-machine tests and the telemetry outcome-mapping tests below cannot
# drift apart (a half-applied edit to a duplicated fixture would silently
# change what the outcome test exercises instead of failing).
clean_loop() {      # -> CONVERGED
  loop --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' "$@"
}
stuck_loop() {      # -> ESCALATE_NO_CONVERGENCE (same blocker every round)
  loop --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true' "$@"
}
budget_loop() {     # -> BUDGET_EXHAUSTED (a genuinely distinct blocker each round)
  loop --review-cmd 'printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":$((REVIEW_ROUND*1000)),\"title\":\"b$REVIEW_ROUND\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true' "$@"
}
conflict_loop() {   # -> ESCALATE_CONFLICT (two reviewers, same line, opposed)
  loop --review-cmd 'printf "%s" '"'"'[{"severity":"WARNING","dimension":"performance","file":"app.py","line":1,"title":"c","description":"d","reviewer":"p"},{"severity":"WARNING","dimension":"code_quality","file":"app.py","line":1,"title":"e","description":"d","reviewer":"q"}]'"'"' > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true' "$@"
}
ambiguous_run() {   # -> ESCALATE_AMBIGUOUS (pre-loop: two languages)
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python","java"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wdamb" \
    --review-cmd 'true' --fix-cmd 'true' "$@"
}

@test "#1434 hook mode: a FULL round whose panel writes NO findings is refused, never converged" {
  # Hook mode has no --findings-file guards at all, so this branch is the only
  # thing that keeps a silent panel from converging a run. Round 1 is always
  # full, so `--review-cmd 'true'` (which writes nothing) lands squarely on it.
  loop --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  # the HOOK-mode wording: it names $REVIEW_FINDINGS, the file the hook must
  # write, not the --findings-file a step-mode caller passes
  contains "$output" "is a FULL round and --review-cmd produced no findings"
}

@test "#1434 hook mode: a DELTA round whose panel writes NO findings is still consumed as no findings" {
  # The other arm of the same condition, and the reason it is conditional: a
  # delta round cannot converge, so a silent panel there is harmless and the
  # `[]` default stands. Round 1 finds a blocker, the fix hook really moves the
  # tree, and from round 2 on the panel writes nothing.
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'echo "print(2)" > "$REVIEW_REPO/fixed.py"'
  # round 2 is consumed as zero blockers and promotes the closing sweep; round
  # 3 IS that sweep — a full round whose panel is again silent, so it refuses
  [ "$status" -eq 2 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  contains "$output" "round 3 is a FULL round and --review-cmd produced no findings"
  # the delta round really did run and really did promote: without the
  # conditional the run would have refused at round 2 instead
  [ "$(cat "$BATS_TEST_TMPDIR/wd/.closing-sweep")" = "3" ]
  [ -s "$BATS_TEST_TMPDIR/wd/changelist-2.json" ]
  [ "$(jq '.summary.blocking' "$BATS_TEST_TMPDIR/wd/changelist-2.json")" -eq 0 ]
}

@test "clean story converges in round 1 (exit 0), one-line status JSON" {
  clean_loop
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  # stdout must be exactly the status JSON (no leaked variable echoes)
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
}

@test "seeded blocker fixed and converges by round 2" {
  # round 1 emits a blocker; round 2 (post-fix) emits nothing
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  # #563: every round's changelist is retained for the review dossier
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 2 ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 1 ]
}

@test "unfixable identical blocker exits ESCALATE_NO_CONVERGENCE before round 3" {
  stuck_loop
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  # early exit at round 2 — round 3 never wasted
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  echo "$output" | jq -e '.escalation_reasons | index("non_converging_blocker")' >/dev/null
}

@test "identity false trip (#983): a disjoint-title neighbour of a fixed blocker auto-continues, never escalates" {
  # round 1: a blocker; round 2: it is FIXED and a genuinely different finding
  # lands 3 lines away (disjoint title) — a proximity false trip that must NOT
  # ESCALATE_NO_CONVERGENCE; round 3 is clean, so the loop CONVERGES. The old
  # proximity-only matcher would have escalated at round 2 (the #976 bug).
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in matcher\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":8,\"title\":\"missing pipefail on the download pipeline\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  # round 2 recorded the false trip and did NOT flag non-convergence
  [ "$(echo "$output" | jq '.round_changelists[1].summary.false_trips')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists[1].non_converging')" = "false" ]
  [ "$(echo "$output" | jq '.round_changelists[1].blocking[0].false_trip')" = "true" ]
  # the loop history carries the per-round false-trip count (#983)
  [ "$(echo "$output" | jq '.history[1].false_trips')" -eq 1 ]
  # never escalated on non-convergence
  echo "$output" | jq -e '(.escalation_reasons | index("non_converging_blocker")) | not' >/dev/null
}

@test "identity false trip (#983) on the final budget round: BUDGET_EXHAUSTED, not ESCALATE_NO_CONVERGENCE" {
  # the fate ladder puts round==max_rounds AFTER the non-converging check, so a
  # false trip on the last round must fall through to BUDGET_EXHAUSTED (still
  # recording summary.false_trips), never flip the terminal verdict.
  loop --max-rounds 2 \
       --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in matcher\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; else printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":8,\"title\":\"missing pipefail on the download pipeline\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.false_trips')" -eq 1 ]
  [ "$(echo "$output" | jq '.history[1].false_trips')" -eq 1 ]
  echo "$output" | jq -e '(.escalation_reasons | index("non_converging_blocker")) | not' >/dev/null
}

@test "round budget exhaustion exits BUDGET_EXHAUSTED at the default cap of 5 (#993)" {
  # A GENUINELY different blocker each round -> never non_converging -> runs out
  # the budget. Non-convergence is fingerprinted on [file, dimension] + line
  # proximity (#606), NOT the title — so a distinct blocker must differ in
  # location: the 1000-line jumps inside budget_loop are the ONLY safeguard here
  # — the b1..bN titles carry no significant (>= 4-char) token, so they would
  # route to the ambiguous branch rather than clear as an identity false trip
  # (#983). The terminal verdict is therefore the budget, not non-convergence,
  # on the line spacing alone; widen the proximity window and this test flips to
  # ESCALATE_NO_CONVERGENCE.
  # This also pins MAX_REVIEW_ROUNDS: no --max-rounds is passed, so the run
  # length IS the default (5 since #993, previously 3).
  budget_loop
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 5 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 5 ]
  # five rounds genuinely executed and the budget was spent for the intended
  # reason — not an escalation that happened to echo max_rounds
  [ "$(echo "$output" | jq '.history | length')" -eq 5 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 5 ]
  [ "$(echo "$output" | jq '.escalation_reasons | length')" -eq 0 ]
}

@test "an explicit --max-rounds BELOW the default still overrides it (#993)" {
  # same never-repeating blocker stream, but the caller asks for 2 rounds: the
  # flag wins over MAX_REVIEW_ROUNDS, so the budget is spent at round 2.
  budget_loop --max-rounds 2
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 2 ]
}

@test "an explicit --max-rounds ABOVE the default is never clamped to it (#993)" {
  # The production path the interactive extension drives: a granted extension
  # resumes with `--max-rounds <prev_max + 3>` — 8 once the new default of 5 is
  # spent, a ceiling ABOVE MAX_REVIEW_ROUNDS. That exact value is used here so
  # the fixture IS the first-grant ceiling. A regression that clamped the flag
  # to the compiled constant (or re-derived the ceiling from it after parsing)
  # would stop at 5 while every below-default test stayed green.
  budget_loop --max-rounds 8
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 8 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 8 ]
  # all eight rounds genuinely ran — the budget was spent, not short-circuited
  [ "$(echo "$output" | jq '.history | length')" -eq 8 ]
}

@test "surviving conflict exits ESCALATE_CONFLICT" {
  conflict_loop
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_CONFLICT" ]
}

@test "unsupported/ambiguous repo type exits ESCALATE_AMBIGUOUS before any round" {
  ambiguous_run
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_AMBIGUOUS" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 0 ]
}

@test "--no-review skips the loop entirely (SKIPPED, exit 0, needs no repo)" {
  run zsh "$S" --no-review
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "SKIPPED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 0 ]
}

# --- telemetry/v1 (#1004) ---------------------------------------------------
# The loop emits through the SHARED emitter now, so these assert the envelope
# it is responsible for populating; the payload's own shape is
# tests/build-telemetry-record.bats.

# Assert the envelope invariants that must hold on EVERY emitted record,
# whatever the terminal status: exactly one record, the contract's own
# validator, and the fields a regression would most plausibly break.
# $1 sink · $2 expected outcome · $3 expected payload.status
assert_envelope() {
  local f="$1" want_outcome="$2" want_status="$3"
  [ "$(grep -c '' "$f")" -eq 1 ] || { echo "expected exactly 1 record in $f"; return 1; }
  [ "$(jq -r '.schema' "$f")" = "telemetry/v1" ] || {
    echo "schema: want telemetry/v1, got $(jq -r '.schema' "$f")"; return 1; }
  [ "$(jq -r '.kind' "$f")" = "run" ] || {
    echo "kind: want run, got $(jq -r '.kind' "$f")"; return 1; }
  [ "$(jq -r '.pipeline' "$f")" = "review-loop" ] || {
    echo "pipeline: want review-loop, got $(jq -r '.pipeline' "$f")"; return 1; }
  [ "$(jq -r '.outcome' "$f")" = "$want_outcome" ] || {
    echo "outcome: want $want_outcome, got $(jq -r '.outcome' "$f")"; return 1; }
  [ "$(jq -r '.payload.status' "$f")" = "$want_status" ] || {
    echo "payload.status: want $want_status, got $(jq -r '.payload.status' "$f")"; return 1; }
  # AC5: repo is never null — a record must never be anonymous
  [ "$(jq -r '.repo | type' "$f")" = "string" ] || {
    echo "repo type: want string, got $(jq -r '.repo | type' "$f")"; return 1; }
  # a SHAPE check, not an emptiness one (the emitter exits rather than emit an
  # empty repo, so that branch was unreachable): this catches a fabricated
  # multi-segment or whitespace-bearing identity, which is what _derive_repo's
  # local-path handling exists to prevent
  jq -e '.repo | test("^[^/[:space:]]+(/[^/[:space:]]+)?$")' "$f" >/dev/null || {
    echo "repo has a fabricated/ill-formed shape: $(jq -r '.repo' "$f")"; return 1; }
  # AC6: wall_s is a NUMBER on every run record (jq -r prints 0 and null alike,
  # so type is the only assertion that separates them)
  [ "$(jq -r '.wall_s | type' "$f")" = "number" ] || {
    echo "wall_s type: want number, got $(jq -r '.wall_s | type' "$f")"; return 1; }
  # ts is the loop's LOGICAL start (--ts from .t0), not the terminal moment —
  # drop --ts and the emitter silently defaults to now, mis-stamping run_id too
  [ "$(jq -r '.ts | type' "$f")" = "number" ] || {
    echo "ts type: want number, got $(jq -r '.ts | type' "$f")"; return 1; }
  # run_id is the contract's join key — a wrong/empty pipeline prefix must fail
  jq -e '.run_id | test("^review-loop-[0-9]+-[0-9a-f]{4}$")' "$f" >/dev/null || {
    echo "bad run_id: $(jq -r '.run_id' "$f")"; return 1; }
  # AC7: and the whole thing conforms to the contract
  zsh "$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh" "$f" --require-records
}

@test "the terminal record is a telemetry/v1 envelope wrapping the review-loop payload (#1004)" {
  T="$BATS_TEST_TMPDIR/telemetry.jsonl"
  git -C "$R" remote add origin https://github.com/timo-jakob/widget.git
  clean_loop --issue 1004 --telemetry-file "$T"
  [ "$status" -eq 0 ]
  assert_envelope "$T" success CONVERGED
  [ "$(jq '.issue' "$T")" -eq 1004 ]
  # repo is derived by the emitter — the pre-contract record had none at all
  [ "$(jq -r '.repo' "$T")" = "timo-jakob/widget" ]
  [ "$(jq -r '.repo_type' "$T")" = "python" ]
  [ "$(jq -r '.tokens' "$T")" = "null" ]
  [ "$(jq '.payload.rounds' "$T")" -eq 1 ]
  # AC8 (override half): --telemetry-file must be the ONLY sink written —
  # emitting to both would double-count every run in the shared stream
  [ ! -e "$R/.claude/telemetry/telemetry.jsonl" ]
}

@test "the emitter's basename fallback still yields a non-null repo with no git remote (#1004)" {
  # every other test leaves $R remote-less; pin what that actually produces
  T="$BATS_TEST_TMPDIR/norem.jsonl"
  clean_loop --telemetry-file "$T"
  [ "$status" -eq 0 ]
  assert_envelope "$T" success CONVERGED
  [ "$(jq -r '.repo' "$T")" = "repo" ]   # basename of $BATS_TEST_TMPDIR/repo
}

@test "the loop hands the emitter the builder's FULL payload, not a trimmed one (#1004)" {
  T="$BATS_TEST_TMPDIR/full.jsonl"
  ST="$BATS_TEST_TMPDIR/status.json"
  clean_loop --telemetry-file "$T" --status-file "$ST"
  [ "$status" -eq 0 ]
  # rebuild the payload from the same status JSON and require byte equality
  zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/build-telemetry-record.zsh" \
    --status "$ST" > "$BATS_TEST_TMPDIR/expected-payload.json"
  [ "$(jq -cS '.payload' "$T")" = "$(jq -cS '.' "$BATS_TEST_TMPDIR/expected-payload.json")" ]
}

@test "the default sink is the shared .claude/telemetry/telemetry.jsonl (#1004)" {
  clean_loop --issue 7
  [ "$status" -eq 0 ]
  D="$R/.claude/telemetry/telemetry.jsonl"
  assert_envelope "$D" success CONVERGED
  [ "$(jq '.issue' "$D")" -eq 7 ]
  # the pre-contract per-pipeline file is NOT written any more
  [ ! -e "$R/.claude/telemetry/review-loop.jsonl" ]
}

# AC4 — the outcome mapping, asserted PER STATUS so a broken mapping names its
# own failing test instead of aborting the six that follow it.

@test "outcome mapping: CONVERGED -> success (#1004)" {
  T="$BATS_TEST_TMPDIR/converged.jsonl"
  clean_loop --telemetry-file "$T"
  [ "$status" -eq 0 ]
  assert_envelope "$T" success CONVERGED
}

@test "outcome mapping: SKIPPED -> success (#1004)" {
  # the --no-review fast path: no work-dir, so t_begin falls back to $t0
  T="$BATS_TEST_TMPDIR/skipped.jsonl"
  run zsh "$S" --repo "$R" --no-review --telemetry-file "$T"
  [ "$status" -eq 0 ]
  assert_envelope "$T" success SKIPPED
}

@test "outcome mapping: ESCALATE_NO_CONVERGENCE -> escalated (#1004)" {
  T="$BATS_TEST_TMPDIR/noconv.jsonl"
  stuck_loop --telemetry-file "$T"
  [ "$status" -eq 12 ]
  assert_envelope "$T" escalated ESCALATE_NO_CONVERGENCE
}

@test "outcome mapping: BUDGET_EXHAUSTED -> escalated (#1004)" {
  T="$BATS_TEST_TMPDIR/budget.jsonl"
  budget_loop --telemetry-file "$T"
  [ "$status" -eq 13 ]
  assert_envelope "$T" escalated BUDGET_EXHAUSTED
}

@test "outcome mapping: ESCALATE_CONFLICT -> escalated (#1004)" {
  T="$BATS_TEST_TMPDIR/conflict.jsonl"
  conflict_loop --telemetry-file "$T"
  [ "$status" -eq 11 ]
  assert_envelope "$T" escalated ESCALATE_CONFLICT
}

@test "outcome mapping: ESCALATE_AMBIGUOUS -> escalated, with a null repo_type (#1004)" {
  # pre-loop dispatch failure: repo_type is not known yet, so the envelope must
  # carry null there and STILL validate
  T="$BATS_TEST_TMPDIR/ambiguous.jsonl"
  ambiguous_run --telemetry-file "$T"
  [ "$status" -eq 10 ]
  assert_envelope "$T" escalated ESCALATE_AMBIGUOUS
  [ "$(jq -r '.repo_type' "$T")" = "null" ]
}

@test "outcome mapping: ERROR -> failed (#1004)" {
  T="$BATS_TEST_TMPDIR/error.jsonl"
  stuck_loop --test-cmd 'false' --telemetry-file "$T"
  [ "$status" -eq 1 ]
  assert_envelope "$T" failed ERROR
  # ERROR is NOT an escalation, so the payload's escalation field is null —
  # the null bucket of an escalation breakdown is not a success bucket
  [ "$(jq -r '.payload.escalation' "$T")" = "null" ]
}

@test "a telemetry failure never changes the loop's exit, and leaves no trace (#1004)" {
  # root ignores the mode bits, so the unwritable-dir premise silently evaporates
  # and the test would pass having exercised nothing
  [ "$(id -u)" -ne 0 ] || skip "runs as root: chmod a-w cannot make the sink unwritable"
  local BAD="$BATS_TEST_TMPDIR/nosink"
  mkdir -p "$BAD"
  chmod a-w "$BAD"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' \
    --telemetry-file "$BAD/sub/telemetry.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # the emitter really did fail: nothing at the named sink...
  [ ! -e "$BAD/sub/telemetry.jsonl" ]
  # ...and no silent fallback to the default sink either
  [ ! -e "$R/.claude/telemetry/telemetry.jsonl" ]
  # and it said so, naming THIS failure — "emit-telemetry" alone would also
  # match an unknown-flag regression, keeping the test green on the wrong cause
  contains "$stderr" "cannot create sink directory"
}

@test "a failed payload build emits NO record at all, and never changes the exit (#1004)" {
  # an envelope around an empty payload would PASS validation (payload is OPEN)
  # and silently poison the convergence metrics, so the loop must emit nothing
  T="$BATS_TEST_TMPDIR/nopayload.jsonl"
  local STUB_BUILDER="$BATS_TEST_TMPDIR/bad-builder.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_BUILDER"
  chmod +x "$STUB_BUILDER"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    RESOLVE_LOOP_PAYLOAD_BIN="$STUB_BUILDER" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  [ ! -e "$T" ]
  [ ! -e "$R/.claude/telemetry/telemetry.jsonl" ]
}

@test "--no-review with no --repo emits nothing, and writes into no cwd (#1004)" {
  # The emitter's --repo-dir default is "." — so if the loop ever stopped
  # passing --repo-dir, or resolved the sink before the guard, the record would
  # land in whatever directory the process happens to run from. Run from a
  # scratch cwd we own so that regression is caught HERE, deterministically,
  # instead of depending on where bats was launched.
  # NB: `cd`, not `env -C` — -C is a GNU coreutils extension and this suite
  # also runs on macos-latest, whose BSD env would abort with "illegal option".
  # bats runs each @test in its own subshell, so this cannot leak to siblings.
  local CWD="$BATS_TEST_TMPDIR/elsewhere"
  mkdir -p "$CWD"
  # a marker stub proves the telemetry block was never ENTERED at all — the
  # actual contract. Without it the test only fails for a compound regression,
  # because a dropped `-d "$repo"` guard would still hand the emitter an empty
  # --repo-dir, which it rejects before resolving any sink.
  local MARK="$BATS_TEST_TMPDIR/telemetry-entered"
  local PSTUB="$BATS_TEST_TMPDIR/marker-builder.sh"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$MARK" > "$PSTUB"
  chmod +x "$PSTUB"
  cd "$CWD"
  run env RESOLVE_LOOP_PAYLOAD_BIN="$PSTUB" zsh "$S" --no-review
  [ "$status" -eq 0 ]
  [ ! -e "$MARK" ]
  [ "$(echo "$output" | jq -r '.status')" = "SKIPPED" ]
  # nothing anywhere: not the cwd, not the repo
  [ ! -e "$CWD/.claude" ]
  [ ! -e "$R/.claude/telemetry/telemetry.jsonl" ]
}

@test "--no-review WITH a valid --repo does emit, so the guard is about the repo dir alone (#1004)" {
  # the paired positive case: without it, the test above would also pass if
  # SKIPPED simply never emitted telemetry at all
  T="$BATS_TEST_TMPDIR/skip-positive.jsonl"
  run zsh "$S" --repo "$R" --no-review --telemetry-file "$T"
  [ "$status" -eq 0 ]
  assert_envelope "$T" success SKIPPED
}

# --- the telemetry run_id sidecar (#995, test cases #1028 / #1034) ----------
#
# An enrichment MUST carry the run_id of the run it enriches, and the emitter
# only ever printed it — so before this the id was unrecoverable and any
# promotion enrichment would have minted an orphan. The sidecar is what makes
# the join possible; it deliberately does NOT go into the status JSON, which is
# written before telemetry runs so a slow or broken emitter cannot delay or
# damage the loop's primary output.

@test "#1028 a terminal exit writes the EMITTED record's run_id to <work-dir>/.telemetry-run-id" {
  T="$BATS_TEST_TMPDIR/sidecar.jsonl"
  WD="$BATS_TEST_TMPDIR/wd"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --issue 995 --telemetry-file "$T" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  # the loop's stdout contract is untouched: EXACTLY one JSON object, the status
  echo "$output" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # ...and the record is NOT on stdout, which capturing it could easily leak
  run -1 grep -q 'telemetry/v1' <<<"$output"

  [ -s "$WD/.telemetry-run-id" ]
  # the id must be THE emitted record's, not a fresh or fabricated one — that
  # is the whole point, and a plausible-looking wrong id joins to nothing
  [ "$(cat "$WD/.telemetry-run-id")" = "$(jq -r '.run_id' "$T")" ]
  # one line, no trailing junk a `$(cat …)` consumer would carry into --run-id
  [ "$(grep -c '' "$WD/.telemetry-run-id")" -eq 1 ]
}

@test "#1028 an emitter failure leaves the exit and status untouched, and writes NO sidecar" {
  [ "$(id -u)" -ne 0 ] || skip "runs as root: chmod a-w cannot make the sink unwritable"
  local BAD="$BATS_TEST_TMPDIR/nosink"
  mkdir -p "$BAD"
  chmod a-w "$BAD"
  WD="$BATS_TEST_TMPDIR/wd-failed-emit"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' \
    --telemetry-file "$BAD/sub/telemetry.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # nothing landed in a sink, so there is nothing to join to — an id here would
  # point at a record that does not exist
  [ ! -e "$WD/.telemetry-run-id" ]
}

@test "#1028 a failed payload build writes no sidecar either (no record, no id)" {
  T="$BATS_TEST_TMPDIR/nopayload-sidecar.jsonl"
  WD="$BATS_TEST_TMPDIR/wd-nopayload"
  local STUB_BUILDER="$BATS_TEST_TMPDIR/bad-builder2.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB_BUILDER"
  chmod +x "$STUB_BUILDER"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    RESOLVE_LOOP_PAYLOAD_BIN="$STUB_BUILDER" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ ! -e "$T" ]
  [ ! -e "$WD/.telemetry-run-id" ]
}

@test "#1028 a fresh (non---resume) run clears a stale sidecar rather than inheriting it" {
  # A re-used work-dir must never hand the caller the PREVIOUS run's id: the
  # enrichment would join onto a foreign record and quietly attribute one
  # story's promotion to another.
  [ "$(id -u)" -ne 0 ] || skip "runs as root: chmod a-w cannot make the sink unwritable"
  WD="$BATS_TEST_TMPDIR/wd-stale"
  mkdir -p "$WD"
  printf 'review-loop-1-stale\n' > "$WD/.telemetry-run-id"
  local BAD="$BATS_TEST_TMPDIR/nosink-stale"
  mkdir -p "$BAD"
  chmod a-w "$BAD"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' \
    --telemetry-file "$BAD/sub/telemetry.jsonl"
  [ "$status" -eq 0 ]
  # the emit failed, so nothing rewrote it — and the stale id is gone, not kept
  [ ! -e "$WD/.telemetry-run-id" ]
}

@test "#1028 a --resume does not clear the sidecar at START — only a fresh run does" {
  # The start-of-run clear is guarded by `(( ! resume ))` on purpose: a resume
  # continues the same loop. The observable case is a resume that exits
  # NON-TERMINALLY — AWAITING_FIX emits no telemetry, so nothing rewrites the
  # sidecar and only the guard can explain a surviving id. (Every TERMINAL exit
  # now clears immediately before its own emission attempt, so this is the one
  # path where the start-of-run guard is visible at all.)
  WD="$BATS_TEST_TMPDIR/wd-resume-keeps"
  T="$BATS_TEST_TMPDIR/resume-keeps.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --telemetry-file "$T" --issue 995 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  local first_id
  first_id=$(cat "$WD/.telemetry-run-id")
  [ -n "$first_id" ]

  # step mode, blockers remain, budget left -> AWAITING_FIX (exit 20): a
  # non-terminal exit, so no telemetry is emitted on it. The finding must be
  # DISTINCT from round 1's, or the cross-round match trips non-convergence and
  # the run exits terminally instead.
  local FIND="$BATS_TEST_TMPDIR/resume-keeps-findings.json"
  printf '%s' '[{"severity":"CRITICAL","dimension":"tests","file":"app.py","line":500,"title":"a different blocker","description":"d","reviewer":"r"}]' > "$FIND"
  # the in-session fix, so round 2 has a real delta to review: since #1434 a
  # resumed round whose delta is empty while blockers are carried is refused
  # (its findings were produced against an empty scope), which would put this
  # test on a subject that is not the telemetry sidecar
  echo "x = 1" > "$R/fixed.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 5 \
    --telemetry-file "$T" --issue 995 --findings-file "$FIND"
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  # the id is STILL there, unchanged: the resume did not clear it at start
  [ -s "$WD/.telemetry-run-id" ]
  [ "$(cat "$WD/.telemetry-run-id")" = "$first_id" ]
}

@test "#1028 a failed sidecar WRITE stays swallowed: exit, status and stderr are untouched" {
  # The branch the brace-group + 2>/dev/null exist for — the emitter SUCCEEDED
  # and the record landed, but the sidecar path cannot be opened. Every other
  # negative test makes the EMIT fail instead, so a regression dropping the
  # redirection (leaking an open-failure onto the loop's real stderr, which
  # callers parse alongside the status JSON) or the `|| true` would slip past.
  WD="$BATS_TEST_TMPDIR/wd-write-fail"
  T="$BATS_TEST_TMPDIR/write-fail.jsonl"
  mkdir -p "$WD"
  # a DIRECTORY at the sidecar path: `print > dir` cannot open it. Planted
  # before a --resume so the fresh-start `rm -f` (which also refuses a
  # directory) is not what is under test here.
  mkdir -p "$WD/.telemetry-run-id"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --telemetry-file "$T" --issue 995 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  # this FRESH run also exercises the clear's failure branch (rm -f refuses the
  # directory) — and the clear is deliberately NOT silent, because a silent
  # failure leaves a foreign story's id in place with nothing to notice it
  contains "$stderr" "could not clear the stale telemetry run-id sidecar"
  [ -d "$WD/.telemetry-run-id" ]

  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --telemetry-file "$T" --issue 995 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  # the loop is unaffected: its exit, its status JSON...
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # ...and the record still landed (the emit succeeded; only the sidecar failed)
  [ "$(grep -c '' "$T")" -eq 2 ]
  # ...and nothing about the sidecar leaked to stderr
  lacks "$stderr" ".telemetry-run-id"
}

@test "#1034 a FAILED emission on a later terminal exit leaves NO id, never the earlier one" {
  # The sidecar is cleared at fresh-run start AND immediately before each
  # emission attempt, so it holds this exit's id or nothing. Without the second
  # clear, an extended run whose later emission fails keeps the EARLIER exit's
  # id — a reader then finds a non-empty sidecar, the "no id, no enrichment"
  # valve never fires, and the enrichment joins a superseded record.
  [ "$(id -u)" -ne 0 ] || skip "runs as root: chmod a-w cannot make the sink unwritable"
  WD="$BATS_TEST_TMPDIR/wd-stale-after-fail"
  T="$BATS_TEST_TMPDIR/stale-after-fail.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --telemetry-file "$T" --issue 995 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ -s "$WD/.telemetry-run-id" ]                      # first exit wrote an id

  # resume into a CONVERGED exit whose emission cannot land
  local BAD="$BATS_TEST_TMPDIR/nosink-after-fail"
  mkdir -p "$BAD"
  chmod a-w "$BAD"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --telemetry-file "$BAD/sub/telemetry.jsonl" --issue 995 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # the earlier id must be GONE — not left to be joined to the wrong record
  [ ! -e "$WD/.telemetry-run-id" ]
}

@test "#1034 an extended loop leaves the LAST terminal exit's run_id in the sidecar" {
  # escalate -> grant -> --resume -> converge. SKILL.md reads the sidecar on the
  # CONVERGED exit, so that is the id it must find; the earlier escalation's id
  # must have been overwritten, not kept.
  WD="$BATS_TEST_TMPDIR/wd-extended-sidecar"
  XT="$BATS_TEST_TMPDIR/extended-sidecar.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --telemetry-file "$XT" --issue 995 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  local first_id
  first_id=$(cat "$WD/.telemetry-run-id")
  [ "$first_id" = "$(jq -r 'select(.payload.status == "BUDGET_EXHAUSTED") | .run_id' "$XT")" ]

  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --telemetry-file "$XT" --issue 995 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]

  local final_id
  final_id=$(cat "$WD/.telemetry-run-id")
  [ "$final_id" != "$first_id" ]
  [ "$final_id" = "$(jq -r 'select(.payload.status == "CONVERGED") | .run_id' "$XT")" ]
  # and it really is joinable: the record it names is in the sink
  [ "$(jq -s --arg id "$final_id" '[.[] | select(.run_id == $id)] | length' "$XT")" -eq 1 ]
}

# --- promotion_phase in the status JSON (#995, test case #1033) -------------

@test "#995 --no-review with a VALID --promote is refused before anything is emitted" {
  # The three existing --no-review --promote tests all pass an absent/empty/
  # flag-shaped value, so _need_val answers them during argv parsing and none
  # ever reaches the guard. Only a VALID file exercises it — and the stake is
  # telemetry: the fast path reaches emit_and_exit ABOVE _validate_promote, so
  # without the guard this invocation emits a SKIPPED record stamped
  # promotion_phase:true from a promote file nothing ever checked.
  P="$BATS_TEST_TMPDIR/valid-promote.json"
  cat > "$P" <<'EOF'
[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]
EOF
  T="$BATS_TEST_TMPDIR/no-review-promote.jsonl"
  WD="$BATS_TEST_TMPDIR/wd-no-review-promote"
  run zsh "$S" --repo "$R" --no-review --promote "$P" \
    --telemetry-file "$T" --work-dir "$WD"
  [ "$status" -eq 2 ]
  contains "$output" "--promote is meaningless with --no-review"
  # nothing was emitted, and no join key was left behind — a guard moved below
  # the SKIPPED emit would fail exactly here
  [ ! -e "$T" ]
  [ ! -e "$WD/.telemetry-run-id" ]
}

@test "#1033 the status JSON carries promotion_phase — true under --promote, false without" {
  P="$BATS_TEST_TMPDIR/phase-promote.json"
  cat > "$P" <<'EOF'
[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]
EOF
  # without the flag: a phase-1 run, explicitly false rather than absent
  suggestion_loop
  [ "$status" -eq 0 ]
  # STRICT equality, not `jq -r … = "false"`: jq -r prints the boolean false and
  # the STRING "false" identically, while the documented metric predicate
  # (select(.payload.promotion_phase != true)) is a strict JSON comparison — so a
  # --argjson -> --arg slip would keep every promotion record in both published
  # rates with a type-blind suite still green
  echo "$output" | jq -e '.promotion_phase == false' >/dev/null
  [ "$(echo "$output" | jq 'has("promotion_phase")')" = "true" ]

  # with it: the promotion sub-loop, which the documented metrics exclude
  suggestion_loop --promote "$P"
  [ "$status" -eq 12 ]
  echo "$output" | jq -e '.promotion_phase == true' >/dev/null
}

@test "#1033 promotion_phase reaches the telemetry payload, not just the status JSON" {
  # the status JSON is only the carrier; the metric reads .payload.promotion_phase
  P="$BATS_TEST_TMPDIR/phase-payload.json"
  cat > "$P" <<'EOF'
[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]
EOF
  T="$BATS_TEST_TMPDIR/phase.jsonl"
  suggestion_loop --promote "$P" --telemetry-file "$T" --issue 995
  [ "$status" -eq 12 ]
  jq -e '.payload.promotion_phase == true' "$T" >/dev/null

  T2="$BATS_TEST_TMPDIR/phase1.jsonl"
  suggestion_loop --telemetry-file "$T2" --issue 995
  [ "$status" -eq 0 ]
  jq -e '.payload.promotion_phase == false' "$T2" >/dev/null
}

@test "a non-numeric --issue is a usage error, not a silently dropped record (#1004)" {
  # it rides into the envelope, whose contract is a non-negative integer; the
  # emitter would reject it behind `|| true`, costing the whole record
  run zsh "$S" --repo "$R" --base main --issue '#123' --no-review
  [ "$status" -eq 2 ]
  # ...and for the RIGHT reason: the parser catch-all ("unknown flag: --issue")
  # also exits 2, so a dropped --issue case would otherwise pass here
  contains "$output" "must be a non-negative integer"
}

@test "a red gate after a fix aborts as an operational error (exit 1), not a verdict" {
  # blocker every round, fix leaves tests red -> --test-cmd fails in round 1
  loop --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true' --test-cmd 'false'
  [ "$status" -eq 1 ]
  # bats merges stderr into $output, so parse only the JSON status line
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "usage: missing hooks without --no-review is a usage error (exit 2)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main
  [ "$status" -eq 2 ]
}

@test "--resume continues from a prior work-dir at last_round+1 and can converge" {
  WD="$BATS_TEST_TMPDIR/wd-resume"
  XT="$BATS_TEST_TMPDIR/extended.jsonl"   # both terminal exits share this sink
  # First pass: budget 1 -> a single round with a blocker -> BUDGET_EXHAUSTED at round 1.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 --telemetry-file "$XT" --issue 1004 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]

  # Resume with a raised ceiling; this round emits nothing -> CONVERGED at round 2.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 --telemetry-file "$XT" --issue 1004 \
    --review-cmd 'sleep 2; printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # continued, did not restart: exit round is 2, and history/changelists span both passes
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 2 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 2 ]
  # AC3's PLURAL half (#1004): a second terminal exit must APPEND, and the two
  # records must stay groupable as ONE loop — same ts (.t0 is not rewritten on
  # --resume) with a growing wall_s. Those are exactly the facts the documented
  # group_by([.repo,.issue,.ts]) | min_by/max_by(.wall_s) consumer queries
  # stand on; a regression splitting one loop into two ungroupable ones would
  # otherwise leave every single-record test green.
  [ "$(grep -c '' "$XT")" -eq 2 ]
  [ "$(jq -s '.[0].ts == .[1].ts' "$XT")" = "true" ]
  # ...and the issue half of the documented [.repo,.issue,.ts] grouping key,
  # which a null-issue fixture would leave unexercised
  [ "$(jq -s '.[0].issue == .[1].issue' "$XT")" = "true" ]
  [ "$(jq -s '.[0].issue' "$XT")" -eq 1004 ]
  # STRICTLY growing: the resume's deliberately slow round makes this
  # deterministic — with two sub-second passes a `>=` would tie and pass even
  # under the regression it is meant to catch. NB the fix is a slow round, not
  # a back-dated .t0: rewriting .t0 would break the ts-equality above, which is
  # the same invariant.
  [ "$(jq -s '.[1].wall_s > .[0].wall_s' "$XT")" = "true" ]
  [ "$(jq -s -r '[.[].outcome] | join(",")' "$XT")" = "escalated,success" ]
  # ...and the DOCUMENTED ordering rule, proven on real loop output rather than
  # hand-emitted fixtures: min_by is the first-pass verdict (it escalated),
  # max_by the final one (it converged). A min<->max flip fails here.
  [ "$(jq -s 'group_by([.repo,.issue,.ts]) | map(min_by(.wall_s))[0].payload.status' -r "$XT")" = "BUDGET_EXHAUSTED" ]
  [ "$(jq -s 'group_by([.repo,.issue,.ts]) | map(max_by(.wall_s))[0].payload.status' -r "$XT")" = "CONVERGED" ]
  run zsh "$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh" "$XT" --require-records
  [ "$status" -eq 0 ]
}

@test "--resume carries prev_changelist so the first extension round can trip NO_CONVERGENCE" {
  WD="$BATS_TEST_TMPDIR/wd-resume-nc"
  # First pass budget 1: one blocker, one round, exhausts (no prior round to compare against yet).
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]

  # Resume: the SAME blocker recurs -> non-convergence must fire against the carried prior round.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  # exited on the first resumed round (round 2), not after burning to the new ceiling
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
}

@test "--resume without prior history in the work-dir is a usage error (exit 2)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-empty" --resume \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 2 ]
}

# seed a real one-round BUDGET_EXHAUSTED work-dir for the resume-guard tests
seed_exhausted_wd() {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$1" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
}

@test "--resume with a corrupt round number in history is an internal error (exit 1)" {
  WD="$BATS_TEST_TMPDIR/wd-corrupt-round"
  seed_exhausted_wd "$WD"
  printf '%s\n' '{"round":"x","blocking":1,"conflicts":0,"non_converging":false}' > "$WD/history.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 1 ]
}

@test "--resume with the prior round's changelist missing is an internal error (exit 1)" {
  WD="$BATS_TEST_TMPDIR/wd-lost-changelist"
  seed_exhausted_wd "$WD"
  rm "$WD/changelist-1.json"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 1 ]
}

@test "--resume with a corrupt (partial) history line is an internal error (exit 1)" {
  WD="$BATS_TEST_TMPDIR/wd-corrupt-partial"
  seed_exhausted_wd "$WD"
  printf '{"round":' >> "$WD/history.jsonl"   # a run killed mid-append
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 1 ]
}

@test "a non-positive --max-rounds is a usage error (exit 2), not an empty-status exit 1" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-zero" --max-rounds 0 \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 2 ]
}

@test "--resume with a ceiling at or below the resumed round is a usage error (exit 2)" {
  WD="$BATS_TEST_TMPDIR/wd-low-ceiling"
  seed_exhausted_wd "$WD"
  # default --max-rounds (5) is fine, but an explicit ceiling <= last round must refuse
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 1 \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 2 ]
}

@test "an unresolvable --base is an operational error (exit 1), never CONVERGED (#910)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base refs/heads/does-not-exist --work-dir "$BATS_TEST_TMPDIR/wd-badbase" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 1 ]
  run -1 grep -q 'CONVERGED' <<< "$output"
}

@test "scope refreshes each round: a file the fix pass creates is reviewed next round (#911, delta-scoped since #1434)" {
  WD="$BATS_TEST_TMPDIR/wd-scope-refresh"
  # round 1 (full): blocker + the fix pass creates helper.py; round 2 (delta):
  # clean, so it promotes round 3 to the closing full sweep, which converges.
  # The review hook snapshots its scope per round so we can assert the refresh.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope-r$REVIEW_ROUND.txt"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = 1" > "$REVIEW_REPO/helper.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # capture BEFORE any `run !` below: `run` overwrites $output, so a later
  # `jq <<<"$output"` would be reading grep's output, not the loop's
  local rounds; rounds="$(echo "$output" | jq -r '.rounds')"
  # the closing full sweep sees the WHOLE story diff again, which is the safety
  # net that makes the delta scoping below safe to have
  [ "$rounds" = "3" ]
  # round 1 reviewed the real pre-fix scope (positive assertion proves the
  # snapshot captured content, so the negative one below discriminates)
  grep -qx 'app.py' "$WD/scope-r1.txt"
  run -1 grep -qx 'helper.py' "$WD/scope-r1.txt"
  # round 2 is a DELTA round: it must see the fix's new file, and ONLY that —
  # app.py has not changed since round 1's tree, so re-reviewing it would be the
  # independent-repeat behaviour #1434 removed
  grep -qx 'helper.py' "$WD/scope-r2.txt"
  run -1 grep -qx 'app.py' "$WD/scope-r2.txt"
  grep -qx 'app.py' "$WD/scope-r3.txt"
  grep -qx 'helper.py' "$WD/scope-r3.txt"
}

@test "a repo-internal --work-dir's own state files never enter the refreshed scope (#911)" {
  WD="$R/.loop-wd"   # deliberately INSIDE the repo
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    SNAP="$BATS_TEST_TMPDIR" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/wdscope-r$REVIEW_ROUND.txt"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = 1" > "$REVIEW_REPO/helper.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # round 2's refreshed DELTA scope: the file the fix created, and none of the
  # loop's own state — which a repo-internal work-dir puts squarely INSIDE the
  # delta, so this is the harder half of the #911 guarantee, not the easier one
  grep -qx 'helper.py' "$BATS_TEST_TMPDIR/wdscope-r2.txt"
  run -1 grep -q '^\.loop-wd/' "$BATS_TEST_TMPDIR/wdscope-r2.txt"
  # the closing full sweep re-reads the whole story diff, still without the
  # work-dir's own files
  grep -qx 'app.py' "$BATS_TEST_TMPDIR/wdscope-r3.txt"
  grep -qx 'helper.py' "$BATS_TEST_TMPDIR/wdscope-r3.txt"
  run -1 grep -q '^\.loop-wd/' "$BATS_TEST_TMPDIR/wdscope-r3.txt"
}

# ---- delta scoping, the closing full sweep, and the adjudicated list (#1434)
#
# A fix hook that does NOT touch the tree leaves an empty delta, which the loop
# promotes back to a full sweep — so these tests use hooks that really edit
# files, otherwise they would silently exercise the promotion path instead of
# the delta path they claim to test.

@test "#1434 each round persists its tree identity, and round 2 is scoped against round 1's" {
  WD="$BATS_TEST_TMPDIR/wd-tree-id"
  # round 1 blocks; its fix pass edits ONLY helper.py; round 2 (delta) is clean,
  # promoting round 3 to the closing sweep, which converges.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 4 \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope-r$REVIEW_ROUND.txt"; printf "%s" "$REVIEW_SCOPE_MODE" > "$SNAP/mode-r$REVIEW_ROUND.txt"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = 1" > "$REVIEW_REPO/helper.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # one identity per round, and they MOVED — a tree id that never changes would
  # make every delta empty and quietly restore full-sweep behaviour
  [ -s "$WD/tree-1.txt" ]
  [ -s "$WD/tree-2.txt" ]
  [ "$(cat "$WD/tree-1.txt")" != "$(cat "$WD/tree-2.txt")" ]
  # the round modes the panel actually saw
  [ "$(cat "$WD/mode-r1.txt")" = "full" ]
  [ "$(cat "$WD/mode-r2.txt")" = "delta" ]
  [ "$(cat "$WD/mode-r3.txt")" = "full" ]
  # ...and round 2's scope is EXACTLY what planning against tree-1.txt yields,
  # which is what proves the loop passed that identity rather than some other
  # (the tree has not moved since round 2: rounds 2 and 3 ran no fix pass)
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh" \
    plan --repo "$R" --base main --round 2 --prior-tree "$(cat "$WD/tree-1.txt")"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.changed_files | join("\n")')" = "$(cat "$WD/scope-r2.txt")" ]
}

@test "#1434 a zero-blocker DELTA round does not converge — it promotes a closing full sweep" {
  WD="$BATS_TEST_TMPDIR/wd-closing-sweep"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 4 \
    --review-cmd 'printf "%s" "$REVIEW_SCOPE_MODE" > "$SNAP/mode-r$REVIEW_ROUND.txt"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = 1" > "$REVIEW_REPO/helper.py"; echo "ran-r$REVIEW_ROUND" >> "$SNAP/fixes.txt"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # round 2 found nothing but did NOT end the run; round 3 — the closing full
  # sweep over the whole story diff — is what converged
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 3 ]
  [ "$(echo "$output" | jq '.history[1].blocking')" -eq 0 ]
  [ "$(cat "$WD/mode-r3.txt")" = "full" ]
  [ -f "$WD/.closing-sweep" ]
  [ "$(cat "$WD/.closing-sweep")" = "3" ]
  # a sweep INSIDE the budget is not a grant: without this control the flag's
  # two `true` assertions elsewhere would pass just as happily on a build that
  # set it for every promoted sweep, and every ordinary run would then report
  # `closing_sweep_granted: true` in its status JSON and telemetry
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  # and the fix hook was NOT invoked for the clean round — there is nothing to
  # fix, and an invented change would alter the tree the sweep is about to read
  [ "$(grep -c . "$WD/fixes.txt")" -eq 1 ]
  grep -qx 'ran-r1' "$WD/fixes.txt"
  # the round's own verdict line says what happened, naming the sweep's round:
  # rendering the ordinary "fix pass (in-loop), continuing" here would tell a
  # user tailing progress.md that a fix ran on a round that found nothing
  grep -q -- '- no blockers in the delta — promoting round 3 to the closing full sweep' "$WD/progress.md"
}

@test "#1434 the closing sweep is not STICKY — a later round is a delta round again" {
  WD="$BATS_TEST_TMPDIR/wd-sweep-not-sticky"
  # Round 2 is clean, so round 3 is the closing sweep. Round 3 then FINDS a
  # blocker, so the run continues — and round 4 must be a DELTA round again.
  # A sweep marker read as `round >= closing_sweep_round` would plan every later
  # round --final, restoring the independent-repeat behaviour #1434 removes.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 5 \
    --review-cmd 'printf "%s" "$REVIEW_SCOPE_MODE" > "$SNAP/mode-r$REVIEW_ROUND.txt"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":1,\"title\":\"unquoted variable in matcher\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 3 ]; then printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":900,\"title\":\"missing pipefail on the download pipeline\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = $REVIEW_ROUND" > "$REVIEW_REPO/helper.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(cat "$WD/mode-r1.txt")" = "full" ]
  [ "$(cat "$WD/mode-r2.txt")" = "delta" ]
  [ "$(cat "$WD/mode-r3.txt")" = "full" ]   # the promoted sweep
  [ "$(cat "$WD/mode-r4.txt")" = "delta" ]  # ...and NOT sticky
}

@test "#1434 a closing sweep that FINDS blockers at the ceiling is BUDGET_EXHAUSTED, not a verdictless exit" {
  WD="$BATS_TEST_TMPDIR/wd-sweep-budget"
  # --max-rounds 2, so round 2 is the ceiling. It is a clean delta round, so the
  # sweep is granted round 3 — and the sweep finds a blocker. The budget test
  # must use the EFFECTIVE ceiling: keyed on --max-rounds it would fall out of
  # the while loop with no verdict at all and exit 1.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 2 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 2 ]; then printf "[]" > "$REVIEW_FINDINGS"; else printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":$((REVIEW_ROUND*900)),\"title\":\"blocker r$REVIEW_ROUND unique wording\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = $REVIEW_ROUND" > "$REVIEW_REPO/helper.py"'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]

  # #1435: the zero-blocker delta round applied NO fix, and hook mode records
  # that as an EMPTY set rather than as no set at all. The distinction is the
  # whole point — present-but-empty says "a fix pass ran and touched nothing",
  # absent says "the capture could not run" — and only the empty file makes the
  # loop pass `--fix-touched` to the sweep, so the sweep's blockers get a class.
  # Without this the write can be deleted with every exit-code assertion above
  # still green, while the class histogram goes dark on the one wiring the bats
  # suite drives.
  [ -f "$WD/fix-touched-2.txt" ]
  [ ! -s "$WD/fix-touched-2.txt" ]
  [ "$(jq -r '[.blocking[].class] | join(",")' "$WD/changelist-3.json")" = "new_defect" ]
  grep -q -- '- by class: new_defect 1, incomplete_propagation 0, under_assertion 0' "$WD/progress.md"
}

@test "#1434 a malformed suggestion never reaches adjudicated.json — the work-dir cannot be bricked" {
  WD="$BATS_TEST_TMPDIR/wd-adj-normalise"
  # The consolidator TOLERATES a non-string title and a missing dimension on a
  # reviewer's finding, but its own --adjudicated validator refuses both. An
  # unnormalised append would persist them, and every later round (and every
  # later --resume) would die on the consolidator's refusal as a bare exit 1.
  local r1='[{"severity":"CRITICAL","dimension":"bugs","file":"helper.py","line":1,"title":"unquoted path in the copy step","description":"d","reviewer":"r"},{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":42,"description":"d","reviewer":"r"},{"severity":"SUGGESTION","file":"app.py","line":2,"title":"no dimension at all","description":"d","reviewer":"r"}]'
  echo "print(1)" > "$R/helper.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    R1="$r1" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 4 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "$R1" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = 2" > "$REVIEW_REPO/helper.py"'
  # the run reached its verdict rather than dying on round 2's consolidator
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # every persisted entry satisfies the consolidator's own --adjudicated
  # predicate, and the dimension-less one was dropped rather than stored empty
  jq -e 'all(.[]; (.file | type == "string" and length > 0)
                  and (.dimension | type == "string" and length > 0)
                  and (.title | type == "string"))' "$WD/adjudicated.json" >/dev/null
  [ "$(jq 'length' "$WD/adjudicated.json")" -eq 1 ]
  [ "$(jq -r '.[0].title' "$WD/adjudicated.json")" = "42" ]
}

@test "#1434 a zero-blocker delta round at the ceiling is granted the closing sweep, once" {
  WD="$BATS_TEST_TMPDIR/wd-grant"
  # --max-rounds 2, so round 2 IS the ceiling. It is a delta round that finds
  # nothing, so the sweep must still run — at round 3.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 2 \
    --review-cmd 'printf "%s" "$REVIEW_SCOPE_MODE" > "$SNAP/mode-r$REVIEW_ROUND.txt"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = 1" > "$REVIEW_REPO/helper.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(cat "$WD/mode-r3.txt")" = "full" ]
  # the grant is a fact about THIS run, not a bigger budget: max_rounds still
  # reports what the caller passed, and a separate boolean records the grant
  [ "$(echo "$output" | jq '.max_rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
}

@test "#1434 closing_sweep_granted is present and false on an ordinary run" {
  # always-present, for the same reason promotion_phase is: a consumer must
  # never have to tell `false` from "a status file that predates the key"
  clean_loop
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'has("closing_sweep_granted")')" = "true" ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
}

@test "#1434 an empty delta with carried blockers runs as a full sweep, not a refusal" {
  WD="$BATS_TEST_TMPDIR/wd-empty-delta-carried"
  # the fix hook deliberately changes NOTHING, so round 2's delta is empty —
  # but round 1's blocker is carried for verification, so the round is a
  # legitimate verification-only sweep, not an unreviewed round
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 \
    --review-cmd 'printf "%s" "$REVIEW_SCOPE_MODE" > "$SNAP/mode-r$REVIEW_ROUND.txt"; cp "$REVIEW_SCOPE_FILE" "$SNAP/scope-r$REVIEW_ROUND.txt"; printf "%s" "$REVIEW_FIX_VERIFICATION" > "$SNAP/verify-path-r$REVIEW_ROUND.txt"; cp "$REVIEW_FIX_VERIFICATION" "$SNAP/verify-seen-r$REVIEW_ROUND.json" 2>/dev/null || true; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(cat "$WD/mode-r2.txt")" = "full" ]
  # the scope was RE-DERIVED after the promotion: without the second
  # write_round_scope the panel would be handed the delta round's empty scope
  # while the descriptor said full, converging on a sweep that read zero files
  grep -qx 'app.py' "$WD/scope-r2.txt"
  # round 2 was handed the previous round's blockers to verify
  [ "$(jq 'length' "$WD/verify-2.json")" -eq 1 ]
  [ "$(jq -r '.[0].title' "$WD/verify-seen-r2.json")" = "T" ]
  # ...and round 1 was handed NOTHING — the documented asymmetry a hook is told
  # to code against (REVIEW_FIX_VERIFICATION is empty on round 1;
  # REVIEW_ADJUDICATED is always a path). Snapshot the VARIABLE, not the file it
  # names: a `cp` that quietly fails proves nothing either way.
  [ ! -s "$WD/verify-path-r1.txt" ]
  [ -s "$WD/verify-path-r2.txt" ]
  # the HOOK-mode wording specifically: the two wirings deliberately say
  # different things here, and asserting only the shared prefix would let the
  # step-mode sentence ("this round cannot converge") be rendered on a hook run
  # that just did converge
  grep -q '^\*\*Scope (round 2):\*\* empty delta' "$WD/progress.md"
  grep -q 'running this round as a full sweep' "$WD/progress.md"
  run -1 grep -q 'cannot converge' "$WD/progress.md"
}

@test "#1434 an empty delta with NOTHING carried is refused as STALE_FINDINGS, not converged" {
  WD="$BATS_TEST_TMPDIR/wd-empty-delta-bare"
  ST="$BATS_TEST_TMPDIR/status-empty-delta.json"
  TEL="$BATS_TEST_TMPDIR/telemetry-empty-delta.jsonl"
  # Reached by RESUMING a run that already converged: the tree has not moved, so
  # round 2's delta is empty, and the previous round had no blockers, so nothing
  # is carried to verify either. No reviewer would look at anything — reading
  # such a round as a result is the same false green a never-run panel would be.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 \
    --status-file "$ST" --telemetry-file "$TEL" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$ST")" = "CONVERGED" ]
  [ "$(grep -c . "$TEL")" -eq 1 ]   # the converged run's own terminal record

  # separate-stderr, so the stdout-is-one-JSON-line contract is observed rather
  # than blurred by bats merging the human complaint into $output
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 --resume \
    --status-file "$ST" --telemetry-file "$TEL" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
  [ "$(jq -r '.status' <<<"$output")" = "STALE_FINDINGS" ]
  contains "$stderr" "delta against the previous round is EMPTY"
  # typed: the status file carries THIS invocation's refusal, never the prior
  # CONVERGED verdict
  [ "$(jq -r '.status' "$ST")" = "STALE_FINDINGS" ]
  # ...and non-terminal: no new telemetry record, no Final line, but a Refused
  # line so a human tailing progress.md sees why round 2 did not happen
  [ "$(grep -c . "$TEL")" -eq 1 ]
  grep -q '^\*\*Refused (round 2):\*\*' "$WD/progress.md"
  run -1 grep -q '^## Round 2' "$WD/progress.md"
}

@test "#1434 the adjudicated list suppresses a re-raised suggestion, and says so" {
  WD="$BATS_TEST_TMPDIR/wd-adjudicated"
  # round 1 raises a blocker AND a suggestion; the fix pass edits helper.py
  # (never app.py, where the suggestion lives, so the adjudication stays valid);
  # round 2 re-raises the very same suggestion and nothing else.
  local r1='[{"severity":"CRITICAL","dimension":"bugs","file":"helper.py","line":1,"title":"unquoted path in the copy step","description":"d","reviewer":"r"},{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  local r2='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"d2","reviewer":"r2"}]'
  echo "print(1)" > "$R/helper.py"     # so the fix pass EDITS rather than creates
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    R1="$r1" R2="$r2" SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 4 \
    --review-cmd 'cp "$REVIEW_ADJUDICATED" "$SNAP/adj-seen-r$REVIEW_ROUND.json"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "$R1" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "$R2" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = 2" > "$REVIEW_REPO/helper.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # round 1 waived the suggestion; round 2 re-raised it and was dropped
  [ "$(echo "$output" | jq '.round_changelists[0].summary.adjudicated_dropped')" -eq 0 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.adjudicated_dropped')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.low')" -eq 0 ]
  # the count rides the per-round history line and the progress tail
  [ "$(echo "$output" | jq '.history[1].adjudicated_dropped')" -eq 1 ]
  grep -q -- '- adjudicated re-raises dropped: 1' "$WD/progress.md"
  # the list itself is work-dir state, never written under .review/
  [ -s "$WD/adjudicated.json" ]
  [ ! -e "$R/.review/adjudicated.json" ]
  # REVIEW_ADJUDICATED really reaches the panel, and really carries the waived
  # item by round 2 — without this the export could be deleted and every panel
  # would run blind to the list, re-raising everything the human let go
  [ "$(jq 'length' "$WD/adj-seen-r1.json")" -eq 0 ]
  [ "$(jq -r '.[0].title' "$WD/adj-seen-r2.json")" = "rename the temp variable" ]
  [ "$(jq -r '.[0].file' "$WD/adj-seen-r2.json")" = "app.py" ]
}

@test "#1434 the adjudication is invalidated on the CLOSING SWEEP too, not just delta rounds" {
  WD="$BATS_TEST_TMPDIR/wd-adjudicated-sweep"
  # Round 2 is a clean DELTA round, so it promotes round 3 to the closing full
  # sweep. delta_files must still be computed on that full round — it is the
  # only thing that re-opens an adjudication whose file the last fix pass
  # touched — so gating --prior-tree on `is_final` would leave the safety-net
  # round suppressing a suggestion it should have re-raised.
  local r1='[{"severity":"CRITICAL","dimension":"bugs","file":"helper.py","line":1,"title":"unquoted path in the copy step","description":"d","reviewer":"r"},{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  local r3='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"d3","reviewer":"r3"}]'
  echo "print(1)" > "$R/helper.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    R1="$r1" R3="$r3" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 4 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "$R1" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 3 ]; then printf "%s" "$R3" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "print(99)" > "$REVIEW_REPO/app.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  # round 3 IS the closing sweep, and the round-1 fix pass edited app.py, so the
  # waived suggestion there was re-opened rather than suppressed
  [ "$(echo "$output" | jq '.round_changelists[2].summary.adjudicated_dropped')" -eq 0 ]
  [ "$(echo "$output" | jq '.round_changelists[2].summary.low')" -eq 1 ]
}

@test "#1434 a delta of ONLY work-dir state is empty for the panel, however the descriptor reads it" {
  WD="$R/.loop-wd"   # deliberately INSIDE the repo
  # The descriptor's scope_empty is FALSE here — the loop's own history,
  # changelists and progress file are all inside the delta — while the #909/#911
  # filter leaves the panel with nothing at all. Judging emptiness on
  # scope_empty would run this as an ordinary delta round, reach zero blockers,
  # promote a closing sweep and green-light the PR on a round nobody reviewed.
  ST="$BATS_TEST_TMPDIR/status-wd-delta.json"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 --status-file "$ST" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' "$ST")" = "CONVERGED" ]

  # resume: nothing in the repo changed, so round 2's only delta entries are the
  # loop's own state files, and round 1 left no blockers to verify
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 --resume --status-file "$ST" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$(jq -r '.status' <<<"$output")" = "STALE_FINDINGS" ]
  contains "$stderr" "delta against the previous round is EMPTY"
}

@test "#1434 an uncomputable tree identity aborts the round, naming it" {
  WD="$BATS_TEST_TMPDIR/wd-treeid-fail"
  # An empty tree-N.txt would make the NEXT round die with a misattributed
  # "no usable prior tree identity", blaming a round that was fine.
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$BATS_TEST_TMPDIR/definitely-not-git" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 1 ]
  contains "$stderr" "could not compute the working-tree identity for round 1"
}

@test "#1434 a failed PERSIST of the tree identity aborts the round, naming it" {
  WD="$BATS_TEST_TMPDIR/wd-treeid-persist"
  mkdir -p "$WD/tree-1.txt"   # a directory where the file must go
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 1 ]
  contains "$stderr" "could not persist the round 1 tree identity"
}

@test "#1434 an adjudication is INVALIDATED when the fix pass touches its file" {
  WD="$BATS_TEST_TMPDIR/wd-adjudicated-invalidated"
  # Same shape as above, except the fix pass edits app.py — the very file the
  # waived suggestion is about. A suggestion re-raised there is plausibly a NEW
  # observation about NEW code, so it must survive.
  local r1='[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"unquoted path in the copy step","description":"d","reviewer":"r"},{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  local r2='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"d2","reviewer":"r2"}]'
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    R1="$r1" R2="$r2" SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 4 \
    --review-cmd 'cp "$REVIEW_ADJUDICATED" "$SNAP/adj-seen-r$REVIEW_ROUND.json"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "$R1" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "$R2" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "print(99)" > "$REVIEW_REPO/app.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.adjudicated_dropped')" -eq 0 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.low')" -eq 1 ]
  # ...and the invalidation ran BEFORE the panel, not merely before the
  # consolidator: the PANEL is what is told "do not re-raise these", so a
  # suggestion it withholds never reaches the consolidator at all. Asserting
  # only the consolidator's count passes under either placement.
  [ "$(jq 'length' "$WD/adj-seen-r2.json")" -eq 0 ]
}

@test "#1434 a fresh run that cannot truncate history.jsonl aborts, rather than appending onto a foreign run" {
  # A directory at the path, so the failure is uid-independent (#1360). Without
  # the guard the "fresh" run appends onto the PREVIOUS run's lines: the status
  # JSON reports a foreign run's rounds, and the next --resume reads the skew as
  # the kill-window orphan and truncates a completed round's changelist.
  local WDX="$BATS_TEST_TMPDIR/wd-frozen-hist"
  mkdir -p "$WDX/history.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDX" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 1 ]
  contains "$output" "could not truncate"
  contains "$output" "history.jsonl for a fresh run"
  # the abort is BEFORE any round work
  [ ! -e "$WDX/changelist-1.json" ]
}

@test "#1434 a fresh run that cannot truncate changelists.jsonl aborts too" {
  local WDX="$BATS_TEST_TMPDIR/wd-frozen-clists"
  mkdir -p "$WDX/changelists.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDX" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 1 ]
  contains "$output" "could not truncate"
  contains "$output" "changelists.jsonl for a fresh run"
  [ ! -e "$WDX/changelist-1.json" ]
}

@test "#1434 a fresh run that CANNOT clear the iteration state says so, and is not fatal" {
  # The clear is deliberately non-fatal but never silent: leaving a previous
  # run's verify-*.json in place is the exact condition it exists to prevent,
  # and the round-2 fallback reads a foreign carry as present. `rm -f` refuses
  # a directory whatever the uid, so no #1360 skip is needed.
  local WDX="$BATS_TEST_TMPDIR/wd-unclearable"
  mkdir -p "$WDX/.closing-sweep"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDX" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  # non-fatal is half the contract: the run still reaches a verdict
  [ "$status" -eq 0 ]
  contains "$stderr" "could not clear the previous run's iteration state"
  # the arm-unique tail: the telemetry sidecar clear has its own diagnostic
  contains "$stderr" "foreign fix-verification carry"
}

@test "#1434 a fresh run truncates the iteration state a previous run left behind" {
  WD="$BATS_TEST_TMPDIR/wd-fresh-truncate"
  mkdir -p "$WD"
  # a previous run's leavings: a foreign tree identity (a delta against which is
  # arbitrary), foreign waived suggestions, and a closing-sweep grant this run
  # never earned
  printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$WD/tree-1.txt"
  printf '[{"file":"app.py","line":1,"dimension":"code_quality","title":"rename the temp variable"}]' > "$WD/adjudicated.json"
  printf '[{"file":"x"}]' > "$WD/verify-2.json"
  printf '9\n' > "$WD/.closing-sweep"
  # a suggestion the STALE list would have suppressed must survive a fresh run
  local r1='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"d","reviewer":"r"}]'
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    R1="$r1" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 \
    --review-cmd 'printf "%s" "$R1" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.adjudicated_dropped')" -eq 0 ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.low')" -eq 1 ]
  [ ! -e "$WD/.closing-sweep" ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  # the stale verify-2.json was truncated, and the one now on disk is THIS
  # run's: round 1 writes the next round's carry at its own end, so the file
  # exists again — with round 1's (empty) blocking array, not the planted stub
  [ "$(jq -c '.' "$WD/verify-2.json")" = "[]" ]
  # this run's OWN identity replaced the foreign one
  [ "$(cat "$WD/tree-1.txt")" != "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]
}

@test "mid-loop dispatch ambiguity exits typed ESCALATE_AMBIGUOUS, not a bare exit 1 (#912)" {
  WD="$BATS_TEST_TMPDIR/wd-midamb"
  # file-driven detection so the fix pass can flip it ambiguous mid-chain:
  # round 1 sees python only; its fix pass adds a second supported language,
  # so round 2's per-round dispatch returns rc=3.
  LANGS_FILE="$BATS_TEST_TMPDIR/langs.json"
  printf '%s' '{"languages":["python"]}' > "$LANGS_FILE"
  DSTUB="$BATS_TEST_TMPDIR/detect-from-file.sh"
  printf '#!/usr/bin/env bash\ncat "$LANGS_FILE_PATH"\n' > "$DSTUB"
  chmod +x "$DSTUB"
  MIDT="$BATS_TEST_TMPDIR/midamb-telemetry.jsonl"
  run env DETECT_STACK_BIN="$DSTUB" LANGS_FILE_PATH="$LANGS_FILE" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 \
    --status-file "$BATS_TEST_TMPDIR/midamb-status.json" --telemetry-file "$MIDT" \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'printf "%s" "{\"languages\":[\"python\",\"java\"]}" > "$LANGS_FILE_PATH"'
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_AMBIGUOUS" ]
  echo "$output" | jq -e '.escalation_reasons | index("ambiguous_dispatch")' >/dev/null
  # --status-file carries the SAME typed verdict, not the previous round's
  [ "$(jq -r '.status' "$BATS_TEST_TMPDIR/midamb-status.json")" = "ESCALATE_AMBIGUOUS" ]
  jq -e '.escalation_reasons | index("ambiguous_dispatch")' "$BATS_TEST_TMPDIR/midamb-status.json" >/dev/null
  # round context is real: round 1 completed before the ambiguity struck
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 1 ]
  # ...and the carried element is round 1's REAL changelist, not a placeholder
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 1 ]
  # telemetry (#1004): this is the loop's OTHER ambiguous emit call site — the
  # mid-loop one, which (unlike the pre-loop path) already knows repo_type, so
  # the envelope must carry it rather than null
  assert_envelope "$MIDT" escalated ESCALATE_AMBIGUOUS
  [ "$(jq -r '.repo_type' "$MIDT")" = "python" ]
  [ "$(jq '.payload.rounds' "$MIDT")" -eq 1 ]
}

@test "--resume into ambiguous dispatch reports the prior run's rounds and changelists, not 0/[] (#912)" {
  WD="$BATS_TEST_TMPDIR/wd-resume-amb"
  seed_exhausted_wd "$WD"   # one completed round of history + changelist
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python","java"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 10 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_AMBIGUOUS" ]
  echo "$output" | jq -e '.escalation_reasons | index("ambiguous_dispatch")' >/dev/null
  # the carried-over state rides out with the status: rounds/changelists agree
  # with the populated history instead of rendering "0/N rounds" above it
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 1 ]
  # ...and the carried element is the prior run's REAL round, not a placeholder
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 1 ]
}

@test "--resume truncates an orphaned changelist line left by a kill between the two appends (#913)" {
  WD="$BATS_TEST_TMPDIR/wd-killwindow"
  seed_exhausted_wd "$WD"
  # simulate the kill window: round 2 ran, its changelist was appended, the run
  # died before the history line — changelists is one valid line ahead
  tail -n 1 "$WD/changelists.jsonl" >> "$WD/changelists.jsonl"
  # resume with a clean round -> the orphaned round re-runs and converges.
  # --separate-stderr: the notice must be OUT-OF-BAND — stdout stays exactly
  # the one-line status JSON (the clean-path contract asserted above).
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
  # one entry per COMPLETED round — the orphan did not survive as a duplicate
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 2 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 2 ]
  # the truncation was announced on stderr, not silent and not on stdout
  echo "$stderr" | grep -q 'orphaned changelist'
}

@test "--resume with a corrupt (partial) changelists line is an internal error (exit 1) (#913)" {
  WD="$BATS_TEST_TMPDIR/wd-corrupt-clist"
  seed_exhausted_wd "$WD"
  # a kill DURING the changelist append leaves a partial line — the validity
  # guard must catch it before any skew arithmetic runs on garbage
  printf '{"round":' >> "$WD/changelists.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'corrupt changelists'
}

@test "--resume with a changelists surplus beyond one line is an internal error, not a repair (#913)" {
  WD="$BATS_TEST_TMPDIR/wd-surplus2"
  seed_exhausted_wd "$WD"
  # a surplus of 2+ cannot come from the single kill window — foreign
  # corruption must error, never silently drop a completed round's record
  tail -n 1 "$WD/changelists.jsonl" >> "$WD/changelists.jsonl"
  tail -n 1 "$WD/changelists.jsonl" >> "$WD/changelists.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 1 ]
  run -1 grep -q 'CONVERGED' <<< "$output"
}

@test "--resume with history ahead of changelists is an internal error (exit 1), never silent repair (#913)" {
  WD="$BATS_TEST_TMPDIR/wd-hist-ahead"
  seed_exhausted_wd "$WD"
  # the documented append order cannot produce this direction — a completed
  # round losing its changelist record is corruption, not a kill-window orphan
  : > "$WD/changelists.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'true' --fix-cmd 'true'
  [ "$status" -eq 1 ]
}

@test "the envelope's ts is the loop's LOGICAL start, not the terminal moment (#1004)" {
  # the loop passes --ts "$t_begin" from the work-dir's .t0; drop it and the
  # emitter silently defaults to `date +%s` at TERMINAL time, mis-stamping both
  # ts and the run_id epoch. A deliberately slow round separates the two
  # moments, so this cannot pass by both landing in the same second.
  T="$BATS_TEST_TMPDIR/ts.jsonl"
  loop --review-cmd 'sleep 2; printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' \
       --telemetry-file "$T"
  [ "$status" -eq 0 ]
  local T0
  T0="$(cat "$BATS_TEST_TMPDIR/wd/.t0")"
  [ "$(jq '.ts' "$T")" -eq "$T0" ]              # the logical start, not "now"
  [ "$(jq '.wall_s' "$T")" -ge 2 ]              # ...and the run really did span it
  # the minted run_id carries that same epoch
  jq -e --argjson t "$T0" '.run_id | startswith("review-loop-\($t|tostring)-")' "$T" >/dev/null
}

@test "an over-wide --issue is a usage error, not a silently dropped record (#1004)" {
  # digit-only but 20 wide: it satisfies zsh <-> yet breaks the emitter's
  # 18-digit cap, which `|| true` would swallow along with the whole record
  run zsh "$S" --repo "$R" --base main --issue 99999999999999999999 --no-review
  [ "$status" -eq 2 ]
  # the WIDTH rule specifically — "--issue" alone would also match the
  # digits-only message and the parser's unknown-flag catch-all
  contains "$output" "out of range (max 18 digits"
}

@test "an explicitly empty --telemetry-file is a usage error, not a silent default-sink write (#1004)" {
  run zsh "$S" --repo "$R" --base main --no-review --telemetry-file ""
  [ "$status" -eq 2 ]
  contains "$output" "requires a non-empty value"
  [ ! -e "$R/.claude/telemetry/telemetry.jsonl" ]
}

@test "_need_val: a dangling value flag is a usage error (2), not a raw nounset abort (#1004)" {
  # under `setopt nounset` the bare "$2" would abort with zsh's own
  # "2: parameter not set" and exit 1 — a code this script reserves for
  # INTERNAL errors, so a caller mistake would be misreported as one
  local f
  for f in --repo --base --review-cmd --fix-cmd --test-cmd --gate-attest \
           --findings-file --max-rounds --status-file --work-dir --issue --telemetry-file; do
    run zsh "$S" "$f"
    [ "$status" -eq 2 ] || { echo "$f dangling: want exit 2, got $status"; return 1; }
    contains "$output" "$f requires a value" || {
      echo "$f dangling: message did not name the flag: $output"; return 1; }
  done
}

@test "_need_val: a flag-shaped value is refused instead of swallowing the next flag (#1004)" {
  # `--telemetry-file $VAR --resume` with VAR unset collapses to
  # `--telemetry-file --resume`: the value eats --resume, so the run would
  # execute FRESH and TRUNCATE a real in-progress loop's accumulators, then
  # lose the telemetry record when the emitter rejects the flag-shaped path
  run zsh "$S" --repo "$R" --telemetry-file --resume --no-review
  [ "$status" -eq 2 ]
  contains "$output" "requires a value (got the flag --resume)"
}

@test "_need_val: an explicitly empty value is refused for every value flag (#1004)" {
  # `--flag "$VAR"` with VAR unset reads downstream as "flag omitted", exit 0.
  # The worst is silent: --test-cmd "" makes BOTH gate call sites fall to their
  # `[[ -n "$test_cmd" ]]` branches, so the loop could converge having never
  # run the suite.
  local f
  for f in --repo --base --review-cmd --fix-cmd --test-cmd \
           --findings-file --max-rounds --status-file --work-dir --issue --telemetry-file; do
    run zsh "$S" "$f" "" --no-review
    [ "$status" -eq 2 ] || { echo "$f empty: want exit 2, got $status"; return 1; }
    contains "$output" "$f requires a non-empty value" || {
      echo "$f empty: message did not name the flag: $output"; return 1; }
  done
}

@test "_need_val: --gate-attest is the documented exception — empty means fail-closed, not a usage error (#981)" {
  # #981 defines an empty/absent attestation as "run the gate anyway", so
  # refusing it would turn a documented safe default into a hard failure.
  # The arg-count and flag-shape checks still apply.
  run zsh "$S" --repo "$R" --no-review --gate-attest ""
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "SKIPPED" ]
  run zsh "$S" --repo "$R" --no-review --gate-attest
  [ "$status" -eq 2 ]
  # ...naming the rule, like its two siblings: with the arg-count check gone
  # the following `shift 2` would also fail, so exit 2 alone discriminates little
  contains "$output" "--gate-attest requires a value"
  run zsh "$S" --repo "$R" --gate-attest --resume --no-review
  [ "$status" -eq 2 ]
  contains "$output" "got the flag --resume"
}

@test "a leading-zero --max-rounds is normalised, never a blank status JSON (#1004)" {
  # `<->` accepts '03' but JSON forbids it, so without the 10# normalisation it
  # reaches --argjson, fails jq, and the loop prints a BLANK line as its status
  # JSON while still exiting 0 — and emits no telemetry record either
  T="$BATS_TEST_TMPDIR/leadingzero.jsonl"
  run zsh "$S" --repo "$R" --no-review --max-rounds 03 --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(echo "$output" | jq -r '.status')" = "SKIPPED" ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
  assert_envelope "$T" success SKIPPED
}

@test "an over-wide --max-rounds is a usage error, not a truncated unbounded budget (#1004)" {
  # zsh arithmetic truncates after 19 digits and would evaluate the prefix,
  # landing positive and silently accepting an effectively unbounded ceiling
  run zsh "$S" --repo "$R" --no-review --max-rounds 12345678901234567890
  [ "$status" -eq 2 ]
  contains "$output" "at most 18 digits"
}

# --- suggestion promotion pass-through (#994, test case #1021) ---------------
#
# The loop never interprets the promoted set — it forwards --promote to the
# consolidator on EVERY round. The observable proof is behavioural rather than
# argv-shaped: a SUGGESTION-only round converges immediately today, so if the
# same round STOPS converging under --promote the overlay reached the
# consolidator; and if it keeps blocking into round 2+ it was forwarded there
# too, rather than applied once and dropped.

# a reviewer panel that raises the same waived Low finding every round
suggestion_loop() {
  loop --review-cmd 'printf "%s" '"'"'[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"d","reviewer":"q"}]'"'"' > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true' "$@"
}

@test "#1021 promote: without --promote a suggestion-only round still converges in round 1" {
  # the baseline this feature must not disturb — and the headless/autonomous path
  suggestion_loop
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 0 ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.low')" -eq 1 ]
}

@test "#1021 promote: --promote reaches the consolidator — the same round no longer converges" {
  P="$BATS_TEST_TMPDIR/promote.json"
  cat > "$P" <<'EOF'
[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]
EOF
  suggestion_loop --promote "$P"
  # the promoted suggestion is now a blocker the fix-cmd never clears, so the
  # loop escalates instead of converging — it cannot have converged in round 1
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.round_changelists[0].blocking[0].priority')" = "High" ]
  # #995: the per-item stamp must survive INTO the loop's status JSON — that is
  # the single link between the consolidator that writes it and the four
  # surfaces that read it (all of whose tests otherwise run on hand-written
  # fixtures). A loop that reshaped or key-filtered the changelist would leave
  # every fixture-based test green while production rendered no label at all.
  echo "$output" | jq -e '.round_changelists[0].blocking[0].promoted == true' >/dev/null
  echo "$output" | jq -e '.final_changelist.blocking[0].promoted == true' >/dev/null
}

@test "#1029 a reviewer-raised blocker in the same round is NOT stamped promoted" {
  # the stamp must mark the human's pick alone; stamping everything would make
  # the label meaningless in all four surfaces
  P="$BATS_TEST_TMPDIR/promote-mixed.json"
  cat > "$P" <<'EOF'
[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]
EOF
  loop --promote "$P" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"'[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"d","reviewer":"q"},{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":80,"title":"unchecked exit","description":"d","reviewer":"b"}]'"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq '[.round_changelists[0].blocking[] | select(.promoted == true)] | length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '[.round_changelists[0].blocking[] | select(.promoted == true)][0].title')" = "extract the magic number" ]
  # assert over the COMPLEMENT, and bound the round: `[…] | any` over an empty
  # array is false, so a select that matches nothing (a dropped blocker, an
  # edited fixture title) would silently stop asserting anything
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 2 ]
  [ "$(echo "$output" | jq '[.round_changelists[0].blocking[] | select(.promoted != true) | has("promoted")] | any')" = "false" ]
  [ "$(echo "$output" | jq '[.round_changelists[0].blocking[] | select(.title == "unchecked exit")] | length')" -eq 1 ]
}

@test "#1021 promote: the overlay is forwarded on round 2+, not applied once" {
  # If --promote were forwarded only on round 1, round 2 would consolidate
  # WITHOUT it, the item would fall back to Low, blocking would drop to 0 and
  # the loop would converge. Round 2 still blocking is the pass-through proof.
  P="$BATS_TEST_TMPDIR/promote.json"
  cat > "$P" <<'EOF'
[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]
EOF
  suggestion_loop --promote "$P"
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -ge 2 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.blocking')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.low')" -eq 0 ]
}

@test "#1021 promote: an EMPTY promoted set is refused — selecting none skips the sub-loop" {
  # The contract is that selecting nothing converges immediately and the sub-loop
  # is never invoked. `[]` reaching the loop is therefore a glue slip, and left
  # accepted it would run a provably no-op overlay every round and converge
  # reporting success on a phase that promoted nothing.
  P="$BATS_TEST_TMPDIR/promote.json"
  printf '[]' > "$P"
  suggestion_loop --promote "$P"
  [ "$status" -eq 2 ]
  contains "$output" "non-empty JSON array"
}

@test "#1021 promote: without --promote the same round converges on the inherited budget" {
  # the no-flag baseline the empty-set case used to stand in for: max_rounds is 5
  # for every invocation, so assert the whole round-1 verdict too
  suggestion_loop
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 0 ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.low')" -eq 1 ]
  # the promotion phase is an ordinary invocation of this same state machine, so
  # its ceiling is MAX_REVIEW_ROUNDS; there is deliberately no second constant
  [ "$(echo "$output" | jq '.max_rounds')" -eq 5 ]
}

@test "#1021 promote: a malformed promote file is refused up front, not mid-round" {
  # The promote file is HUMAN-authored, so a typo is the most likely failure of
  # the whole feature — and the shapes a model produces (a bare string array, a
  # truncated write) are likelier than a missing path. Caught only by the
  # consolidator, they surfaced as a BARE exit 1 mid-round that writes no status
  # JSON, leaving --status-file holding a previous verdict. The up-front guard
  # validates the SHAPE, so these are typed usage errors before any round work.
  P="$BATS_TEST_TMPDIR/promote.json"
  ST="$BATS_TEST_TMPDIR/status.json"

  printf 'not json' > "$P"
  printf '%s' '{"status":"AWAITING_FIX","rounds":1}' > "$ST"
  suggestion_loop --promote "$P" --status-file "$ST"
  [ "$status" -eq 2 ]
  contains "$output" "non-empty file and dimension and a string title"
  # the prior verdict is untouched — no bogus status was written over it
  [ "$(jq -r '.status' "$ST")" = "AWAITING_FIX" ]
}

@test "#1021 promote: an array of NON-OBJECTS is refused up front too" {
  P="$BATS_TEST_TMPDIR/promote.json"
  ST="$BATS_TEST_TMPDIR/status.json"
  printf '["a title"]' > "$P"
  printf '%s' '{"status":"AWAITING_FIX","rounds":1}' > "$ST"
  suggestion_loop --promote "$P" --status-file "$ST"
  [ "$status" -eq 2 ]
  contains "$output" "non-empty file and dimension and a string title"
  [ "$(jq -r '.status' "$ST")" = "AWAITING_FIX" ]
}

@test "#1021 promote: a --promote path that is a DIRECTORY is a usage error" {
  # -s alone is true for a directory, so an existence-only guard would let the
  # scratch dir through and fail inside jq mid-round
  suggestion_loop --promote "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  contains "$output" "--promote must be a non-empty regular file"
}

@test "#1026 promote: the loop's --promote with no value exits 2" {
  run zsh "$S" --repo "$R" --no-review --promote
  [ "$status" -eq 2 ]
  contains "$output" "--promote requires a value"
}

@test "#1026 promote: the loop's --promote followed by another flag exits 2" {
  run zsh "$S" --repo "$R" --no-review --promote --resume
  [ "$status" -eq 2 ]
  contains "$output" "--promote requires a value (got the flag --resume)"
}

@test "#1026 promote: the loop's --promote with an empty value exits 2" {
  run zsh "$S" --repo "$R" --no-review --promote ""
  [ "$status" -eq 2 ]
  contains "$output" "--promote requires a non-empty value"
}

@test "#1021 promote: a file holding TWO concatenated JSON arrays is refused up front" {
  # The realistic scratch-file-rewritten-with->> shape. `jq -e` takes its exit
  # status from the LAST output value and jq runs the filter once per top-level
  # value, so an unslurped guard emits true,true and passes — the path is then
  # forwarded and only the consolidator refuses it, as a bare exit 1 that writes
  # no status JSON and leaves --status-file holding the previous verdict.
  P="$BATS_TEST_TMPDIR/promote.json"
  ST="$BATS_TEST_TMPDIR/status.json"
  printf '[]\n[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]\n' > "$P"
  printf '%s' '{"status":"AWAITING_FIX","rounds":1}' > "$ST"
  suggestion_loop --promote "$P" --status-file "$ST"
  [ "$status" -eq 2 ]
  contains "$output" "non-empty file and dimension and a string title"
  [ "$(jq -r '.status' "$ST")" = "AWAITING_FIX" ]
}

@test "#1021 promote: hook mode also persists and re-adopts the promoted set" {
  # The persistence/adoption code is NOT step-mode gated, but every other test
  # for it lives in the step-mode suite. A regression gating it behind step mode
  # would leave every hook-mode --resume converging as a false success.
  P="$BATS_TEST_TMPDIR/promote.json"
  cat > "$P" <<'EOF'
[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]
EOF
  suggestion_loop --promote "$P" --max-rounds 1
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ -s "$BATS_TEST_TMPDIR/wd/.promote" ]

  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd 'printf "%s" '"'"'[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"d2","reviewer":"q2"}]'"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true' --resume --max-rounds 3
  contains "$stderr" "adopting the run's promoted set"
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.blocking')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.low')" -eq 0 ]
  # #995: promotion_phase is derived from $promote, so on THIS path it depends
  # on the adoption having run first — the resume carried no --promote. Its
  # record is the one that would otherwise be counted as a phase-1 story.
  echo "$output" | jq -e '.promotion_phase == true' >/dev/null
}

@test "#1033 an adopting --resume that CONVERGES still records promotion_phase true" {
  # the sub-loop's SUCCESS record is the dangerous one: counted as phase-1 it
  # would credit the story with a convergence it already had, in both published
  # rates. Round 1 promotes and exhausts; the resume's panel finds nothing.
  P="$BATS_TEST_TMPDIR/promote-adopt-converge.json"
  cat > "$P" <<'EOF'
[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]
EOF
  T="$BATS_TEST_TMPDIR/adopt-converge.jsonl"
  WD="$BATS_TEST_TMPDIR/wd-adopt-converge"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --promote "$P" --max-rounds 1 \
    --telemetry-file "$T" --issue 995 \
    --review-cmd 'printf "%s" '"'"'[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"d","reviewer":"q"}]'"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 13 ]

  # the resume drops --promote on purpose: the adoption branch is the realistic
  # path, and it is what promotion_phase must survive. --separate-stderr because
  # the adoption prints a notice there, which bats would otherwise merge into
  # $output ahead of the status JSON.
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --telemetry-file "$T" --issue 995 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  contains "$stderr" "adopting the run's promoted set"
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  echo "$output" | jq -e '.promotion_phase == true' >/dev/null
  # ...and it reaches the payload, which is what the metric predicate reads
  jq -es 'all(.[]; .payload.promotion_phase == true)' "$T" >/dev/null
}

# --- #1435: CONVERGED_WITH_RESIDUE (exit 14) and the fix-touched capture ------
#
# The fixtures below share one shape, defined once so a half-applied edit cannot
# make the positive and negative cases exercise different things: `touched.py`
# exists BEFORE the loop starts (so a round-1 finding in it survives
# scope-findings, which scopes against the story diff), and every fix pass
# rewrites it — making `touched.py` the fix-touched set from round 1 onward,
# while `app.py` stays a file no fix pass ever wrote.
residue_setup() {
  echo "v0" > "$R/touched.py"
}

# a WARNING (never a CRITICAL) in $1, with a per-round title so consecutive
# rounds are neither byte-identical (#974) nor read as one carried blocker (#983)
residue_review() {  # $1 = file
  printf '%s' 'printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"'"$1"'\",\"line\":$((REVIEW_ROUND*100)),\"title\":\"round $REVIEW_ROUND unquoted expansion\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"'
}

residue_fix='echo "v$REVIEW_ROUND" > "$REVIEW_REPO/touched.py"'

@test "#1435 tc-happy-residue-terminal: hook mode, zero-CRITICAL window on a full round -> exit 14" {
  residue_setup
  # round 2 IS the ceiling, so it lands on the BUDGET_EXHAUSTED rung — which the
  # residue check replaces. Both rounds report critical 0, and round 2's blocker
  # is in touched.py, which round 1's fix pass wrote.
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  # ...and it really did still have blockers: residue is not a disguised zero
  echo "$output" | jq -e '.final_changelist.summary.blocking > 0' >/dev/null
  echo "$output" | jq -e '.final_changelist.summary.critical == 0' >/dev/null
  # progress.md is what a human actually watches, and it is the one surface that
  # can quietly disagree with the status JSON — replacing the residue verdict
  # with "converged" leaves every JSON assertion above green while telling the
  # human the run converged clean.
  P="$BATS_TEST_TMPDIR/wd/progress.md"
  grep -q '^\*\*Final:\*\* CONVERGED_WITH_RESIDUE' "$P"
  # Pin the CLAIM, not just the prefix. The verdict used to continue "...and
  # lives in the previous round's own fix-touched files", which #1571 made false
  # — and this needle stopped one word short of it, so progress.md (the surface a
  # human tails through a long run) stated the retired condition while the suite
  # stayed green.
  grep -q -- '- converged with residue' "$P"
  grep -q 'this round read the whole story diff' "$P"
  run ! grep -q "lives in the previous round's own fix-touched files" "$P"
  # ...and the class stamp is wired end-to-end into it, not merely into the JSON
  grep -q -- '- by class: new_defect 0, incomplete_propagation 1, under_assertion 0' "$P"
}

@test "#1435 a residue exit reports NO escalation_reasons, and says what residue replaced instead" {
  residue_setup
  # The non-convergence rung is the one residue path whose changelist carries
  # `non_converging_blocker` — that is WHY the rung was reached. Copied through,
  # the ending that exists to say "this did not escalate" would report that it
  # did, and the two rungs would report different shapes.
  loop --max-rounds 5 \
    --review-cmd 'printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":10,\"title\":\"unquoted expansion in the matcher\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  # the changelist DID carry the reason — otherwise this pins nothing
  echo "$output" | jq -e '.final_changelist.escalation_reasons == ["non_converging_blocker"]' >/dev/null
  # ...and the status JSON does not, so `escalation_reasons != []` keeps its one
  # meaning: this run escalated
  echo "$output" | jq -e '.escalation_reasons == []' >/dev/null
  # the provenance is not lost, it is relabelled
  echo "$output" | jq -e '.residue_replaced_reasons == ["non_converging_blocker"]' >/dev/null
  grep -q '^\*\*Final:\*\* CONVERGED_WITH_RESIDUE — residue replaced: non_converging_blocker' \
    "$BATS_TEST_TMPDIR/wd/progress.md"
}

@test "#1435 residue_replaced_reasons is ALWAYS present, so [] never has to be told from an older status" {
  residue_setup
  # the budget rung, whose changelist carries no reason at all
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  echo "$output" | jq -e '.residue_replaced_reasons == []' >/dev/null
  # ...and on every other terminal too — same always-present rule as
  # promotion_phase and closing_sweep_granted
  clean_loop
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.residue_replaced_reasons == []' >/dev/null
}

@test "#1435 residue also replaces the NON-CONVERGENCE rung, not just the budget one" {
  residue_setup
  # the SAME title every round, so round 2 stamps non_converging and would have
  # exited 12 — well before the 5-round ceiling.
  loop --max-rounds 5 \
    --review-cmd 'printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":10,\"title\":\"unquoted expansion in the matcher\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  # THREE rounds, not two (#1435 §9). Round 2 stamps non_converging and its two
  # residue conditions hold — but it is a DELTA round, so it promotes the closing
  # full sweep instead of ending the run, and round 3 (the sweep) is what
  # declares 14. The rung being replaced is still the non-convergence one; what
  # changed is that replacing it now costs the sweep first.
  [ "$(echo "$output" | jq -r '.rounds')" = "3" ]
  # the promotion really happened — the marker names round 3 as the sweep.
  # `closing_sweep_granted` stays FALSE here on purpose: the sweep fits inside
  # --max-rounds 5, so no grant beyond the ceiling was needed. The grant arm is
  # exercised by the ceiling fixture below.
  [ "$(cat "$BATS_TEST_TMPDIR/wd/.closing-sweep")" = "3" ]
  echo "$output" | jq -e '.final_changelist.non_converging == true' >/dev/null
  # the round that promoted says SO — `residue_promoted_sweep` has three
  # write/read sites and only the ceiling rung asserted any of them, so deleting
  # the flag from THIS rung left the suite green while the round rendered the
  # generic "fix pass (in-loop), continuing".
  grep -q 'residue conditions hold, but on a DELTA round — promoting round 3' "$BATS_TEST_TMPDIR/wd/progress.md"
  # ...and the promotion line appears EXACTLY once. The obvious negative here —
  # grepping for `promoting round 4` — is unreachable: the verdict interpolates
  # `closing_sweep_round`, which stays 3 once round 2 promotes, so that needle can
  # never match under any mutation and would pin nothing. A count is what
  # actually catches a missing per-round reset.
  [ "$(grep -c 'residue conditions hold, but on a DELTA round' "$BATS_TEST_TMPDIR/wd/progress.md")" -eq 1 ]
}

@test "#1435 tc-error-critical-in-window: a CRITICAL in either of the last two rounds exits 13, never 14" {
  residue_setup
  # round 1 CRITICAL, round 2 WARNING — both in touched.py, so ONLY the
  # zero-CRITICAL condition fails. That is the point: one condition, one case.
  loop --max-rounds 2 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 null dereference\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":200,\"title\":\"round 2 unquoted expansion\",\"description\":\"d2\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
}

@test "#1435 tc-error-critical-in-window: a CRITICAL in the FINAL round exits 13 too (the other half of the window)" {
  residue_setup
  # The mirror of the case above, and it is not redundant: the condition is
  # `c_cur == 0 && c_prev == 0`, so a fixture that only ever plants the CRITICAL
  # in round N-1 leaves the `c_cur` half unpinned — drop it from the loop and
  # every other case still passes, while a run whose FINAL round found a
  # CRITICAL would open a PR with a consumer-visible break in it.
  loop --max-rounds 2 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":200,\"title\":\"round 2 null dereference\",\"description\":\"d2\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  # the fixture really is the one described: round 2 IS the critical one, and its
  # blocker IS fix-touched — so only the c_cur half can be what refused it
  echo "$output" | jq -e '.final_changelist.summary.critical == 1' >/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt")" = "touched.py" ]
}

@test "#1571 a mixed round SHIPS: the fix-touched split survives as a class stamp, never as a residue veto" {
  residue_setup
  # This once pinned residue's quantifier (`n_outside == 0`). #1571 removed that
  # condition, so the mixed round now SHIPS — and what this test is for changed
  # with it: the fix-touched split it sets up must still reach the changelist as
  # `class`, because the progress histogram and the grant decision read it. The
  # class assertion below is therefore the whole point now, and the exit code is
  # the scaffolding. Both blockers are in the story diff (`scope-findings` would
  # have dropped either otherwise), which is why neither is a reason to refuse.
  loop --max-rounds 2 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":200,\"title\":\"round 2 unquoted expansion\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":300,\"title\":\"round 2 stale cache never invalidated\",\"description\":\"d3\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  # the round really is MIXED — otherwise this degenerates into the
  # single-outside-blocker case above and pins nothing new
  [ "$(jq '.blocking | length' "$BATS_TEST_TMPDIR/wd/changelist-2.json")" -eq 2 ]
  [ "$(jq -r '[.blocking[].class] | sort | join(",")' "$BATS_TEST_TMPDIR/wd/changelist-2.json")" = "incomplete_propagation,new_defect" ]
}

@test "#1571 tc-error-untouched-file RETIRED: a blocker outside the fix-touched set now ships as residue" {
  residue_setup
  # Both rounds zero-CRITICAL, and round 2's blocker is in app.py — in the story
  # diff, but written by no fix pass. Under the retired condition 2 that alone
  # refused residue; since #1571 it ships, because being in the story diff is
  # the only file-level claim residue ever needed and `scope-findings` already
  # guarantees it.
  loop --max-rounds 2 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":200,\"title\":\"round 2 stale cache never invalidated\",\"description\":\"d2\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
}

@test "#1435 tc-error-conflict-still-escalates: a surviving conflict still exits 11 under residue conditions" {
  residue_setup
  # Round 2 carries an opposed pair at one location in touched.py, so the
  # residue conditions hold (zero CRITICALs both rounds) and the conflict rung
  # must still win — no automated ending can
  # pick between two opposed recommendations.
  loop --max-rounds 3 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"performance\",\"file\":\"touched.py\",\"line\":200,\"title\":\"hoist the allocation\",\"description\":\"d\",\"reviewer\":\"p\"},{\"severity\":\"WARNING\",\"dimension\":\"code_quality\",\"file\":\"touched.py\",\"line\":200,\"title\":\"keep the helper readable\",\"description\":\"d\",\"reviewer\":\"q\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_CONFLICT" ]
}

@test "#1435 AC3: zero blockers still exits CONVERGED (0) even with a fix-touched set on disk" {
  residue_setup
  # round 1 finds a fix-touched blocker, round 2 finds nothing: the zero-blocker
  # arm is evaluated FIRST, so it promotes the closing sweep and converges —
  # residue never pre-empts it.
  loop --max-rounds 4 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "[]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "#1435 tc-corner-round1-unreachable: --max-rounds 1 exits 13, never 14" {
  residue_setup
  # Zero CRITICALs and a blocker in the story diff — every surface condition of
  # residue except the one round 1 structurally cannot meet: there is no second
  # changelist, so the two-round zero-CRITICAL window cannot exist. (Before #1571
  # it also failed for want of a previous fix pass to attribute the blocker to;
  # that half went with condition 2, and the round-1 guard survives on this one.)
  loop --max-rounds 1 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/fix-touched-0.txt" ]
}

@test "#1435 AC5 hook mode: fix-touched-N.txt lists exactly what the fix pass created and modified" {
  residue_setup
  echo "tracked" > "$R/lib.zsh"
  git -C "$R" add lib.zsh
  git -C "$R" commit -qm lib
  # --max-rounds 2, not 1: the fix hook runs only on a round that CONTINUES, so
  # a single-round run captures nothing at all. Round 2 then exits 14: both
  # rounds are zero-CRITICAL and it is at the ceiling, so residue replaces
  # BUDGET_EXHAUSTED. Where the fix pass wrote is no longer part of that verdict
  # (#1571) — the set this test pins is now purely the `class` input.
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'echo modified >> "$REVIEW_REPO/lib.zsh"; echo new > "$REVIEW_REPO/created.zsh"'
  [ "$status" -eq 14 ]
  # sorted, repo-relative, and nothing else: not the loop's own state, not the
  # findings sink, not README.md
  [ "$(cat "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt")" = "created.zsh
lib.zsh" ]
}

@test "#1435 AC5 hook mode: a fix confined to .review/ or .claude/telemetry/ yields an EMPTY set" {
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'mkdir -p "$REVIEW_REPO/.review" "$REVIEW_REPO/.claude/telemetry"; echo x > "$REVIEW_REPO/.review/scratch.json"; echo y > "$REVIEW_REPO/.claude/telemetry/telemetry.jsonl"'
  [ "$status" -eq 14 ]
  # present but empty — "the fix pass touched nothing REVIEWABLE" is a real
  # answer, and a distinct one from "no capture ran" (no file at all)
  [ -f "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt" ]
  [ ! -s "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt" ]
}

@test "#1571 an empty fix-touched set no longer blocks residue — every blocker is still classed new_defect" {
  residue_setup
  # The fix pass only ever writes under .review/, so nothing reviewable is ever
  # attributable to it and the set comes out EMPTY. That is the #1558 shape in
  # miniature: under the retired condition 2 an empty set made every blocker
  # "outside" and residue unreachable — the defect #1571 fixed. The exclusion
  # list is still load-bearing, but now for the CLASS rather than the verdict,
  # which is what the last assertion pins.
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'mkdir -p "$REVIEW_REPO/.review"; echo x > "$REVIEW_REPO/.review/scratch.json"'
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  [ "$(jq -r '[.blocking[].class] | join(",")' "$BATS_TEST_TMPDIR/wd/changelist-2.json")" = "new_defect" ]
}

@test "#1435 tc-corner-history-line-no-residue-key: the per-round history line gains NO residue key" {
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  H="$BATS_TEST_TMPDIR/wd/history.jsonl"
  # the five pre-existing keys are all still there...
  jq -es 'all(.[]; has("round") and has("blocking") and has("conflicts")
                   and has("non_converging") and has("false_trips"))' "$H" >/dev/null
  # ...alongside the SIXTH key sibling #1434 legitimately mirrors onto the same
  # line, which is exactly why this is a negative on the residue keys and NOT a
  # closed-key-set assertion (#1463)
  jq -es 'all(.[]; has("adjudicated_dropped"))' "$H" >/dev/null
  # ...and nothing residue-derived joined them. A REGEX FAMILY over the key
  # names, not a guess-list of four literals: a fifth spelling (`residue_class`,
  # `fix_touched_files`, `by_class`) would slip straight through a closed list,
  # which is the rot this repo has already paid for once. Still not a closed KEY
  # SET, which #1463 rules out — a sibling may legitimately add its own key.
  jq -es 'all(.[]; [keys[] | select(test("residue|fix.?touched|class"))] | length == 0)' "$H" >/dev/null
}

@test "#1435 the history-line regex family really catches a residue-derived key" {
  # Non-vacuity for the negative above: a regex nobody can trip passes forever.
  # Each spelling the family is meant to cover is shown to red on a probe line.
  local probe="$BATS_TEST_TMPDIR/history-probe.jsonl"
  local k
  for k in class fix_touched fix-touched residue_class residue_blocking by_class; do
    jq -nc --arg k "$k" '{round:1, blocking:0, conflicts:0, non_converging:false,
                          false_trips:0, adjudicated_dropped:0} + {($k): 1}' > "$probe"
    # the family assertion must FAIL on a probe carrying the key — asserted on
    # jq's own exit rather than through `run !`, so the message names the key
    jq -es 'all(.[]; [keys[] | select(test("residue|fix.?touched|class"))] | length == 0)' \
      "$probe" >/dev/null && { echo "family missed the key: $k"; return 1; }
  done
  # ...and it does NOT red on the six legitimate keys, so it is a filter and not
  # a blanket refusal
  jq -nc '{round:1, blocking:0, conflicts:0, non_converging:false,
           false_trips:0, adjudicated_dropped:0}' > "$probe"
  jq -es 'all(.[]; [keys[] | select(test("residue|fix.?touched|class"))] | length == 0)' "$probe" >/dev/null
}

@test "#1435 outcome mapping: CONVERGED_WITH_RESIDUE -> success, with a null escalation" {
  residue_setup
  T="$BATS_TEST_TMPDIR/residue.jsonl"
  loop --max-rounds 2 --telemetry-file "$T" --issue 1435 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  # named in the $st case, NOT swept into the deliberate `*) failed` catch-all
  assert_envelope "$T" success CONVERGED_WITH_RESIDUE
  # `escalation` tests ^ESCALATE_ / BUDGET_EXHAUSTED, so it must stay null here
  jq -es 'all(.[]; .payload.escalation == null)' "$T" >/dev/null
  # ...and the per-round class histogram rides along (round 1 has no
  # fix-touched set to classify against, hence null)
  jq -es 'all(.[]; (.payload.findings_by_round[0].by_class == null)
                   and (.payload.findings_by_round[1].by_class.incomplete_propagation == 1))' "$T" >/dev/null
}

@test "#1435 a failed tree identity leaves NO fix-touched set, says so, and does not fail the run" {
  residue_setup
  # A stub that is real git EXCEPT for `diff-tree`, which is the one call the
  # capture makes on its own. Pointing the seam at a missing binary instead would
  # also break git-tree-id.zsh — which mints the identities the whole round needs
  # — and abort the run at round 1 for an unrelated reason, testing nothing about
  # this arm. review-dispatch reads GIT_BIN for its own delta, and passes that
  # down to git-tree-id.zsh, so its scope computation is unaffected.
  #
  # The rule under test is fail-CLOSED-but-not-fatal: no set on disk (so no
  # blocker is stamped from a guess), a named diagnostic (so a round whose
  # by-class row is dark is distinguishable from one whose fix pass genuinely
  # touched nothing), and a run that still reaches its terminal. Since #1571 the
  # residue verdict is not among the things at stake here — which is why this
  # test asserts exit 14 below.
  GITSTUB="$BATS_TEST_TMPDIR/git-no-difftree"
  cat > "$GITSTUB" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "diff-tree" ]; then
    echo "stub: diff-tree refused" >&2
    exit 1
  fi
done
exec git "$@"
STUB_EOF
  chmod +x "$GITSTUB"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$GITSTUB" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-nogit" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  # the run is NOT aborted by the capture failure — it reaches a real terminal
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  # ...leaving no set, so no blocker could be classed from a stale one
  [ ! -e "$BATS_TEST_TMPDIR/wd-nogit/fix-touched-1.txt" ]
  # ...and it said which arm failed, rather than going dark
  contains "$stderr" "fix-touched set (#1435)"
  # The diagnostic names the consequence that is REAL since #1571. It used to
  # promise "residue is unreachable this round" — in the very run this test also
  # asserts exits 14, a contradiction the suite pinned rather than caught.
  contains "$stderr" "will carry no class"
  contains "$stderr" "residue is unaffected since #1571"
}

@test "#1435 each capture failure names ITS OWN arm, so an operator can tell which went dark" {
  residue_setup
  # The three arms print three distinct diagnostics precisely so a round whose
  # class stamps went dark for a capture failure is distinguishable from one
  # whose fix pass touched nothing — and from each other. A shared tail cannot establish that;
  # each needle here is arm-unique.
  #
  # The stub is counter-keyed, because both identities in a round are minted by
  # the same binary: failing the Nth call is the only way to reach one arm
  # without also breaking the round's own tree-id (which aborts at exit 1).
  local CTR="$BATS_TEST_TMPDIR/mint-count"
  _mk_counting_stub() {  # $1 = 1-based call number to fail on
    printf '0' > "$CTR"
    cat > "$BATS_TEST_TMPDIR/git-nth" <<STUB_EOF
#!/usr/bin/env bash
# only WRITE-TREE calls are counted: that is the last step of a mint, so
# failing the Nth of them fails exactly the Nth identity
for a in "\$@"; do
  if [ "\$a" = "write-tree" ]; then
    n=\$(( \$(cat "$CTR") + 1 ))
    printf '%s' "\$n" > "$CTR"
    if [ "\$n" = "$1" ]; then exit 1; fi
  fi
done
exec git "\$@"
STUB_EOF
    chmod +x "$BATS_TEST_TMPDIR/git-nth"
  }

  # Round 1 mints, in order: (1) the round's own tree identity, (2) the cadence
  # guard's re-read of the working tree (#1435 §10), (3) the hook-mode pre-fix
  # stamp, (4) the post-fix identity inside the capture. Failing #3 empties
  # `fix_base_tree`; failing #4 empties `cur`. (#2 is deliberately absent from
  # the arms below: the cadence guard is silent when it cannot mint an identity,
  # by the same fail-quiet rule as every other missing-state path here — losing
  # the detection, never the run.)
  _mk_counting_stub 3
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$BATS_TEST_TMPDIR/git-nth" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-arm2" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  contains "$stderr" "no pre-fix tree identity for round 1"
  [ ! -e "$BATS_TEST_TMPDIR/wd-arm2/fix-touched-1.txt" ]

  _mk_counting_stub 4
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$BATS_TEST_TMPDIR/git-nth" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-arm3" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  contains "$stderr" "could not compute the post-fix tree identity for round 1"
  [ ! -e "$BATS_TEST_TMPDIR/wd-arm3/fix-touched-1.txt" ]
}

@test "#1435 a capture failure CLEARS any stale set, so no blocker is classed from a previous round's" {
  residue_setup
  # The `rm -f` at the top of the capture is what makes the fail-closed promise
  # absolute rather than likely: without it a set left by an earlier round could
  # be read as this round's.
  WD4="$BATS_TEST_TMPDIR/wd-stale"
  mkdir -p "$WD4"
  printf 'planted-stale.py\n' > "$WD4/fix-touched-1.txt"
  GITSTUB2="$BATS_TEST_TMPDIR/git-no-dt2"
  cat > "$GITSTUB2" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "diff-tree" ]; then exit 1; fi
done
exec git "$@"
STUB_EOF
  chmod +x "$GITSTUB2"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$GITSTUB2" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD4" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  [ ! -e "$WD4/fix-touched-1.txt" ]
}

@test "#1435 every tree identity is minted through the ONE bridged helper" {
  # `GIT_TREE_ID_BIN` is one name in two scopes: this script reads it as a shell
  # parameter, git-tree-id.zsh only as an exported env var. `_tree_id` sets it on
  # the invocation so both halves of every comparison provably run one binary. A
  # future call site that invokes $TREE_ID directly would silently reopen that,
  # and no behavioural test can see it (a caller that exports the seam works
  # either way) — so the invariant is pinned structurally.
  grep -q 'GIT_TREE_ID_BIN="\${GIT_TREE_ID_BIN:-git}" "\$TREE_ID"' "$S"
  # exactly two mentions of "$TREE_ID" as a command: the helper body and the
  # `-x` executability guard beside the gate attestation
  [ "$(grep -c '"\$TREE_ID"' "$S")" -eq 2 ]
  # ...and every mint goes through the helper
  [ "$(grep -c '_tree_id "\$repo"' "$S")" -eq 6 ]
}

@test "#1435 the fix-touched set and the review scope share ONE path rule" {
  # _capture_fix_touched hand-copies review-dispatch.zsh's _normalise_paths, and
  # the header calls the two "deliberately identical". A one-sided edit would
  # make the `class` stamp and the review scope disagree about the same file,
  # whose only symptom is a blocker misclassified `new_defect` and a by-class
  # row nobody can trust. Pin the copies against each other rather than trusting
  # the comment.
  D="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  # the ./-strip, the two artifact exclusions and the blank-line drop, in both
  for needle in "sed -E 's#^\./##'" \
                "\\#^\\.review/#d" \
                "\\#^\\.claude/telemetry/#d" \
                "/^\$/d"; do
    grep -qF -- "$needle" "$S" || { echo "loop lost the path rule: $needle"; return 1; }
    grep -qF -- "$needle" "$D" || { echo "dispatch lost the path rule: $needle"; return 1; }
  done
  # ...and the quotePath flag both need so a non-ASCII path is spelled the same
  # way on both sides (#1435).
  #
  # EXACT counts, not `-ge`: dispatch has THREE git invocations that list paths
  # (`diff --name-only`, `ls-files --others`, and the delta `diff-tree`), and a
  # tolerance of `-ge 2` let any ONE of them lose the flag with this test still
  # green — while that one invocation then C-quotes a non-ASCII path and the two
  # sides stop agreeing about the same file. The counts here are LINE counts and
  # each script mentions the flag once in a comment above the call site, hence
  # 3 calls + 2 comments in dispatch, 1 call + 1 comment in the loop. The
  # behavioural pin is the test below; this one localises a deletion to the
  # line that lost it.
  [ "$(grep -cF -- 'core.quotePath=false' "$S")" -eq 3 ]
  [ "$(grep -cF -- 'core.quotePath=false' "$D")" -eq 5 ]
}

@test "#1435 a NON-ASCII path is spelled identically in the review scope and the fix-touched set" {
  # The behavioural half of the pin above. git's default `core.quotePath=true`
  # renders `café.zsh` as the C-quoted, DOUBLE-QUOTE-WRAPPED `"caf\303\251.zsh"`.
  # If either side keeps that default, the review scope and the fix-touched set
  # carry two different spellings of one file — so `consolidate-findings
  # --fix-touched` finds no match, a blocker the fix pass just wrote is classed
  # `new_defect` instead of `incomplete_propagation` — silently mis-stamping
  # every `class` for a repo with a non-ASCII filename.
  # seeded like residue_setup, but with the non-ASCII name the flag is about
  printf 'v0\n' > "$R/café.py"
  local WD="$BATS_TEST_TMPDIR/wd"
  loop --max-rounds 2 --review-cmd "$(residue_review café.py)" \
       --fix-cmd 'echo "v$REVIEW_ROUND" > "$REVIEW_REPO/café.py"'

  # the fix-touched set carries the PLAIN spelling — no backslash escapes, no
  # wrapping double quotes
  [ -f "$WD/fix-touched-1.txt" ]
  grep -qxF 'café.py' "$WD/fix-touched-1.txt"
  run ! grep -q '303' "$WD/fix-touched-1.txt"
  run ! grep -q '^"' "$WD/fix-touched-1.txt"

  # ...and the classification agrees, which is the consequence that matters: the
  # round-2 blocker sits in the file round 1's fix pass wrote, so it is
  # incomplete_propagation and NOT new_defect
  [ "$(jq -r '.blocking[0].class' "$WD/changelist-2.json")" = "incomplete_propagation" ]
  [ "$(jq -r '.blocking[0].file' "$WD/changelist-2.json")" = "café.py" ]
}

@test "#1435 residue NEVER fires in a promotion sub-loop — the human's own picks are not re-waived" {
  residue_setup
  # The identical fixture that exits 14 without --promote. #994 contracts that a
  # promoted item is "treated as blocking, not quietly re-waived", and residue
  # would re-waive it — filing the human's explicit request back to them as a
  # follow-up. It is also what keeps the residue story single-phase, so every
  # downstream surface can say "filed" without a per-phase qualifier.
  P="$BATS_TEST_TMPDIR/promoted-set.json"
  cat > "$P" <<'EOF'
[{"file":"touched.py","line":100,"dimension":"code_quality","title":"extract the helper"}]
EOF
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-promo" --max-rounds 2 \
    --promote "$P" \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  # ...and it really was the promotion gate that refused it: the run is the
  # promotion sub-loop, and every OTHER residue condition held (that is the
  # non-vacuity half — the same fixture exits 14 without --promote).
  # The fix-touched assertion below is NOT part of that evidence since #1571 —
  # the predicate does not read the set — it pins the `class` input instead, and
  # is kept because a promotion round that lost its capture would go dark in the
  # by-class histogram exactly where the grant decision reads it.
  echo "$output" | jq -e '.promotion_phase == true' >/dev/null
  echo "$output" | jq -e '.final_changelist.summary.critical == 0' >/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/wd-promo/fix-touched-1.txt")" = "touched.py" ]
}

@test "#1435 an ESCALATING round stamps its pre-fix tree too, so a granted round is still classified" {
  residue_setup
  # §3.5 step 5 requires a fix pass BEFORE the resume a grant buys, so a fix pass
  # really does follow an escalation. Without a stamp there its touched set is
  # unrecoverable and the round after the grant carries no class at all — the
  # histogram the grant decision reads, dark one round after the grant was spent.
  WD3="$BATS_TEST_TMPDIR/wd-escalate"
  # the SAME blocker every round trips non-convergence at round 2
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD3" --max-rounds 5 \
    --review-cmd 'printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":10,\"title\":\"unquoted expansion in the matcher\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  # the escalating round left the stamp a granted resume needs
  [ -s "$WD3/fix-base-2.txt" ]
}

@test "#1435 the stamp covers every GRANTABLE terminal — and not the one a grant cannot resume" {
  residue_setup
  # Three-of-four membership, not presence alone. BUDGET_EXHAUSTED is the other
  # terminal the interactive extension can grant from, so dropping it leaves a
  # granted resume with no base to diff and the class histogram dark exactly one
  # round after the grant was spent.
  WD5="$BATS_TEST_TMPDIR/wd-budget-stamp"
  # A CRITICAL in round 1 keeps this fixture OFF the residue terminal (#1571).
  # Exit 14 is a terminal SUCCESS with no fix pass after it, so it is correctly
  # not in the stamp list — and since #1571 removed residue's file condition, a
  # zero-CRITICAL fixture here now ships instead of exhausting its budget, and
  # would silently stop testing the BUDGET_EXHAUSTED arm this test is named for.
  loop --max-rounds 2 --work-dir "$WD5" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":10,\"title\":\"round 1 null dereference\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":900,\"title\":\"missing pipefail on download\",\"description\":\"d2\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ -s "$WD5/fix-base-2.txt" ]

  # ESCALATE_CONFLICT IS in the list, on the same reasoning: the interactive
  # extension covers it too, a human picks the winner, and a fix pass follows the
  # grant — so without a stamp that round is consolidated with no `--fix-touched`
  # at all, stamping no `class` and blanking the histogram on the round after a
  # grant was spent — which is when it is most wanted. (This test previously
  # asserted the opposite, on the mistaken premise that no grant resumes from a
  # conflict.)
  WD6="$BATS_TEST_TMPDIR/wd-conflict-stamp"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD6" --max-rounds 3 \
    --review-cmd 'printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"performance\",\"file\":\"touched.py\",\"line\":200,\"title\":\"hoist the allocation\",\"description\":\"d\",\"reviewer\":\"p\"},{\"severity\":\"WARNING\",\"dimension\":\"code_quality\",\"file\":\"touched.py\",\"line\":200,\"title\":\"keep the helper readable\",\"description\":\"d\",\"reviewer\":\"q\"}]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 11 ]
  [ -s "$WD6/fix-base-1.txt" ]

  # ESCALATE_AMBIGUOUS remains OUT, and for a different reason — `emit_ambiguous`
  # exits before the round produces any findings to classify, so a stamp would
  # serve nothing. That exclusion is what keeps this a membership test rather
  # than "stamp everything".
  run ! grep -qE 'ESCALATE_AMBIGUOUS' <<< "$(sed -n '/pre-fix tree identity/,/^  fi$/p' "$S")"
}

@test "#1435 a fresh (non---resume) run clears a previous run's fix-touched state" {
  residue_setup
  WD2="$BATS_TEST_TMPDIR/wd-reuse"
  # run 1 goes three rounds, so it leaves BOTH fix-touched-1 and fix-touched-2
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD2" --max-rounds 3 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  [ -s "$WD2/fix-touched-1.txt" ]
  [ -s "$WD2/fix-touched-2.txt" ]
  # run 2 re-uses the work-dir WITHOUT --resume and stops at round 2, so it
  # never writes a fix-touched-2 of its own. Run 1's must be gone: left behind,
  # it would attribute a later round's blockers to a fix pass from a different
  # run entirely, stamping `incomplete_propagation` against edits that are not
  # ours and corrupting the by-class histogram the grant decision reads.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD2" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd 'true'
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  [ ! -e "$WD2/fix-touched-2.txt" ]
}

@test "#1435 AC5 hook mode: a REPO-INTERNAL work-dir is not charged to the fix pass" {
  # The loop mints its pre-fix identity AFTER the round writes its own
  # bookkeeping, precisely so a work-dir living inside the repo cannot make the
  # loop's changelist/history/progress files look like the session's edits. The
  # exclusion list strips only `.review/` and `.claude/telemetry/`, so a work-dir
  # at any OTHER in-repo path is not filtered — the ordering is the only thing
  # protecting it, and a repo-internal work-dir is a supported configuration
  # used elsewhere in this very file.
  #
  # Every other #1435 test puts the work-dir outside the repo, where the
  # ordering cannot matter. Surviving mutation: hoist the `fix_base_tree`
  # assignment above the `append_progress_round` write of that same round. The
  # `_tree_id` occurrence count is unchanged, so the structural test stays
  # green, while `fix-touched-1.txt` silently grows `.loop-wd/changelist-1.json`,
  # `.loop-wd/history.jsonl` and `.loop-wd/progress.md` — inflating the set that
  # stamps `class`, on a side effect whose exact contents this AC pins.
  # (NB: no stray apostrophes in these comments — the inert-assertion scanner
  # tracks quote parity across lines and an odd one desyncs the whole scan.)
  residue_setup
  local IWD="$R/.loop-wd"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'echo modified >> "$REVIEW_REPO/lib.zsh"; echo new > "$REVIEW_REPO/created.zsh"'
  [ "$status" -eq 14 ]
  # the work-dir really is inside the repo, or this pins nothing
  [ -f "$IWD/changelist-1.json" ]
  # ...and the set is EXACTLY the two edits the fix hook made — the same
  # contents the outside-the-repo case above pins.
  #
  # Newlines folded to spaces so the expectation fits on ONE line. That is not
  # cosmetic: the repo inert-assertion scanner mis-tracks quote parity across a
  # two-line quoted literal, and the sibling tests only scan clean because an
  # EVEN number of such literals cancel out. Adding a third would desync the
  # scan and silently stop the rest of this file from being checked at all.
  [ "$(tr '\n' ' ' < "$IWD/fix-touched-1.txt")" = "created.zsh lib.zsh " ]
  # stated separately, because a future exclusion rule could strip the work-dir
  # by name and still leave the ordering broken for some other in-repo writer
  run ! grep -q '\.loop-wd' "$IWD/fix-touched-1.txt"
}

@test "#1435 HOOK mode: the fix-touched capture runs BEFORE --test-cmd too" {
  # The step-mode twin of this exists; the hook-mode call site had the same
  # ordering and no coverage, because no #1435 hook fixture ever passed a
  # --test-cmd and no --test-cmd test ever looked at fix-touched-N.txt.
  #
  # Surviving mutation: move the hook-mode `_capture_fix_touched` call below the
  # gate block. Every file the gate writes — a regenerated fixture, a formatter
  # run from a test, a coverage report — then joins the set and is attributed to
  # the fix pass, so a blocker in one is stamped `incomplete_propagation` instead
  # of `new_defect`. That is exactly the input the by-class histogram — and so the
  # grant decision — reads, and the whole suite stayed green through it.
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd "$residue_fix" \
    --test-cmd 'echo gate > "'"$R"'/gate-artifact.txt"'
  # the gate really wrote it, or the absence below proves nothing
  [ -f "$R/gate-artifact.txt" ]
  # ...and the set is exactly the fix pass, with no gate artifact in it
  [ "$(cat "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt")" = "touched.py" ]
}

@test "#1435 an OUTSIDE-the-repo work-dir excludes NOTHING, even on a basename collision" {
  # The documented normal configuration, and the direction no test covered: every
  # outside fixture uses a work-dir named `wd`/`wd2`/... and no fixture repo has a
  # directory of that name, so an OVER-BROAD rule was invisible.
  #
  # Surviving mutation: replace the whole prefix computation with an
  # unconditional `wd_rel="${work_dir:t}/"` (just the basename). Every
  # repo-internal test still passes — the basename IS the right prefix there —
  # and every outside test still passes, because nothing collides. In production
  # it silently deletes every fix-pass edit under any repo directory whose name
  # matches the work-dir basename (`--work-dir /tmp/tests`, `$TMPDIR/src`), so
  # those blockers are classed `new_defect` on evidence nobody produced, and the
  # class histogram the grant decision reads is confidently wrong.
  #
  # So: force the collision. The work-dir is OUTSIDE the repo and named `wd`,
  # and the repo has a tracked `wd/` directory the fix hook edits.
  # the colliding directory is committed FIRST, so the story's own uncommitted
  # edits (touched.py) stay in the review scope — committing after residue_setup
  # would sweep them into main and the round would converge with nothing to fix
  mkdir -p "$R/wd"
  echo tracked > "$R/wd/keep.zsh"
  git -C "$R" add -A
  git -C "$R" commit -qm wd
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'echo modified >> "$REVIEW_REPO/wd/keep.zsh"; echo "v$REVIEW_ROUND" > "$REVIEW_REPO/touched.py"'
  # the edit under the colliding directory IS in the set — an outside work-dir
  # excludes nothing
  grep -qxF 'wd/keep.zsh' "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt"
  # ...alongside the ordinary edit, so the set is not simply unfiltered garbage
  grep -qxF 'touched.py' "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt"
}

# --- #1435 §9: the closing full sweep is a precondition of exit 14 -----------

@test "#1435 AC19 hook mode: a DELTA round satisfying residue promotes the sweep, never 14" {
  # Hook mode's half of §9. Round 2 is the ceiling AND satisfies both residue
  # conditions; before §9 it exited 14 off a delta round. Now it promotes round 3
  # to the closing full sweep under the one-round grant and keeps going, so the
  # PR-opening verdict is reached by a round that read the whole story diff.
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  # THREE rounds ran, not two — the sweep is the third
  [ "$(echo "$output" | jq -r '.rounds')" = "3" ]
  echo "$output" | jq -e '.closing_sweep_granted == true' >/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/wd/.closing-sweep")" = "3" ]
  # ...and the progress trail says which round did what, so the extra round is
  # explained rather than mysterious
  grep -q 'promoting round 3 to the closing full sweep' "$BATS_TEST_TMPDIR/wd/progress.md"
}

@test "#1571 AC20 hook mode: a sweep blocker outside the fix-touched set SHIPS as residue" {
  # The sweep reads files the deltas never covered — that is its whole purpose —
  # and under the retired condition 2 that made its findings unshippable by
  # construction, which is precisely why the motivating run never reached exit
  # 14. Since #1571 such a blocker is the residue case rather than the veto: it
  # is in the story diff, it is not Critical, and a full sweep raised it.
  residue_setup
  loop --max-rounds 2 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 3 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":300,\"title\":\"round 3 sweep only finding\",\"description\":\"d3\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":$((REVIEW_ROUND*100)),\"title\":\"round $REVIEW_ROUND unquoted expansion\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  # it really did reach the sweep, or this proves nothing about the sweep
  [ "$(echo "$output" | jq -r '.rounds')" = "3" ]
  # ...and the sweep-only blocker is the remainder that gets filed
  [ "$(echo "$output" | jq -r '.final_changelist.blocking[0].file')" = "app.py" ]
}

@test "#1435 AC19 the zero-blocker promotion trigger is UNCHANGED (#1434 non-goal)" {
  # §9 adds a second trigger; it must not disturb the first. A delta round that
  # returns zero blockers still promotes the sweep exactly as before, and the
  # sweep still converges — no residue anywhere in the picture.
  residue_setup
  loop --max-rounds 3 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "[]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  grep -q 'no blockers in the delta' "$BATS_TEST_TMPDIR/wd/progress.md"
}


@test "#1435 §10 HOOK mode: a --review-cmd that rewrites the tree is refused by the per-round stamp" {
  # The stamp arm of the cadence guard, which no test reached: every AC21 case
  # attests via --findings-tree, and in step mode the early call refuses first,
  # so this branch ran but never refused. Surviving mutation: return early unless
  # the source is the attested one — hook mode then loses cadence detection
  # entirely and a panel that rewrites the tree mid-round is consumed as if its
  # findings described the tree the loop is looking at.
  residue_setup
  loop --max-rounds 2 \
    --review-cmd 'printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"r1\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; echo mutated > "$REVIEW_REPO/app.py"' \
    --fix-cmd 'true'
  [ "$status" -eq 2 ]
  # `loop` merges stderr into $output, and the refusal writes its diagnostic
  # there BEFORE the status JSON — so assert on the durable artifacts and on the
  # emitted status string rather than parsing the stream as JSON.
  echo "$output" | grep -q '"status":"STALE_FINDINGS"'
  # the message names THIS arm, so an operator can tell which source refused
  grep -q "this round's recorded dispatch tree" "$BATS_TEST_TMPDIR/wd/progress.md"
  grep -q 'app.py' "$BATS_TEST_TMPDIR/wd/progress.md"
}

@test "#1435 §10 HOOK mode non-vacuity: a panel that writes ONLY its findings sink is fine" {
  # Pins the guard to REVIEWABLE files. The panel writes $REVIEW_FINDINGS on
  # every healthy round and that moves the raw tree identity, so a guard keyed on
  # bare inequality would refuse every hook-mode run ever — which is how the
  # first draft of this check behaved.
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -ne 2 ]
  [ "$(echo "$output" | jq -r '.status')" != "STALE_FINDINGS" ]
}

@test "#1435 §10 --findings-tree is refused in HOOK mode, where one value cannot attest many rounds" {
  # It attests ONE round's panel; hook mode runs every round in a single
  # invocation. Left accepted, round 2 would be compared against round 1's
  # attestation — which round 1's own fix pass has legitimately moved — so every
  # multi-round hook run would be refused for a cadence mistake that did not
  # happen, and the per-round stamp that DOES cover hook mode would be displaced
  # by it.
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix" \
    --findings-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'step-mode flag'
}

@test "#1435 §10 --findings-tree requires a value, and rejects a following flag" {
  # It is parsed with the STRICT value guard, not the --gate-attest exception:
  # there an empty value is fail-CLOSED (run the gate anyway), here it would be
  # fail-OPEN — the guard silently disarmed while the caller believes it is on.
  # The documented `PANEL_TREE=$(git-tree-id.zsh .)` has no error check and that
  # command prints nothing when it fails, so the empty value is a live slip.
  residue_setup
  loop --max-rounds 1 --review-cmd "$(residue_review touched.py)" --fix-cmd 'true' --findings-tree ""
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'requires a non-empty value'

  residue_setup
  loop --max-rounds 1 --review-cmd "$(residue_review touched.py)" --fix-cmd 'true' --findings-tree --resume
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'got the flag'
}

@test "#1435 §9 the promotion flag RESETS: a later round never claims a sweep it did not earn" {
  # `residue_promoted_sweep` is set on the round that promotes and must be
  # cleared at the top of the next. The obvious negative (grep for a round number
  # one higher) is unreachable, because the verdict interpolates
  # `closing_sweep_round`, which stays fixed once promoted. So reach the state
  # instead: round 2 promotes round 3, and round 3 — the SWEEP — raises a fresh,
  # uncarried blocker with budget still left, so it reaches neither residue rung
  # (`nonconv == 0`, and it is not at the ceiling) and falls to the ordinary
  # continuing verdict.
  #
  # Surviving mutation without this: delete the reset. Round 3 then renders
  # "residue conditions hold, but on a DELTA round — promoting round 3" for a
  # FULL round that promoted nothing — a progress trail that lies about which
  # round earned the sweep, on the one surface a human tails.
  residue_setup
  loop --max-rounds 5 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 3 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":300,\"title\":\"round 3 sweep only finding\",\"description\":\"d3\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":10,\"title\":\"unquoted expansion in the matcher\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  # The run's TERMINAL is deliberately not asserted: with budget left the loop
  # keeps going after the sweep, and a later round may legitimately reach residue
  # once its blockers are back inside the fix-touched set. What this fixture pins
  # is the PROGRESS TRAIL — which round claimed the promotion.
  # Round 2 earned the promotion and says so.
  local r2
  r2="$(awk '/^## Round 2 /{f=1} f{print} /^## Round 3 /{exit}' "$BATS_TEST_TMPDIR/wd/progress.md")"
  grep -q 'residue conditions hold, but on a DELTA round' <<< "$r2"
  # A GLOBAL count is deliberately not asserted: with budget left, later DELTA
  # rounds may legitimately promote again, so "exactly once" would be a claim
  # about this fixture rather than about the reset.
  # ...and round 3 — the sweep, which promoted nothing — rendered an ordinary
  # continuing verdict. Sliced to round 3's own block, so a match from round 1
  # cannot stand in for it.
  local r3
  r3="$(awk '/^## Round 3 /{f=1} f{print} /^## Round 4 /{exit}' "$BATS_TEST_TMPDIR/wd/progress.md")"
  grep -q 'fix pass (in-loop), continuing' <<< "$r3"
  run ! grep -q 'residue conditions hold' <<< "$r3"
}

# --- #1498: the one-shot all-ambiguous auto-continue ---------------------------
#
# ONE fixture shape, defined once, so a half-applied edit cannot make the
# positive and the veto cases exercise different things. Round 1 raises two
# WARNINGs 55 lines apart — further than LINEWIN (10), so neither can ever
# gather the other's prior and the one-to-one attribution is unambiguous. Round 2
# raises two more, each three lines from its OWN prior and each sharing
# significant (>= 4-char) tokens with it without matching it exactly. That is
# precisely the AMBIGUOUS verdict: not a verified survivor (no exact title), not
# a #983 disjoint false trip (tokens are shared).
#
# WARNING, never CRITICAL: a Critical anywhere in the carried set vetoes the
# rung, which the veto test below drives on purpose.
#
# Round 1's first title is deliberately NOT already normalised — mixed case, a
# double space, and a literal tab. The marker records `normtitle`, so the
# expected content below stays lower-cased and single-spaced, which is what
# makes the `diff` kill a lost `ascii_downcase`, a lost `gsub("\\s+"; " ")`, and
# a tab reaching the marker (where it would forge a fourth field and break the
# `cut -f2-` round-trip the one-shot bound depends on). With every fixture title
# pre-normalised, all three of those deletions passed the suite.
pft_round1='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"Unquoted  Variable\\tIn The Matcher\",\"description\":\"d1\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":60,\"title\":\"missing timeout on the fetch helper\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
pft_round2='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":63,\"title\":\"missing timeout on the upload helper\",\"description\":\"d2\",\"reviewer\":\"r\"}]'

# The marker this run should write, in full. Asserted as CONTENT rather than as
# a line count: the identity rule (#1498) records BOTH titles of every match —
# the item's own and its matched prior's — so a per-item count would pass on an
# implementation that recorded only one of them, which is exactly the hole a
# re-wording would then walk through. `unique` inside the loop sorts them, so
# the expected order is lexicographic.
pft_expected_marker() {   # $1 = the round that continued
  printf '%s\tapp.py\ttests\tmissing timeout on the fetch helper\n' "$1"
  printf '%s\tapp.py\ttests\tmissing timeout on the upload helper\n' "$1"
  printf '%s\tapp.py\ttests\tunquoted variable in the dispatcher\n' "$1"
  printf '%s\tapp.py\ttests\tunquoted variable in the matcher\n' "$1"
}

# `$1` is the round-3 findings document (escaped for the printf inside the hook);
# rounds 4+ are always clean, so a run that gets past round 3 converges rather
# than drifting into the budget and reporting the wrong terminal for the wrong
# reason.
pft_review() {  # $1 = round-3 findings (default: none)
  local r3="${1:-[]}"
  printf '%s' 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$pft_round1"'" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "'"$pft_round2"'" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 3 ]; then printf "%s" "'"$r3"'" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi'
}

@test "#1498 tc-happy-possible-false-trip-auto-continue: an all-ambiguous carried set continues instead of exiting 12" {
  loop --review-cmd "$(pft_review)" --fix-cmd 'true'
  # the run did NOT stop at round 2 — it took the round it already had and then
  # converged on the clean round 3
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  # ...and round 2 really was the state this rung is about: two carried matches,
  # both ambiguous, no Critical. Without this the test would pass on a run that
  # never reached the rung at all.
  echo "$output" | jq -e '.round_changelists[1].non_converging == true' >/dev/null
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | length == 2' >/dev/null
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  echo "$output" | jq -e '.round_changelists[1].summary.critical == 0' >/dev/null
  # the count is of CONTINUATIONS, not identities: four records, one round
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  diff <(pft_expected_marker 2) "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  # ...and exactly four records. A lost whitespace collapse would split round 1's
  # tab-bearing title into an extra field rather than adding a line, so the diff
  # above is what catches that; this catches the reverse — a normalisation that
  # merges or drops one of the four identities.
  [ "$(wc -l < "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued" | tr -d ' ')" -eq 4 ]
}

@test "#1498 the continued round says so in progress.md, distinctly from #983's line" {
  loop --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  local r2
  r2="$(awk '/^## Round 2 /{f=1} f{print} /^## Round 3 /{exit}' "$BATS_TEST_TMPDIR/wd/progress.md")"
  # the per-blocker line carries the marker, on BOTH carried matches
  [ "$(grep -c -- '- possible false trip auto-continued (#1498):' <<< "$r2")" -eq 2 ]
  # ...and the round verdict says the run continued without a grant
  grep -q 'auto-continued once, no grant consumed (#1498)' <<< "$r2"
  # #983's line is for a DISJOINT-title match, which this round has none of —
  # so the two must not be collapsible into one another
  run ! grep -q -- '- false trip auto-continued (#983):' <<< "$r2"
}

@test "#1571 tc-error-second-ambiguous-match: a recorded identity is refused, and residue catches the rung" {
  # Round 3 re-raises a title the marker already holds. Its own normalised title
  # IS recorded, so the one-shot bound refuses — and since #1571 the ladder falls
  # through to RESIDUE, not to the escalation it would have taken before.
  local r3='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":11,\"title\":\"unquoted variable in the matcher\",\"description\":\"d3\",\"reviewer\":\"r\"}]'
  loop --review-cmd "$(pft_review "$r3")" --fix-cmd 'true'
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  # round 3 really was another ambiguous carried match — otherwise this pins the
  # wrong thing entirely
  echo "$output" | jq -e '[.round_changelists[2].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  # the count did not move, and neither did the marker
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  diff <(pft_expected_marker 2) "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  # ...and the round that ENDS the run renders the PLAIN line. Without this the loop's
  # `(( pftc )) &&` flag guard is only tested positively: pass the flag
  # unconditionally and every other assertion here still holds, while progress.md
  # tells the human the run continued on a round that in fact stopped.
  local r3
  r3="$(awk '/^## Round 3 /{f=1} f{print}' "$BATS_TEST_TMPDIR/wd/progress.md")"
  grep -q -- '- possible false trip: `app.py:11`' <<< "$r3"
  lacks "$r3" 'possible false trip auto-continued (#1498)'
  lacks "$r3" 'continued once without a human grant'
}

@test "#1498 tc-corner-marker-identity-matched-prior-title: a rewording buys no second continuation" {
  # Round 3's OWN title is fresh — nothing in the marker matches it — but the
  # prior it matched is recorded. Recording only the current title would let the
  # very re-wording that makes a match ambiguous earn an unbounded run of free
  # rounds, one new synonym at a time.
  local r3='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":11,\"title\":\"unquoted variable in the resolver\",\"description\":\"d3\",\"reviewer\":\"r\"}]'
  loop --review-cmd "$(pft_review "$r3")" --fix-cmd 'true'
  [ "$status" -eq 14 ]
  # ...and it really was the matched_prior half that refused: round 3 matched
  # the prior the marker holds. Read BEFORE the `run !` below, which replaces
  # $output with grep's.
  echo "$output" | jq -e '.round_changelists[2].blocking[0].matched_prior.title == "unquoted variable in the dispatcher"' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  grep -qF 'app.py	tests	unquoted variable in the dispatcher' \
    "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  # the round-3 title itself is absent from the marker, so nothing but the
  # matched_prior half can have produced the refusal
  run ! grep -qF 'unquoted variable in the resolver' \
    "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
}

@test "#1571 tc-error-mixed-carried-set: one exact-title match vetoes the free round, residue catches the rung" {
  # Round 2 re-raises the second blocker VERBATIM at its own line: an exact
  # normalised-title match, which is a verified survivor (possible_false_trip
  # false). "Every carried match is ambiguous" is then false, and the rung must
  # not fire on a genuinely stuck blocker; since #1571 what catches the rung
  # afterwards is residue rather than the escalation.
  local r2='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":60,\"title\":\"missing timeout on the fetch helper\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$pft_round1"'" > "$REVIEW_FINDINGS"; else printf "%s" "'"$r2"'" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  # the mix really is a mix: one ambiguous, one verified
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true) | .possible_false_trip] | sort == [false, true]' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued" ]
}

@test "#1498 tc-error-critical-in-carried-set-escalates: a Critical among the ambiguous matches vetoes" {
  local one='[{\"severity\":\"CRITICAL\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in the matcher\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  local two='[{\"severity\":\"CRITICAL\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$one"'" > "$REVIEW_FINDINGS"; else printf "%s" "'"$two"'" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 12 ]
  # the carried match IS ambiguous — the ONLY thing separating this from the
  # happy case is the severity, which is what makes it a test of the veto
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  echo "$output" | jq -e '.round_changelists[1].summary.critical == 1' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued" ]
}

@test "#1498 tc-corner-critical-outside-carried-set-auto-continues: the veto is per-match, not round-wide" {
  # A fresh Critical that is NOT part of the ambiguity (non_converging false) has
  # nothing to do with whether the cross-round match is a proximity artifact, so
  # it must not veto. `other.py` exists before the loop starts, so a finding in
  # it survives scope-findings (which scopes against the story diff).
  echo "print(2)" > "$R/other.py"
  local r2='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"other.py\",\"line\":200,\"title\":\"brand new unrelated defect here\",\"description\":\"d2\",\"reviewer\":\"q\"}]'
  local one='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in the matcher\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$one"'" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "'"$r2"'" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # the Critical really was there, and really was outside the carried set
  echo "$output" | jq -e '.round_changelists[1].summary.critical == 1' >/dev/null
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.priority == "Critical")] | (length > 0) and all(.non_converging == false)' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  # The marker's CONTENT, not merely its existence — which is the other half of
  # this test's thesis. The out-of-set Critical must not be given a bound
  # either: `_pft_identities` enumerates the carried set, so dropping its
  # `select(.non_converging == true)` would record `other.py` too, and a bare
  # `-s` cannot see that. The cost of missing it is the rung silently ceasing to
  # fire on any run that also carries unrelated fresh findings.
  local M="$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  diff <(printf '2\tapp.py\ttests\tunquoted variable in the dispatcher\n2\tapp.py\ttests\tunquoted variable in the matcher\n') "$M"
  run ! grep -qF 'other.py' "$M"
}

@test "#1498 tc-corner-at-ceiling-no-auto-continue: the ceiling stands, and never as a bare-status exit 1" {
  # `round < effective_max` is load-bearing rather than decorative: the while
  # loop exited with an EMPTY loop_status falls through to the exit case's
  # catch-all and emits a bare-status exit 1 — an operational failure, not a
  # terminal. So this asserts the CODE as much as the absence of the marker.
  loop --max-rounds 2 --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  # the round really did carry an all-ambiguous set — the ceiling is the ONLY
  # thing that refused it
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued" ]
  # ...and the round renders the PLAIN line: a ceiling refusal is still a
  # refusal, so progress.md must not claim a continuation happened
  local r2
  r2="$(awk '/^## Round 2 /{f=1} f{print}' "$BATS_TEST_TMPDIR/wd/progress.md")"
  grep -q -- '- possible false trip: `app.py:8`' <<< "$r2"
  lacks "$r2" 'possible false trip auto-continued (#1498)'
}

@test "#1498 tc-corner-ceiling-unmutated: an auto-continue is not a grant" {
  loop --max-rounds 4 --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  # the ceiling the caller passed is what gets reported, the closing-sweep grant
  # is untouched, and the run ended no later than that ceiling
  [ "$(echo "$output" | jq '.max_rounds')" -eq 4 ]
  [ "$(echo "$output" | jq -r '.closing_sweep_granted')" = "false" ]
  echo "$output" | jq -e '.rounds <= .max_rounds' >/dev/null
}

@test "#1498 an auto-continued run still runs OUT of budget on time — the ceiling is observed, not assumed" {
  # The reported `max_rounds` is the caller's value by construction, so asserting
  # it can never see `effective_max`. This drives a run to the ceiling instead:
  # round 2 auto-continues, round 3 IS the ceiling and exhausts the budget. Add
  # `(( effective_max++ ))` beside the auto-continue and the run reaches round 4,
  # so the exact round count and the terminal both red — which is what makes
  # "a CONTINUE, not a grant" a tested claim rather than a stated one.
  echo "print(2)" > "$R/other.py"
  local one='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in the matcher\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  local two='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  # a genuinely different blocker: another file, and no shared significant token
  local three='[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"other.py\",\"line\":200,\"title\":\"stale cache never invalidated\",\"description\":\"d3\",\"reviewer\":\"q\"}]'
  loop --max-rounds 3 \
    --review-cmd 'case "$REVIEW_ROUND" in 1) printf "%s" "'"$one"'" > "$REVIEW_FINDINGS" ;; 2) printf "%s" "'"$two"'" > "$REVIEW_FINDINGS" ;; *) printf "%s" "'"$three"'" > "$REVIEW_FINDINGS" ;; esac' \
    --fix-cmd 'true'
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  # EXACTLY the ceiling, not merely within it
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
  [ "$(echo "$output" | jq -r '.closing_sweep_granted')" = "false" ]
  # ...and the auto-continue really did happen on the way, so the run reached the
  # ceiling THROUGH the rung rather than never touching it
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
}

@test "#1571 tc-corner-auto-continue-wins-over-residue: the rung sits ABOVE the residue rung" {
  # The ORDER of the two rungs, and #1571 inverted it. #1435's placement rule
  # put residue first, which was right while residue also required every blocker
  # to be in the previous round's fix-touched set — that made it rare here. With
  # condition 2 removed residue holds on almost any zero-CRITICAL
  # non-convergence, so leaving it first let it SWALLOW this rung: a run that
  # admits it cannot tell a reworded survivor from a new neighbour would ship the
  # finding instead of spending the round it still had. The auto-continue is
  # therefore tried FIRST — it is the loop continuing, so the rung is not yet the
  # ending residue is entitled to replace — and residue catches whatever it
  # declines.
  residue_setup
  local one='[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":5,\"title\":\"unquoted variable in the matcher\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  local two='[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  loop --max-rounds 5 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$one"'" > "$REVIEW_FINDINGS"; else printf "%s" "'"$two"'" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd "$residue_fix"
  # ROUND 2 is the round both rungs were live on: its carried set is entirely
  # ambiguous AND its residue conditions hold. The auto-continue taking that
  # round — rather than residue promoting the closing sweep there — is the whole
  # assertion, and it is the exact inversion of what this test pinned before.
  echo "$output" | jq -e '[.round_changelists[1].blocking[] | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  # the free round was SPENT, and its identity recorded so it cannot be spent twice
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  [ -e "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued" ]
}

@test "#1498 tc-corner-null-line-file-wide-match: a file-wide match auto-continues on a line-independent identity" {
  # `line: null` is the documented file-wide wildcard: it gathers against every
  # candidate in its file+dimension. The identity is file/dimension/normtitle, so
  # it carries no line either — which is what keeps the one-shot bound working
  # for a match that has no line to be near.
  local one='[{\"severity\":\"WARNING\",\"dimension\":\"resilience\",\"file\":\"app.py\",\"line\":null,\"title\":\"outbound call has no breaker\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  local two='[{\"severity\":\"WARNING\",\"dimension\":\"resilience\",\"file\":\"app.py\",\"line\":null,\"title\":\"outbound call has no timeout\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  local three='[{\"severity\":\"WARNING\",\"dimension\":\"resilience\",\"file\":\"app.py\",\"line\":null,\"title\":\"outbound call has no fallback\",\"description\":\"d3\",\"reviewer\":\"r\"}]'
  loop --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "'"$one"'" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "'"$two"'" > "$REVIEW_FINDINGS"; else printf "%s" "'"$three"'" > "$REVIEW_FINDINGS"; fi' \
       --fix-cmd 'true'
  # round 2 auto-continued; round 3 matched a RECORDED identity (round 2's own
  # title, which is round 3's matched prior) and was refused a second
  # continuation, so residue caught the rung
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  echo "$output" | jq -e '.round_changelists[1].blocking[0].line == null' >/dev/null
  echo "$output" | jq -e '[.round_changelists[1].blocking[]
      | select(.non_converging == true)] | (length > 0) and all(.possible_false_trip == true)' >/dev/null
  grep -qF 'app.py	resilience	outbound call has no timeout' \
    "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
}

@test "#1498 tc-corner-status-key-always-present: an integer on every terminal, 0 when nothing continued" {
  clean_loop
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.possible_false_trip_auto_continues == 0' >/dev/null
  budget_loop
  [ "$status" -eq 13 ]
  echo "$output" | jq -e '.possible_false_trip_auto_continues == 0' >/dev/null
  # ...and it is an INTEGER, not a string or a null, so a consumer never has to
  # tell 0 from a status file predating the key
  echo "$output" | jq -e '(.possible_false_trip_auto_continues | type) == "number"' >/dev/null
  stuck_loop
  [ "$status" -eq 12 ]
  echo "$output" | jq -e '.possible_false_trip_auto_continues == 0' >/dev/null
}

@test "#1498 tc-corner-history-no-new-key: the per-round history line gains NO auto-continue key" {
  loop --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  H="$BATS_TEST_TMPDIR/wd/history.jsonl"
  # the six legitimate keys are all still there...
  jq -es 'all(.[]; has("round") and has("blocking") and has("conflicts")
                   and has("non_converging") and has("false_trips")
                   and has("adjudicated_dropped"))' "$H" >/dev/null
  # ...and nothing #1498-derived joined them. A REGEX FAMILY over the key names
  # rather than a guess-list of literals, for the reason #1435 records: a fifth
  # spelling would slip straight through a closed list. Still not a closed KEY
  # SET (#1463) — a sibling may legitimately add its own key.
  jq -es 'all(.[]; [keys[] | select(test("continu|auto|possible"))] | length == 0)' "$H" >/dev/null
}

@test "#1498 the history-line regex family really catches an auto-continue-derived key" {
  # Non-vacuity for the negative above: a regex nobody can trip passes forever.
  local probe="$BATS_TEST_TMPDIR/history-probe-1498.jsonl"
  local k
  for k in possible_false_trip_auto_continues auto_continued continued possible_false_trips; do
    jq -nc --arg k "$k" '{round:1, blocking:0, conflicts:0, non_converging:false,
                          false_trips:0, adjudicated_dropped:0} + {($k): 1}' > "$probe"
    jq -es 'all(.[]; [keys[] | select(test("continu|auto|possible"))] | length == 0)' \
      "$probe" >/dev/null && { echo "family missed the key: $k"; return 1; }
  done
  # ...and it does not red on the six legitimate keys, so it filters rather than
  # refusing everything
  jq -nc '{round:1, blocking:0, conflicts:0, non_converging:false,
           false_trips:0, adjudicated_dropped:0}' > "$probe"
  jq -es 'all(.[]; [keys[] | select(test("continu|auto|possible"))] | length == 0)' "$probe" >/dev/null
}

@test "#1571 tc-error-unstamped-changelist: an absent per-item flag is never read as a pass, and residue catches the rung" {
  # The rung reuses the `$stamped` predicate its four sibling surfaces use, and
  # the reason it must is that an UNSTAMPED changelist cannot be distinguished
  # from an all-ambiguous one by reading `.possible_false_trip` alone: both
  # answer "not true" for every item. Reading absence as a pass would
  # auto-continue a round nothing classified.
  #
  # The current consolidator always stamps, so the state is reachable only from
  # an older or a foreign producer. Driven here by running the loop out of a COPY
  # of its scripts directory whose consolidator strips the per-item stamp — no
  # production seam, and `${0:A:h}` resolves to the copy, so every sibling the
  # loop calls comes from it too.
  local dir="$BATS_TEST_TMPDIR/unstamped-scripts"
  cp -R "$REPO_ROOT/development/skills/resolve-issue/scripts" "$dir"
  cat > "$dir/consolidate-findings.zsh" <<EOF
#!/usr/bin/env zsh
"$REPO_ROOT/development/skills/resolve-issue/scripts/consolidate-findings.zsh" "\$@" \\
  | jq -c '.blocking |= map(del(.non_converging))'
EOF
  chmod +x "$dir/consolidate-findings.zsh"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$dir/resolve-story-loop.zsh" --repo "$R" --base main \
    --work-dir "$BATS_TEST_TMPDIR/wdu" \
    --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 14 ]
  # The copy sits at a different depth, so the loop cannot reach the telemetry
  # emitter by its relative path and says so on stderr — best-effort, swallowed,
  # and the run is unaffected. `grep '^{'` isolates the status JSON from that
  # note, the same idiom the #1434 hook-mode tests above use.
  local st
  st="$(echo "$output" | grep '^{')"
  # The stamp gate REFUSES the auto-continue — the subject of this test, and
  # unchanged. What follows the refusal changed in #1571: residue now catches
  # whatever the rung declines, so the run ends there instead of escalating.
  [ "$(echo "$st" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  # the continuation really was refused, or the fall-through proves nothing
  [ "$(echo "$st" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  # the stripping really happened — otherwise this is just the happy path
  # asserting the wrong thing
  echo "$st" | jq -e '[.round_changelists[1].blocking[] | has("non_converging")] | (length > 0) and (map(.) | any | not)' >/dev/null
  # ...and the round WAS the all-ambiguous shape underneath: the surviving
  # per-item flag still says so, which is exactly why the stamp gate has to be
  # what decides
  echo "$st" | jq -e '[.round_changelists[1].blocking[] | .possible_false_trip] | (length > 0) and all' >/dev/null
  [ "$(echo "$st" | jq '.possible_false_trip_auto_continues')" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/wdu/.possible-false-trip-continued" ]
}

@test "#1498 a fresh run clears a previous run's marker rather than inheriting its bound" {
  # The marker is per-RUN state, like .closing-sweep and .promote: a re-used
  # work-dir must not let a previous run's identities deny THIS run the
  # continuation it has not spent, nor let its rounds inflate the reported count.
  mkdir -p "$BATS_TEST_TMPDIR/wd"
  printf '9\tapp.py\ttests\tunquoted variable in the dispatcher\n' \
    > "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  loop --review-cmd "$(pft_review)" --fix-cmd 'true'
  [ "$status" -eq 0 ]
  # the planted record would have refused round 2 had it survived
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 1 ]
  diff <(pft_expected_marker 2) "$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
}

@test "#1498 the bound is per IDENTITY, not per run: a second, disjoint all-ambiguous carry continues too" {
  # Without this, once-per-identity and once-per-RUN are indistinguishable —
  # `(( pft_continues == 0 )) || return 1` at the top of _pft_auto_continue, or a
  # `pft_continues=1` in place of the derivation, would pass every other test
  # here. Two ambiguous pairs in DIFFERENT files, far apart in the run: rounds
  # 1->2 continue on app.py, rounds 3->4 continue on other.py, round 5 is clean.
  echo "print(2)" > "$R/other.py"
  local a1='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":5,\"title\":\"unquoted variable in the matcher\",\"description\":\"d1\",\"reviewer\":\"r\"}]'
  local a2='[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":8,\"title\":\"unquoted variable in the dispatcher\",\"description\":\"d2\",\"reviewer\":\"r\"}]'
  local b3='[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"other.py\",\"line\":40,\"title\":\"retry budget never decremented\",\"description\":\"d3\",\"reviewer\":\"q\"}]'
  local b4='[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"other.py\",\"line\":43,\"title\":\"retry budget never inspected\",\"description\":\"d4\",\"reviewer\":\"q\"}]'
  loop --max-rounds 6 \
    --review-cmd 'case "$REVIEW_ROUND" in 1) printf "%s" "'"$a1"'" > "$REVIEW_FINDINGS" ;; 2) printf "%s" "'"$a2"'" > "$REVIEW_FINDINGS" ;; 3) printf "%s" "'"$b3"'" > "$REVIEW_FINDINGS" ;; 4) printf "%s" "'"$b4"'" > "$REVIEW_FINDINGS" ;; *) printf "[]" > "$REVIEW_FINDINGS" ;; esac' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 5 ]
  # BOTH ambiguous rounds really were the rung's state — round 3 is a fresh
  # blocker in another file, so it carries nothing
  echo "$output" | jq -e '[.round_changelists[1].blocking[] | select(.non_converging == true)] | (length == 1) and all(.possible_false_trip == true)' >/dev/null
  echo "$output" | jq -e '.round_changelists[2].non_converging == false' >/dev/null
  echo "$output" | jq -e '[.round_changelists[3].blocking[] | select(.non_converging == true)] | (length == 1) and all(.possible_false_trip == true)' >/dev/null
  # TWO continuations, on two distinct rounds — the count is of continuations
  [ "$(echo "$output" | jq '.possible_false_trip_auto_continues')" -eq 2 ]
  local M="$BATS_TEST_TMPDIR/wd/.possible-false-trip-continued"
  [ "$(cut -f1 "$M" | sort -u | tr '\n' ' ')" = "2 4 " ]
  # ...and all four identities are recorded, both titles of each match
  grep -qF 'app.py	tests	unquoted variable in the matcher' "$M"
  grep -qF 'app.py	tests	unquoted variable in the dispatcher' "$M"
  grep -qF 'other.py	bugs	retry budget never decremented' "$M"
  grep -qF 'other.py	bugs	retry budget never inspected' "$M"
}

# ---- the human-grant ceiling sidecar, `<work-dir>/.max-rounds` (#1576) -------
#
# The WRITER (record-grant.zsh) has its own file, tests/record-grant.bats. What
# follows is the READER: adoption, its refusal and clamp arms, the fresh-run clear,
# the adoption order against #1434's closing sweep, and one end-to-end case that
# actually runs the writer and then resumes — the write-then-read seam is
# precisely what #1558 lost, so it is proven rather than assumed.
#
# These live here rather than in resolve-story-loop-step.bats on purpose: that
# file is the gate's wall-clock floor (~297 s), and every case below is
# expressible against the hook-mode seam this file already uses.

# Drive one round to BUDGET_EXHAUSTED so the work-dir holds a resumable history,
# then hand the caller a work-dir to seed. `--max-rounds 1` keeps it to a single
# round; the blocker is what makes it exhaust rather than converge.
seed_resumable() {   # seed_resumable <work-dir>
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$1" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
}

# The loop's own sidecar slack, read from source so a retune moves every
# fixture with it. Fails loudly rather than yielding an empty string, which
# would silently turn `$(( 5 + slack ))` into 5 and red a neighbouring test
# with a message about the wrong thing.
sidecar_slack() {
  local v
  v=$(sed -n 's/^typeset -gr MAX_ROUNDS_SIDECAR_SLACK=\([0-9]*\)$/\1/p' "$S")
  [ -n "$v" ] || { echo "could not read MAX_ROUNDS_SIDECAR_SLACK from $S" >&2; return 1; }
  printf '%s' "$v"
}

# Resume that work-dir with a clean round, at the given --max-rounds.
resume_clean() {   # resume_clean <work-dir> <max-rounds>
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$1" --resume --max-rounds "$2" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
}

@test "#1576 a .max-rounds sidecar raises the EFFECTIVE ceiling, never max_rounds itself" {
  # AC 4. The invariant #1434 established stands: max_rounds keeps reporting
  # what the caller passed, so build-escalation.zsh's header, its
  # BUDGET_EXHAUSTED line and build-telemetry-record.zsh's payload all keep
  # reading the number the command line actually carried.
  WD="$BATS_TEST_TMPDIR/wd-adopt"
  seed_resumable "$WD"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
}

@test "#1576 with NO sidecar the two agree and the source is the flag" {
  WD="$BATS_TEST_TMPDIR/wd-nosidecar"
  seed_resumable "$WD"
  [ ! -e "$WD/.max-rounds" ]
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 both keys are ALWAYS present — on a resumed run and on the --no-review fast path" {
  # Same argument promotion_phase and closing_sweep_granted carry: a consumer
  # must never have to tell a value from "a status file that predates the key".
  # The fast path is the one that would silently drop them, because it emits
  # without ever entering the --resume block that adopts the sidecar.
  loop --no-review
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("effective_max_rounds") and has("max_rounds_source")' >/dev/null
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]

  WD="$BATS_TEST_TMPDIR/wd-present"
  seed_resumable "$WD"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  echo "$output" | jq -e 'has("effective_max_rounds") and has("max_rounds_source")' >/dev/null
}

@test "#1576 reader arm (a): a whitespace-padded sidecar is stripped and adopted, silently" {
  WD="$BATS_TEST_TMPDIR/wd-ws"
  seed_resumable "$WD"
  printf '  8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
  # a legitimate value is not a diagnostic
  lacks "$stderr" "max-rounds sidecar"
}

@test "#1576 reader arm (a): internal whitespace is NOT collapsed — a multi-token file is refused" {
  # The strip is leading/trailing ONLY. Collapsing internal whitespace would
  # repair `1\n2` into a ceiling of 12 that nobody wrote. 12 sits INSIDE the
  # soft cap, so if the collapse regressed it would be silently ADOPTED rather
  # than tripping arm (c) — which is why the fixture is chosen this way.
  WD="$BATS_TEST_TMPDIR/wd-multitoken"
  seed_resumable "$WD"
  printf '1\n2\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "ignoring an unreadable max-rounds sidecar"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 a ZERO-BYTE sidecar is treated as absent by the reader, with no diagnostic" {
  # Both ends gate on `-s`. An `-e` would emit 'unreadable sidecar (got:
  # <empty>)' on every resume of a work-dir where a truncated write left the
  # file, sending the operator after a corruption that does not exist.
  WD="$BATS_TEST_TMPDIR/wd-zerobyte"
  seed_resumable "$WD"
  : > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  lacks "$stderr" "max-rounds sidecar"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 reader arm (b): a non-numeric sidecar is refused loudly and falls back to the flag" {
  WD="$BATS_TEST_TMPDIR/wd-garbage"
  seed_resumable "$WD"
  printf 'eight\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "ignoring an unreadable max-rounds sidecar"
  contains "$stderr" "$WD/.max-rounds"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 reader arm (b): an OVER-WIDE (19-digit) sidecar is refused too" {
  # The guard is two-part (`<->` AND an 18-digit cap); the non-numeric case
  # above exercises only the first conjunct. All-digits-but-enormous is the
  # same corrupt-sidecar class the loop already guards for --max-rounds, .t0
  # and .closing-sweep.
  WD="$BATS_TEST_TMPDIR/wd-wide"
  seed_resumable "$WD"
  printf '9999999999999999999\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "ignoring an unreadable max-rounds sidecar"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 reader arm (c): a sidecar beyond the soft cap is CLAMPED and adopted, naming the cap" {
  # A WELL-FORMED but wrong number is the road that actually defeats a budget —
  # exactly what #1434's clamp learned. The cap is derived, never transcribed,
  # so a retune of MAX_ROUNDS_SIDECAR_SLACK moves the fixture with it.
  local slack cap over
  slack=$(sidecar_slack)
  cap=$(( 5 + slack ))
  over=$(( cap + 1 ))
  WD="$BATS_TEST_TMPDIR/wd-overcap"
  seed_resumable "$WD"
  printf '%s\n' "$over" > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "beyond the soft cap"
  contains "$stderr" "$WD/.max-rounds"
  contains "$stderr" "cap $cap"
  # CLAMPED to the cap, not discarded. Dropping it would collapse the ceiling
  # back to --max-rounds and, on a run already past that round, brick every
  # later --resume with exit 2 — stranding a granted, in-progress run.
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq "$cap" ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
}

@test "#1576 an over-cap sidecar does NOT strand a run already past --max-rounds" {
  # The concrete harm of discarding: with the ceiling collapsed back to the
  # flag, the resume guard refuses every subsequent invocation and the human's
  # granted run is unrunnable without hand-editing the sidecar, which the
  # docs forbid.
  local slack over
  slack=$(sidecar_slack)
  over=$(( 1 + slack + 5 ))
  WD="$BATS_TEST_TMPDIR/wd-overcap-strand"
  seed_resumable "$WD"          # exhausted at --max-rounds 1, so round 2 is next
  printf '%s\n' "$over" > "$WD/.max-rounds"
  resume_clean "$WD" 1
  # clamped, so round 2 is admitted rather than refused with exit 2
  [ "$status" -ne 2 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq $(( 1 + slack )) ]
}

@test "#1576 reader arm (c) non-vacuity: the value AT the cap is still adopted" {
  # Without this the clamp could be off by one (or reject everything) and the
  # refusal test above would stay green.
  local slack cap
  slack=$(sidecar_slack)
  cap=$(( 5 + slack ))
  WD="$BATS_TEST_TMPDIR/wd-atcap"
  seed_resumable "$WD"
  printf '%s\n' "$cap" > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  lacks "$stderr" "beyond the soft cap"
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq "$cap" ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
}

@test "#1576 the slack constant covers the sanctioned grant sequence, incl. the #1434 round" {
  # The derivation is 5 grants x +3 PLUS the one closing-sweep round
  # record-grant.zsh folds into its base. A slack of 15 would clamp away exactly
  # the round the fifth sanctioned grant of a sweep-granted run bought.
  local slack softcap increment
  slack=$(sidecar_slack)
  softcap=5
  increment=3
  [ "$slack" -eq $(( softcap * increment + 1 )) ]
}

@test "#1576 reader arm (d): a sidecar at or below the passed flag simply loses to it" {
  # This is what makes "a passed value ABOVE the file wins" a special case of
  # one rule rather than a second rule to keep in sync: a human raising
  # --max-rounds further needs no sidecar edit.
  WD="$BATS_TEST_TMPDIR/wd-below"
  seed_resumable "$WD"
  printf '4\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
  # arm (d) is not a refusal — nothing is wrong with the file
  lacks "$stderr" "max-rounds sidecar"
}

@test "#1576 reader arm (d): a sidecar EQUAL to the passed flag also loses to it" {
  # The realistic shape: the conductor passes `prev_max + 3`, which is exactly
  # the value the sidecar holds. A `<` instead of `<=` would stamp
  # max_rounds_source: "work-dir" on a run where no grant is in force, so the
  # two keys would disagree about the same run.
  WD="$BATS_TEST_TMPDIR/wd-atflag"
  seed_resumable "$WD"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 8
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
  lacks "$stderr" "max-rounds sidecar"
}

@test "#1576 the sidecar SURVIVES an adopting resume and is re-adopted by the next one" {
  # Step mode runs every round as its own --resume, so a sidecar consumed once
  # would fund exactly ONE round and the next resume would be refused by the
  # ceiling guard — sending the conductor back to the human for rounds already
  # granted. The file is per-RUN, cleared on a fresh start, NOT on a resume.
  WD="$BATS_TEST_TMPDIR/wd-survive"
  seed_resumable "$WD"
  printf '3\n' > "$WD/.max-rounds"
  # An ADOPTING resume: the sidecar is what lets round 2 run at all (the flag
  # is still 1). The terminal is deliberately not asserted — this case is about
  # the file's lifetime, and pinning a terminal here would couple it to the
  # non-convergence rung's fingerprint rules.
  resume_clean "$WD" 1
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 3 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
  # THE assertion: still on disk, unchanged, for the NEXT invocation. In step
  # mode every round is its own --resume, so a sidecar consumed once would fund
  # exactly one round and the next resume would be refused by the ceiling guard.
  [ -e "$WD/.max-rounds" ]
  [ "$(cat "$WD/.max-rounds")" = "3" ]
}

@test "#1576 non-vacuity: the fresh-run clear DOES remove it, so survival is a resume property" {
  # Without this pair, a reader could not tell "survives a resume" from "is
  # never cleared at all" — and the per-run contract depends on both halves.
  WD="$BATS_TEST_TMPDIR/wd-survive-neg"
  seed_resumable "$WD"
  printf '3\n' > "$WD/.max-rounds"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 2 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ ! -e "$WD/.max-rounds" ]
}

@test "#1576 no refusal arm is fatal: every one exits exactly as the no-sidecar run does" {
  # The whole reader is fail-open by design — losing a grant costs one re-grant,
  # dying costs the resumable run. Compare each arm against the control rather
  # than hard-coding 0, so a change to the fixture's terminal moves both.
  WD="$BATS_TEST_TMPDIR/wd-ctl"
  seed_resumable "$WD"
  resume_clean "$WD" 5
  local control="$status"
  # validate the control itself: without this, a regression that broke EVERY
  # resume would move all four values together and the test would pass while
  # proving nothing
  [ "$control" -eq 0 ]

  local slack over
  slack=$(sidecar_slack)
  over=$(( 5 + slack + 1 ))
  local bad
  for bad in eight 9999999999999999999 "$over"; do
    WD="$BATS_TEST_TMPDIR/wd-fatal-$bad"
    seed_resumable "$WD"
    printf '%s\n' "$bad" > "$WD/.max-rounds"
    resume_clean "$WD" 5
    [ "$status" -eq "$control" ]
  done
}

@test "#1576 a fresh (non---resume) run CLEARS a stale .max-rounds rather than inheriting it" {
  # The largest blast radius of the per-run set: a previous story's granted
  # ceiling would silently FUND rounds this run never earned.
  WD="$BATS_TEST_TMPDIR/wd-fresh"
  mkdir -p "$WD"
  printf '99\n' > "$WD/.max-rounds"
  # ...and the writer's atomic-rename debris, which record-grant.zsh's own trap
  # comment promises this same clear sweeps
  printf '9\n' > "$WD/.max-rounds.tmp.99"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 5 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  # assert on the loop's own output BEFORE any further `run` overwrites it
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 5 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
  [ ! -e "$WD/.max-rounds" ]
  [ ! -e "$WD/.max-rounds.tmp.99" ]
}

@test "#1576 the fresh-run clear NAMES the sidecar, in the rm diagnostic and the header inventory" {
  # A clear whose failure diagnostic does not name the file it failed to remove
  # leaves the operator guessing which foreign state was adopted.
  run grep -c 'max-rounds sidecar (\.max-rounds, \.max-rounds\.tmp\.\*)' "$S"
  [ "$output" = "1" ]
  # ...and the file is inventoried in the header beside its siblings
  run grep -c '`<work-dir>/\.max-rounds`' "$S"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "#1576 adoption order: a STALE .closing-sweep is still refused against the granted ceiling" {
  # THE order test. The clamp measures one round beyond the ceiling IN FORCE,
  # so the grant must be VALIDATED before the sweep is judged. A foreign marker
  # is still refused — here 99 against a granted ceiling of 8.
  WD="$BATS_TEST_TMPDIR/wd-order"
  seed_resumable "$WD"
  printf '99\n' > "$WD/.closing-sweep"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  contains "$stderr" "beyond the one-round grant"
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  # ...while the grant itself is adopted normally
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
}

@test "#1576 adoption order: a sweep promoted DURING granted rounds is accepted, not refused" {
  # The defect this ordering exists to prevent. With the clamp measured against
  # the bare flag, a legitimate sweep at round 7 under a granted ceiling of 8
  # is 7 > 5+1 and would be REFUSED — which makes the promoted round a delta
  # round, and §9 forbids a delta round from declaring CONVERGED, so the run
  # could only ever end BUDGET_EXHAUSTED however clean it was.
  WD="$BATS_TEST_TMPDIR/wd-order-during"
  seed_resumable "$WD"
  printf '7\n' > "$WD/.closing-sweep"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  lacks "$stderr" "beyond the one-round grant"
  # 7 is within the granted ceiling of 8, so it is not a GRANT of an extra round
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "false" ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 8 ]
}

@test "#1576 a closing sweep may NOT lower a grant-raised ceiling" {
  # _promote_closing_sweep raises rather than assigns. Keyed on the passed flag
  # it would pull a granted ceiling of 8 down to the sweep's own 7, throwing
  # away the human's last granted round and reporting BUDGET_EXHAUSTED for
  # rounds they had already given.
  WD="$BATS_TEST_TMPDIR/wd-nolower"
  seed_resumable "$WD"
  printf '6\n' > "$WD/.closing-sweep"
  printf '9\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  # the sweep sits BELOW the granted ceiling, so the ceiling is untouched
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 9 ]
}

@test "#1576 max_rounds_source stays 'flag' when only the #1434 sweep raised the ceiling" {
  # The field distinguishes a HUMAN grant from the loop's own safety net. With
  # no sidecar at all, a sweep-raised ceiling must not claim a grant it never
  # got — the one thing this key exists to tell apart.
  WD="$BATS_TEST_TMPDIR/wd-sweeponly"
  seed_resumable "$WD"
  printf '6\n' > "$WD/.closing-sweep"
  [ ! -e "$WD/.max-rounds" ]
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 6 ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "flag" ]
}

@test "#1576 a sweep one past the GRANTED ceiling is itself granted, and raises it again" {
  # The grant is "one round beyond the ceiling in force", and since #1576 that
  # ceiling can be a human grant. A sweep at 9 against a granted 8 is exactly
  # one past, so it is granted and the ceiling becomes 9 — the safety net still
  # works at the top of an extended run, which is when it matters most.
  WD="$BATS_TEST_TMPDIR/wd-order-ok"
  seed_resumable "$WD"
  printf '9\n' > "$WD/.closing-sweep"
  printf '8\n' > "$WD/.max-rounds"
  resume_clean "$WD" 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.closing_sweep_granted')" = "true" ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq 9 ]
  # ...and max_rounds still reports what the caller passed
  [ "$(echo "$output" | jq '.max_rounds')" -eq 5 ]
}

@test "#1576 END-TO-END: record-grant.zsh writes the ceiling and the very next --resume runs under it" {
  # The seam #1558 actually lost. Every other case here hand-seeds the file,
  # which proves the reader but would stay green if the two ends disagreed on
  # the format. This one runs the real writer against the real status JSON and
  # asserts the resume adopts exactly the ceiling it echoed.
  WD="$BATS_TEST_TMPDIR/wd-e2e"
  local ST="$BATS_TEST_TMPDIR/e2e-status.json"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 --status-file "$ST" \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]

  local RG="$REPO_ROOT/development/skills/resolve-issue/scripts/record-grant.zsh"
  run zsh "$RG" --work-dir "$WD" --status "$ST" --add 3
  [ "$status" -eq 0 ]
  local echoed="$output"
  [ "$echoed" = "4" ]   # base 1 (max_rounds, no sweep grant) + 3

  # ...and the resume, still passing the ORIGINAL ceiling, runs under the grant
  resume_clean "$WD" 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.effective_max_rounds')" -eq "$echoed" ]
  [ "$(echo "$output" | jq -r '.max_rounds_source')" = "work-dir" ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
}

@test "#1576 non-vacuity: without the grant, that same resume is REFUSED by the ceiling guard" {
  # Proves the end-to-end case is really exercising the grant: the identical
  # resume at --max-rounds 1 with no sidecar cannot start round 2 at all.
  WD="$BATS_TEST_TMPDIR/wd-e2e-neg"
  seed_resumable "$WD"
  [ ! -e "$WD/.max-rounds" ]
  resume_clean "$WD" 1
  [ "$status" -eq 2 ]
  contains "$stderr" "raise --max-rounds"
}

@test "#1571 the upstream rail holds AT THE LOOP: an out-of-diff blocker never becomes residue" {
  # This is the guarantee #1571 traded condition 2 for, pinned where it actually
  # has to hold. reference/residue.md says removal is safe because
  # `scope-findings` confines every round's findings to the story diff and
  # `$scoped` is the ONLY input to the changelist's `.blocking`. Nothing tested
  # that JOIN: tests/review-dispatch.bats pins the filter as a unit, and every
  # loop fixture files against app.py/touched.py, which are in the story diff
  # anyway. Mutation this closes: replace the loop's `scope-findings` call with
  # `cp "$findings_path" "$scoped"` — both loop suites stayed green, while the
  # loop would ship, as residue, a WARNING filed against committed code this
  # story never touched.
  residue_setup
  # README.md is committed at base and never modified, so it is OUTSIDE the story
  # diff — unlike every other file these fixtures use.
  loop --max-rounds 2 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":200,\"title\":\"round 2 unquoted expansion\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"README.md\",\"line\":1,\"title\":\"shipped behaviour this run never opened\",\"description\":\"d3\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 14 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED_WITH_RESIDUE" ]
  # the run really did reach the terminal with a remainder to file...
  echo "$output" | jq -e '.final_changelist.summary.blocking > 0' >/dev/null
  # ...and the out-of-diff finding is NOT in it, so it can never be filed as a
  # follow-up issue against code this story never touched
  [ "$(echo "$output" | jq '[.final_changelist.blocking[] | select(.file == "README.md")] | length')" -eq 0 ]
  # non-vacuity: the IN-diff blocker of the same round did survive, so the
  # assertion above is the filter biting rather than an empty changelist
  [ "$(echo "$output" | jq '[.final_changelist.blocking[] | select(.file == "touched.py")] | length')" -eq 1 ]

  # ...and the claim is about EVERY round, not just the one that ends the run.
  # `.final_changelist` here is round 3, the promoted full sweep. Scoping only
  # full rounds would satisfy every assertion above while round 2 (a DELTA round)
  # carried the out-of-diff blocker into its changelist, into the fix pass's work
  # list and into the review dossier — so assert it on the delta round as well.
  [ "$(echo "$output" | jq '[.round_changelists[] | .blocking[]? | select(.file == "README.md")] | length')" -eq 0 ]
  [ "$(echo "$output" | jq '[.round_changelists[1].blocking[]? | select(.file == "touched.py")] | length')" -ge 1 ]
}
