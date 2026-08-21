#!/usr/bin/env zsh
# render-progress-block.zsh — render one review-loop round as a human-readable
# markdown block for the loop's tail-able progress.md (#971). Pure function:
# changelist JSON (consolidate-findings.zsh output) in, markdown on stdout.
#
# Per #969 every round's block carries judgment-grade counts: the severity
# split (critical/warning on the blockers line — "suggestions" is already the
# Suggestion count), found-vs-fixed against the previous round (--prev), the
# cumulative blocking trend (--history), a per-blocker possible-false-trip line
# whenever the consolidator flagged an ESCALATING carried blocker whose matched
# prior has a different title (#913/#969), a distinct "false trip
# auto-continued" line for each identity-cleared false trip (#983), and — when
# the human promoted a suggestion (#995) — a `promoted: N` term inside the
# blockers line's severity parens plus one "- promoted suggestion:" line per
# promoted blocker, so the human's own picks read differently from
# reviewer-raised Warnings. Since #1434 it also carries an
# `- adjudicated re-raises dropped: N` line whenever the consolidator suppressed
# a re-raise of an already-waived suggestion — rendered only when N > 0, on the
# same direct-read, no-stamp-gate rule, so a run with no adjudicated list is
# byte-identical to before the count existed.
#
# The new/carried split (and everything derived from it: fixed-since, the
# escalating possible-false-trip lines) is rendered ONLY when every blocker
# carries the #913 per-item non_converging stamp; a stamp-less (pre-#913) or
# mixed producer gets totals only — no label rather than a confident wrong one.
# An EMPTY blocking array counts as stamped (carried is determinately 0 with no
# per-item stamps to consult), so the converged round still reports what its fix
# pass cleared. The #983 auto-continued false-trip line renders off the direct
# per-item false_trip flag with NO stamp gate — an absent flag (a pre-#983
# changelist) simply yields no line. The #995 promoted term and lines are the
# same shape: a direct per-item `promoted` flag, NO stamp gate, and rendered
# only when the count is non-zero — which is what keeps a run without
# --promote byte-identical to before the label existed.
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
  # verified false trips (#983): a proximity match identity cleared as a
  # genuinely different finding — the loop AUTO-CONTINUES on these (no escalation,
  # no human grant), so they render distinctly from the escalating $ftrips above.
  # A direct flag, no $stamped gate: a pre-#983 changelist simply lacks it.
  | ([ $blk[] | select(.false_trip == true) ]) as $auto_ftrips
  # human-promoted blockers (#995): the overlay raised them from Suggestion, so
  # without a label they read as ordinary reviewer-raised Warnings. The rendered
  # term is a SUBSET of the `warning:` count it sits beside, never added to it —
  # stated here too because this is the surface where an additive misreading is
  # most likely (the term sits inside the same severity parentheses). NB: no
  # apostrophes in this block — the jq program is single-quoted. Same
  # per-item expression as the four sibling copies (escalation table, telemetry
  # payload, and the two build-dossier reads: raised-set + round suffix, #1064),
  # and — like $auto_ftrips — a
  # direct flag with NO $stamped gate: an unstamped changelist simply counts 0
  # and renders neither the term nor a line, keeping a no-promote run
  # byte-identical.
  | ([ $blk[] | select(.promoted == true) ]) as $promoted
  | "## Round \($r) — \(if (.summary.blocking // 0) == 0 then "no blockers" else "blockers remain" end) (\($ts))",
    ("- blockers: \(.summary.blocking // 0)"
     + (if (.summary.blocking // 0) > 0 then " (critical: \(.summary.critical // 0), warning: \(.summary.high // 0)"
        + (if ($promoted | length) > 0 then ", promoted: \($promoted | length)" else "" end) + ")" else "" end)
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
    # adjudicated re-raises (#1434): suggestions an earlier round already
    # surfaced and the human already let go, dropped instead of re-logged.
    # Rendered ONLY when non-zero — the same rule the promoted term follows, and
    # what keeps a run with no adjudicated list byte-identical to before the
    # count existed. A direct read with no stamp gate: a pre-#1434 changelist
    # simply has no key, `// 0` makes it zero, and no line renders.
    (if (.summary.adjudicated_dropped // 0) > 0 then
       "- adjudicated re-raises dropped: \(.summary.adjudicated_dropped)"
     else empty end),
    ($promoted[] | "- promoted suggestion: `\(.file | safe)\(if (.line | type) == "number" then ":\(.line)" else "" end)` [\(.dimension | dimlabel)] \"\(.title | safe)\""
       + " — raised from Suggestion by the human at convergence; blocking until cleared"),
    ($ftrips[] | "- possible false trip: `\(.file | safe)\(if (.line | type) == "number" then ":\(.line)" else "" end)` [\(.dimension | dimlabel)] matched prior-round blocker"
       + (if ((.matched_prior.line | type) == "number") and ((.line | type) == "number")
          then " at line \(.matched_prior.line)" else " file-wide" end)
       + " (\"\(.matched_prior.title // "" | safe)\") but the titles differ — may be a NEW finding inside the match window, not a stuck one"),
    ($auto_ftrips[] | "- false trip auto-continued (#983): `\(.file | safe)\(if (.line | type) == "number" then ":\(.line)" else "" end)` [\(.dimension | dimlabel)] landed in the match window of prior-round blocker"
       + (if ((.matched_prior.line | type) == "number") then " at line \(.matched_prior.line)" else " (file-wide)" end)
       + " (\"\(.matched_prior.title // "" | safe)\") but shares no title terms — treated as a NEW blocker, not a stuck one; no escalation, no human grant consumed"),
    "- \($v)",
    ""
' "$changelist" || { print -u2 -- "render-progress-block: invalid changelist JSON"; exit 1 }
