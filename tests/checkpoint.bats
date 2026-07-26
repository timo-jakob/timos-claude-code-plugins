#!/usr/bin/env bats
#
# Behavioral tests for checkpoint.zsh (#517/#534) — the session-surviving
# run-state store for the maintenance orchestrator. The store lives in the
# target repo's `$(git rev-parse --git-common-dir)/claude-maintenance/`:
# repo-scoped, outside the working tree (never dirties it), shared across
# worktrees, and it survives session death — which is the whole point
# (/tmp artifacts and session scratchpads don't).

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CK="$REPO_ROOT/development/skills/maintenance/scripts/checkpoint.zsh"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
}

ck() { run zsh "$CK" "$@"; }

@test "usage: no subcommand -> exit 2" {
  ck
  [ "$status" -eq 2 ]
  contains "$output" "usage"
}

@test "usage: unknown subcommand -> exit 2" {
  ck bogus --repo "$R"
  [ "$status" -eq 2 ]
}

@test "usage: save without --phase/--data -> exit 2" {
  ck save --repo "$R"
  [ "$status" -eq 2 ]
}

@test "not a git repository -> exit 1" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  ck status --repo "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 1 ]
  contains "$output" "not a git repository"
}

@test "save + load round-trips one phase's data" {
  printf '{"languages":["java"],"primary":"java"}' > "$BATS_TEST_TMPDIR/d.json"
  ck save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/d.json"
  [ "$status" -eq 0 ]
  ck load --repo "$R" --phase phase1-detect
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c .)" = '{"languages":["java"],"primary":"java"}' ]
}

@test "save reads --data - from stdin" {
  run bash -c "echo '{\"plan\":[1,2]}' | zsh '$CK' save --repo '$R' --phase phase6-plan --data -"
  [ "$status" -eq 0 ]
  ck load --repo "$R" --phase phase6-plan
  [ "$(echo "$output" | jq -c .plan)" = '[1,2]' ]
}

@test "two phases: both retained, last_completed_phase is the latest save" {
  printf '{"a":1}' > "$BATS_TEST_TMPDIR/a.json"
  printf '{"b":2}' > "$BATS_TEST_TMPDIR/b.json"
  zsh "$CK" save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/a.json"
  zsh "$CK" save --repo "$R" --phase phase4-payload --data "$BATS_TEST_TMPDIR/b.json"
  ck load --repo "$R"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .last_completed_phase)" = "phase4-payload" ]
  [ "$(echo "$output" | jq -r .schema)" = "1" ]
  [ "$(echo "$output" | jq -c '.phases | keys | sort')" = '["phase1-detect","phase4-payload"]' ]
}

@test "re-saving a phase overwrites its data" {
  printf '{"v":1}' > "$BATS_TEST_TMPDIR/d.json"
  zsh "$CK" save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/d.json"
  printf '{"v":2}' > "$BATS_TEST_TMPDIR/d.json"
  zsh "$CK" save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/d.json"
  ck load --repo "$R" --phase phase1-detect
  [ "$(echo "$output" | jq -r .v)" = "2" ]
}

@test "load with no checkpoint -> exit 3" {
  ck load --repo "$R"
  [ "$status" -eq 3 ]
}

@test "load --phase that was never saved -> exit 3" {
  printf '{"a":1}' > "$BATS_TEST_TMPDIR/a.json"
  zsh "$CK" save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/a.json"
  ck load --repo "$R" --phase phase8-stages
  [ "$status" -eq 3 ]
}

@test "status with no checkpoint -> exit 3, says so" {
  ck status --repo "$R"
  [ "$status" -eq 3 ]
  contains "$output" "no checkpoint"
}

@test "status after a save -> exit 0, names the last phase and age" {
  printf '{"a":1}' > "$BATS_TEST_TMPDIR/a.json"
  zsh "$CK" save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/a.json"
  ck status --repo "$R"
  [ "$status" -eq 0 ]
  contains "$output" "last=phase1-detect"
  contains "$output" "age="
}

@test "clear is idempotent and removes the store" {
  printf '{"a":1}' > "$BATS_TEST_TMPDIR/a.json"
  zsh "$CK" save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/a.json"
  ck clear --repo "$R"; [ "$status" -eq 0 ]
  ck clear --repo "$R"; [ "$status" -eq 0 ]
  ck status --repo "$R"; [ "$status" -eq 3 ]
}

@test "dir prints (and creates) the store directory inside .git" {
  ck dir --repo "$R"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  ends_with "$output" "/.git/claude-maintenance"
}

@test "invalid JSON data is rejected (exit 1) and writes nothing" {
  printf 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  ck save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 1 ]
  ck status --repo "$R"
  [ "$status" -eq 3 ]
}

@test "the store never dirties the working tree" {
  printf '{"a":1}' > "$BATS_TEST_TMPDIR/a.json"
  zsh "$CK" save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/a.json"
  [ -z "$(git -C "$R" status --porcelain)" ]
}

@test "worktrees share the checkpoint (git-common-dir): save in main checkout, load in worktree" {
  git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$R" worktree add -q "$BATS_TEST_TMPDIR/wt" -b wt-branch
  printf '{"from":"main-checkout"}' > "$BATS_TEST_TMPDIR/a.json"
  zsh "$CK" save --repo "$R" --phase phase1-detect --data "$BATS_TEST_TMPDIR/a.json"
  ck load --repo "$BATS_TEST_TMPDIR/wt" --phase phase1-detect
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .from)" = "main-checkout" ]
}
