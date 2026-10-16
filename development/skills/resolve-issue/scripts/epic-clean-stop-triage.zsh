#!/usr/bin/env zsh
# epic-clean-stop-triage.zsh — which children an UNATTENDED epic walk resolves,
# parks or skips once a child has clean-stopped (#2585, epic #2582).
#
# Why: a clean stop (#2579) is a typed escalation, so E3's triage already keeps
# walking the children that do not depend on it. What it could not do was tell a
# clean stop from any other escalation, protect the kept work-dir from a later
# walk, or say which child a parked dependant is waiting on. This script makes
# that one decision, purely: no network call, nothing written. E3 calls it once
# before the first child and again after each child that clean-stops.
#
# Usage:
#   epic-clean-stop-triage.zsh --repo OWNER/NAME --children N[,N…] --deps FILE
#                              [--clean-stopped N[,N…]] [--marker-root DIR]
#     --children       the epic's open children, in walk order
#     --deps           JSON Lines: one read-dependencies.zsh record per child in
#                      --children, keyed by its `issue` field. A child has a
#                      path to a clean-stopped child when that child's number is
#                      in the record's `blockers[]`, at any `depth` — the reader
#                      already walked the native blockedBy graph transitively
#     --clean-stopped  the children that clean-stopped in this invocation
#     --marker-root    where the durable markers live (default
#                      $HOME/.claude/resolve-issue). Child N's marker is
#                      <marker-root>/<repo-slug>/<N>/clean-stop.json, <repo-slug>
#                      being tlm_repo_slug of --repo — the rule #2579's
#                      clean-stop.zsh uses for the durable work-dir
#
# The clean-stopped set is --clean-stopped plus every child whose marker exists.
# On exit 0 it prints one JSON object:
#   {"clean_stopped": [{"child", "marker": path|null, "resume"}],
#    "parked": [{"child", "blocked_by": [clean-stopped children it reaches,
#                                        ascending]}],
#    "skip": [the clean-stopped children, never walked],
#    "walk": [every other child],
#    "summary": [one line per clean-stopped child, then one per parked child],
#    "counts": {"clean_stopped", "parked_behind_clean_stop"}}
# Every list keeps --children order, except `blocked_by`.
#
# Exit codes:
#   0  ok
#   2  usage or malformed input: a missing, unknown or empty flag; a malformed
#      child list; an unreadable or invalid --deps file; a child with no
#      record; a --clean-stopped number not in --children
#   3  cannot decide: a record has `truncated: true` while the clean-stopped
#      set is non-empty, or no --marker-root and HOME is unset or empty. E3
#      then parks every child it has not resolved — it never walks a child it
#      cannot prove independent
#   1  internal (jq missing, the slug library cannot load)

emulate -L zsh
setopt nounset pipefail extended_glob

local self_dir="${0:A:h}"
local usage="usage: epic-clean-stop-triage.zsh --repo OWNER/NAME --children N[,N…] --deps FILE
                                  [--clean-stopped N[,N…]] [--marker-root DIR]"

_fail() { print -ru2 -- "epic-clean-stop-triage: $1"; exit 2 }
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || _fail "$1 requires a value"
  [[ -n "$3" && "$3" != --* ]] || _fail "$1 requires a non-empty value"
}

local repo="" children="" deps="" stopped="" root="" seen_stopped=0 seen_root=0
while (( $# > 0 )); do
  case "$1" in
  --repo) _need_val "$1" $# "${2:-}"; repo="$2"; shift 2 ;;
  --children) _need_val "$1" $# "${2:-}"; children="$2"; shift 2 ;;
  --deps) _need_val "$1" $# "${2:-}"; deps="$2"; shift 2 ;;
  --clean-stopped) _need_val "$1" $# "${2:-}"; stopped="$2"; seen_stopped=1; shift 2 ;;
  --marker-root) _need_val "$1" $# "${2:-}"; root="$2"; seen_root=1; shift 2 ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) _fail "unknown flag: $1" ;;
  *) _fail "unexpected argument: $1" ;;
  esac
done
[[ -n "$repo" && -n "$children" && -n "$deps" ]] || { print -ru2 -- "$usage"; exit 2 }
[[ "$repo" == [^/]##/[^/]## ]] || _fail "--repo must be OWNER/NAME (got: $repo)"

# a comma list of positive issue numbers, no duplicates
_nums() {  # $1 = flag, $2 = list; prints one number per line
  local n="" item=""
  local -A seen=()
  for item in "${(@s:,:)2}"; do
    [[ "$item" == <1-> && "$item" != 0* ]] || _fail "$1 must be a comma list of issue numbers (got: $2)"
    (( ! ${+seen[$item]} )) || _fail "$1 lists #$item twice"
    seen[$item]=1
    print -r -- "$item"
  done
}
local -a kids=() cs=()
kids=( ${(f)"$(_nums --children "$children")"} ) || exit 2
(( ${#kids} > 0 )) || _fail "--children is empty"
if (( seen_stopped )); then
  cs=( ${(f)"$(_nums --clean-stopped "$stopped")"} ) || exit 2
  local c=""
  for c in "${cs[@]}"; do
    (( ${kids[(Ie)$c]} )) || _fail "--clean-stopped #$c is not in --children"
  done
fi

[[ -f "$deps" && -r "$deps" ]] || _fail "--deps is not a readable file: $deps"
command -v jq >/dev/null 2>&1 || { print -u2 -- "epic-clean-stop-triage: jq not found on PATH"; exit 1 }
local records=""
records=$(jq -cs 'if all(.[]; type == "object" and (.issue | type) == "number"
                       and ((.blockers // []) | type) == "array")
                  then . else error("bad") end' -- "$deps" 2>/dev/null) || \
  _fail "--deps must be JSON Lines of read-dependencies.zsh records (an object with a numeric issue and a blockers array): $deps"
local kids_json="" missing=""
kids_json=$(print -rl -- "${kids[@]}" | jq -cs '.')
missing=$(jq -nr --argjson r "$records" --argjson k "$kids_json" \
  '[ $k[] | select(. as $n | ($r | map(.issue) | index($n)) == null) ] | map("#\(.)") | join(", ")')
[[ -z "$missing" ]] || _fail "--deps has no record for $missing"

# the marker root: an explicit flag, else the user-level default
if (( ! seen_root )); then
  [[ -n "${HOME:-}" ]] || {
    print -ru2 -- "epic-clean-stop-triage: no --marker-root and HOME is unset or empty — cannot look for clean-stop markers"
    exit 3 }
  root="$HOME/.claude/resolve-issue"
fi
source "${self_dir}/../../../scripts/telemetry/telemetry-sink-lib.zsh" || {
  print -u2 -- "epic-clean-stop-triage: cannot load telemetry-sink-lib.zsh"; exit 1 }
local slug=""
slug=$(tlm_repo_slug "$repo")

# markers found on disk, child by child
local -A marker=()
local k=""
for k in "${kids[@]}"; do
  [[ -f "$root/$slug/$k/clean-stop.json" ]] && marker[$k]="$root/$slug/$k/clean-stop.json"
done
local marker_json="{}"
for k in "${(@k)marker}"; do
  marker_json=$(jq -c --arg k "$k" --arg p "${marker[$k]}" '. + {($k): $p}' <<< "$marker_json")
done
local cs_json=""
cs_json=$(print -rl -- "${cs[@]}" | jq -cs 'map(select(. != null))' 2>/dev/null) || cs_json="[]"
[[ -n "$cs_json" ]] || cs_json="[]"

# One pass: the clean-stopped set in --children order, then — unless a record
# was truncated while that set is non-empty — parked (every other child whose
# blockers[] reaches a clean-stopped one), skip and walk.
local out=""
out=$(jq -nc --argjson r "$records" --argjson k "$kids_json" --argjson cs "$cs_json" \
       --argjson m "$marker_json" '
  [ $k[] | select(. as $n | ($cs | index($n)) != null or ($m | has($n | tostring))) ] as $stop
  | ($r | map({key: (.issue | tostring), value: .}) | from_entries) as $rec
  | if ($stop | length) > 0 and ([ $k[] | $rec[tostring].truncated == true ] | any)
    then {truncated: [ $k[] | select($rec[tostring].truncated == true) ]}
    else
      ([ $k[] | select(. as $n | ($stop | index($n)) == null)
         | . as $n
         | ([ ($rec[$n | tostring].blockers // [])[] | .number ] | unique) as $reach
         | { child: $n, blocked_by: ([ $stop[] | select(. as $s | ($reach | index($s)) != null) ] | sort) }
         | select(.blocked_by | length > 0) ]) as $parked
      | ($parked | map(.child)) as $pk
      | { clean_stopped: [ $stop[] | { child: ., marker: ($m[tostring] // null),
                                       resume: "/development:resolve-issue \(.) --resume" } ],
          parked: $parked,
          skip: $stop,
          walk: [ $k[] | select(. as $n | ($stop | index($n)) == null and ($pk | index($n)) == null) ],
          summary: ([ $stop[] | "#\(.) clean-stopped — resume with /development:resolve-issue \(.) --resume" ]
                    + [ $parked[] | "#\(.child) parked — blocked by clean-stopped \(.blocked_by | map("#\(.)") | join(", "))" ]),
          counts: { clean_stopped: ($stop | length), parked_behind_clean_stop: ($parked | length) } }
    end') || { print -u2 -- "epic-clean-stop-triage: could not compute the triage"; exit 1 }

if jq -e 'has("truncated")' <<< "$out" >/dev/null; then
  print -ru2 -- "epic-clean-stop-triage: the dependency walk was truncated for $(jq -r '.truncated | map("#\(.)") | join(", ")' <<< "$out") while a child has clean-stopped — cannot prove any child independent"
  exit 3
fi
print -r -- "$out"
