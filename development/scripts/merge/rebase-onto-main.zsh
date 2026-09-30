#!/usr/bin/env zsh
# rebase-onto-main.zsh — rebase the current branch onto origin/main with the
# repo type's merge driver wired in for that one rebase (epic #1820, child
# #1822). `open-pr` Step 1b runs it before pushing.
#
# Run from inside the repository to rebase. It fetches `origin main`, and when
# main has commits the branch lacks it rebases onto `origin/main`. When a
# `merge-driver-<repo_type>.zsh` sits beside this script (repo type from
# `review-dispatch.zsh detect`), each path pattern the driver prints for
# `--patterns` is mapped to `merge=repo-type-driver` in a temporary attributes
# file, and the rebase runs as
#   git -c core.attributesFile=<tmp> \
#       -c merge.repo-type-driver.driver='<driver> %O %A %B %P' rebase <origin/main sha>
# with MERGE_DRIVER_RECORD pointing at a temporary file. The temporary
# attributes file starts as a copy of the user's global one, which the `-c`
# would otherwise replace. The driver is wired in through `-c` only, so no git
# config (global, repo or worktree) is written.
# A repo type with no driver file, or a repo whose type cannot be determined
# (detect's exit 3), gets a plain `git rebase origin/main`: any conflict stops.
#
# Attributes passed via core.attributesFile rank below a committed
# .gitattributes, so a repo that sets its own `merge=` on the same paths keeps
# its own setting. Only textual conflicts are resolved; a textually clean rebase
# that breaks something semantically is CI's to catch.
#
# Usage:
#   rebase-onto-main.zsh            (no arguments)
#
# Stdout carries only the JSON verdict; diagnostics go to stderr.
#   {"verdict":"clean"}                                 main not ahead, no rebase
#   {"verdict":"clean","base":"<sha>"}                  rebased, nothing resolved
#   {"verdict":"resolved","base":"<sha>","resolved":[<driver records>]}
#                                                       rebased, the driver
#                                                       resolved fields by rule
#   {"verdict":"conflict","files":[<paths>]}            rebase stopped on a
#                                                       conflict and was aborted:
#                                                       the branch is as it was
#
# Exit codes:
#   0  clean or resolved
#   1  conflict — the rebase was aborted, the branch tip and working tree are
#      as they were before the run
#   2  usage — any argument
#   3  runtime — not a git repo, jq missing, a rebase already in progress, the
#      fetch failed, detect or the driver's --patterns failed, the rebase could
#      not start (e.g. a dirty tree), stopped with no unmerged path, or could
#      not be aborted. One case follows a COMPLETED rebase: driver records that
#      cannot be read (the message names the new base)
#   130 interrupted (INT, TERM or HUP); a rebase under way may be left stopped
#
# Temporary files are removed on every exit path.

emulate -L zsh
setopt nounset pipefail

local here="${0:A:h}"
local dispatch="${here:h:h}/skills/resolve-issue/scripts/review-dispatch.zsh"

die() { print -u2 -- "rebase-onto-main: $1"; exit 3 }

(( $# == 0 )) || { print -u2 -- "rebase-onto-main: expected no arguments, got $#
usage: rebase-onto-main.zsh   (run from inside the repository to rebase)"; exit 2 }

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

local top
top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]] || die "not inside a git work tree"
cd -- "$top" || die "cannot enter $top"

# A rebase already in progress is someone else's: never start over it, and
# never let the conflict arm below abort it.
in_rebase() {
  local d
  for d in rebase-merge rebase-apply; do
    [[ -d "$(git rev-parse --git-path "$d")" ]] && return 0
  done
  return 1
}
in_rebase && die "a rebase is already in progress; finish or abort it first"

local tmp=""
trap '[[ -n "$tmp" ]] && rm -rf -- "$tmp"' EXIT
trap 'exit 130' INT TERM HUP

git fetch origin main >&2 || die "git fetch origin main failed"

# Everything below uses this sha, never the ref: origin/main is shared by every
# worktree, and another session's fetch may move it mid-run.
local base
base="$(git rev-parse --verify -q 'origin/main^{commit}')" || die "origin/main does not resolve after the fetch"

local ahead
ahead="$(git rev-list -n 1 "HEAD..$base")" || die "git rev-list HEAD..$base failed"
if [[ -z "$ahead" ]]; then
  jq -nc '{verdict: "clean"}'
  exit 0
fi

# The repo type decides the driver. Exit 3 is a type that could not be
# determined, which has no driver to name: the plain rebase, as for a type
# without one. Any other failure is a failed detect.
local detect_out repo_type="" rc=0
detect_out="$(zsh "$dispatch" detect --repo "$top")" || rc=$?
case $rc in
  0) repo_type="$(jq -er '.repo_type | select(type == "string" and length > 0)' <<<"$detect_out")" \
       || die "review-dispatch.zsh detect printed no repo type" ;;
  3) print -u2 -- "rebase-onto-main: repo type not determined ($detect_out); no merge driver" ;;
  *) die "review-dispatch.zsh detect failed (exit $rc)" ;;
esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rebase-onto-main.XXXXXX")" || die "mktemp failed"
local record="$tmp/records.jsonl"
: > "$record" || die "cannot create $record"

local driver="$here/merge-driver-${repo_type}.zsh"
local -a rebase_cmd
if [[ -n "$repo_type" && -f "$driver" ]]; then
  local patterns
  patterns="$(zsh "$driver" --patterns)" || die "${driver:t} --patterns failed"
  # core.attributesFile REPLACES the user's global attributes file, so carry its
  # rules over first; the driver's lines come last and win on their own paths.
  local attrs="$tmp/attributes" p global
  global="$(git config --path core.attributesFile)" || global="${XDG_CONFIG_HOME:-$HOME/.config}/git/attributes"
  if [[ -r "$global" ]]; then
    cat -- "$global" > "$attrs" || die "cannot copy $global"
  else
    : > "$attrs" || die "cannot create $attrs"
  fi
  for p in "${(@f)patterns}"; do
    [[ -n "$p" ]] && print -r -- "$p merge=repo-type-driver" >> "$attrs"
  done
  rebase_cmd=(git -c "core.attributesFile=$attrs"
    -c "merge.repo-type-driver.name=repo type merge driver (${driver:t})"
    -c "merge.repo-type-driver.driver=zsh ${(qq)driver} %O %A %B %P"
    rebase "$base")
else
  rebase_cmd=(git rebase "$base")
fi

if MERGE_DRIVER_RECORD="$record" "${rebase_cmd[@]}" >&2; then
  if [[ -s "$record" ]]; then
    jq -sc --arg base "$base" '{verdict: "resolved", base: $base, resolved: .}' "$record" \
      || die "rebased onto $base, but the driver records could not be read"
  else
    jq -nc --arg base "$base" '{verdict: "clean", base: $base}'
  fi
  exit 0
fi

# The rebase failed. Stopped on a conflict, it is in progress; a rebase that
# never started (a dirty tree, say) is not a conflict.
in_rebase || die "git rebase $base failed without stopping on a conflict"

local files
files="$(git diff --name-only -z --diff-filter=U | jq -Rsc 'split("\u0000") | map(select(length > 0))')" \
  || files='[]'
git rebase --abort >&2 || die "git rebase --abort failed; the rebase is still in progress"
# Stopped with no unmerged path (untracked files in the way, say): not a conflict.
[[ "$files" != '[]' ]] || die "git rebase $base stopped without an unmerged path; aborted"
jq -nc --argjson files "$files" '{verdict: "conflict", files: $files}'
exit 1
