#!/usr/bin/env bats
#
# Behavioral tests for rebase-onto-main.zsh — the rebase engine that wires the
# repo type's merge driver into one `git rebase origin/main` (#1822, epic
# #1820). Real git in temp repos, each cloned from a local bare `origin`; the
# git config, XDG config home and TMPDIR are the test's own, so "no config
# written" and "no temporary files left" are checked against a known-empty
# baseline.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repos' git calls would land in the REAL repository
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ENGINE="$REPO_ROOT/development/scripts/merge/rebase-onto-main.zsh"
  OPEN_PR="$REPO_ROOT/development/skills/open-pr/SKILL.md"
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
}

# ---- fixtures --------------------------------------------------------------

# new_repo — a bare origin and a work clone on main; the caller's files are
# committed as the first commit and pushed.
new_repo() {
  git init -q --bare "$ORIGIN"
  git init -q "$WORK"
  cd "$WORK"
  "$@"
  git add -A
  git commit -qm init
  git remote add origin "$ORIGIN"
  git push -q -u origin main
}

# A claude-plugin repo: one plugin, its plugin.json and the marketplace entry.
plugin_files() {
  mkdir -p .claude-plugin dev/.claude-plugin
  jq -n '{name: "dev", description: "Dev tools.", version: "1.4.2"}' > dev/.claude-plugin/plugin.json
  jq -n '{name: "market", plugins: [{name: "dev", description: "Dev tools.", version: "1.4.2", source: "./dev"}]}' \
    > .claude-plugin/marketplace.json
  printf 'line one\n' > notes.md
}

# set_version <v> — bump the plugin in both manifests.
set_version() {
  jq --arg v "$1" '.version = $v' dev/.claude-plugin/plugin.json > m.tmp
  mv m.tmp dev/.claude-plugin/plugin.json
  jq --arg v "$1" '.plugins[0].version = $v' .claude-plugin/marketplace.json > m.tmp
  mv m.tmp .claude-plugin/marketplace.json
}

# A python repo: detect says `python`, which ships no merge driver.
python_files() {
  printf '[project]\nname = "svc"\nversion = "1.4.2"\n' > pyproject.toml
}

# A repo whose type cannot be determined (detect exits 3).
plain_files() {
  printf 'line one\n' > notes.md
}

# commit_on <branch> <message> <cmd...> — run cmd on the branch and commit;
# main's commits are pushed so origin/main moves ahead of the feature branch.
commit_on() {
  local branch="$1" msg="$2"
  shift 2
  git switch -q "$branch"
  "$@"
  git commit -qam "$msg"
  if [[ "$branch" == main ]]; then git push -q origin main; fi
}

edit_notes() { printf '%s\n' "$1" > notes.md; }
set_pyversion() { sed -i.bak "s/^version = .*/version = \"$1\"/" pyproject.toml && rm -f pyproject.toml.bak; }
bump_and_note() { set_version "$1"; edit_notes "$2"; }

# The notes.md conflict beside both version bumps, left checked out on feat.
conflicting_bumps() {
  new_repo plugin_files
  git switch -q -c feat
  commit_on feat "fix: patch" bump_and_note 1.4.3 "branch line"
  commit_on main "feat: minor" bump_and_note 1.5.0 "main line"
  git switch -q feat
}

# run_engine [args] — from inside the work tree, stdout and stderr kept apart.
run_engine() {
  cd "$WORK"
  run --separate-stderr zsh "$ENGINE" "$@"
}

# stub_engine <detect body> [driver body] — a copy of the engine in its own
# layout, with review-dispatch.zsh (and optionally merge-driver-stub.zsh)
# replaced by stubs; sets ENGINE to the copy.
stub_engine() {
  local root="$BATS_TEST_TMPDIR/stub/development"
  mkdir -p "$root/scripts/merge" "$root/skills/resolve-issue/scripts"
  cp "$ENGINE" "$root/scripts/merge/rebase-onto-main.zsh"
  printf '%s\n' "$1" > "$root/skills/resolve-issue/scripts/review-dispatch.zsh"
  if [[ -n "${2-}" ]]; then printf '%s\n' "$2" > "$root/scripts/merge/merge-driver-stub.zsh"; fi
  ENGINE="$root/scripts/merge/rebase-onto-main.zsh"
}

# git_wrapper <case body> — a `git` first on PATH that runs the given case arm
# before forwarding to the real git.
git_wrapper() {
  local real bin="$BATS_TEST_TMPDIR/bin"
  real="$(command -v git)"
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase "$*" in\n%s\nesac\nexec "%s" "$@"\n' "$1" "$real" > "$bin/git"
  chmod +x "$bin/git"
  export PATH="$bin:$PATH"
}

# The criteria every run shares: stdout is exactly one JSON object, no git
# config entry was written, and no temporary file is left behind.
one_json_object() {
  [ "$(printf '%s\n' "$output" | jq -s 'length')" -eq 1 ]
  printf '%s\n' "$output" | jq -e 'type == "object"' >/dev/null
}

# (`! cmd` never fails a bats test under errexit, so the config check returns
# explicitly.)
no_residue() {
  if git -C "$WORK" config --list --show-origin | grep -Ei 'merge\.repo-type-driver|core\.attributesfile'; then
    return 1
  fi
  [ -z "$(ls -A "$TMPDIR")" ]
  [ ! -d "$WORK/.git/rebase-merge" ]
  [ ! -d "$WORK/.git/rebase-apply" ]
}

# ---- main not ahead ---------------------------------------------------------

@test "main not ahead: verdict clean with no base, exit 0, HEAD unchanged — run directly, as open-pr does" {
  new_repo plugin_files
  git switch -q -c feat
  commit_on feat "feat: bump" set_version 1.4.3
  local before
  before="$(git rev-parse HEAD)"
  # Executed, not `zsh <file>`: open-pr Step 1b runs the engine by path.
  run --separate-stderr "$ENGINE"
  [ "$status" -eq 0 ]
  [ "$output" = '{"verdict":"clean"}' ]
  [ "$(git rev-parse HEAD)" = "$before" ]
  one_json_object
  no_residue
}

# ---- claude-plugin: the driver resolves the manifests -----------------------

@test "both sides bumped the version: verdict resolved, main's version bumped by a patch in both manifests" {
  new_repo plugin_files
  git switch -q -c feat
  commit_on feat "fix: patch" set_version 1.4.3
  commit_on main "feat: minor" set_version 1.5.0
  git switch -q feat
  run_engine
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(jq -r .verdict <<<"$output")" = resolved ]
  [ "$(jq -r .base <<<"$output")" = "$(git rev-parse origin/main)" ]
  [ "$(jq -r .version dev/.claude-plugin/plugin.json)" = 1.5.1 ]
  [ "$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)" = 1.5.1 ]
  [ "$(jq -c '[.resolved[].path] | sort' <<<"$output")" = '[".claude-plugin/marketplace.json","dev/.claude-plugin/plugin.json"]' ]
  jq -e '.resolved | all(.field == "version" and .main == "1.5.0" and .pr == "1.4.3" and .result == "1.5.1")' \
    <<<"$output" >/dev/null
  # Really rebased: main's commit is now an ancestor of the branch.
  git merge-base --is-ancestor origin/main HEAD
  [ -z "$(git status --porcelain)" ]
  no_residue
}

@test "main ahead with no conflict: verdict clean carrying the new base, nothing resolved" {
  new_repo plugin_files
  git switch -q -c feat
  commit_on feat "fix: patch" set_version 1.4.3
  commit_on main "docs: notes" edit_notes "main line"
  git switch -q feat
  run_engine
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(jq -c 'keys' <<<"$output")" = '["base","verdict"]' ]
  [ "$(jq -r .verdict <<<"$output")" = clean ]
  [ "$(jq -r .base <<<"$output")" = "$(git rev-parse origin/main)" ]
  git merge-base --is-ancestor origin/main HEAD
  no_residue
}

@test "a conflicting non-manifest edit beside the bumps: verdict conflict naming it, branch and status as before" {
  conflicting_bumps
  local tip status_before
  tip="$(git rev-parse HEAD)"
  status_before="$(git status --porcelain)"
  run_engine
  [ "$status" -eq 1 ]
  one_json_object
  [ "$output" = '{"verdict":"conflict","files":["notes.md"]}' ]
  [ "$(git rev-parse HEAD)" = "$tip" ]
  [ "$(git status --porcelain)" = "$status_before" ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = feat ]
  no_residue
}

@test "the user's global attributes still apply beside the driver's (a global merge=union resolves notes.md)" {
  mkdir -p "$XDG_CONFIG_HOME/git"
  printf 'notes.md merge=union\n' > "$XDG_CONFIG_HOME/git/attributes"
  conflicting_bumps
  run_engine
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(jq -r .verdict <<<"$output")" = resolved ]
  [ "$(jq -r .version dev/.claude-plugin/plugin.json)" = 1.5.1 ]
  [ "$(sort notes.md | tr '\n' ' ')" = 'branch line main line ' ]
  no_residue
}

# ---- repo types with no driver ----------------------------------------------

@test "a repo type with no merge driver and a manifest-style conflict: verdict conflict, exit 1" {
  new_repo python_files
  [ ! -e "$REPO_ROOT/development/scripts/merge/merge-driver-python.zsh" ]
  git switch -q -c feat
  commit_on feat "fix: patch" set_pyversion 1.4.3
  commit_on main "feat: minor" set_pyversion 1.5.0
  git switch -q feat
  local tip
  tip="$(git rev-parse HEAD)"
  run_engine
  [ "$status" -eq 1 ]
  one_json_object
  [ "$output" = '{"verdict":"conflict","files":["pyproject.toml"]}' ]
  [ "$(git rev-parse HEAD)" = "$tip" ]
  [ -z "$(git status --porcelain)" ]
  no_residue
}

@test "a repo whose type cannot be determined still rebases plainly" {
  new_repo plain_files
  git switch -q -c feat
  printf 'x\n' > other.txt
  git add other.txt
  git commit -qm "feat: other"
  commit_on main "docs: notes" edit_notes "main line"
  git switch -q feat
  run_engine
  [ "$status" -eq 0 ]
  one_json_object
  [ "$(jq -r .verdict <<<"$output")" = clean ]
  [ "$(jq -r .base <<<"$output")" = "$(git rev-parse origin/main)" ]
  git merge-base --is-ancestor origin/main HEAD
  contains "$stderr" "repo type not determined"
  no_residue
}

# ---- usage and runtime failures ---------------------------------------------

@test "any argument is a usage error: exit 2, nothing on stdout" {
  new_repo plugin_files
  run_engine --base main
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "usage: rebase-onto-main.zsh"
}

@test "outside a git repository: exit 3, nothing on stdout" {
  mkdir -p "$BATS_TEST_TMPDIR/nogit"
  cd "$BATS_TEST_TMPDIR/nogit"
  run --separate-stderr env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" zsh "$ENGINE"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "not inside a git work tree"
}

@test "jq missing: exit 3, nothing on stdout" {
  new_repo plugin_files
  local bin="$BATS_TEST_TMPDIR/nojq" zsh_bin
  zsh_bin="$(command -v zsh)"
  mkdir -p "$bin"
  ln -s "$(command -v git)" "$bin/git"
  cd "$WORK"
  run --separate-stderr env PATH="$bin" "$zsh_bin" "$ENGINE"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "jq not found on PATH"
}

@test "a failed fetch: exit 3, nothing on stdout, no temporary files" {
  new_repo plugin_files
  git remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
  run_engine
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "git fetch origin main failed"
  no_residue
}

@test "an unborn HEAD fails rev-list: exit 3, never a clean verdict" {
  new_repo plugin_files
  git switch -q --orphan fresh
  run_engine
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "git rev-list HEAD.."
}

@test "a failed detect (exit 2) is a runtime error, not a plain rebase" {
  conflicting_bumps
  stub_engine 'exit 2'
  local tip
  tip="$(git rev-parse HEAD)"
  run_engine
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "review-dispatch.zsh detect failed (exit 2)"
  [ "$(git rev-parse HEAD)" = "$tip" ]
  no_residue
}

@test "a driver whose --patterns fails: exit 3, temporary files removed" {
  conflicting_bumps
  stub_engine "print -r -- '{\"repo_type\":\"stub\"}'" 'exit 1'
  run_engine
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "merge-driver-stub.zsh --patterns failed"
  no_residue
}

@test "a rebase that cannot start (dirty tree) is a runtime error, not a conflict" {
  new_repo plugin_files
  git switch -q -c feat
  commit_on feat "fix: patch" set_version 1.4.3
  commit_on main "docs: notes" edit_notes "main line"
  git switch -q feat
  printf 'uncommitted\n' >> dev/.claude-plugin/plugin.json
  local tip
  tip="$(git rev-parse HEAD)"
  run_engine
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "failed without stopping on a conflict"
  lacks "$stderr" "rebase --abort failed"
  [ "$(git rev-parse HEAD)" = "$tip" ]
  [ "$(git diff --name-only)" = dev/.claude-plugin/plugin.json ]
  no_residue
}

@test "a rebase stopped with no unmerged path is aborted and is a runtime error, not a conflict" {
  conflicting_bumps
  local tip
  tip="$(git rev-parse HEAD)"
  git_wrapper 'diff\ --name-only\ -z\ --diff-filter=U) exit 0 ;;'
  run_engine
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "stopped without an unmerged path"
  [ "$(git rev-parse HEAD)" = "$tip" ]
  no_residue
}

@test "a rebase --abort that fails: exit 3, never a conflict verdict" {
  conflicting_bumps
  git_wrapper 'rebase\ --abort) exit 1 ;;'
  run_engine
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "git rebase --abort failed"
}

@test "a rebase already in progress is refused and left in progress" {
  new_repo plain_files
  git switch -q -c feat
  commit_on feat "feat: branch" edit_notes "branch line"
  commit_on main "docs: main" edit_notes "main line"
  git switch -q feat
  git rebase -q origin/main 2>/dev/null || true
  [ -d .git/rebase-merge ]
  run_engine
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "a rebase is already in progress"
  [ -d .git/rebase-merge ]
}

# ---- open-pr Step 1b --------------------------------------------------------

@test "open-pr Step 1b runs the engine, documents its three verdicts and drops the manual re-bump advice" {
  local step report
  step="$(awk '/^## Step 1b/{on=1; print; next} /^## /{on=0} on' "$OPEN_PR")"
  report="$(awk '/^## Step 5/{on=1; next} /^## /{on=0} on' "$OPEN_PR")"
  contains "$step" 'scripts/merge/rebase-onto-main.zsh'
  contains "$step" '**`clean`**'
  contains "$step" '**`resolved`**'
  contains "$step" '**`conflict`**'
  contains "$step" 'Stop — open no PR'
  contains "$step" 'never resolve it by picking a side automatically'
  lacks "$step" 'git rebase origin/main ||'
  run grep -ci 're-bump' "$OPEN_PR"
  [ "$output" = 0 ]
  # A resolved rebase is reported in the PR body and in the final report.
  contains "$step" 'PR body'
  contains "$report" 'resolved'
}

@test "open-pr pushes under a lease recorded before the rebase, named explicitly on every push" {
  local step step3
  step="$(awk '/^## Step 1b/{on=1; print; next} /^## /{on=0} on' "$OPEN_PR")"
  step3="$(awk '/^## Step 3/{on=1; print; next} /^## /{on=0} on' "$OPEN_PR")"
  # Taken before the engine runs, and a remote tip the branch lacks stops the run.
  contains "${step%%rebase-onto-main.zsh*}" 'LEASE=$(git ls-remote origin "refs/heads/${BRANCH}"'
  contains "${step%%rebase-onto-main.zsh*}" 'git merge-base --is-ancestor "$LEASE" HEAD'
  contains "${step%%rebase-onto-main.zsh*}" 'has commits this branch lacks — stop, open no PR"; exit 1; }'
  # Never re-read at push time: stated, and no ls-remote after the engine runs.
  contains "$step" 'never re-read'
  lacks "${step#*rebase-onto-main.zsh}" 'ls-remote'
  contains "$step" '--force-with-lease="${BRANCH}:${LEASE}"'
  contains "$step3" '--force-with-lease="${BRANCH}:${LEASE}"'
  lacks "$step3" 'ls-remote'
  run grep -c "under Step 1b's lease" "$OPEN_PR"
  [ "$output" = 2 ]
}
