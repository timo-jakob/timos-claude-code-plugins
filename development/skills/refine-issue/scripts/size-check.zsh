#!/usr/bin/env zsh
# size-check.zsh — judge a story's DECLARED inventory with the size pre-flight
# while a human is still present: at the readiness gate and in refinement
# (#2589, epic #2582).
#
# resolve-issue §2 runs the size pre-flight just before implementation, when the
# human who refined the story has usually left. This script lets `story-readiness`
# and `/development:refine-issue` ask the same question earlier, where correcting
# a story's shape costs one question instead of review rounds.
#
# It is a thin wrapper, on purpose: it calls resolve-issue's
# `scripts/size-preflight.zsh` and passes that script's verdict and exit code
# through unchanged. It holds no threshold of its own and restates none, so
# retuning the pre-flight retunes every caller. The one thing it adds is the
# SKIPPED case: an inventory whose `files` array is empty — the caller could not
# name a single concrete path — prints `{"verdict":"skipped"}` and exits 0. A
# story the caller cannot inventory is never stopped by size; §2's pre-flight
# remains the backstop.
#
# Inventory shape: the same as size-preflight.zsh's — exactly one JSON object,
#   { "files": ["development/agents/story-readiness.md", …], "plugins": [...] }
# Anything other than an empty `files` array is handed to the pre-flight as-is,
# so a malformed inventory gets the pre-flight's own diagnosis and exit 3.
#
# Run it from the repository root: the pre-flight reads the plugin roster from
# `.claude-plugin/marketplace.json` under the current directory unless
# --manifest names another.
#
# Exit codes (the pre-flight's, passed through):
#   0 — pass, or skipped (empty `files`); the verdict is on stdout.
#   1 — stop: a threshold was crossed; the verdict on stdout names the triggers.
#   2 — usage error. Nothing on stdout.
#   3 — runtime error: invalid JSON, a malformed inventory, jq missing, or the
#       pre-flight script not found. Nothing on stdout.
# Exits 2 and 3 never mean pass — never read an empty document as one.
#
# Usage:
#   size-check.zsh --file <inventory.json> [--manifest <marketplace.json>]
#   size-check.zsh [--manifest <marketplace.json>] < inventory.json

emulate -L zsh
set -uo pipefail

local -r preflight="${0:A:h}/../../resolve-issue/scripts/size-preflight.zsh"

local file="" manifest=""
while (( $# > 0 )); do
  case "$1" in
    --file|--manifest)
      (( $# >= 2 )) && [[ -n "$2" ]] \
        || { print -u2 "size-check.zsh: $1 needs a value"; exit 2; }
      if [[ "$1" == --file ]]; then file="$2"; else manifest="$2"; fi
      shift 2 ;;
    -h|--help)
      print -u2 -r -- "usage: size-check.zsh [--file <inventory.json>] [--manifest <marketplace.json>]  (else reads stdin)"
      print -u2 -r -- "exit 0 pass or skipped, 1 stop (verdict on stdout for both), 2 usage, 3 runtime."
      exit 0 ;;
    *) print -u2 "size-check.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -n "$file" ]]; then
  [[ -f "$file" && -r "$file" ]] \
    || { print -u2 "size-check.zsh: inventory not found or unreadable: $file"; exit 2; }
else
  [[ ! -t 0 ]] || { print -u2 "size-check.zsh: no --file and stdin is a terminal"; exit 2; }
fi
command -v jq >/dev/null 2>&1 || { print -u2 "size-check.zsh: jq not found on PATH"; exit 3; }
[[ -f "$preflight" && -r "$preflight" ]] \
  || { print -u2 "size-check.zsh: size pre-flight not found: $preflight"; exit 3; }

local inv
if [[ -n "$file" ]]; then
  inv="$(<"$file")" || { print -u2 "size-check.zsh: failed to read $file"; exit 3; }
else
  inv="$(cat)" || { print -u2 "size-check.zsh: failed to read stdin"; exit 3; }
fi

# Skipped only for one exact shape — one object whose `files` is an empty
# array. Every other input, valid or not, goes to the pre-flight to judge.
if print -r -- "$inv" \
    | jq -se 'length == 1 and (.[0] | type == "object" and (.files | type) == "array"
              and (.files | length) == 0)' >/dev/null 2>&1; then
  print -r -- '{"verdict":"skipped"}'
  exit 0
fi

local -a args=()
[[ -z "$manifest" ]] || args=(--manifest "$manifest")
print -r -- "$inv" | zsh "$preflight" "${args[@]}"
exit $?
