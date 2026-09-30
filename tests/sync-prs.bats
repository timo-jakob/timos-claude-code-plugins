#!/usr/bin/env bats
#
# Behavioral tests for sync-prs.zsh — re-sync open Maintenance-App PRs that
# became conflicting with main (#1823, epic #1820). Real git in temp repos
# cloned from a local bare `origin`, and the real rebase engine (#1822) with the
# claude-plugin merge driver; `gh`, the mint script and the CI nudge are stubs
# that log their calls. The stub directory is FIRST on PATH, so a host copy of
# `gh` (the ubuntu runner ships one in /usr/bin) is never reached.

bats_require_minimum_version 1.5.0

load assertions

# Low-entropy on purpose: gitleaks flags high-entropy fixture tokens.
TOKEN="sync-prs-test-token-value"
BOT="app/claude-maintenance-acme"

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GH_TOKEN
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SYNC="$REPO_ROOT/development/skills/sync-prs/scripts/sync-prs.zsh"
  SKILL="$REPO_ROOT/development/skills/sync-prs/SKILL.md"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/xdg"
  git config --global user.name "Test Author"
  git config --global user.email "test@example.com"
  git config --global init.defaultBranch main
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  WORK="$BATS_TEST_TMPDIR/work"
  LOGS="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$LOGS"
  export GH_LOG="$LOGS/gh.log" GIT_LOG="$LOGS/git.log" MINT_LOG="$LOGS/mint.log" \
    NUDGE_LOG="$LOGS/nudge.log" PR_LIST="$BATS_TEST_TMPDIR/prs.json"
  stubs
  export SYNC_PRS_PUSH_URL="$ORIGIN"
}

# ---- stubs -----------------------------------------------------------------

stubs() {
  local bin="$BATS_TEST_TMPDIR/bin" real_git
  real_git="$(command -v git)"
  mkdir -p "$bin"
  # gh: argv to GH_LOG, plus whether a token was in the environment (never
  # its value). GH_FAIL names a subcommand pair that fails.
  cat > "$bin/gh" <<'EOF'
#!/bin/sh
printf '%s auth=%s\n' "$*" "${GH_TOKEN:+bot}" >> "$GH_LOG"
case "$1 $2" in
  "${GH_FAIL:-none}") echo "gh: $1 $2 failed${GH_FAIL_ECHO_TOKEN:+ for $GH_TOKEN}" >&2; exit 1 ;;
  "repo view") echo "${GH_REPO:-acme/widgets}" ;;
  "pr list") cat "$PR_LIST" ;;
esac
exit 0
EOF
  # git: argv to GIT_LOG, then the real git. On a push it first asks git's
  # credential machinery, under the push's own -C/-c options, what password a
  # github.com push would send, and logs only whether that is the minted token.
  cat > "$bin/git" <<EOF
#!/usr/bin/env zsh
print -r -- "\$*" >> "\$GIT_LOG"
if (( \${@[(Ie)push]} )); then
  local -a opts; local i=1
  while [[ "\${@[i]}" == -[cC] ]]; do opts+=("\${@[i]}" "\${@[i+1]}"); (( i += 2 )); done
  got="\$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 "$real_git" "\${opts[@]}" credential fill 2>/dev/null | sed -n 's/^password=//p')"
  if [[ -n "\$got" && "\$got" == "\${EXPECTED_TOKEN:-}" ]]; then print -r -- "push-auth=bot" >> "\$GIT_LOG"
  else print -r -- "push-auth=other" >> "\$GIT_LOG"; fi
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$bin/gh" "$bin/git"
  export EXPECTED_TOKEN="$TOKEN"
  export PATH="$bin:$PATH"

  export SYNC_PRS_MINT="$BATS_TEST_TMPDIR/mint.zsh"
  cat > "$SYNC_PRS_MINT" <<EOF
echo called >> "\$MINT_LOG"
[ -z "\${MINT_FAIL:-}" ] || { echo "mint failed" >&2; exit 2; }
f="\$(mktemp "\$TMPDIR/tok.XXXXXX")"
chmod 600 "\$f"
printf '%s' '$TOKEN' > "\$f"
print -r -- "\$f"
EOF
  export SYNC_PRS_RETRIGGER="$BATS_TEST_TMPDIR/nudge.zsh"
  cat > "$SYNC_PRS_RETRIGGER" <<'EOF'
print -r -- "$* auth=${GH_TOKEN:+bot}" >> "$NUDGE_LOG"
print -- "result: NUDGED — closed+reopened PR #${@[-1]} to re-trigger CI on abc."
EOF
}

# engine_failing_for <sha> — the real engine, except it exits 3 at that head.
# Each call logs how many worktrees exist at that moment to WT_LOG.
engine_failing_for() {
  local real="$REPO_ROOT/development/scripts/merge/rebase-onto-main.zsh"
  export SYNC_PRS_ENGINE="$BATS_TEST_TMPDIR/engine.zsh" WT_LOG="$LOGS/wt.log"
  cat > "$SYNC_PRS_ENGINE" <<EOF
git worktree list | wc -l | tr -d ' ' >> "\$WT_LOG"
if [[ "\$(git rev-parse HEAD)" == "$1" ]]; then
  print -u2 -- "rebase-onto-main: git fetch origin main failed"
  exit 3
fi
exec zsh "$real"
EOF
}

# ---- fixtures ----------------------------------------------------------------

set_version() {
  jq --arg v "$1" '.version = $v' dev/.claude-plugin/plugin.json > m.tmp
  mv m.tmp dev/.claude-plugin/plugin.json
  jq --arg v "$1" '.plugins[0].version = $v' .claude-plugin/marketplace.json > m.tmp
  mv m.tmp .claude-plugin/marketplace.json
}

# branch <name> <cmd...> — a branch off the initial commit, one commit, pushed.
branch() {
  local name="$1"
  shift
  git -C "$WORK" switch -q -c "$name" init
  (cd "$WORK" && "$@" && git add -A && git commit -qm "work on $name")
  git -C "$WORK" push -q origin "$name"
  git -C "$WORK" switch -q main
}

patch_bump() { set_version 1.4.3; printf 'a\n' > a.txt; }
patch_bump_b() { set_version 1.4.3; printf 'b\n' > b.txt; }
note_edit() { printf 'branch line\n' > notes.md; }
other_file() { printf 'x\n' > x.txt; }

# A claude-plugin repo; branches off the initial commit; then main moves ahead
# with a minor bump and a notes.md edit, so a patch-bump branch conflicts only
# on the manifests (resolved) and a notes.md branch conflicts for real.
new_repo() {
  git init -q --bare "$ORIGIN"
  git init -q "$WORK"
  cd "$WORK"
  mkdir -p .claude-plugin dev/.claude-plugin
  jq -n '{name: "dev", description: "Dev tools.", version: "1.4.2"}' > dev/.claude-plugin/plugin.json
  jq -n '{name: "market", plugins: [{name: "dev", description: "Dev tools.", version: "1.4.2", source: "./dev"}]}' \
    > .claude-plugin/marketplace.json
  printf 'line one\n' > notes.md
  git add -A
  git commit -qm init
  git tag init
  git remote add origin "$ORIGIN"
  git push -q -u origin main
  local b
  for b in "$@"; do
    case "$b" in
      bump-a) branch bump-a patch_bump ;;
      bump-b) branch bump-b patch_bump_b ;;
      notes) branch notes note_edit ;;
      other) branch other other_file ;;
    esac
  done
  set_version 1.5.0
  printf 'main line\n' > notes.md
  git commit -qam "feat: minor"
  git push -q origin main
  : > "$GIT_LOG"
}

# pr <number> <branch> <mergeable> [author] [label] [cross-repo] — one PR object.
pr() {
  jq -nc --argjson n "$1" --arg b "$2" --arg m "$3" --arg a "${4:-$BOT}" --arg l "${5:-}" \
    --argjson x "${6:-false}" \
    '{number: $n, headRefName: $b, mergeable: $m, isCrossRepository: $x,
      author: {login: $a, is_bot: ($a | startswith("app/"))},
      labels: (if $l == "" then [] else [{name: $l}] end)}'
}

# prs <pr-json…> — the listing the gh stub returns.
prs() { printf '%s\n' "$@" | jq -s . > "$PR_LIST"; }

sha_of() { git -C "$ORIGIN" rev-parse "refs/heads/$1"; }

run_sync() {
  cd "$WORK"
  run --separate-stderr zsh "$SYNC" "$@"
}

entry() { jq -c --argjson n "$1" '.prs[] | select(.number == $n)' <<<"$output"; }
field() { jq -r --argjson n "$1" ".prs[] | select(.number == \$n) | .$2" <<<"$output"; }

one_json_object() {
  [ "$(printf '%s\n' "$output" | jq -s 'length')" -eq 1 ]
  printf '%s\n' "$output" | jq -e 'type == "object" and (keys == ["prs"]) and (.prs | type == "array")' >/dev/null
  printf '%s\n' "$output" | jq -e \
    '.prs | all(keys == ["action","number","reason","resolved","verdict"] and (.resolved | type == "array"))' >/dev/null
}

no_scratch() {
  [ "$(git -C "$WORK" worktree list | wc -l | tr -d ' ')" -eq 1 ]
  [ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'sync-prs.*')" ]
  [ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'tok.*')" ]
}

pushes() { grep -c ' push ' "$GIT_LOG" || true; }

# ---- candidate selection ---------------------------------------------------

@test "the stub gh is the one on PATH, ahead of any host copy" {
  [ "$(command -v gh)" = "$BATS_TEST_TMPDIR/bin/gh" ]
}

@test "only the conflicting, unlabelled bot PR is rebased; the others are reported skipped, in PR order" {
  new_repo bump-a bump-b notes other
  # Listed out of order on purpose: the report and the processing follow the
  # PR number, not the listing.
  prs "$(pr 14 other UNKNOWN)" "$(pr 12 notes CONFLICTING octocat)" "$(pr 15 other MERGEABLE)" \
    "$(pr 11 bump-a CONFLICTING)" "$(pr 13 bump-b CONFLICTING "$BOT" needs-manual-rebase)"
  local b_before n_before
  b_before="$(sha_of bump-b)"
  n_before="$(sha_of notes)"
  : > "$GIT_LOG"
  run_sync
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(jq -c '[.prs[].number]' <<<"$output")" = '[11,12,13,14]' ]
  [ "$(field 11 action)" = pushed ]
  [ "$(entry 12)" = '{"number":12,"verdict":null,"action":"skipped","resolved":[],"reason":"human-authored"}' ]
  [ "$(entry 13)" = '{"number":13,"verdict":null,"action":"skipped","resolved":[],"reason":"labelled"}' ]
  [ "$(entry 14)" = '{"number":14,"verdict":null,"action":"skipped","resolved":[],"reason":"mergeable-unknown"}' ]
  # Only bump-a was fetched, checked out and pushed.
  [ "$(grep -c 'worktree add' "$GIT_LOG")" -eq 1 ]
  lacks "$(cat "$GIT_LOG")" 'refs/heads/notes'
  lacks "$(cat "$GIT_LOG")" 'refs/heads/bump-b'
  lacks "$(cat "$GIT_LOG")" 'refs/heads/other'
  [ "$(sha_of bump-b)" = "$b_before" ]
  [ "$(sha_of notes)" = "$n_before" ]
  [ "$(pushes)" -eq 1 ]
  no_scratch
}

@test "a bot PR whose head lives in a fork is skipped as cross-repository and never fetched" {
  new_repo bump-a
  prs "$(pr 11 bump-a CONFLICTING "$BOT" "" true)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(entry 11)" = '{"number":11,"verdict":null,"action":"skipped","resolved":[],"reason":"cross-repository"}' ]
  lacks "$(cat "$GIT_LOG")" 'worktree add'
  [ ! -e "$MINT_LOG" ]
}

@test "only the needs-manual-rebase label skips a PR; any other label does not" {
  new_repo bump-a
  prs "$(pr 11 bump-a CONFLICTING "$BOT" dependencies)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 11 action)" = pushed ]
}

@test "a human-authored PR is skipped even with the bot's name as a substring" {
  new_repo notes
  prs "$(pr 12 notes CONFLICTING "someone-app/claude-maintenance-acme")"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 12 reason)" = human-authored ]
  [ -z "$(cat "$MINT_LOG" 2>/dev/null)" ]
}

@test "the bot is recognised whatever the case of the owner and the login" {
  new_repo bump-a
  export GH_REPO="Acme/widgets"
  prs "$(pr 11 bump-a CONFLICTING 'App/Claude-Maintenance-Acme')"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 11 action)" = pushed ]
}

@test "the REST spelling of the bot login is a candidate too" {
  new_repo bump-a
  prs "$(pr 11 bump-a CONFLICTING 'claude-maintenance-acme[bot]')"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 11 action)" = pushed ]
}

# ---- resolved: pushed under a pinned lease ---------------------------------

@test "a resolved verdict is force-pushed with the lease pinned to the pre-rebase sha, then CI is nudged" {
  new_repo bump-a
  prs "$(pr 11 bump-a CONFLICTING)"
  local pre
  pre="$(sha_of bump-a)"
  run_sync
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(field 11 verdict)" = resolved ]
  [ "$(field 11 action)" = pushed ]
  [ "$(jq -c --argjson n 11 '[.prs[] | select(.number == $n) | .resolved[].path] | sort' <<<"$output")" \
    = '[".claude-plugin/marketplace.json","dev/.claude-plugin/plugin.json"]' ]
  contains "$(field 11 reason)" 'result: NUDGED'
  contains "$(cat "$GIT_LOG")" "--force-with-lease=refs/heads/bump-a:$pre"
  # The push authenticates with the minted token (git's own credential fill,
  # under the push's options, returns it), and its URL is pinned.
  [ "$(grep -c '^push-auth=bot$' "$GIT_LOG")" -eq 1 ]
  contains "$(grep ' push ' "$GIT_LOG")" "url.$ORIGIN.pushInsteadOf=$ORIGIN"
  # The pushed head is main plus the branch's work, at main's version + a patch.
  git -C "$ORIGIN" merge-base --is-ancestor main bump-a
  [ "$(git -C "$ORIGIN" show bump-a:dev/.claude-plugin/plugin.json | jq -r .version)" = 1.5.1 ]
  [ "$(git -C "$ORIGIN" show bump-a:.claude-plugin/marketplace.json | jq -r '.plugins[0].version')" = 1.5.1 ]
  [ "$(cat "$NUDGE_LOG")" = "--repo acme/widgets --grace 0 11 auth=bot" ]
  [ "$(grep -c called "$MINT_LOG")" -eq 1 ]
  no_scratch
}

@test "a push the remote rejects is reported push-rejected and the run carries on" {
  new_repo bump-a bump-b
  printf '#!/bin/sh\nexit 1\n' > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  prs "$(pr 11 bump-a CONFLICTING)" "$(pr 13 bump-b CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(field 11 action)" = push-rejected ]
  [ "$(field 13 action)" = push-rejected ]
  contains "$(field 11 reason)" 'pre-receive hook declined'
  contains "$(field 13 reason)" 'pre-receive hook declined'
  [ -z "$(cat "$NUDGE_LOG" 2>/dev/null)" ]
  no_scratch
}

@test "a pushInsteadOf rewrite of the push URL is pinned away: the push still lands on the PR's remote" {
  new_repo bump-a
  # A prefix rewrite, as `url."git@github.com:".pushInsteadOf https://github.com/` is.
  git config --global url."$BATS_TEST_TMPDIR/elsewhere/".pushInsteadOf "$BATS_TEST_TMPDIR/"
  prs "$(pr 11 bump-a CONFLICTING)"
  local pre
  pre="$(sha_of bump-a)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 11 action)" = pushed ]
  [ "$(sha_of bump-a)" != "$pre" ]
  git -C "$ORIGIN" merge-base --is-ancestor main bump-a
}

@test "a clean rebase (no manifest conflict) is pushed with verdict clean and no resolved records" {
  new_repo other
  prs "$(pr 17 other CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(entry 17 | jq -c '{verdict, action, resolved}')" = '{"verdict":"clean","action":"pushed","resolved":[]}' ]
  git -C "$ORIGIN" merge-base --is-ancestor main other
}

@test "a PR whose work is already on main is skipped as empty-after-rebase and not pushed" {
  new_repo other
  git -C "$WORK" cherry-pick origin/other >/dev/null
  git -C "$WORK" push -q origin main
  prs "$(pr 17 other CONFLICTING)"
  local pre
  pre="$(sha_of other)"
  : > "$GIT_LOG"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 17 action)" = skipped ]
  contains "$(field 17 reason)" 'empty-after-rebase'
  [ "$(pushes)" -eq 0 ]
  [ "$(sha_of other)" = "$pre" ]
  no_scratch
}

@test "a head branch missing from origin, or not a valid branch name, is reported failed" {
  new_repo bump-a
  prs "$(pr 41 gone CONFLICTING)" "$(pr 42 'bad..name' CONFLICTING)" "$(pr 43 bump-a CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 41 action)" = failed ]
  contains "$(field 41 reason)" 'git fetch of gone failed'
  [ "$(field 42 action)" = failed ]
  contains "$(field 42 reason)" 'not a valid branch'
  lacks "$(cat "$GIT_LOG")" 'bad..name:'
  [ "$(field 43 action)" = pushed ]
  [ "$(pushes)" -eq 1 ]
  no_scratch
}

@test "a failed CI nudge is reported on the pushed entry and does not stop the run" {
  new_repo bump-a
  printf 'print -u2 -- "gh pr reopen failed"; print -- "result: NUDGE-FAILED — x"; exit 3\n' > "$SYNC_PRS_RETRIGGER"
  prs "$(pr 11 bump-a CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 11 action)" = pushed ]
  contains "$(field 11 reason)" 're-triggering CI failed (exit 3): result: NUDGE-FAILED'
}

@test "a nudge that re-triggered CI but could not re-arm auto-merge is reported as a failure on the pushed entry" {
  new_repo bump-a
  printf 'print -- "result: NUDGED-REARM-FAILED — closed+reopened PR #11; re-arm auto-merge by hand."\n' \
    > "$SYNC_PRS_RETRIGGER"
  prs "$(pr 11 bump-a CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 11 action)" = pushed ]
  starts_with "$(field 11 reason)" 'pushed, but re-arming auto-merge failed'
}

# ---- conflict: one comment, the label, no push -----------------------------

@test "a conflict gets exactly one comment naming the files and the needs-manual-rebase label, and nothing is pushed" {
  new_repo notes
  prs "$(pr 21 notes CONFLICTING)"
  local pre
  pre="$(sha_of notes)"
  run_sync
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(field 21 verdict)" = conflict ]
  [ "$(field 21 action)" = conflict ]
  contains "$(field 21 reason)" 'notes.md'
  [ "$(grep -c '^pr comment 21 ' "$GH_LOG")" -eq 1 ]
  # The body spans several log lines; the file list sits inside it.
  contains "$(sed -n '/^pr comment 21 /,/auth=/p' "$GH_LOG")" '- `notes.md`'
  contains "$(sed -n '/^pr comment 21 /,/auth=/p' "$GH_LOG")" 'auth=bot'
  [ "$(grep -c '^pr edit 21 -R acme/widgets --add-label needs-manual-rebase auth=bot$' "$GH_LOG")" -eq 1 ]
  [ "$(grep -c '^label create needs-manual-rebase .* auth=bot$' "$GH_LOG")" -eq 1 ]
  # The label goes on before the comment.
  [ "$(grep -n '^pr edit 21 ' "$GH_LOG" | cut -d: -f1)" -lt "$(grep -n '^pr comment 21 ' "$GH_LOG" | cut -d: -f1)" ]
  [ "$(pushes)" -eq 0 ]
  [ "$(sha_of notes)" = "$pre" ]
  no_scratch
}

@test "a label that fails posts no comment, so the next run retries instead of commenting again" {
  new_repo notes
  export GH_FAIL="pr edit"
  prs "$(pr 21 notes CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 21 action)" = conflict ]
  contains "$(field 21 reason)" 'the label failed, so no comment was posted'
  contains "$(field 21 reason)" 'gh: pr edit failed'
  lacks "$(cat "$GH_LOG")" 'pr comment'
}

@test "a gh error that echoes the token is masked in the report" {
  new_repo notes
  export GH_FAIL="pr edit" GH_FAIL_ECHO_TOKEN=1
  prs "$(pr 21 notes CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  contains "$(field 21 reason)" 'gh: pr edit failed for ***'
  lacks "$output" "$TOKEN"
}

@test "a comment that fails after the label landed is reported on the conflict entry" {
  new_repo notes
  export GH_FAIL="pr comment"
  prs "$(pr 21 notes CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 21 action)" = conflict ]
  contains "$(field 21 reason)" 'the comment failed: gh: pr comment failed'
  [ "$(grep -c '^pr edit 21 ' "$GH_LOG")" -eq 1 ]
}

@test "the label is created once per run, however many PRs conflict" {
  new_repo notes
  git -C "$WORK" branch notes2 origin/notes
  git -C "$WORK" push -q origin notes2
  prs "$(pr 21 notes CONFLICTING)" "$(pr 22 notes2 CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(grep -c '^label create ' "$GH_LOG")" -eq 1 ]
  [ "$(grep -c '^pr edit ' "$GH_LOG")" -eq 2 ]
}

# ---- engine failure --------------------------------------------------------

@test "an engine exit 3 is reported engine-failed with no push, comment or label, and the next candidate still runs" {
  new_repo bump-a bump-b
  engine_failing_for "$(sha_of bump-a)"
  prs "$(pr 11 bump-a CONFLICTING)" "$(pr 13 bump-b CONFLICTING)"
  local pre
  pre="$(sha_of bump-a)"
  run_sync
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(entry 11 | jq -c '{verdict, action, resolved}')" = '{"verdict":null,"action":"engine-failed","resolved":[]}' ]
  contains "$(field 11 reason)" 'exited 3'
  contains "$(field 11 reason)" 'git fetch origin main failed'
  [ "$(sha_of bump-a)" = "$pre" ]
  lacks "$(cat "$GH_LOG")" 'pr comment 11'
  lacks "$(cat "$GH_LOG")" 'pr edit 11'
  lacks "$(cat "$GH_LOG")" 'label create'
  lacks "$(cat "$NUDGE_LOG")" ' 11 '
  [ "$(field 13 action)" = pushed ]
  [ "$(pushes)" -eq 1 ]
  # The failed PR's worktree was removed before the next one was added: the
  # main tree plus exactly one scratch worktree, each time.
  [ "$(tr '\n' ' ' < "$WT_LOG")" = "2 2 " ]
  no_scratch
}

@test "an engine exit 3 that still printed a verdict is engine-failed, and nothing is pushed" {
  new_repo bump-a
  export SYNC_PRS_ENGINE="$BATS_TEST_TMPDIR/engine.zsh"
  printf 'print -- %s; exit 3\n' "'{\"verdict\":\"resolved\",\"resolved\":[]}'" > "$SYNC_PRS_ENGINE"
  prs "$(pr 11 bump-a CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 11 action)" = engine-failed ]
  [ "$(pushes)" -eq 0 ]
}

@test "an engine exit 0 without a verdict is engine-failed, never parsed as a success" {
  new_repo bump-a
  export SYNC_PRS_ENGINE="$BATS_TEST_TMPDIR/engine.zsh"
  printf 'print -- "not json"\n' > "$SYNC_PRS_ENGINE"
  prs "$(pr 11 bump-a CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 11 action)" = engine-failed ]
  contains "$(field 11 reason)" 'exited 0'
  [ "$(pushes)" -eq 0 ]
}

# ---- dry run ---------------------------------------------------------------

@test "--dry-run pushes, comments and labels nothing and never invokes the mint script" {
  new_repo bump-a notes
  prs "$(pr 11 bump-a CONFLICTING)" "$(pr 21 notes CONFLICTING)"
  local a_pre n_pre
  a_pre="$(sha_of bump-a)"
  n_pre="$(sha_of notes)"
  run_sync --dry-run
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(field 11 action)" = would-push ]
  [ "$(field 11 verdict)" = resolved ]
  contains "$(field 11 reason)" "would force-push"
  contains "$(field 11 reason)" "over $a_pre"
  [ "$(field 21 action)" = would-mark-conflict ]
  [ "$(field 21 verdict)" = conflict ]
  [ "$(field 21 reason)" = 'conflicting files: notes.md' ]
  [ ! -e "$MINT_LOG" ]
  [ ! -e "$NUDGE_LOG" ]
  [ "$(pushes)" -eq 0 ]
  lacks "$(cat "$GH_LOG")" 'pr comment'
  lacks "$(cat "$GH_LOG")" 'pr edit'
  lacks "$(cat "$GH_LOG")" 'label create'
  [ "$(sha_of bump-a)" = "$a_pre" ]
  [ "$(sha_of notes)" = "$n_pre" ]
  no_scratch
}

# ---- idempotence -----------------------------------------------------------

@test "a second run over the same state, once the first run's pushes landed, pushes nothing" {
  new_repo bump-a
  prs "$(pr 11 bump-a CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(pushes)" -eq 1 ]
  : > "$GIT_LOG"
  : > "$NUDGE_LOG"
  # GitHub's mergeable may still read CONFLICTING (stale): the run must not
  # push again all the same.
  run_sync
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(field 11 action)" = unchanged ]
  [ "$(field 11 verdict)" = clean ]
  [ "$(pushes)" -eq 0 ]
  [ -z "$(cat "$NUDGE_LOG")" ]
  # Nothing to push, comment or label: the second run mints no token.
  [ "$(grep -c called "$MINT_LOG")" -eq 1 ]
  no_scratch
}

@test "nothing to do: no PR conflicting, no mint, an empty report" {
  new_repo bump-a
  prs "$(pr 11 bump-a MERGEABLE)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$output" = '{"prs":[]}' ]
  [ ! -e "$MINT_LOG" ]
  no_scratch
}

# ---- the token -------------------------------------------------------------

@test "the token value never appears in stdout, stderr or any call log" {
  new_repo bump-a notes
  git -C "$WORK" branch rej origin/bump-a
  git -C "$WORK" push -q origin rej
  printf '#!/bin/sh\nwhile read o n r; do [ "$r" = refs/heads/rej ] && { echo "denied $r" >&2; exit 1; }; done; exit 0\n' \
    > "$ORIGIN/hooks/pre-receive"
  chmod +x "$ORIGIN/hooks/pre-receive"
  prs "$(pr 11 bump-a CONFLICTING)" "$(pr 21 notes CONFLICTING)" "$(pr 31 rej CONFLICTING)"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(field 11 action)" = pushed ]
  [ "$(field 21 action)" = conflict ]
  [ "$(field 31 action)" = push-rejected ]
  # The token was minted and used (gh ran authenticated), yet never written out.
  contains "$(cat "$GH_LOG")" 'auth=bot'
  lacks "$output" "$TOKEN"
  lacks "$stderr" "$TOKEN"
  lacks "$(cat "$GH_LOG" "$GIT_LOG" "$NUDGE_LOG" "$MINT_LOG")" "$TOKEN"
  no_scratch
}

# ---- runtime failures and usage --------------------------------------------

@test "a failed token mint exits 3 with nothing on stdout and nothing pushed" {
  new_repo bump-a
  export MINT_FAIL=1
  prs "$(pr 11 bump-a CONFLICTING)"
  run_sync
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'token mint failed'
  [ "$(pushes)" -eq 0 ]
  no_scratch
}

@test "a failed gh repo view exits 3 with nothing on stdout" {
  new_repo bump-a
  export GH_FAIL="repo view"
  prs "$(pr 11 bump-a CONFLICTING)"
  run_sync
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'gh repo view failed'
  [ ! -e "$MINT_LOG" ]
}

@test "outside a git work tree it exits 3 with nothing on stdout" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  cd "$BATS_TEST_TMPDIR/plain"
  run --separate-stderr zsh "$SYNC"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'not inside a git work tree'
}

@test "gh missing from PATH exits 3 naming it" {
  local bin="$BATS_TEST_TMPDIR/only-zsh"
  mkdir -p "$bin"
  ln -s "$(command -v zsh)" "$bin/zsh"
  run --separate-stderr /usr/bin/env PATH="$bin" "$bin/zsh" "$SYNC"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'gh not found on PATH'
}

@test "a failed gh pr list exits 3 with nothing on stdout" {
  new_repo bump-a
  export GH_FAIL="pr list"
  run_sync
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'gh pr list failed'
}

@test "an unknown argument is a usage error" {
  new_repo
  run_sync --force
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'usage: sync-prs.zsh [--dry-run]'
}

# ---- the skill -------------------------------------------------------------

@test "SKILL.md has valid frontmatter and documents invocation, --dry-run, the report, /loop and approval dismissal" {
  [ "$(sed -n 1p "$SKILL")" = '---' ]
  [ "$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$SKILL")" -gt 2 ]
  [ "$(sed -n '2,/^---$/p' "$SKILL" | grep -c '^name: sync-prs$')" -eq 1 ]
  [ "$(sed -n '2,/^---$/p' "$SKILL" | grep -c '^description:')" -eq 1 ]
  local body
  body="$(cat "$SKILL")"
  contains "$body" 'scripts/sync-prs.zsh'
  contains "$body" '--dry-run'
  contains "$body" '{"prs":[{"number"'
  contains "$body" '/loop'
  contains "$body" 'idempotent'
  contains "$body" 'can dismiss the PR'"'"'s existing approval'
  contains "$body" '#1824'
  contains "$body" 'retrigger-pr-ci.zsh'
}

@test "the command reference lists /development:sync-prs" {
  contains "$(cat "$REPO_ROOT/docs/reference/commands.md")" '`/development:sync-prs`'
}
