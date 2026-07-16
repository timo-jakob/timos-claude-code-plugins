#!/usr/bin/env zsh
# list-refinement-children.zsh — list an epic's children that still need
# refinement (#580, epic #573).
#
# Epic-aware `/development:refine-issue` walks a halted epic's `needs-refinement`
# children through the single-issue flow. This is the enumeration primitive it
# uses: given an epic, it reads the epic's **native sub-issues** through the
# shared reader (`read-sub-issues.zsh`, #802 — the same source resolve-issue's
# E1 uses; the body's markdown task list is the human-readable view, never the
# authoritative one), and prints the child numbers that are **OPEN and carry
# the `needs-refinement` label**, in sub-issue order. Those are exactly the
# children the walk should refine.
#
# It reads GitHub via the shared reader (child list + states) and `gh` (each
# open child's labels).
#
# Output: one child number per line (empty when the epic has no refinable
# children — a clean exit 0, the terminal case for the walk; an un-backfilled
# epic enumerates zero native children and lands here too — backfill first,
# see backfill-sub-issues.zsh).
#
# Exit codes: 0 ok (including "none") · 2 usage · 3 runtime (gh/jq/reader
# missing or failed).
#
# Seams (for tests / non-PATH installs):
#   SUBISSUES_BIN  overrides the shared reader (defaults to the resolve-issue
#                  sibling copy — one reader, no drift).
#
# Usage:
#   list-refinement-children.zsh --repo <owner/name> --epic <N>

emulate -L zsh
set -euo pipefail

local subissues_bin="${SUBISSUES_BIN:-${0:A:h}/../../resolve-issue/scripts/read-sub-issues.zsh}"

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
[[ -x "$subissues_bin" || -f "$subissues_bin" ]] \
  || { print -u2 "list-refinement-children.zsh: shared reader not found: $subissues_bin"; exit 3; }

# The epic's native children (guard the read — a reader failure must be the
# documented runtime exit 3, not a bare set -e abort).
local children_json
children_json="$(zsh "$subissues_bin" --repo "$repo" --epic "$epic")" \
  || { print -u2 "list-refinement-children.zsh: failed to read sub-issues of epic #$epic from $repo"; exit 3; }

# The OPEN children, in sub-issue order (the reader already carries state, so
# closed children never cost a per-child fetch). Guard the extraction: a
# reader-shape drift must be the documented runtime exit 3, not jq's raw
# status leaking through set -e.
local -a children
children=("${(@f)$(print -r -- "$children_json" | jq -r '.open_children[]')}") \
  || { print -u2 "list-refinement-children.zsh: unexpected reader output for epic #$epic"; exit 3; }

# Keep the ones carrying the needs-refinement label, in order.
# Declare `meta` ONCE up front — re-declaring `local` inside the loop echoes the
# parameter at script (non-function) scope in zsh, polluting stdout.
# A SINGLE child's failed label fetch is skipped (a deleted/transferred child
# must not halt the walk) — but when EVERY fetch failed, that's a systemic gh
# failure (auth, network, rate limit), and reporting "no refinable children"
# would be a false terminal case: exit 3 instead.
local n meta
local -i checked=0 failed=0
for n in "${children[@]}"; do
  [[ -n "$n" ]] || continue
  (( checked += 1 ))
  meta="$(gh issue view "$n" --repo "$repo" --json labels 2>/dev/null)" \
    || { print -u2 "list-refinement-children.zsh: skipping #$n (label fetch failed)"; (( failed += 1 )); continue; }
  # Use an `if` (not `&& print`): a non-qualifying child makes jq exit 1, and a
  # bare `&& print` compound would then trip `set -e` and abort the whole walk.
  if print -r -- "$meta" | jq -e '
       (.labels // []) | any(.name == "needs-refinement")' >/dev/null 2>&1; then
    print -r -- "$n"
  fi
done
if (( checked > 0 && failed == checked )); then
  print -u2 "list-refinement-children.zsh: every child's label fetch failed — gh outage or auth failure, not an empty epic"
  exit 3
fi
