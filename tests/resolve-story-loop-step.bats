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
