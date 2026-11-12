#!/usr/bin/env zsh
# init-submodules.zsh — make a resolve-issue work tree's git submodules ready
# before its first gate (#3080).
#
# Why: a fresh branch, a `--resume` checkout or a chain step's worktree does not
# initialise git submodules. A gate that reads a file inside one then fails with
# ENOENT, which reads as a red gate although nothing in the change is wrong. The
# conductor runs this script wherever it creates or checks out the work tree,
# before the first gate, so that cost is never paid.
#
# What it does:
#   * no `.gitmodules` at the work tree's root → runs no submodule command and
#     changes nothing; behaviour is as it was before this script existed;
#   * a `.gitmodules` → `git submodule update --init --recursive`. It only
#     initialises, checking out the commits the superproject records; it never
#     moves a submodule to a newer upstream commit.
#
# A failed update is an ENVIRONMENT error, never a red gate: the script exits 3
# and its stderr says so, naming git's own stderr. The caller stops before the
# gate and reports it as one.
#
# Usage:
#   init-submodules.zsh --repo-dir <dir>
#
# Stdout: one JSON line on exit 0.
#   {"submodules":"none"}          no .gitmodules — nothing ran
#   {"submodules":"initialised"}   the update ran and succeeded
#
# Exit codes:
#   0  ready — no .gitmodules, or the update succeeded
#   2  usage — a missing or unknown flag, or a --repo-dir that is not a git work tree
#   3  environment error — `git submodule update --init --recursive` failed

emulate -L zsh
setopt nounset pipefail

die() { print -u2 -- "init-submodules: $2"; exit "$1" }

local dir=""
while (( $# )); do
  case "$1" in
    --repo-dir)
      (( $# >= 2 )) && [[ -n "$2" ]] || die 2 "--repo-dir needs a directory"
      dir="$2"; shift 2 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
[[ -n "$dir" ]] || die 2 "usage: init-submodules.zsh --repo-dir <dir>"

local top
top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" \
  || die 2 "not a git work tree: $dir"

if [[ ! -e "$top/.gitmodules" ]]; then
  print -r -- '{"submodules":"none"}'
  exit 0
fi

local err
if ! err="$(git -C "$top" submodule update --init --recursive 2>&1 >/dev/null)"; then
  print -u2 -- "init-submodules: environment error, not a red gate: git submodule update --init --recursive failed in $top"
  [[ -n "$err" ]] && print -u2 -r -- "$err"
  exit 3
fi
print -r -- '{"submodules":"initialised"}'
