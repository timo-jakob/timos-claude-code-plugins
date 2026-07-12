#!/usr/bin/env zsh
# list-refinement-children.zsh — list an epic's children that still need
# refinement (#580, epic #573).
#
# Epic-aware `/development:refine-issue` walks a halted epic's `needs-refinement`
# children through the single-issue flow. This is the enumeration primitive it
# uses: given an epic, it parses the epic body's **task-list lines** (the same
# rule resolve-issue's E1 uses — `- [ ] #N` / `- [x] #N`, or `owner/repo#N`; NOT
# every `#N` mention, which would pull in unrelated cross-references), and prints
# the child numbers that are **OPEN and carry the `needs-refinement` label**, in
# body order. Those are exactly the children the walk should refine.
#
# It reads GitHub via `gh` (the epic body, then each child's state + labels).
#
# Output: one child number per line (empty when the epic has no refinable
# children — a clean exit 0, the terminal case for the walk).
#
# Exit codes: 0 ok (including "none") · 2 usage · 3 runtime (gh/jq missing).
#
# Usage:
#   list-refinement-children.zsh --repo <owner/name> --epic <N>

emulate -L zsh
set -euo pipefail

local repo="" epic=""
while (( $# > 0 )); do
  case "$1" in
    --repo)
      (( $# >= 2 )) || { print -u2 "list-refinement-children.zsh: --repo needs a value"; exit 2; }
      repo="$2"; shift 2 ;;
    --epic)
      (( $# >= 2 )) || { print -u2 "list-refinement-children.zsh: --epic needs a value"; exit 2; }
      epic="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: list-refinement-children.zsh --repo <owner/name> --epic <N>"
      exit 0 ;;
    *) print -u2 "list-refinement-children.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$repo" ]] || { print -u2 "list-refinement-children.zsh: --repo is required"; exit 2; }
[[ -n "$epic" ]] || { print -u2 "list-refinement-children.zsh: --epic is required"; exit 2; }
[[ "$epic" == <-> ]] || { print -u2 "list-refinement-children.zsh: --epic must be a number, got: $epic"; exit 2; }
command -v gh >/dev/null 2>&1 || { print -u2 "list-refinement-children.zsh: gh not found on PATH"; exit 3; }
command -v jq >/dev/null 2>&1 || { print -u2 "list-refinement-children.zsh: jq not found on PATH"; exit 3; }

# The epic body (guard the fetch — a 404 must be the documented runtime exit 3,
# not a bare set -e abort).
local body
body="$(gh issue view "$epic" --repo "$repo" --json body -q .body)" \
  || { print -u2 "list-refinement-children.zsh: failed to fetch epic #$epic from $repo"; exit 3; }

# Its task-list child numbers, in body order. One fence-aware awk pass:
#   - drop lines inside ``` code fences (so an illustrative `- [ ] #123` in an
#     example is not parsed as a real child);
#   - match only checklist items (`-`/`*`/`+` bullet + `[ ]`/`[x]`), and take the
#     FIRST `#<digits>` on each (so a trailing dependency ref like
#     "#601 — depends on #700" yields only 601, and a non-numeric `#abc` before
#     the real `#123` is skipped over).
# awk always exits 0 (even with no matches), so this is pipefail-safe — a
# childless body yields an empty list and a clean exit 0.
local -a children
children=("${(@f)$(print -r -- "$body" | awk '
  /^[[:space:]]*```/ { infence = !infence; next }
  infence { next }
  /^[[:space:]]*[-*+] \[[ xX]\]/ {
    if (match($0, /#[0-9]+/)) print substr($0, RSTART + 1, RLENGTH - 1)
  }')}")

# Keep OPEN children carrying the needs-refinement label, in body order.
# Declare `meta` ONCE up front — re-declaring `local` inside the loop echoes the
# parameter at script (non-function) scope in zsh, polluting stdout.
local n meta
for n in "${children[@]}"; do
  [[ -n "$n" ]] || continue
  meta="$(gh issue view "$n" --repo "$repo" --json state,labels 2>/dev/null)" || continue
  # Use an `if` (not `&& print`): a non-qualifying child makes jq exit 1, and a
  # bare `&& print` compound would then trip `set -e` and abort the whole walk.
  if print -r -- "$meta" | jq -e '
       .state == "OPEN"
       and ((.labels // []) | any(.name == "needs-refinement"))' >/dev/null 2>&1; then
    print -r -- "$n"
  fi
done
