#!/usr/bin/env zsh
# build-refine-telemetry-record.zsh — turn a refine-issue run summary into ONE
# JSONL telemetry record (#579, epic #573). Mirrors the review-loop telemetry
# builder (build-telemetry-record.zsh, #566): the refine-issue skill appends one
# record per run to `.claude/telemetry/refine-issue.jsonl` (git-ignored, same
# sink convention as #566) so the plugin self-improvement handoff can learn where
# refinement helps and where it stalls.
#
# The record is deterministic given the state JSON (+ ts/wall), so it is built
# and tested separately from the skill that appends it.
#
# The --state FILE (or stdin) is the run summary:
#   { "rounds": N,
#     "objections_raised": N, "objections_resolved": N,
#     "outcome": "refined-ready" | "parked",
#     "park_type": "needs-decision"|"split-recommended"|"deferred"|null,
#     "risk_classification": "low"|"normal"|"elevated"|null }
#
# Usage:
#   build-refine-telemetry-record.zsh --state FILE [--issue N] [--ts EPOCH] [--wall-s N]
#   … | build-refine-telemetry-record.zsh --issue N            # state on stdin
#     --ts     unix seconds to stamp (default: now). Pinning it keeps tests
#              deterministic; the skill passes its own start time.
#     --wall-s total wall-clock seconds for the run (default: null/reserved).
#
# Exit codes: 0 ok · 2 usage · 1 internal (invalid state JSON / bad outcome).

emulate -L zsh
setopt nounset pipefail

local state_file="" issue="" ts="" wall=""
# shift by 2 for value flags, but only by 1 when the value is missing (a dangling
# final flag) — a bare `shift 2` when $# < 2 fails without consuming, spinning the
# loop forever (and Step 7's `|| true` can't rescue a process that never exits).
while [[ $# -gt 0 ]]; do
  case "$1" in
  --state) state_file="${2:-}"; shift $(( $# < 2 ? $# : 2 )) ;;
  --issue) issue="${2:-}"; shift $(( $# < 2 ? $# : 2 )) ;;
  --ts) ts="${2:-}"; shift $(( $# < 2 ? $# : 2 )) ;;
  --wall-s) wall="${2:-}"; shift $(( $# < 2 ? $# : 2 )) ;;
  -h|--help) print -r -- "usage: build-refine-telemetry-record.zsh --state FILE [--issue N] [--ts EPOCH] [--wall-s N]"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done

[[ -z "$state_file" || -f "$state_file" ]] || { print -u2 -- "build-refine-telemetry-record: state file not found: $state_file"; exit 1 }
command -v jq >/dev/null 2>&1 || { print -u2 -- "build-refine-telemetry-record: jq not found on PATH"; exit 1 }

local state
if [[ -n "$state_file" ]]; then state="$(<"$state_file")"; else state="$(cat)"; fi
# Require exactly ONE top-level JSON object — a concatenated multi-document input
# would otherwise pass the outcome gate on the first doc while the emitter wrote
# one (possibly enum-violating) record per doc, breaking "one record per run".
print -r -- "$state" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
  || { print -u2 -- "build-refine-telemetry-record: state must be a single JSON object"; exit 1 }

# outcome is required and constrained (the two typed run endings).
local outcome
outcome="$(print -r -- "$state" | jq -r '.outcome // empty')"
case "$outcome" in
  refined-ready|parked) ;;
  "") print -u2 -- "build-refine-telemetry-record: state.outcome is required (refined-ready | parked)"; exit 1 ;;
  *)  print -u2 -- "build-refine-telemetry-record: unknown outcome: $outcome"; exit 1 ;;
esac

# A non-numeric --ts falls back to now rather than crashing the --argjson below.
[[ "$ts" == <-> ]] || ts=$(date +%s)

# issue / wall as JSON scalars (number or null), mirroring #566.
local issue_json='null' wall_json='null'
[[ "$issue" == <-> ]] && issue_json="$issue"
[[ "$wall" == <-> ]] && wall_json="$wall"

print -r -- "$state" | jq -c \
  --argjson ts "$ts" --argjson issue "$issue_json" --argjson wall "$wall_json" '
  # coerce a count to a number (a string "3" -> 3), defaulting to 0.
  def num: if type == "number" then . elif type == "string" then (tonumber? // 0) else 0 end;
  . as $s
  | {
      ts: $ts,
      issue: $issue,
      rounds: (($s.rounds // 0) | num),
      objections_raised: (($s.objections_raised // 0) | num),
      objections_resolved: (($s.objections_resolved // 0) | num),
      outcome: $s.outcome,
      park_type: ($s.park_type // null),
      risk_classification: ($s.risk_classification // null),
      wall_s: $wall,
      tokens: null
    }' || { print -u2 -- "build-refine-telemetry-record: failed to build record"; exit 1 }
