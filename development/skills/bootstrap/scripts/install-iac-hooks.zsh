#!/usr/bin/env zsh
# install-iac-hooks.zsh — wire an IaC repository's version-controlled pre-push
# hook through the repository's own `make hooks` (#1605).
#
# Bootstrap's §3l IaC path emits no .pre-commit-config.yaml: its local hook is the
# rendered hooks/pre-push, which runs the same gate command CI's `gate` job runs.
# Step 4a calls this script on that path instead of install-precommit-hooks.zsh.
#
# Usage:
#   install-iac-hooks.zsh [--repo <path>]
#   install-iac-hooks.zsh -h|--help
#
#   --repo <path>  the target repository. It must be the root of a git work tree.
#                  Defaults to the current directory.
#   -h, --help     print this usage header to stdout and exit 0.
#
# Behaviour: the checks run in the order of the exit-code table below, and the
# first failure wins. core.hooksPath is not touched until every check has passed.
# The script then runs `make -C <repo> hooks`, with make's output forwarded to
# stderr under the `install-iac-hooks: ` prefix, and verifies that `git -C <repo> config --get core.hooksPath` is
# `hooks`. If core.hooksPath already held a different non-empty value, it first
# prints `install-iac-hooks: replacing core.hooksPath '<old>'` to stderr.
# Re-runs are idempotent.
#
# Exit codes, in check order:
#   2  usage error: unknown flag, --repo without a value, or --repo is not a
#      directory
#   4  a required tool (git or make) is not on PATH
#   3  --repo is not the root of a git work tree
#   5  a gate artifact is missing: no Makefile, a Makefile with no `hooks` target,
#      or hooks/pre-push missing or not executable
#   1  `make hooks` exited non-zero, or core.hooksPath is not `hooks` afterwards
#   0  hooks wired. Stdout is exactly `install-iac-hooks: core.hooksPath=hooks`.
#
# On every non-zero exit, stdout is empty and stderr carries one or more lines
# prefixed `install-iac-hooks: ` that name the cause.

emulate -L zsh
setopt err_exit nounset pipefail

fail() { local code="$1"; shift; print -u2 -r -- "install-iac-hooks: $*"; exit "$code" }

local repo="."
while (( $# > 0 )); do
  case "$1" in
  --repo)
    { (( $# >= 2 )) && [[ -n "$2" ]] } || fail 2 "--repo needs a non-empty value"
    repo="$2"; shift 2 ;;
  -h|--help)
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  *) fail 2 "unknown argument: $1" ;;
  esac
done
[[ -d "$repo" ]] || fail 2 "--repo is not a directory: $repo"

local tool
for tool in git make; do
  command -v "$tool" >/dev/null 2>&1 || fail 4 "$tool is not on PATH"
done

# The ROOT, not merely inside a work tree: `make -C` and hooks/ resolve against
# --repo, so a subdirectory would wire a hooks path relative to the wrong place.
local top
top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
  || fail 3 "not inside a git work tree: $repo"
[[ -n "$top" && "${top:A}" == "${repo:A}" ]] \
  || fail 3 "not the root of its git work tree (the root is ${top:-unknown}): $repo"

[[ -f "$repo/Makefile" ]] || fail 5 "no Makefile in $repo"
# A rule line — not indented (a recipe), not a comment, not a `:=` assignment —
# whose target list names `hooks`. Read textually rather than by `make -n hooks`:
# with a hooks/ directory on disk, make reports a target it has no rule for as
# up to date and exits 0.
local line targets has_hooks=0
local -a words
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" == [[:space:]]* || "$line" == \#* || "$line" != *:* ]] && continue
  targets="${line%%:*}"
  # `'='*` quoted: a bare `=*` is zsh's EQUALS expansion (a command lookup)
  [[ "${line#*:}" == '='* || "$targets" == *'='* ]] && continue
  # a real array, not the nested ${${(z)targets}[…]}: a one-word target list
  # collapses to a scalar there, where (Ie) searches characters and
  # `install-hooks:` matched
  words=( ${(z)targets} )
  if (( ${words[(Ie)hooks]} )); then
    has_hooks=1
    break
  fi
done < "$repo/Makefile"
(( has_hooks )) || fail 5 "the Makefile in $repo has no hooks target"
[[ -f "$repo/hooks/pre-push" ]] || fail 5 "hooks/pre-push is missing in $repo"
[[ -x "$repo/hooks/pre-push" ]] || fail 5 "hooks/pre-push is not executable in $repo"

local old
old="$(git -C "$repo" config --get core.hooksPath 2>/dev/null)" || old=""
if [[ -n "$old" && "$old" != "hooks" ]]; then
  print -u2 -r -- "install-iac-hooks: replacing core.hooksPath '$old'"
fi

# pipefail carries make's status through the prefixing sed
local rc=0
make -C "$repo" hooks 2>&1 | sed 's/^/install-iac-hooks: /' >&2 || rc=$?
(( rc == 0 )) || fail 1 "make hooks exited $rc"

local now
now="$(git -C "$repo" config --get core.hooksPath 2>/dev/null)" || now=""
[[ "$now" == "hooks" ]] || fail 1 "core.hooksPath is '$now' after make hooks, expected 'hooks'"

print -r -- "install-iac-hooks: core.hooksPath=hooks"
