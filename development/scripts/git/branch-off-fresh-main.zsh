#!/usr/bin/env zsh
# branch-off-fresh-main.zsh — bring main up to date, then create a branch from it.
#
# Why: "branch off main" in this family always means "pull the latest main, then
# branch". A branch cut from a stale main has to be rebased before it can merge,
# and in a sequential epic it would miss the previous child's merged work. This
# script is the one statement of that rule; resolve-issue §1, commit, bootstrap
# and git-branch-naming all call it instead of spelling their own commands.
#
# What it does, in order:
#   1. `git fetch origin main`. A failed fetch is exit 3 — never branch off a
#      main that could not be refreshed.
#   2. With `--after <sha>`: require origin/main to contain that commit (a
#      sequential epic passes the previous child's merge commit), else exit 4
#      and create nothing.
#   3. Update the local main and branch from it:
#      - HEAD is main → `git pull --ff-only origin main`, then `git switch -c`
#        from the updated HEAD, so uncommitted work on main comes along. A pull
#        that cannot fast-forward (main diverged, or local changes in the way) is
#        exit 3 and nothing is created.
#      - HEAD is anything else → the local main is fast-forwarded to origin/main
#        when that is safe (it exists, it is an ancestor, and no worktree has it
#        checked out); otherwise it is left as it is and the report says why.
#        Then `git switch -c <branch> origin/main`, which starts from the fetched
#        tip either way.
#
# Usage:
#   branch-off-fresh-main.zsh [--after <sha>] <branch>
#
# Stdout: one JSON line on success, diagnostics on stderr.
#   {"branch":"<branch>","base":"<sha>","local_main":"<state>"}
#   local_main is one of:
#     pulled      HEAD was main and it was pulled (fast-forward or already current)
#     updated     local main was fast-forwarded to origin/main
#     current     local main already equalled origin/main
#     in-use      local main is checked out in another worktree; left alone
#     diverged    local main has commits origin/main lacks; left alone
#     absent      there is no local main
#
# Exit codes:
#   0  branch created
#   2  usage — no branch name, an unknown flag, or a missing --after value
#   3  runtime — not a git repo, the fetch failed, the branch already exists,
#      the pull could not fast-forward, or the switch failed
#   4  --after names a commit origin/main does not contain (yet)

emulate -L zsh
setopt nounset pipefail

die() { print -u2 -- "branch-off-fresh-main: $2"; exit "$1" }

local after="" branch=""
while (( $# )); do
  case "$1" in
    --after)
      (( $# >= 2 )) && [[ -n "$2" ]] || die 2 "--after needs a commit"
      after="$2"; shift 2 ;;
    -*) die 2 "unknown flag: $1" ;;
    *)
      [[ -z "$branch" ]] || die 2 "one branch name only"
      branch="$1"; shift ;;
  esac
done
[[ -n "$branch" ]] || die 2 "usage: branch-off-fresh-main.zsh [--after <sha>] <branch>"

git rev-parse --git-dir >/dev/null 2>&1 || die 3 "not inside a git repository"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die 3 "not a valid branch name: $branch"
# The name is interpolated into the JSON report, so refuse the two characters
# that would break it; no convention-conforming name carries either.
[[ "$branch" != *[\"\\]* ]] || die 3 "branch name may not contain a quote or backslash: $branch"
if git show-ref --verify --quiet "refs/heads/$branch"; then
  die 3 "branch already exists: $branch"
fi

git fetch -q origin main || die 3 "git fetch origin main failed — not branching off a stale main"
local tip
tip="$(git rev-parse --verify -q refs/remotes/origin/main)" || die 3 "origin/main not found after fetch"

if [[ -n "$after" ]]; then
  git rev-parse --verify -q "${after}^{commit}" >/dev/null \
    || die 4 "origin/main does not contain $after yet (commit unknown after fetch)"
  git merge-base --is-ancestor "$after" "$tip" \
    || die 4 "origin/main does not contain $after yet"
fi

local state current
current="$(git branch --show-current)"

if [[ "$current" == main ]]; then
  git pull -q --ff-only origin main \
    || die 3 "git pull --ff-only origin main failed — local main diverged or local changes are in the way"
  git switch -q -c "$branch" || die 3 "git switch -c $branch failed"
  state=pulled
else
  local have
  if ! have="$(git rev-parse --verify -q refs/heads/main)"; then
    state=absent
  elif [[ "$have" == "$tip" ]]; then
    state=current
  elif git worktree list --porcelain | grep -qx 'branch refs/heads/main'; then
    state=in-use
    print -u2 -- "branch-off-fresh-main: local main is checked out in another worktree; left alone (branching from origin/main)"
  elif git merge-base --is-ancestor "$have" "$tip"; then
    git update-ref refs/heads/main "$tip" "$have" || die 3 "could not fast-forward local main"
    state=updated
  else
    state=diverged
    print -u2 -- "branch-off-fresh-main: local main has commits origin/main lacks; left alone (branching from origin/main)"
  fi
  git switch -q -c "$branch" "$tip" || die 3 "git switch -c $branch origin/main failed"
fi

print -r -- "{\"branch\":\"$branch\",\"base\":\"$(git rev-parse HEAD)\",\"local_main\":\"$state\"}"
