#!/usr/bin/env bats
#
# development/scripts/git/branch-off-fresh-main.zsh — "branch off main" means
# "pull the latest main, then branch". What these pin down, against a real
# bare origin and clones in a temp dir (no network):
#
#   * FRESHNESS — the new branch starts at origin's CURRENT main, including a
#     commit pushed after the clone was made, whether HEAD was main (pulled) or
#     another branch (branched from the fetched tip).
#   * LOCAL MAIN — updated when HEAD is main (pull) or when it is safe from
#     elsewhere (fast-forward); left alone, and reported, when it is checked out
#     in another worktree or has diverged.
#   * --after — a sequential epic's gate: exit 4 and no branch until origin/main
#     holds the named commit; branch once it does.
#   * REFUSALS — a failed fetch, an existing branch, a diverged main when HEAD is
#     main, and bad usage all create nothing.
#   * WIRING — resolve-issue §1, the sequential epic chain, commit,
#     git-branch-naming and bootstrap call the script.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/scripts/git/branch-off-fresh-main.zsh"
  T="$BATS_TEST_TMPDIR"
  export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
  mkdir -p "$HOME"
  git config --global user.name t
  git config --global user.email t@example.invalid
  git config --global init.defaultBranch main
  git config --global commit.gpgsign false

  git init -q --bare "$T/origin.git"
  git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
  commit_in "$T/seed" a
  git -C "$T/seed" push -q origin main
  git clone -q "$T/origin.git" "$T/work"
}

# commit_in <repo> <file> — one commit adding <file>
commit_in() {
  printf '%s\n' "$2" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "add $2"
}

# advance_origin <file> — a commit lands on origin/main after the clone
advance_origin() {
  commit_in "$T/seed" "$1"
  git -C "$T/seed" push -q origin main
  git -C "$T/seed" rev-parse HEAD
}

run_s() { run zsh -c 'cd "$1" && shift && zsh "$@"' _ "$T/work" "$S" "$@"; }

origin_tip() { git -C "$T/seed" rev-parse HEAD; }

# --- freshness ----------------------------------------------------------------

@test "HEAD on main: pulls first, then branches from the pulled tip" {
  local new; new="$(advance_origin b)"
  run_s feat/1-x
  [ "$status" -eq 0 ]
  [ "$output" = "{\"branch\":\"feat/1-x\",\"base\":\"$new\",\"local_main\":\"pulled\"}" ]
  [ "$(git -C "$T/work" branch --show-current)" = "feat/1-x" ]
  [ "$(git -C "$T/work" rev-parse main)" = "$new" ]
}

@test "HEAD on main: uncommitted work comes along onto the new branch" {
  advance_origin b >/dev/null
  printf 'wip\n' > "$T/work/wip.txt"
  run_s feat/1-x
  [ "$status" -eq 0 ]
  [ -f "$T/work/wip.txt" ]
  [ "$(git -C "$T/work" status --porcelain)" = "?? wip.txt" ]
}

@test "HEAD elsewhere: branches from the fetched origin/main and fast-forwards local main" {
  git -C "$T/work" switch -q -c other
  local new; new="$(advance_origin b)"
  run_s feat/2-y
  [ "$status" -eq 0 ]
  [ "$output" = "{\"branch\":\"feat/2-y\",\"base\":\"$new\",\"local_main\":\"updated\"}" ]
  [ "$(git -C "$T/work" rev-parse main)" = "$new" ]
}

@test "HEAD elsewhere, local main already current: reported as current" {
  git -C "$T/work" switch -q -c other
  run_s feat/2-y
  [ "$status" -eq 0 ]
  contains "$output" '"local_main":"current"'
}

@test "local main checked out in another worktree: left alone, branch still fresh" {
  git -C "$T/work" worktree add -q -b wt "$T/wt" main
  local old; old="$(git -C "$T/work" rev-parse main)"
  local new; new="$(advance_origin b)"
  run zsh -c 'cd "$1" && zsh "$2" feat/3-z' _ "$T/wt" "$S"
  [ "$status" -eq 0 ]
  contains "$output" "\"base\":\"$new\""
  contains "$output" '"local_main":"in-use"'
  [ "$(git -C "$T/work" rev-parse main)" = "$old" ]
}

@test "local main diverged, HEAD elsewhere: left alone and reported" {
  advance_origin b >/dev/null
  commit_in "$T/work" local-only
  local mine; mine="$(git -C "$T/work" rev-parse main)"
  git -C "$T/work" switch -q -c other
  run_s feat/4-w
  [ "$status" -eq 0 ]
  contains "$output" '"local_main":"diverged"'
  contains "$output" "\"base\":\"$(origin_tip)\""
  [ "$(git -C "$T/work" rev-parse main)" = "$mine" ]
}

@test "no local main: reported as absent" {
  git -C "$T/work" switch -q -c other
  git -C "$T/work" branch -q -D main
  run_s feat/5-v
  [ "$status" -eq 0 ]
  contains "$output" '"local_main":"absent"'
}

# --- --after --------------------------------------------------------------------

@test "--after: exit 4 and no branch while origin/main lacks the commit" {
  commit_in "$T/work" unmerged
  local sha; sha="$(git -C "$T/work" rev-parse HEAD)"
  git -C "$T/work" switch -q -c other
  run_s --after "$sha" feat/6-u
  [ "$status" -eq 4 ]
  contains "$output" "does not contain $sha"
  run ! git -C "$T/work" show-ref --verify --quiet refs/heads/feat/6-u
}

@test "--after: an unknown commit is exit 4 too" {
  run_s --after 0123456789abcdef0123456789abcdef01234567 feat/6-u
  [ "$status" -eq 4 ]
}

@test "--after: branches once origin/main holds the commit" {
  local merged; merged="$(advance_origin prev-child)"
  run_s --after "$merged" feat/7-t
  [ "$status" -eq 0 ]
  contains "$output" "\"base\":\"$merged\""
}

# --- refusals -------------------------------------------------------------------

@test "a failed fetch is exit 3 and creates nothing" {
  git -C "$T/work" remote set-url origin "$T/missing.git"
  run_s feat/8-s
  [ "$status" -eq 3 ]
  contains "$output" "stale main"
  run ! git -C "$T/work" show-ref --verify --quiet refs/heads/feat/8-s
}

@test "an existing branch is exit 3" {
  git -C "$T/work" branch feat/9-r
  run_s feat/9-r
  [ "$status" -eq 3 ]
  contains "$output" "already exists"
}

@test "HEAD on a diverged main: exit 3, nothing created" {
  advance_origin b >/dev/null
  commit_in "$T/work" local-only
  run_s feat/10-q
  [ "$status" -eq 3 ]
  [ "$(git -C "$T/work" branch --show-current)" = "main" ]
  run ! git -C "$T/work" show-ref --verify --quiet refs/heads/feat/10-q
}

@test "usage errors are exit 2" {
  run_s
  [ "$status" -eq 2 ]
  run_s --after
  [ "$status" -eq 2 ]
  run_s --bogus feat/x
  [ "$status" -eq 2 ]
  run_s feat/a feat/b
  [ "$status" -eq 2 ]
}

@test "a name that would break the JSON report is refused" {
  run_s 'feat/a"b'
  [ "$status" -eq 3 ]
}

@test "the script is executable" {
  [ -x "$S" ]
}

# --- wiring ---------------------------------------------------------------------

@test "resolve-issue §1 and the sequential chain call the script" {
  local c="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  grep -qF '"<skill-base-dir>/../../scripts/git/branch-off-fresh-main.zsh" "<type>/<N>-<slug>"' "$c"
  grep -qF -- '--after <merge commit>' "$c"
  grep -qF -- '--after <merge commit>' "$REPO_ROOT/development/skills/resolve-issue/reference/sequential.md"
}

@test "commit, git-branch-naming and bootstrap call the script" {
  local d="$REPO_ROOT/development/skills"
  grep -qF 'scripts/git/branch-off-fresh-main.zsh' "$d/commit/SKILL.md"
  grep -qF 'scripts/git/branch-off-fresh-main.zsh' "$d/git-branch-naming/SKILL.md"
  grep -qF 'scripts/git/branch-off-fresh-main.zsh' "$d/bootstrap/SKILL.md"
}
