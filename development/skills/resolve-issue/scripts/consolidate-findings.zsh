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
#   { round, summary{critical,high,low,blocking,conflicts,false_trips},
#     blocking[], suggestions[], conflicts[], non_converging, false_trips[],
#     escalation_reasons[] }  (each blocking[] item also carries false_trip:bool)
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
#   - Non-convergence (#606 + #983): candidates for "this blocked last round too"
#     are GATHERED on [file, dimension] + line proximity (within LINEWIN lines; a
#     missing line on either side is a wildcard). The VERDICT on a candidate is
#     title-IDENTITY (#983): an exact normalized-title match => genuine survivor
#     (non_converging:true, escalates); a non-exact match sharing a significant
#     token — or where either side yields no significant tokens (untitled, or a
#     title of only <4-char words) => AMBIGUOUS (non_converging:true, still
#     escalates — a reword must not defeat the match, #606); a non-exact match
#     whose titles BOTH yield tokens and share NONE => a false trip (false_trip:true,
#     non_converging:false) that does NOT escalate — the loop auto-continues,
#     because it is a genuinely different finding that only landed in the window
#     after a fix shifted lines (#983, the #976 21-minute false escalation). Only
#     non_converging (verified/ambiguous) sets the top-level flag + escalation
#     reason; false_trips are counted in the summary and surfaced for the loop to
#     record.
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
def normfile: ((. // "") | tostring | sub("^\\./";""));
# title normalization for the #983 identity verdict (an exact normtitle match =>
# a verified survivor) and the possible_false_trip flag (#969): lenient enough
# that pure case/whitespace re-wording is not read as a different finding;
# tostring keeps a malformed non-string title from aborting the whole round
def normtitle: ((. // "") | tostring | ascii_downcase | gsub("\\s+"; " ")
  | sub("^ +"; "") | sub(" +$"; ""));
# Identity verdict tokens (#983): the significant words of a title — lowercase
# alphanumeric runs of length >= 4 (a cheap stopword filter), de-duplicated.
# The cross-round matcher still GATHERS candidates by [file, dimension] + line
# proximity (#606), but the VERDICT on a carried blocker is now identity-based:
#   * an exact normalized-title match among the candidates => a genuine survivor
#     (escalates, as before);
#   * no exact title, but the current title shares ANY significant token with a
#     candidate (or either title is too short to yield tokens) => AMBIGUOUS — it
#     may be a reworded survivor, so it still escalates (fail-toward-the-human);
#   * no exact title AND fully DISJOINT significant tokens => a verified false
#     trip: a genuinely different finding that merely landed in the proximity
#     window after a fix shifted lines. It does NOT escalate — the loop
#     auto-continues and records it (#983). Disjoint titles are the only signal
#     strong enough to auto-continue; a single shared domain word ("coverage",
#     "counter") is deliberately treated as ambiguous, not clear.
def sigtokens: ((. // "") | tostring | ascii_downcase | [ scan("[a-z0-9]+") ]
  | map(select(length >= 4)) | unique);
def shares_token($a; $b): (($a | length) > 0) and (($b | length) > 0)
  and ([ $a[] | select(. as $x | $b | index($x)) ] | length) > 0;
# Candidate GATHER predicate (#606): same file + dimension, with the line close
# enough that a small edit-drift between rounds still matches (a null line on
# either side is a wildcard). The title plays no role in GATHERING — a reviewer
# re-wording the same finding must not stop it being a candidate. The title then
# decides the VERDICT on the gathered set (#983, see the classification block
# below): exact => verified survivor, shared token => ambiguous, disjoint => false
# trip.
def LINEWIN: 10;
# A missing or non-numeric line on either side is a wildcard (match) — never a
# type error from subtracting a stray string line.
def line_near($a;$b):
  if (($a | type) == "number") and (($b | type) == "number")
  then ((($a) - ($b)) | (if . < 0 then -. else . end) <= LINEWIN)
  else true end;
# nearest candidate by line distance to $c — stable sort, so wildcard or
# line-less candidates rank last (LINEWIN + 1) and ties keep prior
# blocking-array order; used by BOTH matched_prior branches so co-windowed
# priors always attribute to their own successors (#969)
def nearest($c): sort_by(
  if ((.line | type) == "number") and (($c.line | type) == "number")
  then (((.line) - ($c.line)) | if . < 0 then -. else . end)
  else LINEWIN + 1 end) | .[0];

# previous round blockers projected to [file, dimension, line, title] (empty on
# round 1). The title is load-bearing (#983): it decides the identity verdict
# (exact => verified survivor, token overlap => ambiguous, disjoint => false
# trip) and is part of the one-to-one claim key — not a display-only label.
( ($prev // {}) | (.blocking // [])
  | map({ file: (.file | normfile), dimension: ((.dimension // "") | tostring),
          line: .line, title: (.title // "") }) ) as $prevblk

# normalize this round
| [ .[] | {
    severity: (.severity // "SUGGESTION"),
    dimension: ((.dimension // "") | tostring),
    file: (.file | normfile),
    # number-or-null only: a digit-only string line is recovered losslessly
    # (a plausible model-output malformation), anything else becomes null —
    # already a wildcard for line_near — so no downstream renderer can ever
    # interpolate a reviewer-crafted string line into markdown (#969)
    line: (if (.line | type) == "number" then .line
           elif ((.line | type) == "string") and (.line | test("^[0-9]+$")) then (.line | tonumber)
           else null end),
    title: (.title // ""),
    description: ((.description // "") | tostring),
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

# classify carried blockers by cross-round IDENTITY (#983). Candidates are still
# GATHERED on [file, dimension] + line proximity (#606) — a null line on either
# side is a wildcard — but the VERDICT is title-identity, not proximity: an exact
# normalized-title match => genuine survivor (non_converging, escalates); a
# non-exact match that shares a significant token, or a tokenless side => AMBIGUOUS
# (non_converging, escalates — fail-toward-the-human, it may be a reworded
# survivor); a non-exact match with FULLY DISJOINT titles => a false trip that
# does NOT escalate (false_trip:true, non_converging:false — the loop
# auto-continues, #983). Each records matched_prior (its line + title) so a human
# can see what the window hit (#913). possible_false_trip (#969) is "no exact
# title match" on EVERY matched item — including the clear/false_trip branch (true
# there too) — so a surface that wants only the ESCALATING set must read it in
# conjunction with non_converging (as the progress/escalation/telemetry surfaces
# do). Attribution among the escalating set is ONE-TO-ONE: each such item, in
# deduped [file, line, dimension] group order (NOT the Critical-first output
# order), claims the NEAREST still-unclaimed candidate from the pool its verdict
# allows — the exact-title set when verified; ALL matches when the current title yields no
# tokens; otherwise only the token-sharing / tokenless-candidate subset (never a
# disjoint-titled prior) — falling back to the nearest claimed one only when every
# pool candidate is taken, else two carried blockers claim the same prior and the
# distinct-priors fixed count collapses. A false trip is a NEW blocker, not a
# carried one, so it claims nothing. NB: keep this jq program free of
# apostrophes; it lives in a zsh single-quoted string.
| ( $items | reduce .[] as $cur ({out: [], claimed: []};
    ( [ $prevblk[] | select(
          .file == $cur.file and .dimension == $cur.dimension and line_near(.line; $cur.line)) ] ) as $m
    | if ($cur.blocking and ($m | length) > 0)
      then ([ $m[] | select(((.title | normtitle) != "")
               and ((.title | normtitle) == ($cur.title | normtitle))) ]) as $exact
         | ($cur.title | sigtokens) as $ct
         | (if ($exact | length) > 0 then "verified"
            elif ($ct | length) == 0 then "ambiguous"
            elif ([ $m[] | select(((.title | sigtokens | length) == 0)
                     or shares_token($ct; (.title | sigtokens))) ] | length) > 0 then "ambiguous"
            else "clear" end) as $verdict
         | if $verdict == "clear"
           then { out: (.out + [ $cur + {
                    non_converging: false, false_trip: true,
                    matched_prior: ($m | nearest($cur) | {line, title}),
                    possible_false_trip: true } ]),
                  claimed: .claimed }
           else (if $verdict == "verified" then $exact
                 elif ($ct | length) == 0 then $m
                 else [ $m[] | select(((.title | sigtokens | length) == 0)
                          or shares_token($ct; (.title | sigtokens))) ] end) as $cands
              | (.claimed) as $cl
              | ([ $cands[] | [.file, .dimension, .line, .title] as $k
                   | select((any($cl[]; . == $k)) | not) ]) as $free
              | ((if ($free | length) > 0 then $free else $cands end) | nearest($cur)) as $mp
              | { out: (.out + [ $cur + {
                      non_converging: true, false_trip: false,
                      matched_prior: ($mp | {line, title}),
                      possible_false_trip: (($exact | length) == 0) } ]),
                  claimed: (.claimed + [[ $mp.file, $mp.dimension, $mp.line, $mp.title ]]) }
           end
      else { out: (.out + [ $cur + { non_converging: false, false_trip: false } ]), claimed: .claimed }
      end)
    | .out ) as $items

| ( [ $items[] | select(.priority=="Critical") ] ) as $crit
| ( [ $items[] | select(.priority=="High") ] ) as $high
| ( [ $items[] | select(.priority=="Low") ] ) as $low
| ( ($crit + $high) | sort_by(if .priority=="Critical" then 0 else 1 end) ) as $blocking
| ( [ $blocking[] | select(.non_converging) ] | length > 0 ) as $nonconv
# verified false trips (#983): blockers proximity GATHERED as non-convergence
# candidates but identity-cleared (disjoint titles) as genuinely different — they
# are stamped non_converging:false from the start (never set $nonconv), and are
# surfaced so progress/telemetry can record the auto-continue.
| ( [ $blocking[] | select(.false_trip == true) ] ) as $ftrips

| {
    round: $round,
    summary: {
      critical: ($crit | length),
      high: ($high | length),
      low: ($low | length),
      blocking: ($blocking | length),
      conflicts: ($conflicts | length),
      false_trips: ($ftrips | length)
    },
    blocking: $blocking,
    suggestions: $low,
    conflicts: $conflicts,
    non_converging: $nonconv,
    false_trips: $ftrips,
    escalation_reasons: (
      ( if ($conflicts | length) > 0 then ["unresolved_conflict"] else [] end )
      + ( if $nonconv then ["non_converging_blocker"] else [] end )
    )
  }
'

jq -c --argjson round "$round" --argjson prev "$prev_json" "$PROG" "$findings" || {
  print -u2 -- "consolidate-findings: invalid findings JSON: $findings"; exit 1
}
