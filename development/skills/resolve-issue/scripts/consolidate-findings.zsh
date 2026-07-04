#!/usr/bin/env zsh
# consolidate-findings.zsh — turn a review round's aggregate findings into ONE
# prioritised changelist for the autonomous review loop (epic #557, issue #561).
#
# Why: five reviewers giving unmediated feedback to the implementor produces
# conflicting advice and thrash. This is the single consolidation step between
# the panel and the implementor. It is a DETERMINISTIC engine (jq) so the
# severity mapping, dedup, blocking classification and non-convergence detection
# are reliable and testable — the `review-consolidator` agent wraps it and adds
# the semantic judgment (subtle dedup / genuine conflict) the heuristic can't.
#
# Input: the round's aggregate findings JSON (issue #558 schema — a flat array
# of finding objects). Output on stdout: one changelist JSON:
#   { round, summary{critical,high,low,blocking,conflicts},
#     blocking[], suggestions[], conflicts[], non_converging, escalation_reasons[] }
#
# Rules (per #561):
#   - Severity map: CRITICAL->Critical, WARNING->High, SUGGESTION->Low.
#     Blocking = Critical + High. Low is logged in `suggestions`, never blocks.
#   - Dedup: findings sharing file+line+dimension merge into one item — keep the
#     most detailed description, union the reviewers (agreement = how many), and
#     carry the highest severity seen.
#   - Conflict: co-located findings (same file+line) whose dimensions pull in
#     opposite directions (performance vs code_quality) become a `conflicts`
#     item — surfaced, not silently ordered; a surviving conflict is an
#     escalation reason.
#   - Non-convergence: a blocker whose fingerprint (file+dimension+normalized
#     title) also blocked the PREVIOUS round (--prev) is marked
#     non_converging:true, and sets the top-level flag + an escalation reason.
#
# Usage:
#   consolidate-findings.zsh --findings FILE [--round N] [--prev FILE]
#     --findings  aggregate findings JSON for THIS round (required)
#     --round     round number (default 1)
#     --prev      previous round's changelist JSON (this script's own output);
#                 omitted on round 1
#
# Exit codes: 0 ok · 2 usage error · 1 internal (unreadable / invalid JSON)

emulate -L zsh
setopt nounset pipefail

local findings="" round=1 prev=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --findings) findings="$2"; shift 2 ;;
  --round) round="$2"; shift 2 ;;
  --prev) prev="$2"; shift 2 ;;
  -h|--help) print -r -- "usage: consolidate-findings.zsh --findings FILE [--round N] [--prev FILE]"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$findings" ]] || { print -u2 -- "usage: consolidate-findings.zsh --findings FILE [--round N] [--prev FILE]"; exit 2 }
[[ -s "$findings" ]] || { print -u2 -- "consolidate-findings: findings file missing or empty: $findings"; exit 1 }

local prev_json='null'
if [[ -n "$prev" ]]; then
  [[ -s "$prev" ]] || { print -u2 -- "consolidate-findings: --prev file missing or empty: $prev"; exit 1 }
  prev_json=$(<"$prev")
fi

local -r PROG='
def sevrank(s): if s=="CRITICAL" then 3 elif s=="WARNING" then 2 elif s=="SUGGESTION" then 1 else 0 end;
def prio(s): if s=="CRITICAL" then "Critical" elif s=="WARNING" then "High" else "Low" end;
def blocks(s): (s=="CRITICAL" or s=="WARNING");
def norm_title: (. // "" | ascii_downcase | gsub("[^a-z0-9]+";" ") | gsub("^ +| +$";""));
def fp: [ (.file // ""), (.dimension // ""), (.title | norm_title) ];

# previous round blocker fingerprints (empty on round 1)
( ($prev // {}) | (.blocking // []) | map(fp) ) as $prevfp

# normalize this round
| [ .[] | {
    severity: (.severity // "SUGGESTION"),
    dimension: (.dimension // ""),
    file: ((.file // "") | sub("^\\./";"")),
    line: (.line),
    title: (.title // ""),
    description: (.description // ""),
    suggested_fix: (.suggested_fix // ""),
    reviewer: (.reviewer // "")
  } ]

# dedup by file+line+dimension
| ( group_by([.file, (.line|tostring), .dimension]) | map(
      (sort_by(.description | length) | last) as $rep
    | ([ .[].severity ] | max_by(sevrank(.))) as $sev
    | $rep + {
        severity: $sev,
        priority: prio($sev),
        blocking: blocks($sev),
        reviewers: ([ .[].reviewer ] | map(select(. != "")) | unique),
        agreement: ([ .[].reviewer ] | map(select(. != "")) | unique | length)
      }
    | del(.reviewer)
  ) ) as $items

# conflicts: co-located, opposite-direction dimensions (performance vs code_quality)
| ( $items | group_by([.file, (.line|tostring)]) | map(
      select( (length >= 2)
        and ( [ .[].dimension ] as $d
              | ($d | index("performance")) and ($d | index("code_quality")) ) )
      | { file: .[0].file, line: .[0].line,
          between: ["performance","code_quality"],
          items: [ .[] | select(.dimension=="performance" or .dimension=="code_quality")
                   | {dimension, title, priority} ],
          detail: "co-located recommendations pull in opposite directions (performance vs code_quality)" }
  ) ) as $conflicts

# mark non-converging blockers (fingerprint also blocked last round).
# NB: use element-equality (any), not `index($cur)` — index() on an array
# argument does a SUBSEQUENCE search, not a membership test.
| ( $items | map( fp as $cur | . + { non_converging: ( .blocking and ($prevfp | any(. == $cur)) ) } ) ) as $items

| ( [ $items[] | select(.priority=="Critical") ] ) as $crit
| ( [ $items[] | select(.priority=="High") ] ) as $high
| ( [ $items[] | select(.priority=="Low") ] ) as $low
| ( ($crit + $high) | sort_by(if .priority=="Critical" then 0 else 1 end) ) as $blocking
| ( [ $blocking[] | select(.non_converging) ] | length > 0 ) as $nonconv

| {
    round: $round,
    summary: {
      critical: ($crit | length),
      high: ($high | length),
      low: ($low | length),
      blocking: ($blocking | length),
      conflicts: ($conflicts | length)
    },
    blocking: $blocking,
    suggestions: $low,
    conflicts: $conflicts,
    non_converging: $nonconv,
    escalation_reasons: (
      ( if ($conflicts | length) > 0 then ["unresolved_conflict"] else [] end )
      + ( if $nonconv then ["non_converging_blocker"] else [] end )
    )
  }
'

jq -c --argjson round "$round" --argjson prev "$prev_json" "$PROG" "$findings" || {
  print -u2 -- "consolidate-findings: invalid findings JSON: $findings"; exit 1
}
