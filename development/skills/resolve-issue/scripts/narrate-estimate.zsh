#!/usr/bin/env zsh
# narrate-estimate.zsh — the one line the resolve-issue conductor prints before
# a long wait: a sourced time estimate, or an explicit "no estimate" (#2198,
# epic #2195 child (c)).
#
# Why: a reported number is reliable or withheld. While a round waits on its
# gate or a subagent, a guessed "~10 min" is exactly the unsourced figure that
# rule forbids, so the conductor narrates only what this script prints. Its only
# sources are gate-eta.zsh (a running gate's own log, #2196) and
# estimate-step.zsh (past runs in the local telemetry sink, #2197), both beside
# this script; it never computes or rounds a figure of its own.
#
# Read-only: it writes no file.
#
# Usage:
#   narrate-estimate.zsh --step panel|decide|risk|fix|gate [--gate-log FILE]
#                        [--repo-type T] [--sink FILE]
#     --step       the wait to narrate. Required.
#     --gate-log   the round gate's captured run-gate.zsh stderr. Required with
#                  --step gate, refused with any other step.
#     --repo-type, --sink  passed through to estimate-step.zsh.
#
# What it prints, as exactly one line on stdout:
#   gate — gate-eta.zsh --json on the log, then, in order:
#     gate-eta exits non-zero            -> the estimator-error line
#     running with an ETA, or finished   -> live: `estimate for gate: live — `
#                                           followed by gate-eta's own line
#     otherwise, with a `run-gate: start` line in the log -> the prior from
#                                           estimate-step.zsh --step gate with
#                                           that line's --scope and --jobs
#     otherwise                          -> the no-data line
#   panel, decide, risk, fix — the prior from estimate-step.zsh --step <step>.
#
#   prior:   estimate for <step>: prior — median <m>m<ss>s, p80 <m>m<ss>s over <n> past runs
#            with ` (<scope> gate, scaled to jobs=<jobs>)` appended for the gate
#   no data (estimate-step exit 1):  estimate for <step>: no estimate (no data)
#   unreadable sink (exit 3):        estimate for <step>: no estimate (telemetry unreadable)
#   estimator error (exit 2, any other exit, or a missing helper):
#                                    estimate for <step>: no estimate (estimator error)
#
# Exit codes:
#   0  a line was printed — whatever it says
#   2  usage: an unknown flag, a missing or unknown --step, a flag with no
#      value, or --gate-log missing for gate or given for another step. A
#      message goes to stderr and nothing to stdout.

emulate -L zsh
setopt nounset pipefail

die_usage() { print -u2 -- "narrate-estimate: $1"; exit 2 }
need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  (( $2 >= 2 )) && [[ -n "$3" && "$3" != --* ]] || die_usage "$1 needs a value"
}

local step="" gate_log="" repo_type="" sink=""
while (( $# )); do
  case "$1" in
  --step)      need_val "$1" $# "${2:-}"; step="$2"; shift 2 ;;
  --gate-log)  need_val "$1" $# "${2:-}"; gate_log="$2"; shift 2 ;;
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
  [[ -n "$gate_log" ]] || die_usage "--step gate needs --gate-log FILE"
else
  [[ -z "$gate_log" ]] || die_usage "--gate-log applies to --step gate only"
fi

local here="${0:A:h}"
local gate_eta="$here/gate-eta.zsh" estimate="$here/estimate-step.zsh"

say() { print -r -- "estimate for ${step}: $1"; exit 0 }
dur() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )) }

# the prior from estimate-step.zsh, or the line its exit names
prior() {  # $@ = estimate-step arguments; $suffix is appended to a prior line
  [[ -f "$estimate" ]] || say "no estimate (estimator error)"
  local out rc
  out="$(zsh "$estimate" "$@" 2>/dev/null)"; rc=$?
  case $rc in
    0) ;;
    1) say "no estimate (no data)" ;;
    3) say "no estimate (telemetry unreadable)" ;;
    *) say "no estimate (estimator error)" ;;
  esac
  local n m p
  n="$(jq -r '.n' <<< "$out" 2>/dev/null)"
  m="$(jq -r '.median_s' <<< "$out" 2>/dev/null)"
  p="$(jq -r '.p80_s' <<< "$out" 2>/dev/null)"
  [[ "$n" == <-> && "$m" == <-> && "$p" == <-> ]] || say "no estimate (estimator error)"
  say "prior — median $(dur "$m"), p80 $(dur "$p") over $n past runs${suffix}"
}

local -a pass=()
[[ -n "$repo_type" ]] && pass+=(--repo-type "$repo_type")
[[ -n "$sink" ]] && pass+=(--sink "$sink")
local suffix=""

if [[ "$step" != gate ]]; then
  prior --step "$step" "${pass[@]}"
fi

# --- the gate: live when the log can say, else the prior --------------------
[[ -f "$gate_eta" ]] || say "no estimate (estimator error)"
local eta_json state eta
eta_json="$(zsh "$gate_eta" --log "$gate_log" --json 2>/dev/null)" || say "no estimate (estimator error)"
state="$(jq -r '.state' <<< "$eta_json" 2>/dev/null)" || state=""
eta="$(jq -r '.eta_s' <<< "$eta_json" 2>/dev/null)" || eta=""
if [[ "$state" == finished || ( "$state" == running && "$eta" == <-> ) ]]; then
  local live
  live="$(zsh "$gate_eta" --log "$gate_log" 2>/dev/null)" || say "no estimate (estimator error)"
  [[ -n "$live" ]] || say "no estimate (estimator error)"
  say "live — $live"
fi

# no live figure: the prior for a gate of this log's scope and job share
local start scope jobs
start="$(grep -m1 '^run-gate: start ' -- "$gate_log" 2>/dev/null)" || start=""
scope="" jobs=""
[[ "$start" =~ ' scope=([a-z]+)' ]] && scope="$match[1]"
[[ "$start" =~ ' jobs=([0-9]+)' ]] && jobs="$match[1]"
[[ -n "$scope" && -n "$jobs" ]] || say "no estimate (no data)"
suffix=" ($scope gate, scaled to jobs=$jobs)"
prior --step gate --scope "$scope" --jobs "$jobs" "${pass[@]}"
