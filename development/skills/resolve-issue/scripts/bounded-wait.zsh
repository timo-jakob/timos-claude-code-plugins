#!/usr/bin/env zsh
# bounded-wait.zsh — one bounded wait of a human-started resolve-issue chain's
# root on something only another party can finish (#3078, epic #3073).
#
# Why: two orchestrator rules used to stop the run on a wait a human then had
# to end by re-invoking: an open foreign blocker (blockers-first.md step 2) and
# a queue entry's PR that cannot merge without a human (checkpoint.md, the chain
# queue's step 3). Both now first watch the thing under a bounded wait. The root
# runs this script as the command of ONE Monitor call, so it prints exactly one
# line, when the wait ends, and nothing while it polls.
#
# Usage:
#   bounded-wait.zsh issue --repo OWNER/NAME --issue M [--timeout-s S] [--interval-s I]
#       Wait for issue M of OWNER/NAME to close: `gh issue view M --repo
#       OWNER/NAME --json state`.
#   bounded-wait.zsh pr    --repo OWNER/NAME --pr P    [--timeout-s S] [--interval-s I]
#       Wait for PR P to merge: `gh pr view P --repo OWNER/NAME --json state`.
#
# The first read is taken at once, so a thing already closed or merged waits
# not at all. Later reads come every --interval-s seconds (default 60) until
# --timeout-s seconds (default 1740, which leaves a 30-minute Monitor call a
# minute of margin) have passed since the start. A read that fails, or that
# returns a state this script does not know, is skipped and the wait goes on.
#
# Output: one JSON line,
#   {"kind":"issue|pr","ref":"OWNER/NAME#N","result":R,"reads":n,"waited_s":s}
# where R is one of:
#   already-closed / already-merged  the first read found it closed / merged
#   closed / merged                  a later read did
#   closed-unmerged                  (pr) the PR was closed without merging
#   timeout                          the bound passed with it still open
#   unreadable                       the bound passed with no read succeeding
#
# Exit codes: 0 closed or merged (already- included) · 1 internal (gh or jq
# missing, or unreadable) · 2 usage · 3 timeout · 4 closed-unmerged
emulate -L zsh
setopt err_return no_unset pipe_fail
zmodload zsh/datetime

local usage="usage: bounded-wait.zsh issue|pr --repo OWNER/NAME --issue M|--pr P [--timeout-s S] [--interval-s I]"

_need_val() { [[ $2 -ge 2 && -n "$3" ]] || { print -u2 -- "bounded-wait: $1 needs a value"; exit 2 } }
_num() { [[ "$2" == <-> && "$2" != 0* ]] || { print -u2 -- "bounded-wait: $1 must be a positive number (got: $2)"; exit 2 } }
_secs() { [[ "$2" == <-> ]] || { print -u2 -- "bounded-wait: $1 must be a whole number of seconds (got: $2)"; exit 2 } }

(( $# > 0 )) || { print -u2 -- "$usage"; exit 2 }
local kind="$1"; shift
case "$kind" in
  issue|pr) ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  *) print -u2 -- "bounded-wait: unknown subcommand: $kind"; print -u2 -- "$usage"; exit 2 ;;
esac

local repo="" num="" timeout_s=1740 interval_s=60
while (( $# > 0 )); do
  case "$1" in
  --repo) _need_val "$1" $# "${2:-}"; repo="$2"; shift 2 ;;
  --issue) [[ "$kind" == issue ]] || { print -u2 -- "bounded-wait: --issue is not a flag of pr"; exit 2 }
    _need_val "$1" $# "${2:-}"; num="$2"; shift 2 ;;
  --pr) [[ "$kind" == pr ]] || { print -u2 -- "bounded-wait: --pr is not a flag of issue"; exit 2 }
    _need_val "$1" $# "${2:-}"; num="$2"; shift 2 ;;
  --timeout-s) _need_val "$1" $# "${2:-}"; timeout_s="$2"; shift 2 ;;
  --interval-s) _need_val "$1" $# "${2:-}"; interval_s="$2"; shift 2 ;;
  -*) print -u2 -- "bounded-wait: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "bounded-wait: unexpected argument: $1"; exit 2 ;;
  esac
done

[[ -n "$repo" && -n "$num" ]] || { print -u2 -- "$usage"; exit 2 }
[[ "$repo" =~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ]] || {
  print -u2 -- "bounded-wait: --repo must be OWNER/NAME (got: $repo)"; exit 2 }
_num "--$kind" "$num"
_secs --timeout-s "$timeout_s"
_secs --interval-s "$interval_s"

command -v gh >/dev/null 2>&1 || { print -u2 -- "bounded-wait: gh not found on PATH"; exit 1 }
command -v jq >/dev/null 2>&1 || { print -u2 -- "bounded-wait: jq not found on PATH"; exit 1 }

local start=$EPOCHSECONDS reads=0 ok_reads=0 left=0 state="" result=""
_read() {
  local out=""
  if [[ "$kind" == issue ]]; then
    out=$(gh issue view "$num" --repo "$repo" --json state 2>/dev/null) || return 1
  else
    out=$(gh pr view "$num" --repo "$repo" --json state 2>/dev/null) || return 1
  fi
  print -r -- "$out" | jq -er '.state | select(type == "string")' 2>/dev/null
}

while true; do
  (( reads += 1 ))
  state=$(_read) || state=""
  case "$kind:$state" in
    issue:CLOSED) result=closed ;;
    pr:MERGED) result=merged ;;
    pr:CLOSED) result=closed-unmerged ;;
    issue:OPEN|pr:OPEN) ;;
    *) state="" ;;
  esac
  [[ -n "$state" ]] && (( ok_reads += 1 ))
  if [[ -n "$result" ]]; then
    (( reads == 1 )) && [[ "$result" != closed-unmerged ]] && result="already-$result"
    break
  fi
  left=$(( start + timeout_s - EPOCHSECONDS ))
  if (( left <= 0 )); then
    (( ok_reads > 0 )) && result=timeout || result=unreadable
    break
  fi
  sleep $(( interval_s < left ? interval_s : left ))
done

jq -nc --arg k "$kind" --arg ref "$repo#$num" --arg r "$result" --argjson n "$reads" \
  --argjson w "$(( EPOCHSECONDS - start ))" '{kind: $k, ref: $ref, result: $r, reads: $n, waited_s: $w}'
case "$result" in
  already-*|closed|merged) exit 0 ;;
  timeout) exit 3 ;;
  closed-unmerged) exit 4 ;;
  *) exit 1 ;;
esac
