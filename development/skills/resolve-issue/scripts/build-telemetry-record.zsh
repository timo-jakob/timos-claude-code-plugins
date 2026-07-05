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
      findings_by_round: [ $rounds[] | {
        round: .round,
        by_priority: {
          Critical: ([ (.blocking // [])[] | select(.priority=="Critical") ] | length),
          High:     ([ (.blocking // [])[] | select(.priority=="High") ] | length),
          Low:      ((.suggestions // []) | length)
        },
        by_dimension: ( reduce ((.blocking // []) + (.suggestions // []))[] as $f
                          ({}; .[$f.dimension] = ((.[$f.dimension] // 0) + 1)) )
      } ],
      fixed:  ( [ $seen[]
                  | select(.priority=="Critical" or .priority=="High")
                  | ("\(.file)|\(.line)|\(.dimension)|\(.title)") as $k
                  | select( ($final_keys | index($k)) == null ) ]
                | length ),
      waived: ($seen | map(select(.priority=="Low")) | length),
      wall_s: $wall,
      tokens: null
    }' "$status_file" || { print -u2 -- "build-telemetry-record: invalid status JSON"; exit 1 }
