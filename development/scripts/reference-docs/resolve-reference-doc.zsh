#!/usr/bin/env zsh
# Where does a reference document live, and which pinned version of it is
# read? (#3351, child 1 of #3198.)
#
#   resolve-reference-doc.zsh [--repo-dir <dir>] <relative-path>
#
# The lookup is resolve-product-doc.zsh beside this script, a byte-identical
# copy of the `product` plugin's own lookup (ARCHITECTURE.md, *Linked
# reference documents*): the repo's own file wins, otherwise the first
# submodule declared in `.gitmodules` that holds the file at the same relative
# path. This script adds the pinned version of a linked hit: the commit of the
# gitlink the superproject's `HEAD` records for that submodule, never whatever
# happens to be checked out. `--repo-dir` defaults to the current directory.
#
# stdout on success, one JSON object:
#   {"path": "<absolute path>", "origin": "own" | "linked",
#    "submodule": null | "<submodule path>",
#    "pinned_commit": null | "<full SHA of the gitlink HEAD records>"}
#
# Exit codes (2 to 6 print nothing on stdout):
#   0 found
#   1 internal failure: git or jq missing, a `.gitmodules` git cannot read, or a
#     linked hit with no pinned version — the submodule's gitlink is not
#     committed in HEAD yet (stderr names the uncommitted link), or the
#     submodule's checkout cannot be read
#   2 usage error
#   3 not found
#   4 a declared submodule is not initialised (stderr names it and the
#     `git submodule update --init` line)
#   5 the path lies under a submodule's mount
#   6 the submodule holding the file is checked out at a commit other than the
#     pinned one (stderr names both short SHAs and the
#     `git submodule update --init -- <path>` line)

emulate -L zsh
set -uo pipefail

local me="${0:t}"
local lookup="${0:A:h}/resolve-product-doc.zsh"

usage() {
  print -r -- "usage: $me [--repo-dir <dir>] <relative-path>" >&2
  exit 2
}

local repo="$PWD" rel=""
local -i have_rel=0
while (( $# > 0 )); do
  case "$1" in
    --repo-dir)
      (( $# >= 2 )) && [[ -n "$2" ]] || { print -r -- "$me: --repo-dir needs a value" >&2; usage; }
      repo="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: $me [--repo-dir <dir>] <relative-path>"
      exit 0 ;;
    -*) print -r -- "$me: unknown flag: $1" >&2; usage ;;
    *)
      (( have_rel == 0 )) || { print -r -- "$me: more than one path given" >&2; usage; }
      rel="$1"; have_rel=1; shift ;;
  esac
done

(( have_rel == 1 )) && [[ -n "$rel" ]] || { print -r -- "$me: a relative path is required" >&2; usage; }
[[ -d "$repo" ]] || { print -r -- "$me: --repo-dir is not a directory: $repo" >&2; usage; }
command -v jq >/dev/null 2>&1 || { print -r -- "$me: jq is not on PATH" >&2; exit 1; }
[[ -r "$lookup" ]] || { print -r -- "$me: the lookup is missing: $lookup" >&2; exit 1; }

# The lookup owns exits 2 to 5 and its own stderr; they pass through as they are.
local hit
local -i rc=0
hit="$(zsh "$lookup" --repo "$repo" "$rel")" || rc=$?
(( rc == 0 )) || exit "$rc"

local path_abs="${hit%%$'\t'*}" origin="${hit#*$'\t'}"
if [[ "$origin" == own ]]; then
  jq -cn --arg path "$path_abs" '{path: $path, origin: "own", submodule: null, pinned_commit: null}'
  exit 0
fi
[[ "$origin" == linked:?* ]] || { print -r -- "$me: unexpected lookup answer: $hit" >&2; exit 1; }
local sub="${origin#linked:}"

repo="${repo:A}"
command -v git >/dev/null 2>&1 || { print -r -- "$me: git is not on PATH" >&2; exit 1; }

# The pinned version: the gitlink (mode 160000) HEAD records at the submodule's
# path. --literal-pathspecs: a path holding glob characters names only itself.
local entry pinned=""
entry="$(git -C "$repo" --literal-pathspecs ls-tree -z HEAD -- "$sub" 2>/dev/null)" || entry=""
entry="${entry%%$'\0'*}"
if [[ "$entry" == "160000 commit "* ]]; then
  pinned="${${entry#160000 commit }%%$'\t'*}"
fi
if [[ ! "$pinned" =~ '^[0-9a-f]{40}([0-9a-f]{24})?$' ]]; then
  print -r -- "$me: $sub has no pinned version: HEAD in $repo records no gitlink for it" >&2
  print -r -- "  the link is not committed yet; commit it (git add -- ${(q-)sub}) before reading from it" >&2
  exit 1
fi

# The version checked out in the submodule. Its own work tree must answer, never
# the superproject's, which a directory with no checkout of its own would reach.
local dir="$repo/$sub" top checked=""
top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
if [[ -n "$top" && "${top:A}" == "${dir:A}" ]]; then
  checked="$(git -C "$dir" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" || checked=""
fi
if [[ -z "$checked" ]]; then
  print -r -- "$me: cannot read the commit checked out in submodule $sub" >&2
  print -r -- "  run: git submodule update --init -- ${(q-)sub}" >&2
  exit 1
fi
if [[ "$checked" != "$pinned" ]]; then
  print -r -- "reference-doc: submodule $sub is checked out at ${checked[1,12]}, not at its pinned ${pinned[1,12]}" >&2
  print -r -- "  run: git submodule update --init -- ${(q-)sub}" >&2
  exit 6
fi

jq -cn --arg path "$path_abs" --arg sub "$sub" --arg pin "$pinned" \
  '{path: $path, origin: "linked", submodule: $sub, pinned_commit: $pin}'
