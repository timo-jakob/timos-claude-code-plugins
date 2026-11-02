#!/usr/bin/env zsh
# readiness-cache-plan.zsh — which stories the readiness gate runs on, and which
# take a cached verdict (#2955, epic #2953).
#
# Why: readiness-stamp.zsh `check` (#2954) says which stories carry a
# still-valid stamp. The skill then has to turn that into one decision: whom to
# gate, whose cached verdict to take, and whether the pre-flight halts on a
# dependency cycle. A cached verdict can never vouch for acyclicity, because a
# cycle can close through an edge on another story, so the cycle test runs over
# the dependency records on every run. This script makes that decision, purely:
# no network call, nothing written. resolve-issue's E1b calls it with --deps,
# and its step 0b without (0a already refused a cycle there).
#
# Usage:
#   readiness-cache-plan.zsh --targets N[,N…] [--check FILE] [--check-exit CODE]
#                            [--deps FILE]
#     --targets     the stories to judge: E1b's open leaves, or 0b's one issue
#     --check       readiness-stamp.zsh check's stdout
#     --check-exit  check's exit code (default 0)
#     --deps        JSON Lines: one read-dependencies.zsh record per target,
#                   keyed by its `issue` field
#
# On exit 0 it prints one JSON object:
#   {"fallback": bool, "fallback_reason": string|null,
#    "dispatch": [targets to gate fresh],
#    "hits": [{"issue", "verdict"}],          cached verdicts, taken as returned
#    "cycles": [[a,b,a], …],                  every cycle the records report
#    "cycle_members": [targets on a cycle],
#    "readiness_cache": {"hits", "misses", "miss_reasons": {reason: count}}}
# Every list keeps --targets order. A target lands in exactly one of dispatch,
# hits and cycle_members, so hits + misses + cycle members = targets.
#
# A target is dispatched, with its miss reason, when:
#   check_failed           --check-exit is not 0, or --check is missing, empty
#                          or not a check document. Every target not on a cycle
#                          falls back to a fresh gate, and `fallback` is true.
#                          Never a halt
#   <check's reason>       check reported it a miss (no_stamp, key_changed, …)
#   not_checked            check reported it neither a hit nor a miss
#   acyclicity_unverified  --deps was given and the target has no record, or
#                          its record has `truncated: true`: a hit cannot stand
#                          in for a cycle test that never finished
#   dependencies_recheck   check reported it a hit, but the cached verdict has
#                          `checks.dependencies_resolved: false`. The edge that
#                          resolves it, a broken cycle included, may sit on
#                          another issue and moves no stamp key, so a verdict
#                          given on dependency grounds is gated fresh, never
#                          replayed (#2965)
# A target that lies on a reported cycle, or whose own record reports one (its
# blockedBy walk reaches a cycle), is a cycle member, never dispatched and never
# a hit: the caller records it NEEDS_REFINEMENT, naming the cycle, and halts.
#
# Exit codes:
#   0  ok
#   2  usage or malformed input: a missing, unknown or empty flag; a malformed
#      target list or --check-exit; an unreadable or invalid --deps file
#   1  internal (jq missing)

emulate -L zsh
setopt nounset pipefail extended_glob

local usage="usage: readiness-cache-plan.zsh --targets N[,N…] [--check FILE] [--check-exit CODE] [--deps FILE]"

_fail() { print -ru2 -- "readiness-cache-plan: $1"; exit 2 }
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || _fail "$1 requires a value"
  [[ -n "$3" && "$3" != --* ]] || _fail "$1 requires a non-empty value"
}

local targets_arg="" check_file="" check_exit=0 deps_file="" have_targets=0
while (( $# > 0 )); do
  case "$1" in
    --targets)    _need_val "$1" $# "${2:-}"; targets_arg="$2"; have_targets=1; shift 2 ;;
    --check)      _need_val "$1" $# "${2:-}"; check_file="$2"; shift 2 ;;
    --check-exit) _need_val "$1" $# "${2:-}"; check_exit="$2"; shift 2 ;;
    --deps)       _need_val "$1" $# "${2:-}"; deps_file="$2"; shift 2 ;;
    -h|--help)    print -r -- "$usage"; exit 0 ;;
    *)            _fail "unknown argument: $1 ($usage)" ;;
  esac
done

(( have_targets )) || _fail "--targets is required ($usage)"
[[ "$targets_arg" == [1-9][0-9]#(,[1-9][0-9]#)# ]] \
  || _fail "--targets must be a comma-separated list of issue numbers: $targets_arg"
[[ "$check_exit" == (0|[1-9][0-9]#) ]] || _fail "--check-exit must be a non-negative integer: $check_exit"

command -v jq >/dev/null 2>&1 || { print -u2 "readiness-cache-plan: jq not found on PATH"; exit 1 }

local targets_json
targets_json="$(print -r -- "$targets_arg" | jq -Rc 'split(",") | map(tonumber) | unique as $u | if length != ($u | length) then error("duplicate") else . end' 2>/dev/null)" \
  || _fail "--targets lists an issue twice: $targets_arg"

# The check document, or null when it cannot be used (the fallback).
local check_json=null
if [[ "$check_exit" == 0 && -n "$check_file" && -f "$check_file" && -r "$check_file" ]]; then
  check_json="$(jq -ces '
    if length == 1 and (.[0] | type) == "object"
       and (.[0].hits | type) == "array" and (.[0].misses | type) == "array"
       and all(.[0].hits[]; (.issue | type) == "number" and (.verdict | type) == "object")
       and all(.[0].misses[]; (.issue | type) == "number" and (.reason | type) == "string")
    then .[0] else null end' "$check_file" 2>/dev/null)" || check_json=null
fi
local fallback_reason=null
if [[ "$check_json" == null ]]; then
  if [[ "$check_exit" != 0 ]]; then fallback_reason="\"check exited $check_exit\""
  elif [[ -z "$check_file" ]]; then fallback_reason='"no check document"'
  else fallback_reason='"the check document is missing, empty or not a check document"'
  fi
fi

# The dependency records, keyed by issue; null when --deps was not given.
local deps_json=null
if [[ -n "$deps_file" ]]; then
  [[ -f "$deps_file" && -r "$deps_file" ]] || _fail "--deps file missing or unreadable: $deps_file"
  deps_json="$(jq -cs '
    if all(.[]; type == "object" and (.issue | type) == "number")
    then map({key: (.issue | tostring), value: .}) | from_entries
    else error("bad record") end' "$deps_file" 2>/dev/null)" \
    || _fail "--deps is not JSON Lines of read-dependencies records: $deps_file"
fi

jq -nc --argjson targets "$targets_json" --argjson check "$check_json" \
  --argjson deps "$deps_json" --argjson fbr "$fallback_reason" '
  ($deps // {}) as $d
  | ([$d[] | (.cycles // [])[]] | unique) as $cycles
  | ([$cycles[][]] | unique) as $oncycle
  | [ $targets[] as $t
      | if ($oncycle | index($t)) != null or (($d[$t | tostring].cycles // []) | length) > 0
          then {issue: $t, cls: "cycle"}
        elif $check == null then {issue: $t, cls: "miss", reason: "check_failed"}
        elif $deps != null and (($d[$t | tostring] == null) or ($d[$t | tostring].truncated == true))
          then {issue: $t, cls: "miss", reason: "acyclicity_unverified"}
        else
          ([$check.hits[] | select(.issue == $t)] | first) as $hit
          | ([$check.misses[] | select(.issue == $t)] | first) as $miss
          | if $miss != null then {issue: $t, cls: "miss", reason: $miss.reason}
            elif $hit != null and (try $hit.verdict.checks.dependencies_resolved catch null) == false
              then {issue: $t, cls: "miss", reason: "dependencies_recheck"}
            elif $hit != null then {issue: $t, cls: "hit", verdict: $hit.verdict}
            else {issue: $t, cls: "miss", reason: "not_checked"} end
        end ] as $rows
  | [$rows[] | select(.cls == "miss")] as $misses
  | {fallback: ($check == null),
     fallback_reason: $fbr,
     dispatch: [$misses[].issue],
     hits: [$rows[] | select(.cls == "hit") | {issue, verdict}],
     cycles: $cycles,
     cycle_members: [$rows[] | select(.cls == "cycle") | .issue],
     readiness_cache: {
       hits: ([$rows[] | select(.cls == "hit")] | length),
       misses: ($misses | length),
       miss_reasons: (reduce $misses[] as $m ({}; .[$m.reason] += 1))}}'
