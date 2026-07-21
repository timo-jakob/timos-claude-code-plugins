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
#   - Non-convergence: a blocker that also blocked the PREVIOUS round (--prev)
#     is marked non_converging:true, and sets the top-level flag + an escalation
#     reason. Cross-round identity is [file, dimension] with line proximity
#     (within LINEWIN lines; a missing line on either side is a wildcard) —
#     deliberately NOT the free-text title, which a reviewer re-wording the same
#     finding across rounds would defeat (#606). A missed reword would burn a
#     third round and escalate as BUDGET_EXHAUSTED instead of the intended early
#     ESCALATE_NO_CONVERGENCE.
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
def normfile: ((. // "") | sub("^\\./";""));
# Cross-round identity: same file + dimension, with the line close enough that a
# small edit-drift between rounds still matches (a null line on either side is a
# wildcard). The title is NOT part of it — a reviewer re-wording the same finding
# must not defeat the match (#606).
def LINEWIN: 10;
# A missing or non-numeric line on either side is a wildcard (match) — never a
# type error from subtracting a stray string line.
def line_near($a;$b):
  if (($a | type) == "number") and (($b | type) == "number")
  then ((($a) - ($b)) | (if . < 0 then -. else . end) <= LINEWIN)
  else true end;

# previous round blockers projected to [file, dimension, line] (empty on round
# 1); title rides along only to label a match for the human (#913), it is never
# part of the identity (#606)
( ($prev // {}) | (.blocking // [])
  | map({ file: (.file | normfile), dimension: (.dimension // ""), line: .line,
          title: (.title // "") }) ) as $prevblk

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

# mark non-converging blockers (a matching blocker blocked last round too).
# Match on [file, dimension] + line proximity — NOT the title (#606). A match
# also records the FIRST matching prior blocker (matched_prior: its line +
# title, in prior blocking-array order), so the escalation can show the human
# what the match window hit and a false trip — a genuinely different finding
# that merely landed inside the window after a fix pass shifted lines — is
# spottable (#913). NB: keep this jq program free of apostrophes; it lives in a
# zsh single-quoted string.
| ( $items | map( . as $cur
    | [ $prevblk[] | select(
          .file == $cur.file and .dimension == $cur.dimension and line_near(.line; $cur.line)) ] as $m
    | . + (if (.blocking and ($m | length) > 0)
           then { non_converging: true, matched_prior: ($m[0] | {line, title}) }
           else { non_converging: false } end) ) ) as $items

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
