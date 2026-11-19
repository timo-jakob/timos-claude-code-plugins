#!/usr/bin/env zsh
# Where does a product document live? In the repo itself, or in the first
# linked submodule that carries it at the same relative path (#3203).
#
#   resolve-product-doc.zsh [--repo <dir>] <relative-path>
#
# The rule (ARCHITECTURE.md, *The `product` plugin*): the repo's own file wins;
# otherwise the submodules declared in `.gitmodules` are tried in file order and
# the first one holding the file wins. There is no configuration. A repo with no
# `.gitmodules` is simply `own` or not found. `--repo` defaults to the current
# directory; it need not be a git repository, because `.gitmodules` is read as a
# plain config file.
#
# A declared submodule counts as initialised when its directory exists and is
# non-empty. When the walk reaches an uninitialised one before any hit, the
# answer is unknowable — that submodule might hold the file, and it would win
# over every later one — so the script stops there with exit 4 rather than
# reporting a later hit or "not found".
#
# stdout on success, one line, tab-separated:
#   <absolute path>\t<origin>     origin: `own` or `linked:<submodule path>`
#
# Exit codes:
#   0 found
#   1 internal failure: git missing, or a `.gitmodules` git cannot read
#   2 usage error
#   3 not found          (stderr: `product-doc: not found: <relative-path>`)
#   4 a declared submodule is not initialised and no earlier location had the
#     file (stderr names it and the `git submodule update --init` line)

emulate -L zsh
setopt extended_glob
set -uo pipefail

local me="${0:t}"

usage() {
  print -r -- "usage: $me [--repo <dir>] <relative-path>" >&2
  exit 2
}

local repo="$PWD" rel=""
local -i have_rel=0
while (( $# > 0 )); do
  case "$1" in
    --repo)
      (( $# >= 2 )) && [[ -n "$2" ]] || { print -r -- "$me: --repo needs a value" >&2; usage; }
      repo="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: $me [--repo <dir>] <relative-path>"
      exit 0 ;;
    -*) print -r -- "$me: unknown flag: $1" >&2; usage ;;
    *)
      (( have_rel == 0 )) || { print -r -- "$me: more than one path given" >&2; usage; }
      rel="$1"; have_rel=1; shift ;;
  esac
done

(( have_rel == 1 )) && [[ -n "$rel" ]] || { print -r -- "$me: a relative path is required" >&2; usage; }
[[ "$rel" != /* ]] || { print -r -- "$me: the path must be relative to the repo: $rel" >&2; usage; }
[[ -d "$repo" ]] || { print -r -- "$me: --repo is not a directory: $repo" >&2; usage; }

repo="${repo:A}"

# The declared submodules, in .gitmodules file order.
local gm="$repo/.gitmodules"
local -a subs=()
if [[ -f "$gm" ]]; then
  command -v git >/dev/null 2>&1 || { print -r -- "$me: git is not on PATH" >&2; exit 1; }
  local raw entry
  local -i rc=0
  # --null: each entry is `<key>\n<value>\0`, so a name or path holding spaces
  # never splits. Exit 1 is "no submodule.*.path key", which means no
  # submodules; any other non-zero is a file git rejects.
  raw="$(git config --null -f "$gm" --get-regexp '^submodule\..*\.path$')" || rc=$?
  if (( rc != 0 && rc != 1 )); then
    print -r -- "$me: cannot read $gm (git config exit $rc)" >&2
    exit 1
  fi
  for entry in "${(@0)raw}"; do
    entry="${${entry#*$'\n'}%/}"
    [[ -n "$entry" ]] && subs+=( "$entry" )
  done
fi

# 1. The repo's own file wins, unless it lies inside a declared submodule:
#    then it is that submodule's file.
local sub dir origin="own"
for sub in "${subs[@]}"; do
  [[ "$rel" == "$sub"/* ]] && { origin="linked:$sub"; break; }
done
if [[ -f "$repo/$rel" ]]; then
  print -r -- "$repo/$rel"$'\t'"$origin"
  exit 0
fi

# 2. Otherwise the first declared submodule holding the file wins.
local -a full
for sub in "${subs[@]}"; do
  dir="$repo/$sub"
  # (NF): the directory itself, only when it is a non-empty directory
  full=( "$dir"(NF) )
  if (( ${#full} == 0 )); then
    print -r -- "product-doc: submodule not initialised: $sub" >&2
    print -r -- "  it may hold $rel; run: git submodule update --init -- ${(q-)sub}" >&2
    exit 4
  fi
  if [[ -f "$dir/$rel" ]]; then
    print -r -- "${dir:A}/$rel"$'\t'"linked:$sub"
    exit 0
  fi
done

print -r -- "product-doc: not found: $rel" >&2
exit 3
