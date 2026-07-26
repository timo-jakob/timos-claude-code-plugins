#!/usr/bin/env zsh
# build-refine-telemetry-record.zsh — build the refine-issue `payload` for ONE
# `telemetry/v1` record from a refine-issue run summary (#579, epic #573 —
# retrofitted onto the shared contract by epic #740's child (c), issue #1005).
#
# It is a PAYLOAD builder, not a record builder — the same split its review-loop
# sibling took in #1004. The envelope — `schema`, `kind`, `run_id`,
# `parent_run_id`, `ts`, `repo`, `repo_type`, `pipeline`, `issue`, `pr`,
# `outcome`, `wall_s`, `tokens` — belongs to
# `development/scripts/telemetry/emit-telemetry.zsh`, which owns it for EVERY
# pipeline so no skill hand-rolls one. This script contributes only the
# refine-issue's own detail, which the emitter embeds unmodified as `payload`;
# the skill's Step 7 pipes the two together, and the emitter owns the sink (the
# shared `.claude/telemetry/telemetry.jsonl`, not the old per-pipeline file).
# No file migration is performed: records written before this retrofit stay in
# `.claude/telemetry/refine-issue.jsonl` as they are, and child (e)'s rollup is
# what reads both.
#
# `park_type` stays in the PAYLOAD deliberately: the envelope's `outcome` is the
# 4-value cross-pipeline enum dashboards group on, so *which* park type a park
# was is pipeline detail. The `ts`/`issue`/`wall_s` this script used to carry are
# envelope fields now, supplied by the skill to the emitter — hence no
# `--ts`/`--issue`/`--wall-s` flags here.
#
# The payload is deterministic given the state JSON, so it is built and tested
# separately from the skill that emits it.
#
# The --state FILE (or stdin) is the run summary:
#   { "rounds": N,
#     "objections_raised": N, "objections_resolved": N,
#     "outcome": "refined-ready" | "parked",
#     "park_type": "needs-decision"|"split-recommended"|"deferred"|null,
#     "risk_classification": "low"|"normal"|"elevated"|null }
#
# Usage:
#   build-refine-telemetry-record.zsh --state FILE [--print-outcome]
#   … | build-refine-telemetry-record.zsh [--state -]      # state on stdin
#
#     --print-outcome  print the state's `outcome` NARROWED onto the contract's
#                      4-value envelope enum (refined-ready → success, parked →
#                      parked) and exit, instead of the payload. The mapping
#                      lives HERE, in tested code, rather than in the skill's
#                      prose — a prose-only mapping is exactly what drifts, and
#                      the emitter would reject a wrong value only by luck (both
#                      `parked` and `success` are legal enum members).
#
# Exit codes — the shared USAGE code (2) that the emitter and validator declare,
# so a caller mistake means the same number across the family. The internal class
# is 1 here (see the note below), matching the sibling payload builder:
#   0  ok
#   2  usage — caller error: an unknown/dangling flag, a value flag given an
#      empty or `--`-shaped value, an unexpected positional,
#      or a --state operand that is a directory, missing, or unreadable (a path
#      typo must stay distinguishable from a broken state file), and a bare
#      invocation with no --state on a terminal (there is nothing to read).
#   1  internal — a state that exists and is readable but cannot be turned into a
#      payload: not exactly one JSON object, a missing/unknown outcome, a failed
#      read, or a missing jq. (The emitter calls that class 3; this script's
#      documented taxonomy has no 3, so the internal class here is 1.)

emulate -L zsh
setopt nounset pipefail

local usage="usage: build-refine-telemetry-record.zsh [--state FILE|-] [--print-outcome]
  --state    the run summary; omit it (or pass -) to read from stdin
  --print-outcome  print the envelope outcome (success|parked) instead of the payload"

# A value flag with no value is a caller mistake, not an omission. It must also
# never spin: a bare `shift 2` when $# < 2 fails without consuming, looping
# forever — and Step 7's `|| echo` cannot rescue a process that never exits.
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "build-refine-telemetry-record: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "build-refine-telemetry-record: $1 requires a non-empty value"; exit 2 }
}

local state_file="" print_outcome=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --state) _need_val "$1" $# "${2:-}"; state_file="$2"; shift 2 ;;
  --print-outcome) print_outcome=1; shift ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  # Prefixed like every other diagnostic here: Step 7 chains three tools into
  # one `|| echo`, so an unprefixed stderr line is the hardest to attribute.
  -*) print -u2 -- "build-refine-telemetry-record: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "build-refine-telemetry-record: unexpected argument: $1"; exit 2 ;;
  esac
done

# `-` means stdin, the same idiom the emitter's `--payload -` uses; without this
# it would fail the operand checks below with a baffling "does not exist: -".
[[ "$state_file" != "-" ]] || state_file=""

if [[ -n "$state_file" ]]; then
  # A bad operand PATH is a caller mistake (exit 2), matching the sibling builder
  # and the emitter's --payload policy, so a typo stays distinguishable from a
  # broken state file (exit 1). Reject only DIRECTORIES rather than requiring a
  # regular file, which keeps the symmetric `--state <(jq -c …)` idiom working —
  # a /dev/fd FIFO is not a regular file.
  [[ ! -d "$state_file" ]] || {
    print -u2 -- "build-refine-telemetry-record: --state is a directory: $state_file"; exit 2 }
  [[ -e "$state_file" ]] || {
    print -u2 -- "build-refine-telemetry-record: --state file does not exist: $state_file"; exit 2 }
  [[ -r "$state_file" ]] || {
    print -u2 -- "build-refine-telemetry-record: --state file not readable: $state_file"; exit 2 }
else
  # Without this, a bare invocation on a terminal blocks forever in `cat` with no
  # prompt and no diagnostic — the same never-spin promise `_need_val` makes for
  # a dangling flag, and one Step 7's `|| echo` equally cannot rescue.
  [[ ! -t 0 ]] || {
    print -u2 -- "build-refine-telemetry-record: no --state and stdin is a terminal"
    print -u2 -- "$usage"; exit 2 }
fi

command -v jq >/dev/null 2>&1 || { print -u2 -- "build-refine-telemetry-record: jq not found on PATH"; exit 1 }

# Both reads are guarded: an unguarded read leaves `state` empty on an I/O or
# permission failure, which the single-object gate below would then misreport as
# "not a single JSON object" — a wrong diagnosis of an environment problem.
local state
if [[ -n "$state_file" ]]; then
  state="$(<"$state_file")" || {
    print -u2 -- "build-refine-telemetry-record: failed to read state file: $state_file"; exit 1 }
else
  state="$(cat)" || {
    print -u2 -- "build-refine-telemetry-record: failed to read state from stdin"; exit 1 }
fi
# Require exactly ONE top-level JSON object — a concatenated multi-document input
# would otherwise pass the outcome gate on the first doc while jq emitted one
# payload line per doc, and the emitter embeds `payload` as a single object.
print -r -- "$state" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
  || { print -u2 -- "build-refine-telemetry-record: state must be a single JSON object"; exit 1 }

# outcome is required and constrained (the two typed run endings). It is
# validated on EVERY invocation, not just --print-outcome: a payload built from
# a state whose outcome is unknown would be emitted under a guessed envelope
# outcome, which is worse than no record at all.
local outcome
# Guarded like the reads above: an unguarded substitution leaves `outcome` empty
# when jq dies (signal, OOM), which would be reported as "outcome is required" —
# an environment failure misdiagnosed as a caller data error.
outcome="$(print -r -- "$state" | jq -r '.outcome // empty')" || {
  print -u2 -- "build-refine-telemetry-record: failed to read state.outcome"; exit 1 }
local envelope_outcome
case "$outcome" in
  refined-ready) envelope_outcome="success" ;;
  parked)        envelope_outcome="parked" ;;
  "") print -u2 -- "build-refine-telemetry-record: state.outcome is required (refined-ready | parked)"; exit 1 ;;
  *)  print -u2 -- "build-refine-telemetry-record: unknown outcome: $outcome"; exit 1 ;;
esac

if [[ $print_outcome -eq 1 ]]; then
  print -r -- "$envelope_outcome"
  exit 0
fi

print -r -- "$state" | jq -c '
  # coerce a count to a number (a string "3" -> 3), defaulting to 0.
  def num: if type == "number" then . elif type == "string" then (tonumber? // 0) else 0 end;
  . as $s
  | {
      rounds: (($s.rounds // 0) | num),
      objections_raised: (($s.objections_raised // 0) | num),
      objections_resolved: (($s.objections_resolved // 0) | num),
      park_type: ($s.park_type // null),
      risk_classification: ($s.risk_classification // null)
    }' || { print -u2 -- "build-refine-telemetry-record: failed to build payload"; exit 1 }
