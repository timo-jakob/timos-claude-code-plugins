#!/usr/bin/env bats
#
# The loop's telemetry/v1 record (#1004): the envelope, the outcome mapping,
# the run_id sidecar (#995), the logical start and wall clock, --t0 (#1976), and
# the record's parentage and sinks (#1226): --parent-run-id, the run-id ledger,
# --telemetry-dir and --telemetry-file, and the in-repo sink rules.
#
# One of the resolve-story-loop.zsh suites #3085 split by concern; the shared
# setup, the omniscient-panel wrapper and the helpers more than one suite uses
# are tests/resolve-story-loop-fixture.bash.

bats_require_minimum_version 1.5.0
load assertions
load resolve-story-loop-fixture

setup_file() { loop_fixture_setup_file "$BATS_TEST_DIRNAME/../development/skills/resolve-issue/scripts/resolve-story-loop.zsh"; }
setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  loop_fixture_setup
}
teardown() { loop_fixture_teardown; }

# --- telemetry/v1 (#1004) ---------------------------------------------------
# The loop emits through the SHARED emitter now, so these assert the envelope
# it is responsible for populating; the payload's own shape is
# tests/build-telemetry-record.bats.

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
  [ ! -e "$DEFAULT_SINK" ]
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

@test "the default sink is the user-level ~/.claude/telemetry/<repo-slug>.jsonl (#1004, #1972)" {
  clean_loop --issue 7
  [ "$status" -eq 0 ]
  assert_envelope "$DEFAULT_SINK" success CONVERGED
  [ "$(jq '.issue' "$DEFAULT_SINK")" -eq 7 ]
  # nothing lands inside the checkout any more — neither the pre-#1972 shared
  # file nor the pre-contract per-pipeline one
  [ ! -e "$R/.claude/telemetry" ]
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
  [ ! -e "$DEFAULT_SINK" ]
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
  [ ! -e "$DEFAULT_SINK" ]
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
  [ ! -e "$DEFAULT_SINK" ]
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

@test "no telemetry record on AWAITING_FIX; exactly one on the terminal invocation" {
  T="$BATS_TEST_TMPDIR/telemetry.jsonl"
  printf '%s' "$CRIT" > "$F"
  step --telemetry-file "$T"
  [ "$status" -eq 20 ]
  # `! -e`, not `! -s`: the contract is that AWAITING_FIX writes NOTHING, so a
  # regression that merely touches the sink before the terminal guard must fail
  [ ! -e "$T" ]
  # ...and nothing landed in the default sink either (AC3 is about the stream)
  [ ! -e "$DEFAULT_SINK" ]
  # two resumes since #1434 (the clean delta round promotes the closing sweep),
  # and the AWAITING_FIX in between must ALSO write nothing — which is exactly
  # the claim, now tested across one more non-terminal exit
  converge_clean --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
}

@test "terminal telemetry reports whole-loop wall clock from .t0, not the last round's" {
  T="$BATS_TEST_TMPDIR/telemetry-wall.jsonl"
  seed_awaiting
  # back-date the loop's logical start by 100s; the terminal record must span it
  echo "$(( $(date +%s) - 100 ))" > "$WD/.t0"
  converge_clean --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.wall_s >= 100' "$T")" = "true" ]
}

@test "#1434 an empty (zero-byte) findings file on a FULL round is REFUSED too" {
  # Same argument as the missing file: a truncated write is not a clean review.
  : > "$F"
  step
  [ "$status" -eq 2 ]
  # `grep '^{'`: the refusal prints its diagnostic on stderr, which `run` merges
  # into $output ahead of the status JSON
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "STALE_FINDINGS" ]
  # the STEP-mode wording: it must name the caller's own --findings-file,
  # and must NOT send them to write into the dispatch sink, which the alias
  # guard then refuses — one mistake, two contradictory refusals
  contains "$output" "is a FULL round and --findings-file is missing or empty"
  contains "$output" "never the dispatch sink"
}

@test "step mode drops findings on the work-dir's own files (#909/#911 parity)" {
  WDIN="$R/.loop-wd"
  # An in-repo --status-file as well, so BOTH clauses of the scoped-findings
  # filter are exercised: the work-dir PREFIX (the phantoms below) and the
  # loop-internal FILE list (#1435). Only the prefix half had coverage, so
  # deleting the `$internal` clause left the suite green while a blocker raised
  # on a file the loop rewrites every round became unfixable — it re-appears
  # each round and, since the capture drops the same path, is stamped
  # `new_defect` forever, ending the run on the loop's own bookkeeping.
  SFIN="$R/loop-status.json"
  printf '%s' "$CRIT" > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDIN" --findings-file "$F" \
    --status-file "$SFIN"
  [ "$status" -eq 20 ]
  [ -s "$SFIN" ]
  # the phantom finding is dropped, so round 2 sees zero blockers — but since
  # #1434 that clean DELTA round promotes the closing sweep rather than ending
  # the run, and round 3 is what converges. The claim under test (a finding on
  # the work-dir's own files never counts) is unchanged.
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":".loop-wd/progress.md","line":1,"title":"phantom","description":"d","reviewer":"r"},{"severity":"CRITICAL","dimension":"bugs","file":"loop-status.json","line":1,"title":"phantom three","description":"d","reviewer":"r"}]' > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDIN" --findings-file "$F" --resume \
    --status-file "$SFIN"
  [ "$status" -eq 20 ]
  # BOTH phantoms dropped — the work-dir one by the prefix clause, the
  # status-file one by the loop-internal FILE list
  [ "$(echo "$output" | grep '^{' | jq -r '.final_changelist.summary.blocking')" -eq 0 ]
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":".loop-wd/history.jsonl","line":1,"title":"phantom two","description":"d","reviewer":"r"}]' > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDIN" --findings-file "$F" --resume \
    --status-file "$SFIN"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
}

@test "a .t0 stamped in the FUTURE clamps wall_s to 0 instead of losing the record (#1004)" {
  # .t0 survives only across a --resume (a fresh run rewrites it), which is
  # exactly where a copied work-dir or an NTP step back bites. The emitter
  # rejects a negative --wall-s (exit 2) and the loop swallows that with
  # `|| true`, so without the clamp the whole terminal record vanishes.
  T="$BATS_TEST_TMPDIR/future-wall.jsonl"
  seed_awaiting
  echo "$(( $(date +%s) + 600 ))" > "$WD/.t0"
  converge_clean --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
  [ "$(jq '.wall_s' "$T")" -eq 0 ]
}

@test "an over-wide .t0 falls back to the run's own start rather than losing the record (#1004)" {
  # digits alone are not enough: --ts carries the emitter's 18-digit cap, so a
  # 20-digit .t0 would be rejected there and cost the record
  T="$BATS_TEST_TMPDIR/wide-t0.jsonl"
  seed_awaiting
  echo "99999999999999999999" > "$WD/.t0"
  local NOW; NOW="$(date +%s)"
  converge_clean --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
  local TS
  TS="$(jq -r '.ts' "$T")"
  [ "${#TS}" -le 11 ]        # a real epoch, not the unusable stamp
  # ...and specifically THIS invocation's start, not some other epoch: `$now`
  # is captured just before the resume, so a fallback to .t0 (or anything
  # older) fails here rather than passing on a vacuous `>= 0`
  [ "$TS" -ge "$NOW" ]
}

@test "the step-mode RESUME ERROR path emits a telemetry record too (#1004)" {
  # a second emission call site: the red-gate-after-a-fix abort. It passes
  # repo_type="" and the resumed round, unlike every path covered elsewhere.
  T="$BATS_TEST_TMPDIR/resume-error.jsonl"
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'false' --telemetry-file "$T"
  [ "$status" -eq 1 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
  [ "$(jq -r '.schema' "$T")" = "telemetry/v1" ]
  [ "$(jq -r '.pipeline' "$T")" = "review-loop" ]
  [ "$(jq -r '.outcome' "$T")" = "failed" ]
  [ "$(jq -r '.payload.status' "$T")" = "ERROR" ]
  [ "$(jq -r '.repo_type' "$T")" = "null" ]
  [ "$(jq -r '.wall_s | type' "$T")" = "number" ]
  run zsh "$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh" "$T" --require-records
  [ "$status" -eq 0 ]
}

@test "a NON-NUMERIC .t0 falls back to this run's start — the record survives and the exit is untouched (#1004)" {
  # The guard is two-part (`<->` AND width); the width half is covered above,
  # this is the digits half. A corrupt .t0 — a truncated write, a hand-edited
  # or copied work-dir, the same corruption class this suite already tests for
  # history.jsonl and changelists.jsonl — would otherwise reach `--ts`, which
  # the emitter rejects as non-numeric behind `|| true` (losing the whole
  # record), and would make `$(( ... - t_begin ))` evaluate a bare identifier
  # under `setopt nounset`, aborting the loop with exit 1 instead of its verdict.
  T="$BATS_TEST_TMPDIR/corrupt-t0.jsonl"
  seed_awaiting
  printf 'not-a-number\n' > "$WD/.t0"
  local NOW; NOW="$(date +%s)"
  converge_clean --telemetry-file "$T"
  # the verdict is the loop's own, NOT an operational abort
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  # ...and the record still landed, stamped from this invocation's start
  [ "$(grep -c '' "$T")" -eq 1 ]
  [ "$(jq -r '.ts | type' "$T")" = "number" ]
  [ "$(jq '.ts' "$T")" -ge "$NOW" ]
  [ "$(jq -r '.wall_s | type' "$T")" = "number" ]
  run zsh "$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh" "$T" --require-records
  [ "$status" -eq 0 ]
}

# --- --t0: the conductor-supplied logical start (#1976) ----------------------
# In step mode round 1's panel runs before the first invocation, so the loop's
# own clock starts after it. The conductor passes the start it captured.

@test "--t0 on a fresh start that converges in round 1 stamps ts from it and spans the panel (#1976)" {
  T="$BATS_TEST_TMPDIR/t0-round1.jsonl"
  local T0; T0="$(( $(date +%s) - 300 ))"
  printf '[]' > "$F"
  step --t0 "$T0" --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  [ "$(grep -c '' "$T")" -eq 1 ]
  [ "$(jq '.ts' "$T")" -eq "$T0" ]
  [ "$(jq '.wall_s >= 300' "$T")" = "true" ]
  [ "$(cat "$WD/.t0")" = "$T0" ]
}

@test "--t0 written on the fresh start is the ts of a later --resume's record (#1976)" {
  T="$BATS_TEST_TMPDIR/t0-resume.jsonl"
  local T0; T0="$(( $(date +%s) - 120 ))"
  printf '%s' "$CRIT" > "$F"
  step --t0 "$T0" --telemetry-file "$T"
  [ "$status" -eq 20 ]
  [ "$(cat "$WD/.t0")" = "$T0" ]
  converge_clean --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
  [ "$(jq '.ts' "$T")" -eq "$T0" ]
  [ "$(jq '.wall_s >= 120' "$T")" = "true" ]
}

@test "--t0 on a fresh start rewrites a previous loop's .t0, which never reaches the record (#1976)" {
  T="$BATS_TEST_TMPDIR/t0-foreign.jsonl"
  local T0; T0="$(( $(date +%s) - 60 ))"
  mkdir -p "$WD"
  echo "$(( T0 - 5000 ))" > "$WD/.t0"
  printf '[]' > "$F"
  step --t0 "$T0" --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(cat "$WD/.t0")" = "$T0" ]
  [ "$(jq '.ts' "$T")" -eq "$T0" ]
}

@test "without --t0 the fresh start stamps ts and .t0 from the invocation's own clock (#1976)" {
  T="$BATS_TEST_TMPDIR/t0-absent.jsonl"
  local NOW; NOW="$(date +%s)"
  printf '[]' > "$F"
  step --telemetry-file "$T"
  [ "$status" -eq 0 ]
  local TS; TS="$(jq '.ts' "$T")"
  [ "$TS" -ge "$NOW" ]
  [ "$TS" -le "$(( NOW + 5 ))" ]
  [ "$(cat "$WD/.t0")" = "$TS" ]
}

@test "a non-numeric --t0 exits 2 before any work and names the value (#1976)" {
  T="$BATS_TEST_TMPDIR/t0-junk.jsonl"
  printf '[]' > "$F"
  step --t0 not-a-number --telemetry-file "$T" --status-file "$BATS_TEST_TMPDIR/st.json"
  [ "$status" -eq 2 ]
  contains "$output" '--t0 must be a non-negative integer epoch (got: not-a-number)'
  [ ! -e "$BATS_TEST_TMPDIR/st.json" ]
  [ ! -e "$WD/.t0" ]
  [ ! -e "$T" ]
}

@test "a 19-digit --t0 exits 2 with the width cap and writes no record (#1976)" {
  T="$BATS_TEST_TMPDIR/t0-wide.jsonl"
  printf '[]' > "$F"
  step --t0 9999999999999999999 --telemetry-file "$T"
  [ "$status" -eq 2 ]
  contains "$output" '--t0 is out of range (max 18 digits, got: 9999999999999999999)'
  [ ! -e "$T" ]
  [ ! -e "$WD/.t0" ]
}

@test "--t0 beside --resume is refused and leaves .t0 alone (#1976)" {
  seed_awaiting
  local KEPT; KEPT="$(cat "$WD/.t0")"
  printf '[]' > "$F"
  step --resume --t0 "$(( KEPT - 900 ))"
  [ "$status" -eq 2 ]
  contains "$output" '--t0 is fresh-start only; a --resume adopts <work-dir>/.t0'
  [ "$(cat "$WD/.t0")" = "$KEPT" ]
}

@test "--t0 beside --review-cmd is refused as step-mode only (#1976)" {
  run zsh "$LOOP_REAL" --repo "$R" --base main --work-dir "$WD" \
    --review-cmd 'true' --fix-cmd 'true' --t0 "$(date +%s)"
  [ "$status" -eq 2 ]
  contains "$output" '--t0 is step-mode only'
}

@test "a future-dated --t0 clamps wall_s to 0 and keeps the record (#1976)" {
  T="$BATS_TEST_TMPDIR/t0-future.jsonl"
  printf '[]' > "$F"
  step --t0 "$(( $(date +%s) + 600 ))" --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
  [ "$(jq '.wall_s' "$T")" -eq 0 ]
}

@test "--help lists --t0 (#1976)" {
  run zsh "$LOOP_REAL" --help
  [ "$status" -eq 0 ]
  contains "$output" '[--t0 EPOCH]'
}

# --- #1226: --parent-run-id, --telemetry-dir and the run-id ledger -----------
# A resolve-issue run pre-mints its own run_id and hands it to every loop
# invocation as --parent-run-id, together with the sink flags it was given, so
# every nested review-loop record points back at the run and lands in the same
# sink. The run then lists the loop's ids from the <work-dir>/.telemetry-run-ids
# ledger. These pin the loop's half; tests/story-telemetry.bats pins the run's.

PARENT='resolve-issue-1752403000-8f3a'

@test "#1226 --parent-run-id stamps parent_run_id on the terminal record and fills the ledger" {
  T="$BATS_TEST_TMPDIR/parented.jsonl"
  WD="$BATS_TEST_TMPDIR/wd"
  clean_loop --telemetry-file "$T" --parent-run-id "$PARENT" --issue 412
  [ "$status" -eq 0 ]
  assert_envelope "$T" success CONVERGED
  [ "$(jq -r '.parent_run_id' "$T")" = "$PARENT" ]
  # the ledger names exactly the record the loop emitted
  [ "$(grep -c '' "$WD/.telemetry-run-ids")" -eq 1 ]
  [ "$(cat "$WD/.telemetry-run-ids")" = "$(jq -r '.run_id' "$T")" ]
}

@test "#1226 without --parent-run-id the record stays unparented" {
  T="$BATS_TEST_TMPDIR/unparented.jsonl"
  clean_loop --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent_run_id' "$T")" = "null" ]
}

@test "#1226 a resumed escalation keeps the parent, and the ledger keeps BOTH records" {
  # escalate -> grant -> --resume -> converge on one work-dir. The single-id
  # sidecar is overwritten by the second exit; the ledger must not be, or the
  # parent run would lose its escalation record's id.
  WD="$BATS_TEST_TMPDIR/wd-parented-resume"
  T="$BATS_TEST_TMPDIR/parented-resume.jsonl"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --telemetry-file "$T" --parent-run-id "$PARENT" --issue 412 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --telemetry-file "$T" --parent-run-id "$PARENT" --issue 412 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 2 ]
  [ "$(jq -s --arg p "$PARENT" '[.[] | select(.parent_run_id == $p)] | length' "$T")" -eq 2 ]
  # the ledger, in emission order, is exactly the sink's two run_ids
  [ "$(cat "$WD/.telemetry-run-ids")" = "$(jq -r '.run_id' "$T")" ]
  [ "$(grep -c '' "$WD/.telemetry-run-ids")" -eq 2 ]
  zsh "$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh" "$T" --require-records
}

@test "#1226 a fresh run clears a previous run's ledger; a failed emission adds nothing" {
  WD="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$WD"
  printf 'review-loop-1-dead\n' > "$WD/.telemetry-run-ids"
  local BAD="$BATS_TEST_TMPDIR/a-file"
  : > "$BAD"
  # the emitter refuses a --telemetry-dir that names a file (its exit 2)
  clean_loop --telemetry-dir "$BAD" --parent-run-id "$PARENT"
  [ "$status" -eq 0 ]
  [ ! -e "$WD/.telemetry-run-ids" ]
}

@test "#1226 an empty or dangling --parent-run-id is a usage error, and nothing is emitted" {
  T="$BATS_TEST_TMPDIR/no-parent.jsonl"
  clean_loop --telemetry-file "$T" --parent-run-id ''
  [ "$status" -eq 2 ]
  contains "$output" "--parent-run-id requires a non-empty value"
  [ ! -e "$T" ]
  clean_loop --telemetry-file "$T" --parent-run-id
  [ "$status" -eq 2 ]
  [ ! -e "$T" ]
  # a flag-shaped value is the unquoted-$VAR collapse, not an id
  clean_loop --parent-run-id --telemetry-file "$T"
  [ "$status" -eq 2 ]
  [ ! -e "$T" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "#1226 an empty --telemetry-dir is a usage error, not a default-sink write" {
  clean_loop --telemetry-dir ''
  [ "$status" -eq 2 ]
  [ ! -e "$DEFAULT_SINK" ]
}

# #1761: `jq -r` prints an unset sink in the `args` JSON as the string `null`.
# Run from inside the repo, so a forwarded `null` would land as a relative
# path there; the loop must treat it as the absent flag, as it does --repo-type.
@test "#1761 a literal null --telemetry-file is the absent flag: default sink, no null path" {
  cd "$R"
  clean_loop --telemetry-file null --issue 1761
  [ "$status" -eq 0 ]
  [ ! -e "$R/null" ]
  [ ! -e "$BATS_TEST_TMPDIR/null" ]
  assert_envelope "$DEFAULT_SINK" success CONVERGED
}

@test "#1761 a literal null --telemetry-dir is the absent flag: default sink, no null path" {
  cd "$R"
  clean_loop --telemetry-dir null --issue 1761
  [ "$status" -eq 0 ]
  [ ! -e "$R/null" ]
  [ ! -e "$BATS_TEST_TMPDIR/null" ]
  assert_envelope "$DEFAULT_SINK" success CONVERGED
}

@test "#1226 --telemetry-dir DIR appends to DIR/<slug>.jsonl and not to the local default" {
  local TD="$BATS_TEST_TMPDIR/telemetry"
  git -C "$R" remote add origin https://github.com/timos-platform/tenant-service.git
  clean_loop --telemetry-dir "$TD" --parent-run-id "$PARENT" --issue 412
  [ "$status" -eq 0 ]
  assert_envelope "$TD/timos-platform-tenant-service.jsonl" success CONVERGED
  [ "$(jq -r '.parent_run_id' "$TD/timos-platform-tenant-service.jsonl")" = "$PARENT" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "#1226 --telemetry-file beats --telemetry-dir for the loop's record" {
  local TD="$BATS_TEST_TMPDIR/telemetry"
  T="$BATS_TEST_TMPDIR/wins.jsonl"
  clean_loop --telemetry-dir "$TD" --telemetry-file "$T"
  [ "$status" -eq 0 ]
  assert_envelope "$T" success CONVERGED
  [ ! -e "$TD" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "#1226 a --telemetry-dir the emitter refuses never changes the loop's status or exit" {
  local BAD="$BATS_TEST_TMPDIR/not-a-dir"
  : > "$BAD"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' --telemetry-dir "$BAD"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  contains "$stderr" "--telemetry-dir is not a directory"
  [ ! -s "$BAD" ]
  [ ! -e "$DEFAULT_SINK" ]
  # a stub-escalating run keeps its typed exit too
  stuck_loop --telemetry-dir "$BAD"
  [ "$status" -eq 12 ]
}

@test "#1226 an in-repo --telemetry-dir sink never enters the review scope, on any round" {
  # The sink is written at a TERMINAL exit, so the reachable shape is
  # escalate -> grant -> --resume: round 1 exhausts the budget and appends to
  # $R/tmp-telemetry/repo.jsonl, then the resumed rounds must not review it.
  local TD="$R/tmp-telemetry"
  local WD="$BATS_TEST_TMPDIR/wd-tdir"
  SNAP="$BATS_TEST_TMPDIR/snap-tdir"
  mkdir -p "$SNAP"
  export SNAP
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --telemetry-dir "$TD" \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope-r$REVIEW_ROUND.txt"; printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 13 ]
  # non-vacuity: the sink really is an untracked file inside the repo now
  [ -s "$TD/repo.jsonl" ]
  git -C "$R" status --porcelain --untracked-files=all | grep -qF 'tmp-telemetry/repo.jsonl'
  # a genuine story file beside the sink — the exclusion must NOT hide it
  echo "notes" > "$TD/notes.md"
  echo "print(2)" > "$R/app.py"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --telemetry-dir "$TD" \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope-r$REVIEW_ROUND.txt"; printf "[]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  # at least one resumed round was reviewed...
  [ -e "$SNAP/scope-r2.txt" ]
  # ...and no round, first or resumed, ever saw the sink
  run ! grep -qxF 'tmp-telemetry/repo.jsonl' "$SNAP"/scope-r*.txt
  # while the story file beside it was reviewed
  cat "$SNAP"/scope-r*.txt | grep -qxF 'tmp-telemetry/notes.md'
  # the second terminal record landed in the same in-repo sink
  [ "$(grep -c '' "$TD/repo.jsonl")" -eq 2 ]
}

@test "#1226 the in-repo telemetry-dir rule is exact: nested and non-.jsonl files stay in scope" {
  # The rule is the emitter's own write pattern — a .jsonl DIRECTLY inside DIR.
  # A mutation widening it to a prefix match (the work-dir rule) would hide
  # these; one narrowing it to nothing would let the sink through (above).
  local TD="$R/tel"
  SNAP="$BATS_TEST_TMPDIR/snap-exact"
  mkdir -p "$TD/sub" "$SNAP"
  export SNAP
  echo '{}' > "$TD/sub/fixture.jsonl"
  echo '{}' > "$TD/data.json"
  echo '{}' > "$TD/stale.jsonl"
  loop --telemetry-dir "$TD" \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope.txt"; printf "[]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  grep -qxF 'tel/sub/fixture.jsonl' "$SNAP/scope.txt"
  grep -qxF 'tel/data.json' "$SNAP/scope.txt"
  run ! grep -qxF 'tel/stale.jsonl' "$SNAP/scope.txt"
}

@test "#1226 a --telemetry-dir that IS the repo root excludes only top-level .jsonl files" {
  SNAP="$BATS_TEST_TMPDIR/snap-root"
  mkdir -p "$SNAP" "$R/pkg"
  export SNAP
  echo '{}' > "$R/root-sink.jsonl"
  echo '{}' > "$R/pkg/fixture.jsonl"
  loop --telemetry-dir "$R" \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope.txt"; printf "[]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  grep -qxF 'app.py' "$SNAP/scope.txt"
  grep -qxF 'pkg/fixture.jsonl' "$SNAP/scope.txt"
  run ! grep -qxF 'root-sink.jsonl' "$SNAP/scope.txt"
}

@test "#1226 under --telemetry-file the telemetry-dir is not the sink, so nothing in it is excluded" {
  local TD="$R/tel"
  SNAP="$BATS_TEST_TMPDIR/snap-shadowed"
  mkdir -p "$TD" "$SNAP"
  export SNAP
  echo '{}' > "$TD/story.jsonl"
  loop --telemetry-dir "$TD" --telemetry-file "$BATS_TEST_TMPDIR/elsewhere.jsonl" \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope.txt"; printf "[]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  grep -qxF 'tel/story.jsonl' "$SNAP/scope.txt"
}

@test "#1226 --help names both new flags" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "--telemetry-dir DIR"
  contains "$output" "--parent-run-id ID"
}

@test "#1226 a finding raised ON the in-repo telemetry-dir sink is dropped, never consolidated" {
  # The third consumer of the rule: the scoped-findings filter. A panel that
  # reports against the sink (it is in the story diff until it is filtered)
  # must not block the run — the loop rewrites that file at every terminal exit,
  # so a blocker on it could never be fixed.
  local TD="$R/tel"
  mkdir -p "$TD"
  echo '{}' > "$TD/repo.jsonl"
  loop --telemetry-dir "$TD" \
    --review-cmd 'printf "%s" '"'"'[{"severity":"CRITICAL","dimension":"bugs","file":"tel/repo.jsonl","line":1,"title":"sink","description":"d","reviewer":"r"}]'"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
  # control: the same finding on a NON-sink file in that directory does block
  echo '{}' > "$TD/data.json"
  loop --telemetry-dir "$TD" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"'[{"severity":"CRITICAL","dimension":"bugs","file":"tel/data.json","line":1,"title":"real","description":"d","reviewer":"r"}]'"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 13 ]
}

@test "#1226 the findings filter's rule is exact too: a finding on a NESTED .jsonl still blocks" {
  # The scoped-findings filter is the second copy of the exact rule (jq, not
  # the zsh glob), so it needs its own nested and repo-root controls.
  local TD="$R/tel"
  mkdir -p "$TD/sub"
  echo '{}' > "$TD/sub/fixture.jsonl"
  loop --telemetry-dir "$TD" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"'[{"severity":"CRITICAL","dimension":"bugs","file":"tel/sub/fixture.jsonl","line":1,"title":"nested","description":"d","reviewer":"r"}]'"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 13 ]
  # DIR is the repo root: only a TOP-LEVEL .jsonl is the sink
  mkdir -p "$R/pkg"
  echo '{}' > "$R/pkg/fixture.jsonl"
  loop --telemetry-dir "$R" --max-rounds 1 --work-dir "$BATS_TEST_TMPDIR/wd-root" \
    --review-cmd 'printf "%s" '"'"'[{"severity":"CRITICAL","dimension":"bugs","file":"pkg/fixture.jsonl","line":1,"title":"pkg","description":"d","reviewer":"r"}]'"'"' > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 13 ]
}

@test "#1226 a ledger that cannot be cleared on a fresh start says so, and changes nothing else" {
  WD="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$WD/.telemetry-run-ids"      # a directory where the ledger file goes
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true' \
    --telemetry-file "$BATS_TEST_TMPDIR/ledger-clear.jsonl"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  contains "$stderr" "could not clear the stale telemetry run-id ledger"
}

@test "#1226 an OUT-of-repo --telemetry-dir excludes nothing from the review scope" {
  # the exclusion is for an in-repo sink only; an external one must leave the
  # repo's own top-level .jsonl files in scope
  SNAP="$BATS_TEST_TMPDIR/snap-ext"
  mkdir -p "$SNAP"
  export SNAP
  echo '{}' > "$R/root.jsonl"
  loop --telemetry-dir "$BATS_TEST_TMPDIR/ext-telemetry" \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/scope.txt"; printf "[]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  grep -qxF 'root.jsonl' "$SNAP/scope.txt"
}
