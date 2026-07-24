#!/usr/bin/env zsh
# render-progress-block.zsh — render one review-loop round as a human-readable
# markdown block for the loop's tail-able progress.md (#971). Pure function:
# changelist JSON (consolidate-findings.zsh output) in, markdown on stdout.
#
# Per #969 every round's block carries judgment-grade counts: the severity
# split (critical/warning on the blockers line — "suggestions" is already the
# Suggestion count), found-vs-fixed against the previous round (--prev), the
# cumulative blocking trend (--history), and a per-blocker possible-false-trip
# line whenever the consolidator flagged a carried blocker whose matched prior
# has a different title (#913/#969).
#
# The new/carried split (and everything derived from it: fixed-since,
# false-trip lines) is rendered ONLY when every blocker carries the #913
# per-item non_converging stamp; a stamp-less (pre-#913) or mixed producer gets
# totals only — no label rather than a confident wrong one. An EMPTY blocking
# array counts as stamped (carried is determinately 0 with no per-item stamps
# to consult), so the converged round still reports what its fix pass cleared.
#
# Usage: render-progress-block.zsh --changelist FILE --round N --verdict TEXT
#          [--prev FILE] [--history FILE]
#   --prev     the PREVIOUS round changelist (same schema) — enables the
#              "fixed since round N-1" count
#   --history  the loop history.jsonl INCLUDING this round — enables the
#              cumulative blocking trend line
# Exit: 0 ok · 2 usage · 1 missing/empty/invalid changelist, prev, or history

emulate -L zsh
setopt nounset pipefail

local changelist="" round="" verdict="" prev="" hist=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --changelist) changelist="$2"; shift 2 ;;
  --round) round="$2"; shift 2 ;;
  --verdict) verdict="$2"; shift 2 ;;
  --prev) prev="$2"; shift 2 ;;
  --history) hist="$2"; shift 2 ;;
  -h|--help) print -r -- "usage: render-progress-block.zsh --changelist FILE --round N --verdict TEXT [--prev FILE] [--history FILE]"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$changelist" && -n "$round" && -n "$verdict" ]] || {
  print -u2 -- "usage: render-progress-block.zsh --changelist FILE --round N --verdict TEXT [--prev FILE] [--history FILE]"; exit 2 }
[[ "$round" == <-> && "$round" != 0* ]] && (( round >= 1 )) || {
  print -u2 -- "render-progress-block: --round must be a positive integer (got: $round)"; exit 2 }
[[ -s "$changelist" ]] || {
  print -u2 -- "render-progress-block: changelist missing or empty: $changelist"; exit 1 }

local prev_json='null'
if [[ -n "$prev" ]]; then
  (( round >= 2 )) || {
    print -u2 -- "render-progress-block: --prev requires --round >= 2 (there is no round 0 to have fixed since)"; exit 2 }
  [[ -s "$prev" ]] || {
    print -u2 -- "render-progress-block: --prev missing or empty: $prev"; exit 1 }
  jq -e 'type == "object"' "$prev" >/dev/null 2>&1 || {
    print -u2 -- "render-progress-block: invalid --prev JSON: $prev"; exit 1 }
  prev_json=$(<"$prev")
fi

# the trend is the blocking count per round, in order, from history.jsonl
local trend_json='[]'
if [[ -n "$hist" ]]; then
  [[ -s "$hist" ]] || {
    print -u2 -- "render-progress-block: --history missing or empty: $hist"; exit 1 }
  trend_json=$(jq -sc '[ .[].blocking ]' "$hist" 2>/dev/null) || {
    print -u2 -- "render-progress-block: invalid --history JSONL: $hist"; exit 1 }
fi

# The stamped/carried/new/fixed derivation below is one of THREE copies that
# must stay in lockstep — the same logic lives in build-escalation.zsh (the
# per-round table) and build-telemetry-record.zsh (findings_by_round); change
# all three together (#969).
jq -r --arg ts "$(date +%H:%M:%S)" --argjson r "$round" --arg v "$verdict" \
   --argjson prev "$prev_json" --argjson trend "$trend_json" '
  # untrusted reviewer-produced text must not be able to forge progress lines
  # or break out of its markdown span — neutralize newlines and backticks
  def safe: tostring | gsub("[\r\n`]"; " ") | .[0:200];
  def dimlabel: if . == null or . == "" then "?" else safe end;
  (.blocking // []) as $blk
  # an EMPTY blocking array needs no per-item stamps for carried=0 to be
  # correct — same predicate as the two sibling copies, so the converged
  # round still gets its fixed-since line
  | ((($blk | length) == 0) or ([ $blk[] | has("non_converging") ] | all)) as $stamped
  | (if $stamped then ($blk | map(select(.non_converging == true)) | length) else null end) as $carried
  # fixed-since counts DISTINCT matched priors, not current carried items —
  # two current blockers matching the same prior must not hide a genuinely
  # fixed second prior (an item without matched_prior falls back to its own
  # identity, degrading to the per-item count). File AND dimension are part
  # of the identity: the match window guarantees prior.file == item.file and
  # prior.dimension == item.dimension, and dropping either would collapse
  # same-titled priors across files or across dimensions.
  | (if $stamped then ($blk | map(select(.non_converging == true)
        | {file, dimension, mp: (.matched_prior // {line, title})})
      | unique_by([.file, .dimension, .mp.line, .mp.title]) | length)
     else null end) as $carried_priors
  # minuend/denominator read the prior blocking ARRAY, not summary.blocking —
  # the same source of truth as the two sibling copies
  | (if $prev != null then (($prev.blocking // []) | length) else null end) as $prev_blocking
  | (if ($prev_blocking != null) and ($carried_priors != null)
     then (($prev_blocking - $carried_priors) | if . < 0 then 0 else . end)
     else null end) as $fixed
  | (if $stamped then [ $blk[] | select((.non_converging == true) and (.possible_false_trip == true)) ] else [] end) as $ftrips
  | "## Round \($r) — \(if (.summary.blocking // 0) == 0 then "no blockers" else "blockers remain" end) (\($ts))",
    ("- blockers: \(.summary.blocking // 0)"
     + (if (.summary.blocking // 0) > 0 then " (critical: \(.summary.critical // 0), warning: \(.summary.high // 0))" else "" end)
     + (if ($carried != null) and ((.summary.blocking // 0) > 0)
        then " (new: \(($blk | length) - $carried), carried: \($carried))" else "" end)
     + ", conflicts: \(.summary.conflicts // 0), suggestions: \(.summary.low // 0)"),
    (if $fixed != null then
       "- fixed since round \($r - 1): \($fixed) of \($prev_blocking)"
     else empty end),
    (if ($trend | length) >= 2 then
       "- trend: blocking " + ($trend | map(tostring) | join(" → "))
     else empty end),
    (if ($blk | length) > 0 then
       "- by dimension: " + ($blk | group_by(.dimension // "") | map("\(.[0].dimension | dimlabel) \(length)") | join(", "))
     else empty end),
    ($ftrips[] | "- possible false trip: `\(.file | safe)\(if (.line | type) == "number" then ":\(.line)" else "" end)` [\(.dimension | dimlabel)] matched prior-round blocker"
       + (if ((.matched_prior.line | type) == "number") and ((.line | type) == "number")
          then " at line \(.matched_prior.line)" else " file-wide" end)
       + " (\"\(.matched_prior.title // "" | safe)\") but the titles differ — may be a NEW finding inside the match window, not a stuck one"),
    "- \($v)",
    ""
' "$changelist" || { print -u2 -- "render-progress-block: invalid changelist JSON"; exit 1 }
