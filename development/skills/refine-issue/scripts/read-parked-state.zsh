#!/usr/bin/env zsh
# read-parked-state.zsh — extract the resume state from a parked refine-issue
# comment (#578, epic #573).
#
# The companion to build-parked-comment.zsh: on a resuming /development:refine-issue
# run, Step 0 reads the issue's comments and feeds the parked state back into the
# refiner's `conversation` so the session continues instead of restarting. This
# is the robust extractor for that state — pulling the hidden
# `<!-- refine-parked-state: {…} -->` JSON out of the comment text.
#
# It reads comment text from `--file <path>` or stdin (typically the
# concatenated bodies of an issue's comments, or a single comment), finds every
# `<!-- refine-parked-state: … -->` marker, and prints the JSON from the LAST one
# (the most recent park wins) as a compact object to stdout.
#
# Exit codes:
#   0 — a parked-state marker was found and printed (valid JSON on stdout)
#   1 — the INPUT contained no parked marker (not an error; the caller starts a
#       fresh session). This only means "never parked" when the caller knows the
#       input was produced successfully: an empty input is indistinguishable
#       here, so a failed upstream `gh` — or the unreadable-file leak noted
#       under exit 3 — also lands on 1, and treating that as a fresh session
#       would overwrite a real park. Callers piping `gh` should fail the pipe
#       themselves before reading this status.
#   2 — usage error
#   3 — runtime error (the named --file is not a regular file, jq missing,
#       marker present but its payload is not valid JSON). NOT every I/O
#       failure: the guard below is `-f`, so an existing-but-unreadable file
#       passes it and the later read aborts under errexit as 1.
#
# Usage:
#   read-parked-state.zsh --file <comments.md>
#   gh issue view <N> --json comments -q '.comments[].body' | read-parked-state.zsh

emulate -L zsh
set -euo pipefail

local file=""
while (( $# > 0 )); do
  case "$1" in
    --file)
      (( $# >= 2 )) || { print -u2 "read-parked-state.zsh: --file needs a value"; exit 2; }
      file="$2"; shift 2 ;;
    -h|--help)
      print -r -- "usage: read-parked-state.zsh [--file <comments.md>]  (else reads stdin)"
      print -r -- "prints the latest refine-parked-state JSON; exit 1 when none present."
      exit 0 ;;
    *) print -u2 "read-parked-state.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -z "$file" || -f "$file" ]] || { print -u2 "read-parked-state.zsh: file not found: $file"; exit 3; }
command -v jq >/dev/null 2>&1 || { print -u2 "read-parked-state.zsh: jq not found on PATH"; exit 3; }

local text
if [[ -n "$file" ]]; then text="$(<"$file")"; else text="$(cat)"; fi

# Find the marker LINES themselves first (so an empty/whitespace payload on the
# newest marker is still detected — command substitution would otherwise drop a
# trailing blank line and silently resurrect an older park). No marker at all →
# the issue was never parked, so this is a fresh session (exit 1), not an error.
local markers
markers="$(print -r -- "$text" | grep '<!-- refine-parked-state:' || true)"
[[ -n "$markers" ]] || exit 1   # never parked — fresh session

# The most recent park is the LAST marker line; extract its payload (greedy up to
# the final `-->` so a payload string containing '-->' round-trips).
local lastmarker="${markers##*$'\n'}"
local last
last="$(print -r -- "$lastmarker" \
  | sed -n 's/^[[:space:]]*<!-- refine-parked-state:[[:space:]]*\(.*\)-->[[:space:]]*$/\1/p')"
# Trim trailing whitespace the capture kept before the closing -->.
last="${last%"${last##*[![:space:]]}"}"

# A marker is present but its payload is empty or not valid JSON → corrupt state,
# not a fresh session. Report it (exit 3) rather than silently discarding the park.
[[ -n "$last" ]] \
  || { print -u2 "read-parked-state.zsh: parked-state marker present but its payload is empty"; exit 3; }
print -r -- "$last" | jq -e . >/dev/null 2>&1 \
  || { print -u2 "read-parked-state.zsh: parked-state marker present but its payload is not valid JSON"; exit 3; }

print -r -- "$last" | jq -c '.'
