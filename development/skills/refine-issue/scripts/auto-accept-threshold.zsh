#!/usr/bin/env zsh
# auto-accept-threshold.zsh — resolve refine-issue's auto-accept threshold and
# print it in integer thousandths, with where it came from.
#
# Why: `/development:refine-issue --auto-accept <t>` lets the conductor answer an
# issue-refiner question with the refiner's own recommended answer, without
# asking the human, when the answer's confidence is AT OR ABOVE t. The value can
# also come from the `refine_auto_accept_threshold` variable in the `env` block
# of the human's Claude Code settings. The conductor runs this script once per
# session instead of judging the value itself, so the precedence and the parse
# have one statement and one test suite.
#
# Precedence: the flag, then the environment variable, then 1.
#
# Value: a decimal in [0, 1] with at most three decimals (`0.9`, `.95`, `1`,
# `1.0`) — the same shape as `corner_case_risk_threshold`. 1 (the default) means
# only an answer scored 1.0 on every criterion is taken; 0 means every question
# that carries a scored recommendation is taken.
#
# A bad FLAG value is exit 2: the human just typed it, so stop and let them fix
# it. A bad ENVIRONMENT value is ignored — it fails safe to the default 1 (ask
# everything below certainty) and is announced on stderr — because a global
# setting must never block a run, the same rule as corner_case_risk_threshold.
#
# Usage:  auto-accept-threshold.zsh [--flag <value>]
# Output: one line, `<milli> <source>`, source one of flag | env | default |
#         env-ignored (e.g. `900 flag`, `1000 default`).
# Exit:   0 resolved; 2 usage error or a malformed --flag value.

emulate -L zsh
setopt no_unset

usage() { print -r -u2 -- "usage: auto-accept-threshold.zsh [--flag <value in [0,1], at most three decimals>]" }

# parse_milli VALUE — print VALUE in thousandths, or return 1 when the rule does
# not admit it. The digit class refuses `30` and `-0.1`; the decimal cap refuses
# `0.0005`; the range check refuses `1.5`, which the shape alone would admit.
parse_milli() {
  local v="$1"
  [[ -n "$v" && "$v" != "." ]] || return 1
  [[ "$v" =~ '^([01]?)(\.([0-9]{1,3}))?$' ]] || return 1
  local int="${match[1]:-0}" frac="${match[3]-}"
  frac="${(r:3::0:)frac}"
  local milli=$(( 10#$int * 1000 + 10#$frac ))
  (( milli <= 1000 )) || return 1
  print -r -- "$milli"
}

local flag_set=0 flag_val=""
while (( $# > 0 )); do
  case "$1" in
    --flag)
      (( $# >= 2 )) || { usage; exit 2 }
      flag_set=1 flag_val="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

local milli=""
if (( flag_set )); then
  milli="$(parse_milli "$flag_val")" || {
    print -r -u2 -- "auto-accept-threshold: --auto-accept value '$flag_val' is not a decimal in [0, 1] with at most three decimals"
    exit 2
  }
  print -r -- "$milli flag"
  exit 0
fi

local env_val="${refine_auto_accept_threshold-}"
if [[ -z "$env_val" ]]; then
  print -r -- "1000 default"
elif milli="$(parse_milli "$env_val")"; then
  print -r -- "$milli env"
else
  print -r -u2 -- "auto-accept-threshold: ignoring refine_auto_accept_threshold='$env_val' (not a decimal in [0, 1] with at most three decimals) — using the default 1"
  print -r -- "1000 env-ignored"
fi
exit 0
