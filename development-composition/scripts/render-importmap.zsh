#!/usr/bin/env zsh
# render-importmap.zsh — render each environment's /importmap.json from a
# composition repo's `.claude-workspace.yaml` (issue #2660, epic #1122).
#
# The SPA shell (#1124) fetches /importmap.json once per page load and resolves a
# remote's bare specifier through it. This script derives that map entirely from
# the manifest, so a member's image tag stays the only version pin: a remote is
# upgraded by bumping its tag, never by editing the map. The derivation is the
# `claude-workspace/v1` contract's (ARCHITECTURE.md): specifier = member name,
# path = /ui/<name>/remote.js, one entry per `mfe-remote` member in declaration
# order, and nothing else — no image tag or digest ever reaches the map.
#
# It judges the manifest with validate-workspace.zsh FIRST and keeps that
# script's typed exits, writing nothing unless the manifest is valid:
#
#   0  every deploy/<env>/importmap.json was written (one line per file on stdout)
#   1  the manifest violates claude-workspace/v1 — the validator's named error,
#      verbatim on stderr — or an environment name is not a usable directory name
#   2  usage error (bad flag, missing value)
#   3  a required tool is missing or unusable, or a file could not be written
#   4  the manifest file does not exist, or cannot be read
#
# Usage:
#   render-importmap.zsh [--manifest <path>] [--repo <dir>]
#
#   --manifest  the manifest to render from (default: <repo>/.claude-workspace.yaml)
#   --repo      the repo root (default: the current directory)
#
# The maps are written beside the manifest: <manifest's directory>/deploy/<env>/.
# Output is deterministic — the same manifest always renders the same bytes.
emulate -L zsh
setopt err_exit nounset pipefail

readonly SELF="render-importmap.zsh"
readonly VALIDATOR="${0:A:h}/validate-workspace.zsh"

repo="."
manifest=""

need_value() {   # $1 = flag name, $2 = the candidate value (may be absent)
    [[ $# -eq 2 && -n "$2" && "$2" != -* ]] || {
        print -r -u2 -- "$SELF: $1 needs a value"
        exit 2
    }
}

while (( $# > 0 )); do
    case "$1" in
    --manifest)
        need_value --manifest "${@:2:1}"
        manifest="$2"; shift 2 ;;
    --repo)
        need_value --repo "${@:2:1}"
        repo="$2"; shift 2 ;;
    -h|--help)
        print -r -- "usage: $SELF [--manifest <path>] [--repo <dir>]"; exit 0 ;;
    *)
        print -r -u2 -- "$SELF: unknown flag: $1"; exit 2 ;;
    esac
done

[[ -n "$manifest" ]] || manifest="$repo/.claude-workspace.yaml"

# The validator's stderr passes through untouched; its stdout success line is
# not this script's output.
rc=0
zsh "$VALIDATOR" --manifest "$manifest" >/dev/null || rc=$?
case "$rc" in
0) : ;;
1|2|3|4) exit "$rc" ;;
*) exit 3 ;;
esac

doc="$(yq -o=json '.' "$manifest" 2>/dev/null)" || {
    print -r -u2 -- "$SELF: required tool unusable: yq could not re-read $manifest"
    exit 3
}

map="$(jq '{imports: (reduce (.members[] | select(.role == "mfe-remote") | .name) as $n
             ({}; . + {($n): ("/ui/" + $n + "/remote.js")}))}' <<< "$doc")" || {
    print -r -u2 -- "$SELF: required tool unusable: jq"
    exit 3
}

envs="$(jq -r '.environments | keys_unsorted[]' <<< "$doc")"
typeset -a env_names=("${(@f)envs}")

# An environment name becomes a directory under deploy/, so it must be one
# plain path segment — never empty, `.`, `..` or anything carrying a `/`.
for env_name in "${env_names[@]}"; do
    [[ "$env_name" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] \
        || { print -r -u2 -- "$SELF: $manifest: environment '$env_name': name is not a usable directory name"; exit 1; }
done

out_root="${manifest:h}/deploy"
for env_name in "${env_names[@]}"; do
    target="$out_root/$env_name/importmap.json"
    { mkdir -p "${target:h}" && print -r -- "$map" > "$target"; } 2>/dev/null || {
        print -r -u2 -- "$SELF: could not write $target"
        exit 3
    }
    print -r -- "wrote ${target#${manifest:h}/}"
done
