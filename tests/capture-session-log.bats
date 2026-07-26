#!/usr/bin/env bats
# capture-session-log.bats — exercises scripts/capture-session-log.zsh against a
# fixture projects tree via the --projects-dir seam (no real ~/.claude needed).

load assertions

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
  contains "$output" "repo-beta"
  contains "${output#*repo-beta}" "repo-alpha"
}

@test "--dry-run with no project defaults to the newest project + session" {
  run_cap --dry-run --out "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  contains "$output" "repo-beta"
  contains "$output" "sB.jsonl"
  contains "$output" "2 agent log(s)"
}

@test "--project resolves a bare repo name (suffix match)" {
  run_cap --project repo-alpha --dry-run
  [ "$status" -eq 0 ]
  contains "$output" "repo-alpha"
  contains "$output" "sA.jsonl"
}

@test "--project resolves a full repo path by slugifying" {
  run_cap --project /Users/x/repo-beta --dry-run
  [ "$status" -eq 0 ]
  contains "$output" "repo-beta"
}

@test "real bundle contains the main transcript AND the subagents dir" {
  run_cap --project repo-beta --out "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/claude-session-sB.tgz" ]
  contents="$(tar -tzf "$BATS_TEST_TMPDIR/claude-session-sB.tgz")"
  contains "$contents" "sB.jsonl"
  contains "$contents" "sB/subagents/agent-2.jsonl"
}

@test "a session with no subagents still bundles the main transcript (+ warns)" {
  run_cap --project repo-gamma --out "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  contains "$output" "no subagents"
  contents="$(tar -tzf "$BATS_TEST_TMPDIR/claude-session-sG.tgz")"
  contains "$contents" "sG.jsonl"
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

# --- related-session discovery (#414) ----------------------------------------
# A run spans multiple project dirs: the worktree it spawns and headless
# plugin-test/pt-reval sessions. Build a fixture with a main repo + a worktree
# sibling + a headless sibling + an unrelated repo, all under one projects dir.
related_fixture() {
  D="$BATS_TEST_TMPDIR/rel"
  mkdir -p "$D/-Users-x-repositories-acme/main1/subagents" \
           "$D/-Users-x-repositories-acme--claude-worktrees-foo/wt1/subagents" \
           "$D/-private-T-plugin-test-XXXXXX-rnd-acme/h1/subagents" \
           "$D/-Users-x-repositories-unrelated/u1"
  printf '{}\n' > "$D/-Users-x-repositories-acme/main1.jsonl"
  printf '{}\n' > "$D/-Users-x-repositories-acme/main1/subagents/agent-m.jsonl"
  printf '{}\n' > "$D/-Users-x-repositories-acme--claude-worktrees-foo/wt1.jsonl"
  printf '{}\n' > "$D/-Users-x-repositories-acme--claude-worktrees-foo/wt1/subagents/agent-w.jsonl"
  printf '{}\n' > "$D/-private-T-plugin-test-XXXXXX-rnd-acme/h1.jsonl"
  printf '{}\n' > "$D/-private-T-plugin-test-XXXXXX-rnd-acme/h1/subagents/agent-h.jsonl"
  printf '{}\n' > "$D/-Users-x-repositories-unrelated/u1.jsonl"
}

@test "--dry-run lists worktree + headless siblings with their match signal" {
  related_fixture
  run zsh "$CAP" --projects-dir "$D" --project /Users/x/repositories/acme --dry-run
  [ "$status" -eq 0 ]
  contains "$output" "related sessions (2)"
  contains "$output" "claude-worktrees-foo/wt1  [worktree]"
  contains "$output" "plugin-test-XXXXXX-rnd-acme/h1  [headless]"
  lacks "$output" "unrelated"   # a non-sibling repo is never pulled in
}

@test "real bundle stages main at root and siblings under related/" {
  related_fixture
  run zsh "$CAP" --projects-dir "$D" --project /Users/x/repositories/acme --out "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  contents="$(tar -tzf "$BATS_TEST_TMPDIR/claude-session-main1.tgz")"
  contains "$contents" "main1.jsonl"
  contains "$contents" "main1/subagents/agent-m.jsonl"
  contains "$contents" "related/-Users-x-repositories-acme--claude-worktrees-foo/wt1.jsonl"
  contains "$contents" "related/-Users-x-repositories-acme--claude-worktrees-foo/wt1/subagents/agent-w.jsonl"
  contains "$contents" "related/-private-T-plugin-test-XXXXXX-rnd-acme/h1/subagents/agent-h.jsonl"
}

@test "--main-only skips related discovery" {
  related_fixture
  run zsh "$CAP" --projects-dir "$D" --project /Users/x/repositories/acme --dry-run --main-only
  [ "$status" -eq 0 ]
  contains "$output" "skipped — --main-only"
  lacks "$output" "worktree"
}

@test "--window-hours bounds discovery; --related force-includes any dir" {
  related_fixture
  # age the worktree session out of the default 6h window → dropped
  touch -t "$(date -v-10H '+%Y%m%d%H%M' 2>/dev/null || date -d '10 hours ago' '+%Y%m%d%H%M')" \
    "$D/-Users-x-repositories-acme--claude-worktrees-foo/wt1.jsonl"
  run zsh "$CAP" --projects-dir "$D" --project /Users/x/repositories/acme --dry-run
  lacks "$output" "[worktree]"
  # widening the window brings it back
  run zsh "$CAP" --projects-dir "$D" --project /Users/x/repositories/acme --dry-run --window-hours 24
  contains "$output" "[worktree]"
  # --related forces a dir in regardless of signal/window
  run zsh "$CAP" --projects-dir "$D" --project /Users/x/repositories/acme --dry-run --related unrelated
  contains "$output" "unrelated/u1  [manual]"
}
