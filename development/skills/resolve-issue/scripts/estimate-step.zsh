#!/usr/bin/env zsh
# estimate-step.zsh — a prior for how long one review-loop step usually takes,
# from this repo's own past runs (#2197, epic #2195 child (b)).
#
# Why: before a round's gate or panel starts there is no live progress to
# extrapolate from (that is gate-eta.zsh's job once a gate is running, #2196),
# so an estimate has to come from history. Every review-loop run already leaves
# one telemetry/v1 record in the local sink; since #2197 its payload carries the
# per-round step times (step_wall_s_by_round) and each gate's job share
# (gate_by_round[].gate.jobs). This script reads them and prints the median and
# 80th percentile for one step.
#
# Read-only and pure: it never writes, and never reads the slot registry or the
# CPU count.
#
# Usage:
#   estimate-step.zsh --step panel|decide|risk|fix|gate [--scope full|selected]
#                     [--jobs N] [--repo-type T] [--sink FILE]
#     --step       the step to estimate. Required.
#     --scope      gate only, and required there: keep only gates of that scope.
#     --jobs N     gate only: scale each sample to N jobs, as
#                  wall_s × recorded_jobs / N; samples with no recorded jobs are
#                  skipped. Without it, samples are raw.
#     --repo-type  keep only records whose envelope repo_type equals T (a null
#                  repo_type never matches). Omitted, every record counts.
#     --sink       the telemetry file. Default: .claude/telemetry/telemetry.jsonl
#                  relative to the current directory.
#
# Records and samples:
#   Only records with kind "run" and pipeline "review-loop" count; a line that is
#   not JSON is skipped. Records are grouped by [repo, issue, ts] and each group
#   keeps its largest-wall_s record, because an extended loop's records overlap.
#   That record's per-round entries are deduplicated by round, last wins. The
#   sample is step_wall_s_by_round[].step_wall_s.<step>, or for the gate
#   gate_by_round[].gate.wall_s. A null or missing value is no sample, never 0,
#   so records written before #2197 contribute nothing.
#
# Statistics: at least 5 samples. median_s and p80_s are nearest-rank — the
# 1-based rank ceil(p × n) of the ascending samples, for p = 0.5 and 0.8 — each
# rounded half-up to whole seconds after scaling.
#
# Output and exit codes:
#   0  one JSON line {step, scope, jobs, repo_type, n, median_s, p80_s}; a
#      filter that was not given is null
#   1  fewer than 5 samples (an absent sink included): nothing on stdout, and
#      `estimate-step: <n> samples, fewer than 5 — withheld` on stderr
#   2  usage error: message on stderr, nothing on stdout
#   3  the sink exists but cannot be read: message on stderr, nothing on stdout

emulate -L zsh
setopt nounset pipefail

die_usage() { print -u2 -- "estimate-step: $1"; exit 2 }
need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  (( $2 >= 2 )) && [[ -n "$3" && "$3" != --* ]] || die_usage "$1 needs a value"
}

local step="" scope="" jobs="" repo_type="" sink=".claude/telemetry/telemetry.jsonl"
while (( $# )); do
  case "$1" in
  --step)      need_val "$1" $# "${2:-}"; step="$2"; shift 2 ;;
  --scope)     need_val "$1" $# "${2:-}"; scope="$2"; shift 2 ;;
  --jobs)      need_val "$1" $# "${2:-}"; jobs="$2"; shift 2 ;;
  --repo-type) need_val "$1" $# "${2:-}"; repo_type="$2"; shift 2 ;;
  --sink)      need_val "$1" $# "${2:-}"; sink="$2"; shift 2 ;;
  -h|--help)   awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  *)           die_usage "unknown argument: $1" ;;
  esac
done

case "$step" in
  panel|decide|risk|fix|gate) ;;
  "") die_usage "--step is required (panel|decide|risk|fix|gate)" ;;
  *)  die_usage "unknown --step: $step (panel|decide|risk|fix|gate)" ;;
esac
if [[ "$step" == gate ]]; then
  case "$scope" in
    full|selected) ;;
    "") die_usage "--step gate needs --scope full|selected" ;;
    *)  die_usage "unknown --scope: $scope (full|selected)" ;;
  esac
else
  [[ -z "$scope" ]] || die_usage "--scope applies to --step gate only"
  [[ -z "$jobs" ]] || die_usage "--jobs applies to --step gate only"
fi
if [[ -n "$jobs" ]]; then
  [[ "$jobs" == <-> ]] && (( jobs > 0 )) || die_usage "--jobs must be a positive integer: $jobs"
fi

command -v jq >/dev/null 2>&1 || { print -u2 -- "estimate-step: jq not found on PATH"; exit 3 }

withheld() { print -u2 -- "estimate-step: $1 samples, fewer than 5 — withheld"; exit 1 }

[[ -e "$sink" ]] || withheld 0
[[ -f "$sink" && -r "$sink" ]] || { print -u2 -- "estimate-step: cannot read the sink: $sink"; exit 3 }

local samples
samples=$(LC_ALL=C jq -Rn --arg step "$step" --arg scope "$scope" --arg jobs "$jobs" --arg rt "$repo_type" '
  def by_round_last: reduce .[] as $e ({}; .[($e.round | tostring)] = $e) | [ .[] ];
  [ inputs | (try fromjson catch null)
    | select(type == "object" and .kind == "run" and .pipeline == "review-loop"
             and (.payload | type) == "object")
    | select($rt == "" or .repo_type == $rt) ]
  | group_by([.repo, .issue, .ts])
  | map(max_by(if (.wall_s | type) == "number" then .wall_s else -1 end))
  | [ .[] | .payload
      | if $step == "gate" then
          [ (.gate_by_round // [])[]? | select(type == "object") ] | by_round_last
          | .[] | .gate
          | select(type == "object" and .scope == $scope and (.wall_s | type) == "number")
          | if $jobs == "" then .wall_s
            elif (.jobs | type) == "number" and .jobs > 0 then .wall_s * .jobs / ($jobs | tonumber)
            else empty end
        else
          [ (.step_wall_s_by_round // [])[]? | select(type == "object") ] | by_round_last
          | .[] | (.step_wall_s // null)
          | select(type == "object") | .[$step]
          | select(type == "number" and . >= 0)
        end ]
  | sort | .[]' < "$sink") || { print -u2 -- "estimate-step: cannot read the sink: $sink"; exit 3 }

local -a s=( ${(f)samples} )
local n=${#s}
(( n >= 5 )) || withheld $n

# nearest-rank, integer-only: ceil(n/2) and ceil(4n/5), 1-based
local r50=$(( (n + 1) / 2 )) r80=$(( (4 * n + 4) / 5 ))
LC_ALL=C jq -nc --arg step "$step" --arg scope "$scope" --arg jobs "$jobs" --arg rt "$repo_type" \
  --argjson n "$n" --argjson m "${s[r50]}" --argjson p "${s[r80]}" '
  def nz: if . == "" then null else . end;
  def half_up: (. + 0.5) | floor;
  { step: $step, scope: ($scope | nz), jobs: ($jobs | nz | if . == null then null else tonumber end),
    repo_type: ($rt | nz), n: $n, median_s: ($m | half_up), p80_s: ($p | half_up) }'
