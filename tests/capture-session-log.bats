#!/usr/bin/env bats
# capture-session-log.bats — exercises scripts/capture-session-log.zsh against a
# fixture projects tree via the --projects-dir seam (no real ~/.claude needed).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CAP="$REPO_ROOT/scripts/capture-session-log.zsh"
  P="$BATS_TEST_TMPDIR/projects"
  # alpha (older) + beta (newest) — beta has subagents, gamma has none.
  mkdir -p "$P/-Users-x-repo-alpha/sA/subagents" \
           "$P/-Users-x-repo-beta/sB/subagents" \
           "$P/-Users-x-repo-gamma"
  printf '{"type":"user"}\n'    > "$P/-Users-x-repo-alpha/sA.jsonl"
  printf '{"sidechain":true}\n' > "$P/-Users-x-repo-alpha/sA/subagents/agent-1.jsonl"
  printf '{"type":"user"}\n'    > "$P/-Users-x-repo-beta/sB.jsonl"
  printf '{"sidechain":true}\n' > "$P/-Users-x-repo-beta/sB/subagents/agent-2.jsonl"
  printf '{"sidechain":true}\n' > "$P/-Users-x-repo-beta/sB/subagents/agent-3.jsonl"
  printf '{"type":"user"}\n'    > "$P/-Users-x-repo-gamma/sG.jsonl"
  touch "$P/-Users-x-repo-beta/sB.jsonl"   # make beta the most recent
}

run_cap() { run zsh "$CAP" --projects-dir "$P" "$@"; }

@test "--list shows projects, most recent first" {
  run_cap --list
  [ "$status" -eq 0 ]
  # beta (touched last) must appear before alpha
  [[ "$output" == *"repo-beta"*"repo-alpha"* ]]
}

@test "--dry-run with no project defaults to the newest project + session" {
  run_cap --dry-run --out "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo-beta"* ]]
  [[ "$output" == *"sB.jsonl"* ]]
  [[ "$output" == *"2 agent log(s)"* ]]
}

@test "--project resolves a bare repo name (suffix match)" {
  run_cap --project repo-alpha --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo-alpha"* ]]
  [[ "$output" == *"sA.jsonl"* ]]
}

@test "--project resolves a full repo path by slugifying" {
  run_cap --project /Users/x/repo-beta --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo-beta"* ]]
}

@test "real bundle contains the main transcript AND the subagents dir" {
  run_cap --project repo-beta --out "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/claude-session-sB.tgz" ]
  contents="$(tar -tzf "$BATS_TEST_TMPDIR/claude-session-sB.tgz")"
  [[ "$contents" == *"sB.jsonl"* ]]
  [[ "$contents" == *"sB/subagents/agent-2.jsonl"* ]]
}

@test "a session with no subagents still bundles the main transcript (+ warns)" {
  run_cap --project repo-gamma --out "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no subagents"* ]]
  contents="$(tar -tzf "$BATS_TEST_TMPDIR/claude-session-sG.tgz")"
  [[ "$contents" == *"sG.jsonl"* ]]
}

@test "--session picks a specific id; a bad id is an error" {
  run_cap --project repo-beta --session sB --dry-run
  [ "$status" -eq 0 ]
  run_cap --project repo-beta --session nope --dry-run
  [ "$status" -eq 1 ]
}

@test "unknown project -> exit 1; unknown arg -> exit 2" {
  run_cap --project does-not-exist --dry-run
  [ "$status" -eq 1 ]
  run_cap --bogus
  [ "$status" -eq 2 ]
}

@test "missing projects dir is an error" {
  run zsh "$CAP" --projects-dir "$BATS_TEST_TMPDIR/nope" --list
  [ "$status" -ne 0 ]
}
