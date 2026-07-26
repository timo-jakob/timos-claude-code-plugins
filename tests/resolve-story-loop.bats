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
  run ! grep -q 'telemetry/v1' <<<"$output"

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
  run ! grep -q 'CONVERGED' <<< "$output"
}

@test "scope refreshes each round: a file the fix pass creates is reviewed next round (#911)" {
  WD="$BATS_TEST_TMPDIR/wd-scope-refresh"
  # round 1: blocker + the fix pass creates helper.py; round 2: clean -> CONVERGED.
  # The review hook snapshots its scope per round so we can assert the refresh.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope-r$REVIEW_ROUND.txt"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = 1" > "$REVIEW_REPO/helper.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # round 1 reviewed the real pre-fix scope (positive assertion proves the
  # snapshot captured content, so the negative one below discriminates)
  grep -qx 'app.py' "$WD/scope-r1.txt"
  run ! grep -qx 'helper.py' "$WD/scope-r1.txt"
  # round 2 must see the fix's new file
  grep -qx 'helper.py' "$WD/scope-r2.txt"
  grep -qx 'app.py' "$WD/scope-r2.txt"
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
  # round 2's refreshed scope: the story files, but none of the loop's own state
  grep -qx 'app.py' "$BATS_TEST_TMPDIR/wdscope-r2.txt"
  grep -qx 'helper.py' "$BATS_TEST_TMPDIR/wdscope-r2.txt"
  run ! grep -q '^\.loop-wd/' "$BATS_TEST_TMPDIR/wdscope-r2.txt"
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
  run ! grep -q 'CONVERGED' <<< "$output"
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
  # the single link between the consolidator that writes it and the three
  # surfaces that read it (all of whose tests otherwise run on hand-written
  # fixtures). A loop that reshaped or key-filtered the changelist would leave
  # every fixture-based test green while production rendered no label at all.
  echo "$output" | jq -e '.round_changelists[0].blocking[0].promoted == true' >/dev/null
  echo "$output" | jq -e '.final_changelist.blocking[0].promoted == true' >/dev/null
}

@test "#1029 a reviewer-raised blocker in the same round is NOT stamped promoted" {
  # the stamp must mark the human's pick alone; stamping everything would make
  # the label meaningless in all three surfaces
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
