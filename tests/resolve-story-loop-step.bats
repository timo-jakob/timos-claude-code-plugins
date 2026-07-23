#!/usr/bin/env bats
#
# Behavioral tests for resolve-story-loop.zsh STEP MODE (#971): one invocation
# per round, findings supplied via --findings-file, fixes applied in-session
# between invocations (so the loop exits AWAITING_FIX instead of running a fix
# hook). Detection is stubbed via DETECT_STACK_BIN; git runs for real.

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

  WD="$BATS_TEST_TMPDIR/wd"
  F="$BATS_TEST_TMPDIR/findings.json"
  CRIT='[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"T","description":"d","reviewer":"r"}]'
}

# one step-mode invocation against the python repo
step() {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" "$@"
}

# seed a work-dir one AWAITING_FIX round deep (round 1, one CRITICAL blocker)
seed_awaiting() {
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
}

@test "usage: --findings-file with --review-cmd is a usage error (exit 2)" {
  printf '[]' > "$F"
  step --review-cmd 'true'
  [ "$status" -eq 2 ]
}

@test "usage: --findings-file with --fix-cmd is a usage error (exit 2)" {
  printf '[]' > "$F"
  step --fix-cmd 'true'
  [ "$status" -eq 2 ]
}

@test "blockers with budget left exit AWAITING_FIX (20), accumulators populated" {
  printf '%s' "$CRIT" > "$F"
  step
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 1 ]
  [ "$(echo "$output" | jq '.final_changelist.summary.blocking')" -eq 1 ]
  # stdout stays exactly the one-line status JSON
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]
}

@test "clean findings converge in round 1 (exit 0)" {
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 1 ]
}

@test "a missing findings file is treated as no findings (CONVERGED)" {
  rm -f "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "a findings file that is not a JSON array is an internal error (exit 1)" {
  printf 'not json' > "$F"
  step
  [ "$status" -eq 1 ]
}

@test "blockers on the last budget round exit BUDGET_EXHAUSTED (13), not AWAITING_FIX" {
  printf '%s' "$CRIT" > "$F"
  step --max-rounds 1
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
}

@test "a surviving conflict exits ESCALATE_CONFLICT (11) in step mode too" {
  printf '%s' '[{"severity":"WARNING","dimension":"performance","file":"app.py","line":1,"title":"c","description":"d","reviewer":"p"},{"severity":"WARNING","dimension":"code_quality","file":"app.py","line":1,"title":"e","description":"d","reviewer":"q"}]' > "$F"
  step
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_CONFLICT" ]
}

@test "resume with clean findings converges at round 2; accumulators span invocations" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.history | length')" -eq 2 ]
  [ "$(echo "$output" | jq '.round_changelists | length')" -eq 2 ]
}

@test "resume with the SAME blocker trips ESCALATE_NO_CONVERGENCE against the carried prior round" {
  seed_awaiting
  printf '%s' "$CRIT" > "$F"
  step --resume
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
}

@test "a fresh step-mode run does NOT execute --test-cmd (step 3's gate already ran)" {
  printf '%s' "$CRIT" > "$F"
  step --test-cmd 'false'
  # if --test-cmd ran, this would be exit 1; the round must proceed to AWAITING_FIX
  [ "$status" -eq 20 ]
}

@test "--test-cmd red at the start of a step-mode resume is ERROR (exit 1) — the prior fix broke the gate" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'false'
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "ERROR" ]
}

@test "--test-cmd green at the start of a step-mode resume lets the round proceed" {
  seed_awaiting
  printf '[]' > "$F"
  step --resume --test-cmd 'true'
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "progress.md gets a per-round block with the new/carried split (step mode)" {
  seed_awaiting
  grep -q '^## Round 1 — blockers remain' "$WD/progress.md"
  grep -q -- '- blockers: 1 (new: 1, carried: 0), conflicts: 0, suggestions: 0' "$WD/progress.md"
  grep -q -- '- by dimension: bugs 1' "$WD/progress.md"
  printf '%s' "$CRIT" > "$F"
  step --resume
  [ "$status" -eq 12 ]
  grep -q '^## Round 2 — blockers remain' "$WD/progress.md"
  grep -q -- 'new: 0, carried: 1' "$WD/progress.md"
  grep -q '^\*\*Final:\*\* ESCALATE_NO_CONVERGENCE' "$WD/progress.md"
}

@test "progress.md ends with a Final line naming the terminal status (converged run)" {
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  grep -q '^## Round 1 — no blockers' "$WD/progress.md"
  grep -q '^\*\*Final:\*\* CONVERGED' "$WD/progress.md"
}

@test "AWAITING_FIX writes its round block but NO Final line (non-terminal)" {
  seed_awaiting
  run ! grep -q '^\*\*Final:' "$WD/progress.md"
}

@test "hook mode also writes progress.md (both wirings are observable)" {
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-hook" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then printf "%s" '"'"$CRIT"'"' > "$REVIEW_FINDINGS"; else printf "[]" > "$REVIEW_FINDINGS"; fi' \
    --fix-cmd 'true'
  [ "$status" -eq 0 ]
  grep -q '^## Round 1 — blockers remain' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
  grep -q -- '- fix pass (in-loop), continuing' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
  grep -q '^## Round 2 — no blockers' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
  grep -q '^\*\*Final:\*\* CONVERGED' "$BATS_TEST_TMPDIR/wd-hook/progress.md"
}

@test "an unwritable progress.md never aborts the run (transparency is non-fatal)" {
  mkdir -p "$WD/progress.md"   # a DIRECTORY at the target path defeats appends
  printf '[]' > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "no telemetry record on AWAITING_FIX; exactly one on the terminal invocation" {
  T="$BATS_TEST_TMPDIR/telemetry.jsonl"
  printf '%s' "$CRIT" > "$F"
  step --telemetry-file "$T"
  [ "$status" -eq 20 ]
  [ ! -s "$T" ]
  printf '[]' > "$F"
  step --resume --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$T")" -eq 1 ]
}

@test "terminal telemetry reports whole-loop wall clock from .t0, not the last round's" {
  T="$BATS_TEST_TMPDIR/telemetry-wall.jsonl"
  seed_awaiting
  # back-date the loop's logical start by 100s; the terminal record must span it
  echo "$(( $(date +%s) - 100 ))" > "$WD/.t0"
  printf '[]' > "$F"
  step --resume --telemetry-file "$T"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.wall_s >= 100' "$T")" = "true" ]
}

@test "an empty (zero-byte) findings file is treated as no findings (CONVERGED)" {
  : > "$F"
  step
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "step mode drops findings on the work-dir's own files (#909/#911 parity)" {
  WDIN="$R/.loop-wd"
  printf '%s' "$CRIT" > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDIN" --findings-file "$F"
  [ "$status" -eq 20 ]
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":".loop-wd/progress.md","line":1,"title":"phantom","description":"d","reviewer":"r"}]' > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDIN" --findings-file "$F" --resume
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep '^{' | jq -r '.status')" = "CONVERGED" ]
}
