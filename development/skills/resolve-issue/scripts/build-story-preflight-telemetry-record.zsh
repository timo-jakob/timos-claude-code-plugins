#!/usr/bin/env zsh
# build-story-preflight-telemetry-record.zsh — build the `story-preflight`
# `payload` for ONE `telemetry/v1` run record from a size-preflight.zsh verdict
# (#1437).
#
# A PAYLOAD builder, per ARCHITECTURE.md's *Per-pipeline telemetry
# instrumentation*: the envelope belongs to
# `development/scripts/telemetry/emit-telemetry.zsh`, and the outcome mapping
# lives here, behind --print-outcome, so it is tested code rather than skill
# prose. PURE: state in, payload out — no clock, no git, no filesystem beyond
# its one operand.
#
# The --state FILE (or stdin) is size-preflight.zsh's stdout on exit 0 or 1 —
# the verdict IS this stream's state:
#   { "verdict": "pass" | "stop", "triggers": [...], "files": N, "plugins": N, … }
# It must be exactly one JSON document — an empty state (what an erroring
# size-preflight.zsh leaves behind) is refused, never recorded. A verdict whose
# triggers contradict it (a `stop` with none, a `pass` with some), name an
# unknown trigger, or carry counts that are not non-negative integers is
# refused rather than recorded under the wrong outcome.
#
# --override human records that the human answered the stop prompt by
# proceeding anyway. It is the ONLY way `overridden` enters the stream, and it
# is refused on a `pass`: a pass is the no-trigger case, never an override, and
# the two facts must stay distinguishable. Silence, a timeout or an absent human
# is never an override — the caller simply does not pass the flag.
#
# Payload:
#   { "verdict": "pass" | "stop" | "overridden", "triggers": [...],
#     "files": N, "plugins": N, "override_by": "human" | null }
#
# Usage:
#   build-story-preflight-telemetry-record.zsh --state FILE [--override human] [--print-outcome]
#   … | build-story-preflight-telemetry-record.zsh [--state -] [--override human]
#
#     --print-outcome  print the envelope `outcome` instead of the payload:
#                      pass → success, overridden → success, stop → parked.
#
# Exit codes:
#   0  ok
#   2  usage — an unknown/dangling flag, an --override other than `human`, a
#      --state operand that is missing or unreadable, no --state with stdin on
#      a terminal
#   1  the payload cannot be built — jq is missing, or the state is not exactly
#      one JSON document, has the wrong shape, contradicts its own triggers, or
#      overrides a pass

emulate -L zsh
set -euo pipefail

local state_file="-" override="" print_outcome=0
while (( $# > 0 )); do
  case "$1" in
    --state|--override)
      (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] \
        || { print -u2 "build-story-preflight-telemetry-record.zsh: $1 needs a value"; exit 2; }
      if [[ "$1" == --state ]]; then state_file="$2"; else override="$2"; fi
      shift 2 ;;
    --print-outcome) print_outcome=1; shift ;;
    *) print -u2 "build-story-preflight-telemetry-record.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -z "$override" || "$override" == human ]] \
  || { print -u2 "build-story-preflight-telemetry-record.zsh: --override takes only 'human', got: $override"; exit 2; }
if [[ "$state_file" != - ]]; then
  [[ -f "$state_file" && -r "$state_file" ]] \
    || { print -u2 "build-story-preflight-telemetry-record.zsh: state file missing or unreadable: $state_file"; exit 2; }
else
  [[ ! -t 0 ]] || { print -u2 "build-story-preflight-telemetry-record.zsh: no --state and stdin is a terminal"; exit 2; }
fi
command -v jq >/dev/null 2>&1 \
  || { print -u2 "build-story-preflight-telemetry-record.zsh: jq not found on PATH"; exit 1; }

local v
if [[ "$state_file" == - ]]; then v="$(cat)"; else v="$(<"$state_file")"; fi

# stderr never joins the payload, so a jq warning on success cannot corrupt it.
# On failure the same program runs once more to quote its message.
local program='
  def count: type == "number" and . >= 0 and . == floor;
  if length != 1 then error("the state is not exactly one JSON document") else .[0] end
  | if type != "object"
     or ((.verdict == "pass" or .verdict == "stop") | not)
     or (.triggers | type) != "array"
     or any(.triggers[]; IN("files", "plugin", "bootstrap-straddle") | not)
     or (.files | count | not) or (.plugins | count | not)
  then error("not a size-preflight verdict")
  elif (.verdict == "stop") != ((.triggers | length) > 0)
  then error("the verdict contradicts its triggers")
  elif .verdict == "pass" and $ov != "" then error("a pass is never an override")
  else { verdict: (if $ov != "" then "overridden" else .verdict end),
         triggers, files, plugins,
         override_by: (if $ov != "" then $ov else null end) }
  end'
local payload
payload="$(print -r -- "$v" | jq -ces --arg ov "$override" "$program" 2>/dev/null)" || {
  print -u2 "build-story-preflight-telemetry-record.zsh:" \
    "$(print -r -- "$v" | jq -ces --arg ov "$override" "$program" 2>&1 >/dev/null)"
  exit 1
}

if (( print_outcome )); then
  print -r -- "$payload" | jq -r 'if .verdict == "stop" then "parked" else "success" end'
else
  print -r -- "$payload"
fi
