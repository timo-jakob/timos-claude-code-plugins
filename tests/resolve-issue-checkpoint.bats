#!/usr/bin/env bats
#
# checkpoint.zsh (#2920): the recoverable checkpoint of a resolve-issue run — a
# wip commit pushed to the feature branch at the first green gate and after
# every round the loop consolidates, the checkpoint/v1 marker written only
# after the push, the attended `--resume` check against the remote head, the
# superseding rules beside the clean stop (#2579), and the move-aside a fresh
# attended run takes on kept state. The loop cases drive the real review loop
# with --checkpoint against a local bare remote.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  CP="$SCRIPTS/checkpoint.zsh"
  CS="$SCRIPTS/clean-stop.zsh"

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$REMOTE"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  git -C "$R" remote add origin "$REMOTE"
  echo base > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
  git -C "$R" push -q origin main
  git -C "$R" checkout -qb feat/77-x
  echo "print(1)" > "$R/app.py"

  BASE="$(zsh "$CS" dir --repo-dir "$R" --issue 77 | jq -r '.base')"
  WD="$BASE/work-dir"
  SF="$BASE/status.json"
  STUB="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "$DETECT_LANGS_JSON"\n' > "$STUB"
  chmod +x "$STUB"
  F="$BATS_TEST_TMPDIR/findings.json"
  # gh's open-PR count for the branch, never the network
  export CHECKPOINT_GH_BIN="$BATS_TEST_TMPDIR/gh"
  printf '#!/usr/bin/env bash\necho "${GH_OPEN_PRS:-0}"\n' > "$CHECKPOINT_GH_BIN"
  chmod +x "$CHECKPOINT_GH_BIN"
}

remote_head() { git --git-dir "$REMOTE" rev-parse "refs/heads/${1:-feat/77-x}" 2>/dev/null; }

# one step-mode loop invocation on the durable work-dir, checkpointing
loop() {
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$SCRIPTS/resolve-story-loop.zsh" --repo "$R" --base main --issue 77 \
    --work-dir "$WD" --status-file "$SF" --findings-file "$F" "$@"
}

warning() {
  printf '%s' '[{"severity":"WARNING","dimension":"bugs","file":"app.py","line":1,"title":"print without flush","description":"d","reviewer":"r"}]' > "$F"
}

# --- write -------------------------------------------------------------------------

@test "#2920 the first green gate: round 0 commits 'wip(resolve-issue #77): implementation', pushes it and records last_round 0 with that SHA" {
  run -0 --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode attended --run-id resolve-issue-1-abcd
  [ "$output" = "$(jq -c . "$BASE/checkpoint.json")" ]
  # no Maintenance App can be minted for a host-less origin: it says so and pushes as you
  contains "$stderr" "no Maintenance App token could be minted here — pushing the checkpoint to origin as you"
  local sha
  sha="$(git -C "$R" rev-parse HEAD)"
  [ "$(git -C "$R" log -1 --format=%s)" = "wip(resolve-issue #77): implementation" ]
  # a wip commit never skips CI
  run -1 grep -F '[skip ci]' <<<"$(git -C "$R" log -1 --format=%B)"
  [ "$(remote_head)" = "$sha" ]
  [ "$(jq -r '.schema' "$BASE/checkpoint.json")" = "checkpoint/v1" ]
  [ "$(jq -c '{issue, branch, sha, last_round, ceiling, grants, run_id, session_mode}' "$BASE/checkpoint.json")" = "{\"issue\":77,\"branch\":\"feat/77-x\",\"sha\":\"$sha\",\"last_round\":0,\"ceiling\":null,\"grants\":{\"human\":0,\"automatic\":0},\"run_id\":\"resolve-issue-1-abcd\",\"session_mode\":\"attended\"}" ]
  [ "$(jq -r '.work_dir' "$BASE/checkpoint.json")" = "$WD" ]
  [ "$(jq -r '.status_file' "$BASE/checkpoint.json")" = "$SF" ]
}

@test "#2920 a later round commits 'round <k>', records k, the ceiling and the grants, keeps the loop state, and drops the superseded state" {
  mkdir -p "$WD"
  echo one > "$WD/history.jsonl"
  printf '%s\n' '{"source":"human"}' '{"source":"automatic"}' '{"source":"human"}' > "$WD/grants.jsonl"
  echo '{"status":"AWAITING_FIX"}' > "$SF"
  run -0 --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode unattended --ceiling 5
  local first_state
  first_state="$(jq -r '.state_dir' "$BASE/checkpoint.json")"
  [ -d "$first_state" ]
  echo "print(2)" > "$R/app.py"
  echo two >> "$WD/history.jsonl"
  run -0 --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 2 --mode unattended --ceiling 7
  local sha
  sha="$(git -C "$R" rev-parse HEAD)"
  [ "$(git -C "$R" log -1 --format=%s)" = "wip(resolve-issue #77): round 2" ]
  [ "$(remote_head)" = "$sha" ]
  [ "$output" = "$(jq -c . "$BASE/checkpoint.json")" ]
  [ "$(jq -c '{sha, last_round, ceiling, grants, run_id, session_mode}' <<<"$output")" = "{\"sha\":\"$sha\",\"last_round\":2,\"ceiling\":7,\"grants\":{\"human\":2,\"automatic\":1},\"run_id\":null,\"session_mode\":\"unattended\"}" ]
  local state
  state="$(jq -r '.state_dir' <<<"$output")"
  [ "$(cat "$state/work-dir/history.jsonl")" = "$(printf 'one\ntwo')" ]
  [ "$(cat "$state/status.json")" = '{"status":"AWAITING_FIX"}' ]
  [ ! -e "$first_state" ]
}

@test "#2920 a push failure leaves the previous marker in place, byte for byte, and keeps the commit local" {
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended
  local before pushed
  before="$(cat "$BASE/checkpoint.json")"
  pushed="$(remote_head)"
  echo "print(3)" > "$R/app.py"
  run --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 2 --mode attended --remote "$BATS_TEST_TMPDIR/no-such-remote.git"
  [ "$status" -eq 1 ]
  contains "$stderr" "failed — the previous checkpoint marker stands"
  [ "$(cat "$BASE/checkpoint.json")" = "$before" ]
  [ "$(remote_head)" = "$pushed" ]
  [ "$(git -C "$R" log -1 --format=%s)" = "wip(resolve-issue #77): round 2" ]
  [ "$(ls -d "$BASE"/checkpoint-r* | wc -l | tr -d ' ')" = "1" ]
}

@test "#2920 an explicit --remote is pushed to without minting, and a host origin with no App falls back to origin" {
  run -0 --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended --remote "$REMOTE"
  [ -z "$stderr" ]
  [ "$(remote_head)" = "$(git -C "$R" rev-parse HEAD)" ]
  # a host origin tries the minter first; a failing one falls back to pushing as you
  local fake="$BATS_TEST_TMPDIR/fake-mint"
  printf '#!/usr/bin/env bash\necho minted >> "%s/mint-called"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$fake"
  chmod +x "$fake"
  git -C "$R" remote set-url origin https://github.com/Acme/Widget.git
  git -C "$R" remote set-url --push origin "$REMOTE"
  local base2="$HOME/.claude/resolve-issue/acme-widget/77"
  run -0 --separate-stderr env CHECKPOINT_MINT_BIN="$fake" zsh "$CP" write --repo-dir "$R" --issue 77 --round 2 --mode attended
  [ -s "$BATS_TEST_TMPDIR/mint-called" ]
  contains "$stderr" "pushing the checkpoint to origin as you"
  [ "$(jq -r '.last_round' "$base2/checkpoint.json")" = "2" ]
}

@test "#2920 with a minted Maintenance App token the checkpoint is pushed as the App, and the token file is deleted" {
  git -C "$R" remote set-url origin https://github.com/acme/widgets.git
  printf 'tok123' > "$BATS_TEST_TMPDIR/token"
  git -C "$R" config url."$REMOTE".pushInsteadOf "https://x-access-token:tok123@github.com/acme/widgets.git"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$BATS_TEST_TMPDIR/token" > "$BATS_TEST_TMPDIR/mint"
  chmod +x "$BATS_TEST_TMPDIR/mint"
  CHECKPOINT_MINT_BIN="$BATS_TEST_TMPDIR/mint" run -0 --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode attended
  [ "$(remote_head)" = "$(git -C "$R" rev-parse HEAD)" ]
  [ ! -e "$BATS_TEST_TMPDIR/token" ]
}

@test "#2920 write refuses the default branch and a detached HEAD, and commits nothing" {
  git -C "$R" checkout -q main
  run --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode attended
  [ "$status" -eq 1 ]
  contains "$stderr" "refusing to checkpoint onto main"
  [ "$(git -C "$R" log -1 --format=%s)" = "base" ]
  git -C "$R" checkout -q --detach
  run --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode attended
  [ "$status" -eq 1 ]
  contains "$stderr" "HEAD is detached"
  [ ! -e "$BASE/checkpoint.json" ]
  # a failing commit hook fails the checkpoint: nothing is committed or pushed
  git -C "$R" checkout -qB feat/77-x
  printf '#!/bin/sh\nexit 1\n' > "$R/.git/hooks/pre-commit" && chmod +x "$R/.git/hooks/pre-commit"
  run -1 zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode attended
  [ "$(git -C "$R" log -1 --format=%s)" = "base" ]
  [ -z "$(git --git-dir "$REMOTE" branch --list feat/77-x)" ]
}

# --- read ----------------------------------------------------------------------------

@test "#2920 read: refused unattended (4), with no marker (3), and on a malformed marker (1)" {
  run --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 3 ]
  contains "$stderr" "no checkpoint is kept for issue #77"
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended
  run --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode unattended
  [ "$status" -eq 4 ]
  contains "$stderr" "an unattended run never resumes a checkpoint"
  jq -c 'del(.sha)' "$BASE/checkpoint.json" > "$BASE/x" && mv "$BASE/x" "$BASE/checkpoint.json"
  run --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 1 ]
  contains "$stderr" "the marker is malformed"
}

@test "#2920 read refuses, with a clear message, when the remote head differs from the marker's SHA — and restores nothing" {
  mkdir -p "$WD"; echo kept > "$WD/history.jsonl"
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended
  local sha
  sha="$(jq -r '.sha' "$BASE/checkpoint.json")"
  # someone pushes after the checkpoint
  echo "print(9)" > "$R/app.py"
  git -C "$R" commit -qam other
  git -C "$R" push -q origin HEAD:feat/77-x
  echo half > "$WD/tree-2.txt"
  run --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 5 ]
  contains "$stderr" "refusing to resume — the remote head of feat/77-x is $(remote_head), not the checkpoint's $sha"
  [ -e "$WD/tree-2.txt" ]
  # a deleted remote branch is refused the same way
  git --git-dir "$REMOTE" update-ref -d refs/heads/feat/77-x
  run --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  [ "$status" -eq 5 ]
  contains "$stderr" "is <absent>, not the checkpoint's $sha"
}

@test "#2920 read refuses when the checkpoint's kept loop state is missing, and leaves the work-dir alone" {
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended --ceiling 5
  rm -rf -- "$(jq -r '.state_dir' "$BASE/checkpoint.json")"
  mkdir -p "$WD" && echo keep > "$WD/progress.md"
  run -1 --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  contains "$stderr" "the checkpoint's loop state is missing"
  [ "$(cat "$WD/progress.md")" = "keep" ]
}

@test "#2920 read drops a half-finished round and restores the checkpoint's work-dir and status file" {
  mkdir -p "$WD"
  echo r1 > "$WD/history.jsonl"
  echo '{"status":"AWAITING_FIX","rounds":1}' > "$SF"
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended --ceiling 5
  # round 2 got partway, then the session was killed
  echo r2 >> "$WD/history.jsonl"
  echo half > "$WD/tree-2.txt"
  echo '{"status":"ERROR"}' > "$SF"
  run -0 --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  [ "$(jq -c '{last_round, ceiling, loop_resume, next_round}' <<<"$output")" = '{"last_round":1,"ceiling":5,"loop_resume":true,"next_round":2}' ]
  [ "$(cat "$WD/history.jsonl")" = "r1" ]
  [ ! -e "$WD/tree-2.txt" ]
  [ "$(cat "$SF")" = '{"status":"AWAITING_FIX","rounds":1}' ]
}

@test "#2920 read from last_round 0: loop_resume false, next round 1, and an empty work-dir with no status file" {
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode attended
  # a round-1 invocation got partway, then the session was killed
  mkdir -p "$WD"; echo half > "$WD/tree-1.txt"
  echo '{"status":"stale"}' > "$SF"
  run -0 --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  [ "$(jq -c '{last_round, loop_resume, next_round}' <<<"$output")" = '{"last_round":0,"loop_resume":false,"next_round":1}' ]
  [ -d "$WD" ]
  [ -z "$(ls -A "$WD")" ]
  [ ! -e "$SF" ]
}

# --- the loop ---------------------------------------------------------------------------

@test "#2920 loop: a green round k is checkpointed as 'round k' with no PR; a red-gate --resume commits nothing and leaves the marker unchanged" {
  mkdir -p "$WD"
  warning
  loop --checkpoint attended --parent-run-id resolve-issue-7-beef --max-rounds 4
  [ "$status" -eq 20 ]
  local sha
  sha="$(git -C "$R" rev-parse HEAD)"
  [ "$(git -C "$R" log -1 --format=%s)" = "wip(resolve-issue #77): round 1" ]
  [ "$(remote_head)" = "$sha" ]
  [ "$(jq -c '{sha, last_round, ceiling, run_id, session_mode}' "$BASE/checkpoint.json")" = "{\"sha\":\"$sha\",\"last_round\":1,\"ceiling\":4,\"run_id\":\"resolve-issue-7-beef\",\"session_mode\":\"attended\"}" ]
  # the kept state holds the status file this round wrote
  [ "$(jq -r '.status' "$(jq -r '.state_dir' "$BASE/checkpoint.json")/status.json")" = "AWAITING_FIX" ]
  # round 2's gate is red: the loop errors before consolidating and checkpoints nothing
  local before
  before="$(cat "$BASE/checkpoint.json")"
  echo "print(2)" > "$R/app.py"
  printf '[]' > "$F"
  loop --checkpoint attended --resume --test-cmd false
  [ "$status" -eq 1 ]
  [ "$(git -C "$R" rev-parse HEAD)" = "$sha" ]
  [ "$(remote_head)" = "$sha" ]
  [ "$(cat "$BASE/checkpoint.json")" = "$before" ]
}

@test "#2920 loop: a terminal round is checkpointed too, after the telemetry ledger it wrote" {
  mkdir -p "$WD"
  warning
  loop --checkpoint unattended --max-rounds 1
  [ "$status" -eq 13 ]
  [ "$(git -C "$R" log -1 --format=%s)" = "wip(resolve-issue #77): round 1" ]
  [ -s "$(jq -r '.state_dir' "$BASE/checkpoint.json")/work-dir/.telemetry-run-ids" ]
}

@test "#2920 simulated kill: resume from round k continues the loop at round k+1 with --resume on the kept state" {
  mkdir -p "$WD"
  warning
  loop --checkpoint attended
  [ "$status" -eq 20 ]
  # the session fixes, starts round 2 — and is killed partway
  echo "print(2)" > "$R/app.py"
  echo '{"round":2,"blocking":0,"conflicts":0}' >> "$WD/history.jsonl"
  echo half > "$WD/tree-2.txt"
  # a later session checks the branch out from origin and reads the checkpoint
  git -C "$R" checkout -q -- . && git -C "$R" clean -qfd
  git -C "$R" fetch -q origin feat/77-x && git -C "$R" checkout -q -B feat/77-x FETCH_HEAD
  run -0 --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  [ "$(jq -c '{loop_resume, next_round, ceiling}' <<<"$output")" = '{"loop_resume":true,"next_round":2,"ceiling":5}' ]
  [ "$(jq -sc 'map(.round)' "$WD/history.jsonl")" = '[1]' ]
  # the lost fix is redone and round 2 runs under the loop's --resume
  echo "print(2)" > "$R/app.py"
  jq '[.[] | {file, dimension, title, confirmed: ["r"], re_raised: [], unconfirmed: []}]' "$WD/verify-2.json" \
    > "$BATS_TEST_TMPDIR/carry.json"
  printf '[]' > "$F"
  # a grant's sidecar raises the ceiling in force; the marker keeps the caller's
  echo 7 > "$WD/.max-rounds"
  loop --checkpoint attended --resume --max-rounds 5 --carry-accounting "$BATS_TEST_TMPDIR/carry.json"
  [ "$status" -eq 20 ]
  [ "$(jq -c '{max_rounds, effective_max_rounds}' <<<"$output")" = '{"max_rounds":5,"effective_max_rounds":7}' ]
  [ "$(jq -r '.ceiling' "$BASE/checkpoint.json")" = "5" ]
  [ "$(jq '.rounds' <<<"$output")" -eq 2 ]
  [ "$(jq -sc 'map(.round)' "$WD/history.jsonl")" = '[1,2]' ]
  [ "$(git -C "$R" log -1 --format=%s)" = "wip(resolve-issue #77): round 2" ]
  [ "$(jq -r '.last_round' "$BASE/checkpoint.json")" = "2" ]
}

@test "#2920 simulated kill at round 0: resume starts the loop fresh at round 1, without the loop's --resume" {
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode attended
  run -0 --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  [ "$(jq -r '.loop_resume' <<<"$output")" = "false" ]
  # the loop's --resume has nothing to continue from a round-0 checkpoint
  warning
  loop --resume
  [ "$status" -eq 2 ]
  contains "$stderr" "--resume needs an existing non-empty history"
  loop --checkpoint attended
  [ "$status" -eq 20 ]
  [ "$(jq '.rounds' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.last_round' "$BASE/checkpoint.json")" = "1" ]
}

@test "#2920 loop: --checkpoint needs --issue, a known mode, and a reviewed run" {
  warning
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$SCRIPTS/resolve-story-loop.zsh" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --checkpoint attended
  [ "$status" -eq 2 ]
  contains "$stderr" "--checkpoint needs --issue"
  loop --checkpoint sometimes
  [ "$status" -eq 2 ]
  contains "$stderr" "--checkpoint must be attended or unattended (got: sometimes)"
  # --no-review consolidates no round, so it checkpoints nothing
  run -0 --separate-stderr zsh "$SCRIPTS/resolve-story-loop.zsh" --no-review --issue 77 --checkpoint attended
  [ "$(jq -r '.status' <<<"$output")" = "SKIPPED" ]
  [ ! -e "$BASE/checkpoint.json" ]
  [ "$(git -C "$R" log -1 --format=%s)" = "base" ]
}

@test "#2920 loop: a checkpoint that fails is never fatal — the round still exits AWAITING_FIX and says so" {
  mkdir -p "$WD"
  warning
  git -C "$R" remote set-url origin "$BATS_TEST_TMPDIR/no-such-remote.git"
  loop --checkpoint attended
  [ "$status" -eq 20 ]
  contains "$stderr" "could not checkpoint round 1 — the previous checkpoint stands (#2920)"
  [ ! -e "$BASE/checkpoint.json" ]
}

# --- superseding ------------------------------------------------------------------------

clean_stop_status() {
  mkdir -p "$WD"
  jq -n '{status:"BUDGET_EXHAUSTED", rounds:2, max_rounds:5, effective_max_rounds:5,
          history:[{round:1,blocking:2,conflicts:0},{round:2,blocking:4,conflicts:0}],
          round_changelists:[], final_changelist:{blocking:[]}}' > "$SF"
}

@test "#2920 writing a clean stop deletes checkpoint.json and its kept state" {
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode unattended
  clean_stop_status
  run -0 zsh "$CS" write --repo-dir "$R" --issue 77 --branch feat/77-x --run-id r
  [ -e "$BASE/clean-stop.json" ]
  [ ! -e "$BASE/checkpoint.json" ]
  [ -z "$(compgen -G "$BASE/checkpoint-r*")" ]
}

@test "#2920 a checkpoint written after a clean stop deletes the older clean-stop marker: the marker written last wins" {
  clean_stop_status
  run -0 zsh "$CS" write --repo-dir "$R" --issue 77 --branch feat/77-x --run-id r
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 3 --mode attended
  [ ! -e "$BASE/clean-stop.json" ]
  run -0 --separate-stderr zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended
  [ "$(jq -r '.last_round' <<<"$output")" = "3" ]
}

@test "#2920 with both markers kept, the clean-stop read wins, says so, and deletes the checkpoint" {
  clean_stop_status
  run -0 zsh "$CS" write --repo-dir "$R" --issue 77 --branch feat/77-x --run-id r
  cp "$BASE/clean-stop.json" "$BATS_TEST_TMPDIR/cs.json"
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 2 --mode attended
  # both found anyway: the clean stop is restored beside the checkpoint
  cp "$BATS_TEST_TMPDIR/cs.json" "$BASE/clean-stop.json"
  run -0 --separate-stderr zsh "$CS" read --repo-dir "$R" --issue 77 --mode attended
  [ "$(jq -r '.schema' <<<"$output")" = "clean-stop/v1" ]
  contains "$stderr" "a checkpoint is also kept for issue #77 — resuming from the clean stop, which supersedes it"
  [ ! -e "$BASE/checkpoint.json" ]
}

@test "#2920 a run that opens its PR clears the durable directory, checkpoint included; checkpoint clear removes only the checkpoint" {
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended
  mkdir -p "$WD"; echo keep > "$WD/x"
  run -0 zsh "$CP" clear --repo-dir "$R" --issue 77
  [ ! -e "$BASE/checkpoint.json" ]
  [ -z "$(compgen -G "$BASE/checkpoint-r*")" ]
  [ -e "$WD/x" ]
  run -0 zsh "$CP" clear --repo-dir "$R" --issue 77
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 2 --mode attended
  run -0 zsh "$CS" clear --repo-dir "$R" --issue 77
  [ ! -e "$BASE" ]
}

@test "#2920 a fresh attended run moves kept state aside, deletes nothing, and its first push leases exactly the superseded head" {
  run --separate-stderr zsh "$CP" supersede --repo-dir "$R" --issue 77 --branch feat/77-x
  [ "$status" -eq 3 ]
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 3 --mode attended
  local old_sha old_marker
  old_sha="$(jq -r '.sha' "$BASE/checkpoint.json")"
  old_marker="$(cat "$BASE/checkpoint.json")"
  run -0 --separate-stderr zsh "$CP" supersede --repo-dir "$R" --issue 77 --branch feat/77-x
  local dest
  dest="$(jq -r '.superseded_to' <<<"$output")"
  [ "${dest#"$BASE".superseded-}" != "$dest" ]
  grep -Eq '^[0-9]{8}T[0-9]{6}Z$' <<<"${dest#"$BASE".superseded-}"
  [ "$(jq -c '{kept, lease}' <<<"$output")" = "{\"kept\":[\"checkpoint\"],\"lease\":{\"branch\":\"feat/77-x\",\"sha\":\"$old_sha\"}}" ]
  [ "$(cat "$dest/checkpoint.json")" = "$old_marker" ]
  [ -d "$(jq -r '.state_dir' "$dest/checkpoint.json" | sed "s|^$BASE|$dest|")" ]
  [ "$(ls -A "$BASE")" = "lease.json" ]
  # the fresh run rebuilt the branch off main: not a fast-forward of the old head
  git -C "$R" checkout -q main && git -C "$R" checkout -qB feat/77-x
  echo "print(new)" > "$R/app.py"
  run -0 --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode attended
  [ "$(remote_head)" = "$(git -C "$R" rev-parse HEAD)" ]
  [ ! -e "$BASE/lease.json" ]
  run -1 git -C "$R" merge-base --is-ancestor "$old_sha" HEAD
}

@test "#2920 the lease refuses a head the superseded marker never recorded" {
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended
  run -0 zsh "$CP" supersede --repo-dir "$R" --issue 77 --branch feat/77-x
  # someone else pushes after the move
  local other="$BATS_TEST_TMPDIR/other"
  git clone -q "$REMOTE" "$other"
  git -C "$other" checkout -q feat/77-x
  git -C "$other" -c user.email=o@example.com -c user.name=o commit -q --allow-empty -m foreign
  git -C "$other" push -q origin HEAD:feat/77-x
  local foreign
  foreign="$(remote_head)"
  git -C "$R" checkout -q main && git -C "$R" checkout -qB feat/77-x
  run --separate-stderr zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode attended
  [ "$status" -eq 1 ]
  [ "$(remote_head)" = "$foreign" ]
  [ -e "$BASE/lease.json" ]
  [ ! -e "$BASE/checkpoint.json" ]
}

@test "#2920 with nothing kept, supersede leases only a killed run's wip head with no open PR, and refuses any other remote head" {
  run -3 zsh "$CP" supersede --repo-dir "$R" --issue 77 --branch feat/77-x
  git -C "$R" commit -qam wip-left --allow-empty
  git -C "$R" push -q origin HEAD:feat/77-x
  local left
  left="$(remote_head)"
  run -1 --separate-stderr zsh "$CP" supersede --repo-dir "$R" --issue 77 --branch feat/77-x
  contains "$stderr" "feat/77-x is on the remote at $left and no kept state leases it"
  [ ! -e "$BASE/lease.json" ]
  git -C "$R" checkout -q main && git -C "$R" checkout -qB feat/77-x
  run -1 zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode unattended
  [ "$(remote_head)" = "$left" ]
  # a killed run's own checkpoint: leased while no PR is open on the branch
  git -C "$R" commit -q --allow-empty -m "wip(resolve-issue #77): round 2"
  git -C "$R" push -q -f origin HEAD:feat/77-x
  left="$(remote_head)"
  GH_OPEN_PRS=1 run -1 zsh "$CP" supersede --repo-dir "$R" --issue 77 --branch feat/77-x
  [ ! -e "$BASE/lease.json" ]
  run -0 --separate-stderr zsh "$CP" supersede --repo-dir "$R" --issue 77 --branch feat/77-x
  [ "$(jq -c . <<<"$output")" = "{\"superseded_to\":null,\"kept\":[],\"lease\":{\"branch\":\"feat/77-x\",\"sha\":\"$left\"}}" ]
  git -C "$R" checkout -q main && git -C "$R" checkout -qB feat/77-x
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 0 --mode unattended
  [ "$(remote_head)" = "$(git -C "$R" rev-parse HEAD)" ]
}

@test "#2920 superseding a clean stop leases the branch's remote head, read off the remote" {
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode unattended
  clean_stop_status
  run -0 zsh "$CS" write --repo-dir "$R" --issue 77 --branch feat/77-x --run-id r
  run -0 --separate-stderr zsh "$CP" supersede --repo-dir "$R" --issue 77 --branch feat/77-x
  [ "$(jq -c '{kept, lease}' <<<"$output")" = "{\"kept\":[\"clean-stop\"],\"lease\":{\"branch\":\"feat/77-x\",\"sha\":\"$(remote_head)\"}}" ]
  [ -e "$(jq -r '.superseded_to' <<<"$output")/clean-stop.json" ]
}

# --- usage ---------------------------------------------------------------------------------

@test "#2920 usage: subcommands, required flags, per-subcommand flags and bad values exit 2" {
  run -2 zsh "$CP"
  run -2 zsh "$CP" bogus --repo-dir "$R" --issue 77
  run -2 zsh "$CP" write --repo-dir "$R" --issue 77 --mode attended
  run -2 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1
  run -2 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode sometimes
  run -2 zsh "$CP" write --repo-dir "$R" --issue 77 --round 01 --mode attended
  run -2 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended --ceiling 0
  run -2 zsh "$CP" read --repo-dir "$R" --issue 77
  run -2 zsh "$CP" read --repo-dir "$R" --issue 77 --mode attended --round 1
  run -2 zsh "$CP" clear --repo-dir "$R" --issue 77 --remote x
  run -2 zsh "$CP" clear --repo-dir "$R" --issue 0x
  run -2 zsh "$CP" clear --repo-dir "$BATS_TEST_TMPDIR/nope" --issue 77
  run -2 zsh "$CP" clear --repo-dir "$R" --issue
  run -2 zsh "$CP" clear --repo-dir "$R" --issue 77 stray
  run -0 zsh "$CP" --help
  contains "$output" "checkpoint.zsh supersede"
}

# --- the contract and the procedure, pinned ----------------------------------------------

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

@test "#2920 the amended contract: ARCHITECTURE.md, SKILL.md §3.5 and the loop header say no PR until CONVERGED, wip checkpoints only, no [skip ci]" {
  local arch skill loop
  arch="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  skill="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  loop="$(flat "$SCRIPTS/resolve-story-loop.zsh" | sed 's/ # / /g')"
  contains "$arch" "**No PR is opened until it exits \`CONVERGED\` (0); the only earlier pushes are wip checkpoint commits to the feature branch, with no PR** (#2920). A wip commit carries no \`[skip ci]\`"
  contains "$skill" "**No PR until the loop exits \`CONVERGED\`; the only earlier pushes are wip checkpoint commits to the feature branch, with no PR, and none carries \`[skip ci]\`** (#2920)."
  contains "$loop" "No PR is opened until this exits CONVERGED (0)"
  contains "$loop" "the only earlier pushes are wip checkpoint commits to the feature branch, with no PR (#2920)"
  contains "$loop" "A wip commit carries no \`[skip ci]\`."
  # the retired absolute is gone from both
  run -1 grep -F "nothing is pushed and no PR is opened until" "$REPO_ROOT/ARCHITECTURE.md" "$SCRIPTS/resolve-story-loop.zsh"
}

@test "#2920 SKILL.md: every mode keeps the durable pair and checkpoints, and --resume falls from the clean stop to the checkpoint" {
  local skill
  skill="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  contains "$skill" "**In every session mode they are the durable pair** (#2579, #2920)"
  contains "$skill" "pass \`--checkpoint <mode>\` on every blocking-loop invocation."
  contains "$skill" "Exit 3 (no clean stop) falls to the run's checkpoint (#2920), which takes its own procedure:"
  contains "$skill" "On exit 0, note \`resumed_from: clean_stop\`"
  contains "$skill" "An attended run moves any kept state aside instead, deleting nothing."
}

@test "#2920 reference/checkpoint.md: resume never reruns §0b–§3, round 0 starts fresh, round k resumes; the fresh run leases; the PR clears" {
  local ref
  ref="$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/checkpoint.md")"
  contains "$ref" "Skip §0b, §1, §2 and §3, and record \`gate_verdict: READY\`"
  contains "$ref" "enter §3.5 at round 1 and start the loop fresh, **without** the loop's \`--resume\`."
  contains "$ref" "invoke the loop **with** \`--resume\` and \`--max-rounds <the marker's ceiling>\`."
  contains "$ref" "Exit 5 refuses it too: the remote branch head is not the marker's SHA"
  contains "$ref" "The marker written last wins, because writing either one deletes the other."
  contains "$ref" "moved the whole durable folder to \`<N>.superseded-<UTC stamp>/\`"
  contains "$ref" "that push uses \`--force-with-lease=<branch>:<that SHA>\`."
  contains "$ref" "**Once the run's record is emitted (§7), clear the durable folder**"
  contains "$ref" "so the clear is the run's last step:"
  contains "$ref" "**Never rewrite a pushed checkpoint** — no \`reset\`, no amend, no rebase of your own."
  contains "$ref" "make the one Conventional Commit **on top of** them:"
  contains "$ref" "Squash auto-merge folds the wip commits and this one into a single commit on \`main\`, titled from the PR."
  run -1 grep -F 'git reset --soft' "$REPO_ROOT/development/skills/resolve-issue/reference/checkpoint.md"
  contains "$ref" '`--allow-empty` is for the run whose last checkpoint already holds the whole change: the commit then carries only the message.'
  contains "$ref" "Note \`resumed_from: checkpoint\` for the run's record"
  contains "$ref" "**A checkpoint is never fatal.**"
}

@test "#2920 ARCHITECTURE.md names the checkpoint marker and resumed_from in the invocation line and the telemetry contract" {
  local arch
  arch="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$arch" "or else (#2920) the run's last checkpoint."
  contains "$arch" "and when the remote branch head is not the checkpoint's SHA (exit 5)."
  contains "$arch" "**Checkpoints (#2920).**"
  contains "$arch" "renames the \`checkpoint/v1\` marker, \`checkpoint.json\`, into place."
  contains "$arch" "| \`resumed_from\` | \`checkpoint\` \\| \`clean_stop\` \\| \`null\` (#2920)"
  contains "$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/telemetry.md")" "| \`resumed_from\` | §0a |"
}

@test "#2920 the remaining rule sentences of the checkpoint procedure are pinned" {
  local skill ref inv
  skill="$(flat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")"
  ref="$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/checkpoint.md")"
  inv="$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/review-loop/step-2-invocation.md")"
  contains "$skill" 'A run that pushed checkpoints commits on top of its wip commits, never rewriting them, and clears its durable folder once its record is emitted: see `reference/checkpoint.md` § The final commit and the PR (#2920)'
  contains "$ref" 'A run killed from outside — the usage limit, a closed terminal, a crash — never reaches the clean stop, so without a checkpoint it loses everything it has not committed and pushed.'
  contains "$ref" 'No PR is opened until the loop exits `CONVERGED`.'
  contains "$ref" 'A wip commit carries no `[skip ci]`: in a repo whose CI runs on every push, the push-time run is accepted.'
  contains "$ref" 'Its loop work-dir and status file are the durable pair `clean-stop.zsh dir` prints, so the state a checkpoint keeps is one a later session can find.'
  contains "$ref" 'Omit `--run-id` when `start` failed and there is no run id.'
  contains "$ref" 'Pass `--checkpoint <mode>` on every invocation of the blocking loop, round 1 and every `--resume` alike, and never on the promotion sub-loop, whose work-dir is not the one the marker keeps.'
  contains "$ref" 'When no Maintenance App token can be minted, the script pushes to `origin` as the user and says so; open-pr still pushes the final commit as the bot.'
  contains "$ref" 'Reached from §0a when `--resume` finds no kept clean stop (`clean-stop.zsh read` exit 3).'
  contains "$ref" 'On any of them, relay the stderr line, emit the run'"'"'s record as `failed` and stop.'
  contains "$ref" 'The working tree must be clean first.'
  contains "$ref" '**From `last_round: k`, with k >= 1** (`loop_resume: true`), round k ended on the restored status file'"'"'s `status`. Take that exit'"'"'s branch in §3.5, exactly as the interrupted run would have:'
  contains "$ref" 'Every other status is that terminal'"'"'s own path with the restored status file.'
  contains "$ref" 'and never on the promotion sub-loop, whose work-dir is not the one the marker keeps.'
  contains "$inv" 'Never pass it to the promotion sub-loop.'
  contains "$ref" '§1'"'"'s branch script stops when the old run'"'"'s branch still exists locally.'
  contains "$ref" 'Pass the marker'"'"'s `work_dir` and `status_file`, `--checkpoint <mode>` and the run'"'"'s `loop_args` on every invocation.'
  contains "$ref" 'A run without `--resume` never adopts kept state.'
  contains "$ref" 'An unattended one has already cleared the durable folder (§0a); an attended one deletes nothing.'
  contains "$ref" '- **Exit 3** — nothing is kept and the branch is not on the remote. Start fresh.'
  contains "$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/escalation.md")" 'Then run `checkpoint.zsh clear --repo-dir <worktree> --issue <N>` (#2920), so a later `--resume` never re-runs an escalation that already ended.'
  contains "$ref" 'With nothing kept, the branch'"'"'s remote head is a killed run'"'"'s own `wip(resolve-issue #<N>)` commit and no PR is open on it.'
  contains "$ref" 'One cause is a branch on the remote with nothing kept whose head is not a killed run'"'"'s wip checkpoint, or has an open PR: no lease may replace it'
  contains "$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/interactive/extension-ceiling.md")" 'On the blocking loop it carries `--checkpoint <mode>` too (#2920), so a granted round is checkpointed like any other.'
  contains "$ref" '- **Exit 0** — when a clean-stop marker or `checkpoint.json` was kept, the script moved the whole durable folder to `<N>.superseded-<UTC stamp>/` and printed it as `superseded_to`'
  contains "$ref" 'When both are found anyway, `clean-stop.zsh read` resumes the clean stop, says so and deletes the checkpoint.'
  contains "$skill" 'stops on exit 3. Without `--resume`, read first how a run'"'"'s kept state and branch are handled: see `reference/checkpoint.md` § A fresh run on kept state (#2920)'
  contains "$ref" 'In an attended run, ask the human whether to delete it: its loop state stays in the superseded folder, and the run'"'"'s first checkpoint push replaces its remote branch.'
  contains "$ref" 'Once §1 has cut the branch, and before round 1, either one runs:'
  contains "$ref" 'Every other ending keeps the folder, so a later `--resume` can find it.'
  contains "$inv" '**Every blocking-loop invocation carries `--checkpoint <mode>` (#2920).**'
  contains "$inv" 'The template above predates checkpoints too: append the session mode §0a resolved, round 1 and every `--resume` alike, so each round the loop consolidates on a green gate is pushed as a wip checkpoint (`reference/checkpoint.md`).'
  contains "$inv" 'It needs `--issue`, which the template already carries.'
}

@test "#2920 the final commit on top of the checkpoints keeps the pushed tip an ancestor, so open-pr's lease check passes" {
  run -0 zsh "$CP" write --repo-dir "$R" --issue 77 --round 1 --mode attended
  local pushed
  pushed="$(remote_head)"
  # §5: everything is already in the last checkpoint, so the commit carries only the message
  git -C "$R" add -A
  git -C "$R" commit -q --allow-empty -m "feat(x): the story" -m "Closes #77"
  # open-pr Step 1b: the remote tip must be an ancestor of HEAD
  run -0 git -C "$R" merge-base --is-ancestor "$pushed" HEAD
  # ...which a fold onto the base would have broken
  git -C "$R" reset -q --soft main
  git -C "$R" commit -q -m "feat(x): folded"
  run -1 git -C "$R" merge-base --is-ancestor "$pushed" HEAD
}
