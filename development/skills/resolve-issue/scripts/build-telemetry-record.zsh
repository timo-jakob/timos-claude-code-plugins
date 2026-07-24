#!/usr/bin/env zsh
# build-telemetry-record.zsh — turn a review-loop status JSON (from
# resolve-story-loop.zsh, #562) into ONE JSONL telemetry record (epic #557,
# issue #566). The loop appends one record per run to
# `.claude/telemetry/review-loop.jsonl` (git-ignored); this is the raw material
# for the DORA-style dashboard and for deciding future budgets and risk-based
# review depth.
#
# The record is deterministic given the status JSON (+ ts/wall), so it is built
# and tested separately from the loop that appends it.
#
# Usage:
#   build-telemetry-record.zsh --status FILE [--issue N] [--ts EPOCH] [--wall-s N]
#     --ts     unix seconds to stamp (default: now). Pinning it keeps tests
#              deterministic; the loop passes its own start time.
#     --wall-s total wall-clock seconds for the run (default: null/reserved).
#
# Exit codes: 0 ok · 2 usage · 1 internal (invalid status JSON)

emulate -L zsh
setopt nounset pipefail

local status_file="" issue="" ts="" wall=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) status_file="$2"; shift 2 ;;
  --issue) issue="$2"; shift 2 ;;
  --ts) ts="$2"; shift 2 ;;
  --wall-s) wall="$2"; shift 2 ;;
  -h|--help) print -r -- "usage: build-telemetry-record.zsh --status FILE [--issue N] [--ts EPOCH] [--wall-s N]"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$status_file" ]] || { print -u2 -- "usage: build-telemetry-record.zsh --status FILE [--issue N] [--ts EPOCH] [--wall-s N]"; exit 2 }
[[ -s "$status_file" ]] || { print -u2 -- "build-telemetry-record: status file missing or empty: $status_file"; exit 1 }

[[ -n "$ts" ]] || ts=$(date +%s)
# --ts feeds --argjson: a non-numeric value would surface as a misleading
# "invalid status JSON" from jq — name the actual mistake instead
[[ "$ts" == <-> ]] || {
  print -u2 -- "build-telemetry-record: --ts must be unix seconds (got: $ts)"; exit 2 }

# issue / wall as JSON scalars (number or null)
local issue_json='null' wall_json='null'
[[ "$issue" == <-> ]] && issue_json="$issue"
[[ "$wall" == <-> ]] && wall_json="$wall"

jq -c \
  --argjson ts "$ts" --argjson issue "$issue_json" --argjson wall "$wall_json" '
  . as $s
  | [ $s.round_changelists[]? ] as $rounds
  # distinct findings across all rounds, keyed by identity
  | ( [ $rounds[] | (.blocking[]?, .suggestions[]?)
        | {file, line, dimension, title, priority:(.priority // "Low")} ]
      | unique_by([.file, .line, .dimension, .title]) ) as $seen
  | ( [ ($s.final_changelist.blocking // [])[]
        | "\(.file)|\(.line)|\(.dimension)|\(.title)" ] | unique ) as $final_keys
  | {
      ts: $ts,
      issue: $issue,
      repo_type: $s.repo_type,
      status: $s.status,
      escalation: (if ($s.status | test("^ESCALATE_")) or $s.status=="BUDGET_EXHAUSTED"
                   then $s.status else null end),
      rounds: ($s.rounds // 0),
      max_rounds: ($s.max_rounds // 0),
      # per-round severity counts use the USER-FACING vocabulary (#969):
      # Critical / Warning / Suggestion — the same words the human reads in
      # progress.md and the escalation — so on-screen and on-disk agree
      # (internally Warning == priority High, Suggestion == the Low bucket).
      # The stamped/carried/new/fixed derivation is one of THREE copies kept
      # in lockstep with render-progress-block.zsh and build-escalation.zsh;
      # change all three together.
      findings_by_round: [ range(0; ($rounds | length)) as $i | $rounds[$i] as $r
        | ($r.blocking // []) as $blk
        | ((($blk | length) == 0) or ([ $blk[] | has("non_converging") ] | all)) as $stamped
        | (if $stamped then ([ $blk[] | select(.non_converging == true) ] | length) else null end) as $carried
        | (if $stamped then ($blk | map(select(.non_converging == true)
              | {file, dimension, mp: (.matched_prior // {line, title})})
            | unique_by([.file, .dimension, .mp.line, .mp.title]) | length)
           else null end) as $carried_priors
        | {
        round: $r.round,
        by_severity: {
          Critical:   ([ $blk[] | select(.priority=="Critical") ] | length),
          Warning:    ([ $blk[] | select(.priority=="High") ] | length),
          Suggestion: (($r.suggestions // []) | length)
        },
        by_dimension: ( reduce ($blk + ($r.suggestions // []))[] as $f
                          ({}; .[($f.dimension // "")] = ((.[($f.dimension // "")] // 0) + 1)) ),
        # new/carried need the #913 per-item stamp; fixed_from_prev is derived
        # against the previous round from DISTINCT matched priors (null on
        # round 1 / stamp-less rounds — an honest gap, never a confident
        # wrong number)
        new:     (if $carried != null then (($blk | length) - $carried) else null end),
        carried: $carried,
        fixed_from_prev: (if ($i > 0) and ($carried_priors != null)
                          then (((($rounds[$i-1].blocking // []) | length) - $carried_priors)
                                | if . < 0 then 0 else . end)
                          else null end)
      } ],
      # per-loop convergence assessment (#969): the machine-readable form of
      # the read the grant prompt shows the human
      convergence_assessment: (
        if ($rounds | length) == 0 then null else
          ( [ $rounds[] | ((.blocking // []) | length) ] ) as $series
          | ($rounds[-1].blocking // []) as $lastblk
          | ((($lastblk | length) == 0) or ([ $lastblk[] | has("non_converging") ] | all)) as $stamped
          | (if $stamped then ([ $lastblk[] | select(.non_converging == true) ] | length) else null end) as $carried
          | (if $stamped then ($lastblk | map(select(.non_converging == true)
                | {file, dimension, mp: (.matched_prior // {line, title})})
            | unique_by([.file, .dimension, .mp.line, .mp.title]) | length)
             else null end) as $carried_priors
          | {
              blocking_by_round: $series,
              trend: (if ($series | length) < 2 then null
                      elif $series[-1] < $series[-2] then "improving"
                      elif $series[-1] == $series[-2] then "flat"
                      else "regressing" end),
              blockers_moving: (if (($series | length) < 2) or ($carried_priors == null) then null
                                else (((($rounds[-2].blocking // []) | length) - $carried_priors) > 0) end),
              carried_final: $carried,
              possible_false_trips: (if $stamped
                then ([ $lastblk[] | select((.non_converging == true) and (.possible_false_trip == true)) ] | length)
                else null end)
            }
        end),
      fixed:  ( [ $seen[]
                  | select(.priority=="Critical" or .priority=="High")
                  | ("\(.file)|\(.line)|\(.dimension)|\(.title)") as $k
                  | select( ($final_keys | index($k)) == null ) ]
                | length ),
      waived: ($seen | map(select(.priority=="Low")) | length),
      wall_s: $wall,
      tokens: null
    }' "$status_file" || { print -u2 -- "build-telemetry-record: invalid status JSON"; exit 1 }
