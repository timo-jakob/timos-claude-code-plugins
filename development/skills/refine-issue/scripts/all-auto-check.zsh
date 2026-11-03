#!/usr/bin/env zsh
# all-auto-check.zsh — is a whole refinement run ALL-AUTO (#2938)? An all-auto
# refinement is written back with no approval prompt; any other one still
# presents the exact rewrite for the human's approval before Step 3.
#
# A refinement is all-auto when, across the whole run, every round's
# split-refiner-questions.zsh ask set (intent and gap questions only — an
# implementation question is never asked) was empty, every size check passed or
# was skipped, and no round's issue-refiner turn carried a non-null
# proposed_split. The conductor keeps the files; this script decides, so the
# rule is stated once and never judged by eye.
#
# Inputs — three repeatable flags, one file per round or per sizing:
#   --split <split.json>       each round's split-refiner-questions.zsh output:
#                              one JSON object whose `auto` and `ask` are arrays
#   --turn <turn.json>         each round's raw issue-refiner turn, the file the
#                              conductor writes before splitting: one JSON object
#                              whose `questions` is an array; a missing
#                              `proposed_split` reads as null
#   --size-check <verdict.json> each size-check.zsh stdout of the run: one JSON
#                              object whose `verdict` is pass, skipped, stop or
#                              unjudged. size-check.zsh prints nothing on exit 3
#                              or a second exit 2, so for such a sizing the
#                              conductor writes the one-line file
#                              {"verdict":"unjudged"} and passes that.
#
# The conditions, checked in this order; the first that fails is the reason:
#   1. no-rounds            no --split file was given
#   2. ask-question         any split file has a non-empty ask set
#   3. size-check-stop      any --size-check verdict is stop
#   4. size-check-unjudged  any --size-check verdict is unjudged
#   5. proposed-split       any --turn file has a non-null proposed_split
#   6. all-auto             none of the above
# pass and skipped count as passed. Every file is validated before any is
# judged, so a malformed file is exit 2 whatever the verdict would have been.
#
# Usage:  all-auto-check.zsh [--split <f>]… [--turn <f>]… [--size-check <f>]…
# Output: one JSON object on stdout: {"all_auto": true|false, "reason": "<reason>"}
# Exit:   0 judged — any valid input, whatever the verdict (no flags at all is
#           no-rounds);
#         2 usage error (an unknown flag, a flag without a value, a file that is
#           missing or unreadable), or a split, turn or verdict file that is not
#           the expected JSON shape, a verdict outside the four included. The
#           file is named on stderr, and nothing is printed on stdout. jq
#           missing from PATH is exit 2 too: nothing could be judged.
#         2 also when any --split is given and the call is incomplete: the
#           --turn count differs from the --split count (one turn per round),
#           or no --size-check is given (every converged draft was sized). A
#           file the conductor forgot can never read as all-auto; stderr names
#           the counts. With no --split at all the result stays no-rounds.

emulate -L zsh
setopt no_unset pipe_fail

usage() {
  print -r -u2 -- "usage: all-auto-check.zsh [--split <split.json>]… [--turn <turn.json>]… [--size-check <verdict.json>]…"
}

local -a splits turns sizes
while (( $# > 0 )); do
  case "$1" in
    --split|--turn|--size-check)
      (( $# >= 2 )) && [[ -n "$2" ]] || {
        print -r -u2 -- "all-auto-check: $1 needs a file"; usage; exit 2 }
      [[ -f "$2" && -r "$2" ]] || {
        print -r -u2 -- "all-auto-check: $1 file missing or unreadable: $2"; exit 2 }
      case "$1" in
        --split) splits+=("$2") ;;
        --turn)  turns+=("$2") ;;
        *)       sizes+=("$2") ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) print -r -u2 -- "all-auto-check: unknown argument: $1"; usage; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { print -r -u2 -- "all-auto-check: jq not found on PATH"; exit 2 }

# Validate every file first. Each check reads exactly one JSON document.
local f
for f in "${splits[@]}"; do
  jq -e -s 'length == 1 and (.[0] | type == "object")
            and ((.[0].auto // null) | type == "array")
            and ((.[0].ask // null) | type == "array")' "$f" >/dev/null 2>&1 || {
    print -r -u2 -- "all-auto-check: --split is not one JSON object with auto and ask arrays: $f"; exit 2 }
done
for f in "${turns[@]}"; do
  jq -e -s 'length == 1 and (.[0] | type == "object")
            and ((.[0].questions // null) | type == "array")' "$f" >/dev/null 2>&1 || {
    print -r -u2 -- "all-auto-check: --turn is not one JSON object with a questions array: $f"; exit 2 }
done
for f in "${sizes[@]}"; do
  jq -e -s 'length == 1 and (.[0] | type == "object")
            and ((.[0].verdict // null) | IN("pass", "skipped", "stop", "unjudged"))' "$f" >/dev/null 2>&1 || {
    print -r -u2 -- "all-auto-check: --size-check is not one JSON object whose verdict is pass, skipped, stop or unjudged: $f"; exit 2 }
done

# A forgotten file fails closed: an incomplete call is a usage error, never all-auto.
if (( ${#splits} > 0 )); then
  (( ${#turns} == ${#splits} )) || {
    print -r -u2 -- "all-auto-check: one --turn per --split: got ${#splits} --split and ${#turns} --turn"; exit 2 }
  (( ${#sizes} >= 1 )) || {
    print -r -u2 -- "all-auto-check: --split given but no --size-check: got ${#splits} --split and 0 --size-check"; exit 2 }
fi

# Judge, in the documented order.
local reason="all-auto" v
verdict_seen() {  # $1 = verdict; true when any --size-check file carries it
  for v in "${sizes[@]}"; do
    [[ "$(jq -r '.verdict' "$v")" == "$1" ]] && return 0
  done
  return 1
}
any_ask() {
  for v in "${splits[@]}"; do
    jq -e '.ask | length > 0' "$v" >/dev/null && return 0
  done
  return 1
}
any_split() {
  for v in "${turns[@]}"; do
    jq -e '.proposed_split != null' "$v" >/dev/null && return 0
  done
  return 1
}

if (( ${#splits} == 0 )); then reason="no-rounds"
elif any_ask; then reason="ask-question"
elif verdict_seen stop; then reason="size-check-stop"
elif verdict_seen unjudged; then reason="size-check-unjudged"
elif any_split; then reason="proposed-split"
fi

jq -nc --arg r "$reason" '{all_auto: ($r == "all-auto"), reason: $r}'
