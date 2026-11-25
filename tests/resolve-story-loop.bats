#!/usr/bin/env bats
#
# Behavioral tests for resolve-story-loop.zsh (#562), the local, pre-push review
# loop's state machine (epic #557), in HOOK mode: the agentic steps (panel + fix)
# are injected as hook commands, so every exit state is driven deterministically.
# Each terminal status, the usage errors, --resume and its history integrity
# (#912, #913), the per-round scope refresh (#911), delta scoping and the closing
# full sweep (#1434), and what the loop names under the skill's reference/
# directory: next_ref on every exit (#2055) and the --t0 notes (#1976).
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

# --- --promote is retired (#3134) ---------------------------------------------

@test "#3134 --promote is refused like any other unknown option, before anything is emitted" {
  P="$BATS_TEST_TMPDIR/valid-promote.json"
  printf '%s\n' '[{"file":"app.py","line":1,"dimension":"code_quality","title":"extract the magic number"}]' > "$P"
  T="$BATS_TEST_TMPDIR/promote-refused.jsonl"
  WD="$BATS_TEST_TMPDIR/wd-promote-refused"
  run zsh "$S" --repo "$R" --base main --work-dir "$WD" --telemetry-file "$T" --promote "$P" \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 2 ]
  [ "$output" = "unknown flag: --promote" ]
  [ ! -e "$T" ]
  # the same refusal beside --no-review: no special arm is left for the pair
  run zsh "$S" --repo "$R" --no-review --promote "$P"
  [ "$status" -eq 2 ]
  [ "$output" = "unknown flag: --promote" ]
}

@test "#3134 --help no longer lists --promote" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  [ "$(printf "%s" "$output" | grep -c -e "--promote")" -eq 0 ]
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

# ---- delta scoping and the closing full sweep (#1434)
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

@test "#3169 the loop builds no waived-suggestion list: no adjudicated.json, no history key" {
  WD="$BATS_TEST_TMPDIR/wd-no-adjudicated"
  # round 1 raises a blocker, a follow-up: Low and a plain Low; round 2 re-raises
  # the follow-up: Low. The plain Low is discarded by the consolidator, and the
  # re-raised one is logged again rather than suppressed as already waived.
  local r1='[{"severity":"CRITICAL","dimension":"bugs","file":"helper.py","line":1,"title":"unquoted path in the copy step","description":"d","reviewer":"r"},{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"follow-up: rename the temp variable","reviewer":"r"},{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":30,"title":"a plain nit","description":"d","reviewer":"r"}]'
  local r2='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"follow-up: rename the temp variable","reviewer":"r2"}]'
  echo "print(1)" > "$R/helper.py"     # so the fix pass EDITS rather than creates
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    R1="$r1" R2="$r2" SNAP="$WD" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 4 \
    --review-cmd 'printf "%s" "${REVIEW_ADJUDICATED-UNSET}" > "$SNAP/adj-var-r$REVIEW_ROUND.txt"; if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" "$R1" > "$REVIEW_FINDINGS"; elif [ "$REVIEW_ROUND" = 2 ]; then printf "%s" "$R2" > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'echo "x = 2" > "$REVIEW_REPO/helper.py"'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # the plain Low never reached a changelist; the lane Low did, both rounds
  [ "$(echo "$output" | jq '.round_changelists[0].summary.low')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists[1].summary.low')" -eq 1 ]
  echo "$output" | jq -e '[.round_changelists[].summary | has("adjudicated_dropped")] | any | not' >/dev/null
  # no list is built, in the work-dir or under .review/
  [ ! -e "$WD/adjudicated.json" ]
  [ ! -e "$R/.review/adjudicated.json" ]
  # the per-round history line carries no drop count, and progress.md no line
  jq -es 'length >= 2 and all(.[]; has("adjudicated_dropped") | not)' "$WD/history.jsonl" >/dev/null
  run -1 grep -q -- 'adjudicated' "$WD/progress.md"
  # #3168: the panel is never handed a list either
  [ "$(cat "$WD/adj-var-r1.txt")" = "UNSET" ]
  [ "$(cat "$WD/adj-var-r2.txt")" = "UNSET" ]
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
  # always-present: a consumer must
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
  # to code against (REVIEW_FIX_VERIFICATION is empty on round 1). Snapshot
  # the VARIABLE, not the file it
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
  # arbitrary), a closing-sweep grant this run never earned, and an older run's
  # waived-suggestion list, which #3169 retired
  printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$WD/tree-1.txt"
  printf '[{"file":"app.py","line":1,"dimension":"code_quality","title":"rename the temp variable"}]' > "$WD/adjudicated.json"
  cp "$WD/adjudicated.json" "$BATS_TEST_TMPDIR/leftover.json"
  printf '[{"file":"x"}]' > "$WD/verify-2.json"
  printf '9\n' > "$WD/.closing-sweep"
  # a lane suggestion the leftover list names must survive: the list is never read
  local r1='[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"rename the temp variable","description":"follow-up: rename the temp variable","reviewer":"r"}]'
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    R1="$r1" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 3 \
    --review-cmd 'printf "%s" "$R1" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.low')" -eq 1 ]
  # the leftover list is ignored: neither read nor deleted, byte for byte
  cmp "$BATS_TEST_TMPDIR/leftover.json" "$WD/adjudicated.json"
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
  [ ! -e "$DEFAULT_SINK" ]
}

@test "_need_val: a dangling value flag is a usage error (2), not a raw nounset abort (#1004)" {
  # under `setopt nounset` the bare "$2" would abort with zsh's own
  # "2: parameter not set" and exit 1 — a code this script reserves for
  # INTERNAL errors, so a caller mistake would be misreported as one
  local f
  for f in --repo --base --review-cmd --fix-cmd --test-cmd --gate-attest \
           --findings-file --max-rounds --status-file --work-dir --issue --telemetry-file \
           --carry-accounting --risk; do
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
           --findings-file --max-rounds --status-file --work-dir --issue --telemetry-file \
           --carry-accounting --risk; do
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

# --- a suggestion-only round (#1021, #3134) ---------------------------------

# a reviewer panel that raises the same waived Low finding every round
suggestion_loop() {
  loop --review-cmd 'printf "%s" '"'"'[{"severity":"SUGGESTION","dimension":"code_quality","file":"app.py","line":1,"title":"extract the magic number","description":"follow-up: d","reviewer":"q"}]'"'"' > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true' "$@"
}

@test "#1021 a suggestion-only round converges in round 1, and its status JSON carries no promotion_phase (#3134)" {
  suggestion_loop
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.blocking')" -eq 0 ]
  [ "$(echo "$output" | jq '.round_changelists[0].summary.low')" -eq 1 ]
  echo "$output" | jq -e 'has("promotion_phase") | not' >/dev/null
}

# ---------------------------------------------------------------------------
# #2055 next_ref — the closed exit table
# ---------------------------------------------------------------------------

# The table, as the loop states it: one `STATUS-PATTERN<TAB>VALUE` row per arm of
# the `case "$st"` that sets next_ref in emit_and_exit.
next_ref_table() {
  awk '
    /local next_ref=""/ { on = 1; next }
    on && /^[[:space:]]*esac/ { exit }
    on && /\)/ {
      line = $0; sub(/^[[:space:]]*/, "", line)
      pat = line; sub(/\).*/, "", pat)
      val = line; sub(/^[^"]*"/, "", val); sub(/".*/, "", val)
      printf "%s\t%s\n", pat, val
    }' "$LOOP_REAL"
}

@test "#2055 the next_ref table: every non-null value names an existing file under resolve-issue/" {
  local skill_dir="${LOOP_REAL%/scripts/*}" pat val rows=0
  while IFS=$'\t' read -r pat val; do
    [ -n "$pat" ] || continue
    rows=$((rows + 1))
    [ -n "$val" ] || { echo "row $pat has no value" >&2; return 1; }
    case "$val" in /*|../*|*/../*) echo "next_ref $val is not skill-relative" >&2; return 1 ;; esac
    [ -f "$skill_dir/$val" ] || { echo "next_ref $val ($pat) names no file under $skill_dir" >&2; return 1; }
  done < <(next_ref_table)
  # the closed table: AWAITING_FIX, STALE_FINDINGS, ESCALATE_*|BUDGET_EXHAUSTED
  # (CONVERGED_WITH_RESIDUE's row went with the terminal, #2580)
  [ "$rows" -eq 3 ]
  run ! grep -q 'CONVERGED_WITH_RESIDUE' <<< "$(next_ref_table)"
}

@test "#2055 next_ref on every hook-mode exit carries the tabled value" {
  local row producer want
  # producer:expected next_ref (`null` for the statuses the table leaves out).
  # An array, never a heredoc on the loop's stdin: every producer runs the loop
  # script, which would be free to read that stdin away.
  local -a rows=(
    'clean:null'
    'stuck:reference/escalation.md'
    'budget:reference/escalation.md'
    'conflict:reference/escalation.md'
    'ambiguous:reference/escalation.md'
    'skipped:null'
  )
  for row in "${rows[@]}"; do
    producer="${row%%:*}" want="${row#*:}"
    case "$producer" in
      clean)     clean_loop ;;
      stuck)     stuck_loop ;;
      budget)    budget_loop --max-rounds 2 ;;
      conflict)  conflict_loop ;;
      ambiguous) ambiguous_run ;;
      skipped)   run zsh "$S" --no-review ;;
    esac
    [ "$(echo "$output" | jq -r '.next_ref')" = "$want" ] || {
      echo "$producer: next_ref $(echo "$output" | jq -c '.next_ref'), want $want" >&2; return 1; }
    # the key is always PRESENT, null included
    echo "$output" | jq -e 'has("next_ref")' >/dev/null
  done
}

@test "the --t0 notes stand after each frozen span, and no frozen span names --t0 (#1976)" {
  local base="$REPO_ROOT/development/skills/resolve-issue/reference"
  # the text AFTER a span's closing marker (the gap the notes live in)
  after() { awk -v m="<!-- /moved: $2 -->" 'f; $0 == m { f = 1 }' "$1"; }
  local core step2
  core="$(after "$base/review-loop/core.md" round-protocol-head)"
  step2="$(after "$base/review-loop/step-2-invocation.md" round-protocol-step-2)"
  contains "$core" 'step 1 also reads `T0=$(date +%s)` first,
before the `T` mint, the gate and the panel'
  contains "$core" 'Later boundaries capture no `T0`.'
  contains "$core" 'Round 1'"'"'s
panel runs before the loop'"'"'s first invocation, so the loop'"'"'s own clock would
start after it'
  contains "$step2" 'Append `--t0 "$T0"`'
  contains "$step2" 'to the invocation on round
1'"'"'s fresh start only'
  contains "$step2" 'the terminal
record'"'"'s `ts` and `wall_s` span round 1'"'"'s panel'
  contains "$step2" 'Never pass it beside
`--resume`: a resume adopts `<work-dir>/.t0`, and the loop refuses the pair
with exit 2.'
  contains "$step2" 'a resume adopts `<work-dir>/.t0`, and the loop refuses the pair'
  # nothing inside any moved span mentions --t0: the spans stay byte-frozen
  local spans
  spans="$(cat "$base"/review-loop/*.md | awk '/^<!-- moved: /{f=1} /^<!-- \/moved: /{f=0} f')"
  [ -n "$spans" ]
  run grep -c -- '--t0' <<<"$spans"
  [ "$output" = "0" ]
}

@test "#2055 next_ref: AWAITING_FIX names exit-20's shard, STALE_FINDINGS exit-2's" {
  local skill_dir="${LOOP_REAL%/scripts/*}"
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
  [ "$(jq -r '.next_ref' <<<"$output")" = "reference/review-loop/exit-20-awaiting-fix.md" ]
  [ -f "$skill_dir/$(jq -r '.next_ref' <<<"$output")" ]
  # re-passing the same findings file is the byte-identical STALE_FINDINGS refusal
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --resume
  [ "$status" -eq 2 ]
  local json
  json="$(printf '%s\n' "$output" | grep '^{' | tail -1)"
  [ "$(jq -r '.status' <<<"$json")" = "STALE_FINDINGS" ]
  [ "$(jq -r '.next_ref' <<<"$json")" = "reference/review-loop/exit-2-stale-findings.md" ]
  [ -f "$skill_dir/$(jq -r '.next_ref' <<<"$json")" ]
}
