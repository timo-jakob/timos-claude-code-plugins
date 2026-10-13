#!/usr/bin/env bats
#
# Acceptance cases for "worktree telemetry survives the worktree" (#2138) — the
# `cli`-tooled test_cases[] of its story-spec, one test per `tc-*` id:
#
#   tc-happy-worktree-default-sink-lands-in-main   #2155
#   tc-happy-epic-join-across-worktrees            #2156
#   tc-corner-main-checkout-unchanged              #2157
#   tc-corner-explicit-file-passes-through         #2158
#   tc-corner-explicit-dir-passes-through          #2159
#   tc-corner-not-a-git-repo-falls-back            #2160
#   tc-corner-bare-main-falls-back                 #2161
#   tc-corner-many-worktrees-resolves              #2162
#   tc-corner-git-absent-falls-back                #2163
#   tc-corner-run-file-shape-unchanged             #2164
#   tc-error-main-sink-unwritable                  #2165
#   tc-error-repo-dir-not-a-directory              #2166
#
# #2138 landed worktree records in the main checkout's in-repo sink. #1972
# superseded that with the user-level default, ~/.claude/telemetry/<slug>.jsonl,
# which is outside every checkout, so each case keeps its intent against that
# file: a worktree's records outlive the worktree, and every worktree of one
# repo shares one sink.
#
# The use case: timo-platform-builder runs `/development:resolve-issue 741` (an
# epic) from a Claude Code worktree session with no sink flag, and expects the
# epic record, every child record and every review-loop record joined in one
# sink after the worktrees are removed. The model-driven run is reduced to the
# deterministic steps it calls: `story-telemetry.zsh start` / `emit`, and
# `emit-telemetry.zsh` for the loop's record. The default gate's
# tests/telemetry-emit.bats and tests/story-telemetry.bats cover the same
# criteria.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  EMIT="$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh"
  DRIVER="$REPO_ROOT/development/skills/resolve-issue/scripts/story-telemetry.zsh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  UDIR="$HOME/.claude/telemetry"

  MAIN="$BATS_TEST_TMPDIR/timos-claude-code-plugins"
  git init -q "$MAIN"
  git -C "$MAIN" remote add origin git@github.com:timo-jakob/timos-claude-code-plugins.git
  git -C "$MAIN" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  SINK="$UDIR/timo-jakob-timos-claude-code-plugins.jsonl"
  WT="$MAIN/.claude/worktrees/fancy-brewing-magpie"
  git -C "$MAIN" worktree add -q "$WT" -b worktree-fancy-brewing-magpie
}

loop_emit() {  # $1 = --repo-dir, then extra flags
  local rd="$1"; shift
  run --separate-stderr zsh "$EMIT" --pipeline resolve-issue --kind run --outcome success \
    --wall-s 412 --repo-dir "$rd" "$@"
}

@test "tc-happy-worktree-default-sink-lands-in-main: a worktree emit with no sink flag lands in the user-level sink" {
  loop_emit "$WT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$SINK")" -eq 1 ]
  [ ! -e "$WT/.claude/telemetry" ]
  [ ! -e "$MAIN/.claude/telemetry" ]
}

@test "tc-happy-epic-join-across-worktrees: epic, child and loop records join in the user-level sink" {
  local WB="$MAIN/.claude/worktrees/child-2138" ERUN="$BATS_TEST_TMPDIR/epic-run.json"
  local CRUN="$BATS_TEST_TMPDIR/story-run-2138.json" a
  git -C "$MAIN" worktree add -q "$WB" -b fix/2138-worktree-sink
  (cd "$WT" && zsh "$DRIVER" start --run-file "$ERUN" --ts 1791280000 >/dev/null)
  local -a cargs=() largs=()
  while IFS= read -r a; do cargs+=("$a"); done < <(jq -r '.child_start_args[]' "$ERUN")
  (cd "$WB" && zsh "$DRIVER" start --run-file "$CRUN" --ts 1791280410 "${cargs[@]}" >/dev/null)
  while IFS= read -r a; do largs+=("$a"); done < <(jq -r '.loop_args[]' "$CRUN")
  zsh "$EMIT" --pipeline review-loop --outcome success --wall-s 300 --repo-dir "$WB" "${largs[@]}" >/dev/null
  printf '%s' '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","risk":"elevated","pr":2446,"story_spec_present":true}' > "$BATS_TEST_TMPDIR/cs.json"
  zsh "$DRIVER" emit --run-file "$CRUN" --state "$BATS_TEST_TMPDIR/cs.json" --repo-dir "$WB" --issue 2138 >/dev/null
  local epic_id child_id
  epic_id="$(jq -r .run_id "$ERUN")"
  child_id="$(jq -r .run_id "$CRUN")"
  jq -n --arg c "$child_id" '{outcome:"parked",e1_classification:"native_children",children:{total:18,completed_before:6,resolved_this_run:1,escalated:0,parked:0,queued:11},split:{parallel:0,sequential:1},child_run_ids:[$c],e4:{ran:false,result:null}}' > "$BATS_TEST_TMPDIR/es.json"
  zsh "$DRIVER" emit --epic --run-file "$ERUN" --state "$BATS_TEST_TMPDIR/es.json" --repo-dir "$WT" --issue 741 >/dev/null
  git -C "$MAIN" worktree remove --force "$WB"
  git -C "$MAIN" worktree remove --force "$WT"
  [ "$(grep -c '' "$SINK")" -eq 3 ]
  [ "$(jq -r --arg c "$child_id" 'select(.run_id == $c) | .parent_run_id' "$SINK")" = "$epic_id" ]
  [ "$(jq -r --arg e "$epic_id" 'select(.run_id == $e) | .payload.child_run_ids[0]' "$SINK")" = "$child_id" ]
  zsh "$VALIDATE" "$SINK" --require-records
}

@test "tc-corner-main-checkout-unchanged: an emit from the main checkout lands in the same sink as one from a worktree" {
  loop_emit "$MAIN"
  [ "$status" -eq 0 ]
  loop_emit "$WT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$SINK")" -eq 2 ]
  [ ! -e "$MAIN/.claude/telemetry" ]
}

@test "tc-corner-explicit-file-passes-through: --telemetry-file from a worktree writes only there" {
  loop_emit "$WT" --telemetry-file "$BATS_TEST_TMPDIR/chosen.jsonl"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$BATS_TEST_TMPDIR/chosen.jsonl")" -eq 1 ]
  [ ! -e "$SINK" ]
}

@test "tc-corner-explicit-dir-passes-through: --telemetry-dir from a worktree writes only DIR/<slug>.jsonl" {
  loop_emit "$WT" --telemetry-dir "$BATS_TEST_TMPDIR/tele"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$BATS_TEST_TMPDIR/tele/timo-jakob-timos-claude-code-plugins.jsonl")" -eq 1 ]
  [ ! -e "$SINK" ]
}

@test "tc-corner-not-a-git-repo-falls-back: a plain directory's record lands in the user-level file of its own name" {
  local D="$BATS_TEST_TMPDIR/scratch-notes"
  mkdir -p "$D"
  loop_emit "$D"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$UDIR/scratch-notes.jsonl")" -eq 1 ]
  [ ! -e "$D/.claude/telemetry" ]
}

@test "tc-corner-bare-main-falls-back: a worktree of a bare repository lands in the user-level file of its own name" {
  local BARE="$BATS_TEST_TMPDIR/plugins.git" BW="$BATS_TEST_TMPDIR/plugins-wt"
  git clone -q --bare "$MAIN" "$BARE"
  git -C "$BARE" worktree add -q "$BW" -b bare-wt
  loop_emit "$BW"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$UDIR/plugins-wt.jsonl")" -eq 1 ]
  [ ! -e "$BW/.claude/telemetry" ]
}

@test "tc-corner-many-worktrees-resolves: 30 linked worktrees still resolve to the one user-level sink" {
  local i
  for i in {1..29}; do git -C "$MAIN" worktree add -q "$BATS_TEST_TMPDIR/wt-$i" -b "wt-$i"; done
  loop_emit "$BATS_TEST_TMPDIR/wt-29"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$SINK")" -eq 1 ]
}

@test "tc-corner-git-absent-falls-back: with git unavailable the record still lands, under the folder's own name" {
  local stub="$BATS_TEST_TMPDIR/nogit"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 127\n' > "$stub/git"
  chmod +x "$stub/git"
  run --separate-stderr env PATH="$stub:$PATH" zsh "$EMIT" --pipeline resolve-issue --kind run \
    --outcome success --wall-s 412 --repo-dir "$WT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$UDIR/fancy-brewing-magpie.jsonl")" -eq 1 ]
  [ ! -e "$WT/.claude/telemetry" ]
}

@test "tc-corner-run-file-shape-unchanged: start with no sink flag writes only the parent pair" {
  run --separate-stderr zsh "$DRIVER" start --run-file "$BATS_TEST_TMPDIR/r.json" --ts 1791280000
  [ "$status" -eq 0 ]
  [ "$(jq -c '.loop_args' "$BATS_TEST_TMPDIR/r.json")" = "$(jq -c '["--parent-run-id", .run_id]' "$BATS_TEST_TMPDIR/r.json")" ]
  [ "$(jq -c '.child_start_args' "$BATS_TEST_TMPDIR/r.json")" = "$(jq -c '["--parent-run-id", .run_id]' "$BATS_TEST_TMPDIR/r.json")" ]
}

@test "tc-error-main-sink-unwritable: a read-only user-level sink is exit 3 and nothing lands in the worktree" {
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  mkdir -p "$UDIR"
  chmod 555 "$UDIR"
  loop_emit "$WT"
  chmod 755 "$UDIR"
  [ "$status" -eq 3 ]
  contains "$stderr" "$SINK"
  [ ! -e "$WT/.claude/telemetry" ]
}

@test "tc-error-repo-dir-not-a-directory: a file as --repo-dir is exit 2 before any git lookup" {
  printf 'x\n' > "$BATS_TEST_TMPDIR/not-a-dir"
  loop_emit "$BATS_TEST_TMPDIR/not-a-dir"
  [ "$status" -eq 2 ]
  contains "$stderr" "emit-telemetry: --repo-dir is not a directory"
}
