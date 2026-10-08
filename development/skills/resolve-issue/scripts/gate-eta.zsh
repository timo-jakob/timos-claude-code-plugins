#!/usr/bin/env zsh
# gate-eta.zsh — how far a running bats gate has got, and how long it has left
# (#2196, epic #2195 child (a)).
#
# Why: the whole-suite gate is the longest wait in a resolve-issue round, and
# how long it takes depends on how many concurrent gates share the CPUs (#1798),
# so no earlier run predicts it. Its own captured stderr does: run-gate.zsh
# mirrors the TAP stream there (the plan line `1..N`, one `ok`/`not ok` line per
# test) and states its start and its wall time. This helper reads that log and
# turns it into a done/total count and a linear time-left estimate. It reads
# only the log: no telemetry, no file timestamps, no CPU count.
#
# Read-only. It never writes a file and never modifies the log.
#
# Usage:
#   gate-eta.zsh --log FILE [--started EPOCH] [--json]
#     --log FILE       run-gate.zsh's captured stderr (TAP plus `run-gate:`
#                      lines), or a TAP-only --tap-out file. Required.
#     --started EPOCH  the gate's start, in integer epoch seconds, for a log with
#                      no `run-gate: start` line. When given it takes precedence
#                      over the start line.
#     --json           print one JSON object instead of the human line.
#
# What it reads from the log:
#   total  N of the first TAP plan line `1..N`.
#   done   count(^ok ) + count(^not ok ) — run-gate's own counting rule, so a
#          skipped test counts as done.
#   jobs, start epoch  from the first `run-gate: start epoch=… jobs=…` line. A
#          `run-gate: … other live gate(s) … jobs=…` line is not read.
#   wall_s from run-gate's count line (`run-gate: mode=… wall_s=…`), for a
#          finished log.
#
# State, decided in this order:
#   no-plan   no plan line yet: total and eta_s are null.
#   finished  done >= total: eta_s 0; elapsed_s is the count line's wall_s
#             rounded to whole seconds, or null without it — never now − start.
#   withheld  done < max(5, ceil(10% of total)): too few tests for a fair rate,
#             so eta_s is null rather than stated.
#   running   elapsed_s = now − start, eta_s = elapsed_s × (total − done) / done
#             rounded to the nearest second; each null with no start epoch.
#   elapsed_s is also reported, when a start epoch is known, for no-plan and
#   withheld.
#
# Output:
#   default — one human line, e.g.
#     412/1830 tests, 9m12s elapsed, ~31m40s left (jobs=4)
#   Durations are <m>m<ss>s. An unknown jobs share prints `jobs=?`, an unknown
#   elapsed or ETA prints `unknown`. The other states' lines say `no plan line`,
#   `ETA withheld` and `finished`.
#   --json — one object {done, total, elapsed_s, eta_s, jobs, state}: integers
#   or null, and state one of running | finished | withheld | no-plan.
#
# Exit codes:
#   0  the log was read — in every state, an empty log included
#   2  usage: an unknown flag, no --log, a non-integer --started, or a log that
#      is missing, not a regular file or unreadable. A message goes to stderr
#      and nothing to stdout.
#
# Seam (for tests):
#   GATE_ETA_NOW  the current time in integer epoch seconds, instead of the
#                 clock. A non-integer value is a usage error (exit 2).

emulate -L zsh
setopt nounset pipefail
zmodload -F zsh/datetime p:EPOCHSECONDS

die_usage() { print -u2 -- "gate-eta: $1"; exit 2 }

local log="" started="" json=0
while (( $# )); do
  case "$1" in
  --log)     { (( $# >= 2 )) && [[ -n "$2" ]]; } || die_usage "--log needs a file"; log="$2"; shift 2 ;;
  --started) (( $# >= 2 )) || die_usage "--started needs an epoch"; started="$2"; shift 2
             [[ "$started" == <-> ]] || die_usage "--started must be integer epoch seconds: $started" ;;
  --json)    json=1; shift ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  *)         die_usage "unknown argument: $1" ;;
  esac
done
[[ -n "$log" ]] || die_usage "--log FILE is required"
[[ -f "$log" && -r "$log" ]] || die_usage "cannot read log: $log"

local now="${GATE_ETA_NOW:-$EPOCHSECONDS}"
[[ "$now" == <-> ]] || die_usage "GATE_ETA_NOW must be integer epoch seconds: $now"

# One pass over the log. A field the log does not carry prints as `-`.
local parsed total done_n epoch jobs wall
parsed="$(LC_ALL=C awk '
  total == "" && /^1\.\.[0-9]+([^0-9]|$)/ { t = $0; sub(/^1\.\./, "", t); sub(/[^0-9].*$/, "", t); total = t }
  /^ok / || /^not ok / { done++ }
  epoch == "" && /^run-gate: start epoch=[0-9]+ / {
    e = $0; sub(/^run-gate: start epoch=/, "", e); sub(/[^0-9].*$/, "", e); epoch = e
    j = $0
    if (sub(/^.* jobs=/, "", j)) { sub(/[^0-9].*$/, "", j); if (j != "") jobs = j }
  }
  /^run-gate: mode=.* wall_s=[0-9]/ { w = $0; sub(/^.* wall_s=/, "", w); sub(/[^0-9.].*$/, "", w); wall = w }
  END {
    printf "%s %d %s %s %s\n", (total == "" ? "-" : total), done + 0,
      (epoch == "" ? "-" : epoch), (jobs == "" ? "-" : jobs), (wall == "" ? "-" : wall)
  }' "$log")" || die_usage "cannot read log: $log"
read -r total done_n epoch jobs wall <<< "$parsed"

[[ -n "$started" ]] && epoch="$started"

local state elapsed="-" eta="-"
if [[ "$epoch" != "-" ]]; then
  elapsed=$(( now - epoch ))
  (( elapsed < 0 )) && elapsed=0
fi
if [[ "$total" == "-" ]]; then
  state="no-plan"
elif (( done_n >= total )); then
  state="finished"; eta=0
  # a finished run's elapsed is its own measured wall time, never now − start
  elapsed="-"
  [[ "$wall" != "-" ]] && elapsed="$(LC_ALL=C awk -v w="$wall" 'BEGIN { printf "%d", w + 0.5 }')"
else
  local floor=$(( (total + 9) / 10 ))
  (( floor < 5 )) && floor=5
  if (( done_n < floor )); then
    state="withheld"
  else
    state="running"
    # eta = elapsed × remaining / done, rounded half-up in integer arithmetic
    [[ "$elapsed" != "-" ]] \
      && eta=$(( (2 * elapsed * (total - done_n) + done_n) / (2 * done_n) ))
  fi
fi

if (( json )); then
  local -a v=() x
  for x in "$done_n" "$total" "$elapsed" "$eta" "$jobs"; do v+=("${x:/-/null}"); done
  printf '{"done":%s,"total":%s,"elapsed_s":%s,"eta_s":%s,"jobs":%s,"state":"%s"}\n' \
    "${v[@]}" "$state"
  exit 0
fi

dur() {  # <seconds|-> -> <m>m<ss>s, or `unknown`
  [[ "$1" == "-" ]] && { print -r -- unknown; return }
  printf '%dm%02ds\n' $(( $1 / 60 )) $(( $1 % 60 ))
}
local j="${jobs:/-/?}" e; e="$(dur "$elapsed")"
case "$state" in
  no-plan)  print -r -- "no plan line yet, ${done_n} tests, ${e} elapsed (jobs=${j})" ;;
  finished) if [[ "$elapsed" == "-" ]]; then
              print -r -- "${done_n}/${total} tests, finished, elapsed unknown (jobs=${j})"
            else
              print -r -- "${done_n}/${total} tests, finished in ${e} (jobs=${j})"
            fi ;;
  withheld) print -r -- "${done_n}/${total} tests, ${e} elapsed, ETA withheld until ${floor} done (jobs=${j})" ;;
  running)  if [[ "$eta" == "-" ]]; then
              print -r -- "${done_n}/${total} tests, ${e} elapsed, unknown left (jobs=${j})"
            else
              print -r -- "${done_n}/${total} tests, ${e} elapsed, ~$(dur "$eta") left (jobs=${j})"
            fi ;;
esac
exit 0
