#!/usr/bin/env bats
#
# Behavioral tests for resolve-story-loop.zsh (#562): the local, pre-push review
# loop's state machine (epic #557). The agentic steps (panel + fix) are injected
# as hook commands, so every exit state is driven deterministically. Detection
# is stubbed via DETECT_STACK_BIN (review-dispatch's seam); git runs for real.

bats_require_minimum_version 1.5.0

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

# run the loop against a python repo with the given hook flags
loop() {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd" "$@"
}

@test "clean story converges in round 1 (exit 0), one-line status JSON" {
  loop --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
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
  loop --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  # early exit at round 2 — round 3 never wasted
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  echo "$output" | jq -e '.escalation_reasons | index("non_converging_blocker")' >/dev/null
}

@test "round budget exhaustion exits BUDGET_EXHAUSTED with status JSON" {
  # A GENUINELY different blocker each round -> never non_converging -> runs out
  # the budget. Non-convergence is fingerprinted on [file, dimension] + line
  # proximity (#606), NOT the title — so a distinct blocker must differ in
  # location: the line jumps 1000/2000/3000 (well beyond the proximity window),
  # so no round matches the prior one and the loop exhausts all 3 rounds.
  loop --review-cmd 'printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":$((REVIEW_ROUND*1000)),\"title\":\"b$REVIEW_ROUND\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
}

@test "surviving conflict exits ESCALATE_CONFLICT" {
  loop --review-cmd 'printf "%s" '"'"'[{"severity":"WARNING","dimension":"performance","file":"app.py","line":1,"title":"c","description":"d","reviewer":"p"},{"severity":"WARNING","dimension":"code_quality","file":"app.py","line":1,"title":"e","description":"d","reviewer":"q"}]'"'"' > "$REVIEW_FINDINGS"' \
       --fix-cmd 'true'
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_CONFLICT" ]
}

@test "unsupported/ambiguous repo type exits ESCALATE_AMBIGUOUS before any round" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python","java"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wda" \
    --review-cmd 'true' --fix-cmd 'true'
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
  # First pass: budget 1 -> a single round with a blocker -> BUDGET_EXHAUSTED at round 1.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --max-rounds 1 \
    --review-cmd 'printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]

  # Resume with a raised ceiling; this round emits nothing -> CONVERGED at round 2.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --resume --max-rounds 3 \
    --review-cmd 'printf "[]" > "$REVIEW_FINDINGS"' --fix-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  # continued, did not restart: exit round is 2, and history/changelists span both passes
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 2 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 2 ]
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
  # default --max-rounds (3) is fine, but an explicit ceiling <= last round must refuse
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
