#!/usr/bin/env zsh
# render-progress-block.zsh — render one review-loop round as a human-readable
# markdown block for the loop's tail-able progress.md (#971). Pure function:
# changelist JSON (consolidate-findings.zsh output) in, markdown on stdout.
#
# The new/carried split is rendered ONLY when every blocker carries the #913
# per-item non_converging stamp; a stamp-less (pre-#913) or mixed producer gets
# totals only — no label rather than a confident wrong one.
#
# Usage: render-progress-block.zsh --changelist FILE --round N --verdict TEXT
# Exit: 0 ok · 2 usage · 1 missing/empty/invalid changelist

emulate -L zsh
setopt nounset pipefail

local changelist="" round="" verdict=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --changelist) changelist="$2"; shift 2 ;;
  --round) round="$2"; shift 2 ;;
  --verdict) verdict="$2"; shift 2 ;;
  -h|--help) print -r -- "usage: render-progress-block.zsh --changelist FILE --round N --verdict TEXT"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$changelist" && -n "$round" && -n "$verdict" ]] || {
  print -u2 -- "usage: render-progress-block.zsh --changelist FILE --round N --verdict TEXT"; exit 2 }
[[ -s "$changelist" ]] || {
  print -u2 -- "render-progress-block: changelist missing or empty: $changelist"; exit 1 }

jq -r --arg ts "$(date +%H:%M:%S)" --argjson r "$round" --arg v "$verdict" '
  (.blocking // []) as $blk
  | ((($blk | length) > 0) and ([ $blk[] | has("non_converging") ] | all)) as $stamped
  | (if $stamped then ($blk | map(select(.non_converging)) | length) else null end) as $carried
  | "## Round \($r) — \(if (.summary.blocking // 0) == 0 then "no blockers" else "blockers remain" end) (\($ts))",
    ("- blockers: \(.summary.blocking // 0)"
     + (if $carried != null then " (new: \((.summary.blocking // 0) - $carried), carried: \($carried))" else "" end)
     + ", conflicts: \(.summary.conflicts // 0), suggestions: \(.summary.low // 0)"),
    (if ($blk | length) > 0 then
       "- by dimension: " + ($blk | group_by(.dimension // "") | map("\(.[0].dimension // "?") \(length)") | join(", "))
     else empty end),
    "- \($v)",
    ""
' "$changelist" || { print -u2 -- "render-progress-block: invalid changelist JSON"; exit 1 }
