#!/usr/bin/env zsh
# build-story-telemetry-record.zsh — build the resolve-issue STORY-mode `payload`
# for ONE `telemetry/v1` record from a run summary (epic #741, child (a) —
# issue #1226).
#
# Not to be confused with its sibling `build-telemetry-record.zsh` in this
# directory, which is the REVIEW LOOP's payload builder. This one describes the
# resolve-issue run that CONTAINS those loops: did the story reach a PR, park at
# the readiness gate or the dependency precheck, escalate, or fail?
#
# It is a PAYLOAD builder, not a record builder — the split both earlier streams
# took (#1004, #1005). The envelope — `schema`, `kind`, `run_id`,
# `parent_run_id`, `ts`, `repo`, `repo_type`, `pipeline`, `issue`, `pr`,
# `outcome`, `wall_s`, `tokens` — belongs to
# `development/scripts/telemetry/emit-telemetry.zsh`. `story-telemetry.zsh emit`
# pipes the two together; this script is PURE (state in, payload out, no clock,
# no filesystem beyond its one operand) so every branch is bats-testable without
# a run.
#
# The --state FILE (or stdin) is the run summary:
#   { "outcome": "pr-opened" | "gate-parked" | "precheck-parked"
#                | "escalated" | "failed",                          REQUIRED
#     "dependency_precheck": "PROCEED" | "REJECT_BLOCKED" | "REJECT_CYCLE"
#                            | null,    REQUIRED key; null only when the
#                                       precheck itself errored (no decision)
#     "gate_verdict": "READY" | "NEEDS_REFINEMENT" | null,  (null: never reached)
#     "risk": "<the gate's risk>" | null,                   (kept only on READY)
#     "pr": N | null,                   the opened PR — required on pr-opened,
#                                       null on every other ending
#     "story_spec_present": bool,       a story-spec/v1 block was consumed (#577)
#     "review_loop_run_ids": ["review-loop-…", …],
#     "escalation_status": "ESCALATE_CONFLICT" | "ESCALATE_NO_CONVERGENCE"
#                          | "ESCALATE_AMBIGUOUS" | "BUDGET_EXHAUSTED" | null,
#     "fallbacks_fired": ["acceptance_tests" | "user_docs" | "c4_currency", …] }
# Absent optional keys read as null / false / [].
#
# A state whose facts CONTRADICT its outcome is rejected rather than emitted —
# e.g. `pr-opened` with a NEEDS_REFINEMENT gate, `escalated` with no typed
# status, or a REJECT_* precheck on anything but `precheck-parked`. A record
# built from such a state would validate cleanly (payload is OPEN) and then
# count the run under the wrong outcome forever, which is worse than no record.
#
# Usage:
#   build-story-telemetry-record.zsh --state FILE [--print-outcome]
#   … | build-story-telemetry-record.zsh [--state -]      # state on stdin
#
#     --print-outcome  print the state's `outcome` NARROWED onto the contract's
#                      4-value envelope enum and exit, instead of the payload:
#                      pr-opened → success, gate-parked / precheck-parked →
#                      parked, escalated → escalated, failed → failed. The
#                      mapping lives HERE, in tested code, for the reason the
#                      refine-issue builder gives: a prose-only mapping drifts,
#                      and the emitter accepts any of the four values.
#
# Exit codes (the family's shared usage code, and this builder family's
# internal class 1):
#   0  ok
#   2  usage — an unknown/dangling flag, an empty or `--`-shaped value, an
#      unexpected positional, a --state operand that is a directory, missing or
#      unreadable, or no --state with stdin on a terminal
#   1  internal — a readable state that cannot become a payload: not exactly one
#      JSON object, an unknown or missing outcome, a field of the wrong type or
#      outside its enum, facts that contradict the outcome, a failed read, or a
#      missing jq. Nothing is printed on stdout.

emulate -L zsh
setopt nounset pipefail

local usage="usage: build-story-telemetry-record.zsh [--state FILE|-] [--print-outcome]
  --state          the run summary; omit it (or pass -) to read from stdin
  --print-outcome  print the envelope outcome (success|parked|escalated|failed)
                   instead of the payload"

# A value flag with no value is a caller mistake, and must never spin: a bare
# `shift 2` with one argument left fails without consuming and loops forever.
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "build-story-telemetry-record: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "build-story-telemetry-record: $1 requires a non-empty value"; exit 2 }
}

local state_file="" print_outcome=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --state) _need_val "$1" $# "${2:-}"; state_file="$2"; shift 2 ;;
  --print-outcome) print_outcome=1; shift ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -u2 -- "build-story-telemetry-record: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "build-story-telemetry-record: unexpected argument: $1"; exit 2 ;;
  esac
done

[[ "$state_file" != "-" ]] || state_file=""

if [[ -n "$state_file" ]]; then
  # Reject only DIRECTORIES rather than requiring a regular file, so the
  # `--state <(jq -c …)` idiom keeps working (a /dev/fd FIFO is not regular).
  [[ ! -d "$state_file" ]] || {
    print -u2 -- "build-story-telemetry-record: --state is a directory: $state_file"; exit 2 }
  [[ -e "$state_file" ]] || {
    print -u2 -- "build-story-telemetry-record: --state file does not exist: $state_file"; exit 2 }
  [[ -r "$state_file" ]] || {
    print -u2 -- "build-story-telemetry-record: --state file not readable: $state_file"; exit 2 }
else
  [[ ! -t 0 ]] || {
    print -u2 -- "build-story-telemetry-record: no --state and stdin is a terminal"
    print -u2 -- "$usage"; exit 2 }
fi

command -v jq >/dev/null 2>&1 || {
  print -u2 -- "build-story-telemetry-record: jq not found on PATH"; exit 1 }

local state=""
if [[ -n "$state_file" ]]; then
  state="$(<"$state_file")" || {
    print -u2 -- "build-story-telemetry-record: failed to read state file: $state_file"; exit 1 }
else
  state="$(cat)" || {
    print -u2 -- "build-story-telemetry-record: failed to read state from stdin"; exit 1 }
fi

# Exactly ONE top-level object: a concatenated multi-document input would
# otherwise yield one payload line per document.
print -r -- "$state" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || {
  print -u2 -- "build-story-telemetry-record: state must be a single JSON object"; exit 1 }

# Every violation, not just the first, so one fix pass clears them all. The
# rules enforce the outcome/payload contract in ARCHITECTURE.md (Resolve-issue
# telemetry), whose consistency table lists them one by one.
# (No apostrophes inside the jq program: it is single-quoted.)
local problems=""
problems=$(print -r -- "$state" | jq -r '
  def dflt(d): if . == null then d else . end;
  def isnull_or(t): . == null or (type == t);
  def enum(vals): . as $v | (vals | index([$v])) != null;
  . as $s
  | $s.outcome as $o
  | $s.dependency_precheck as $dp
  | $s.gate_verdict as $gv
  | $s.escalation_status as $es
  | $s.pr as $pr
  | [
      ( if $o == null then "state.outcome is required"
        elif ($o | type) != "string"
          or ($o | enum(["pr-opened","gate-parked","precheck-parked","escalated","failed"]) | not)
        then "unknown outcome: \($o | tojson)" else empty end ),
      ( if ($s | has("dependency_precheck") | not)
        then "state.dependency_precheck is required (null only when the precheck errored)"
        elif ($dp == null or ($dp | type == "string" and enum(["PROCEED","REJECT_BLOCKED","REJECT_CYCLE"]))) | not
        then "dependency_precheck must be PROCEED | REJECT_BLOCKED | REJECT_CYCLE | null" else empty end ),
      ( if ($gv == null or ($gv | type == "string" and enum(["READY","NEEDS_REFINEMENT"]))) | not
        then "gate_verdict must be READY | NEEDS_REFINEMENT | null" else empty end ),
      ( if ($s.risk | isnull_or("string")) | not
        then "risk must be a string or null" else empty end ),
      ( if ($es == null or ($es | type == "string" and enum(["ESCALATE_CONFLICT","ESCALATE_NO_CONVERGENCE","ESCALATE_AMBIGUOUS","BUDGET_EXHAUSTED"]))) | not
        then "escalation_status must be a typed review-loop escalation or null" else empty end ),
      ( if ($pr == null or ($pr | type == "number" and . == floor and . > 0)) | not
        then "pr must be a positive integer or null" else empty end ),
      ( if (($s.story_spec_present | dflt(false)) | type) != "boolean"
        then "story_spec_present must be a boolean" else empty end ),
      ( if ((($s.review_loop_run_ids | dflt([])) | type) != "array")
          or ([ ($s.review_loop_run_ids | dflt([]))[] | select((type != "string") or (length == 0)) ] | length > 0)
        then "review_loop_run_ids must be an array of non-empty strings" else empty end ),
      ( if ((($s.fallbacks_fired | dflt([])) | type) != "array")
          or ([ ($s.fallbacks_fired | dflt([]))[] | select((type != "string") or (enum(["acceptance_tests","user_docs","c4_currency"]) | not)) ] | length > 0)
        then "fallbacks_fired must be an array drawn from acceptance_tests | user_docs | c4_currency" else empty end ),
      # the facts must agree with the outcome they are filed under
      ( if ($dp | type) == "string" and ($dp | startswith("REJECT_")) and $o != "precheck-parked"
        then "a \($dp) precheck can only end precheck-parked" else empty end ),
      ( if $o == "precheck-parked" and (($dp | type) != "string" or ($dp | startswith("REJECT_") | not))
        then "precheck-parked needs a REJECT_* dependency_precheck" else empty end ),
      ( if $o == "precheck-parked" and $gv != null
        then "precheck-parked never reaches the readiness gate, so gate_verdict must be null" else empty end ),
      ( if $gv == "NEEDS_REFINEMENT" and $o != "gate-parked"
        then "a NEEDS_REFINEMENT gate can only end gate-parked" else empty end ),
      ( if $o == "gate-parked" and ($gv != "NEEDS_REFINEMENT" or $dp != "PROCEED")
        then "gate-parked needs dependency_precheck PROCEED and gate_verdict NEEDS_REFINEMENT" else empty end ),
      ( if $es != null and $o != "escalated"
        then "escalation_status is set, so the outcome must be escalated" else empty end ),
      ( if $o == "escalated" and ($es == null or $gv != "READY" or $dp != "PROCEED")
        then "escalated needs a typed escalation_status after a PROCEED precheck and a READY gate" else empty end ),
      ( if $o == "pr-opened" and ($pr == null or $gv != "READY" or $dp != "PROCEED")
        then "pr-opened needs a pr after a PROCEED precheck and a READY gate" else empty end ),
      ( if $o != "pr-opened" and $pr != null
        then "pr is set, so the outcome must be pr-opened" else empty end )
    ] | .[]') || {
  print -u2 -- "build-story-telemetry-record: failed to validate the state"; exit 1 }
if [[ -n "$problems" ]]; then
  print -rlu2 -- "${(@)${(f)problems}/#/build-story-telemetry-record: }"
  exit 1
fi

local outcome=""
outcome="$(print -r -- "$state" | jq -r '.outcome')" || {
  print -u2 -- "build-story-telemetry-record: failed to read state.outcome"; exit 1 }

if (( print_outcome )); then
  case "$outcome" in
    pr-opened)                   print -r -- "success" ;;
    gate-parked|precheck-parked) print -r -- "parked" ;;
    escalated)                   print -r -- "escalated" ;;
    failed)                      print -r -- "failed" ;;
    # unreachable after validation; kept so a new outcome added to the enum
    # above without a mapping here fails loudly instead of printing nothing
    *) print -u2 -- "build-story-telemetry-record: no envelope mapping for outcome: $outcome"; exit 1 ;;
  esac
  exit 0
fi

# PAYLOAD ONLY — no envelope key. `pr`, `issue`, `ts`, `wall_s` and `tokens`
# belong to the emitter; duplicating one here would give a consumer two places
# to read one fact.
print -r -- "$state" | jq -c '
  def dflt(d): if . == null then d else . end;
  . as $s
  | {
      mode: "story",
      dependency_precheck: $s.dependency_precheck,
      gate_verdict: $s.gate_verdict,
      # the gate carries a risk only on READY; any other verdict has none to keep
      risk: (if $s.gate_verdict == "READY" then $s.risk else null end),
      story_spec_present: ($s.story_spec_present | dflt(false)),
      # de-duplicated, first-seen order kept: an id listed twice would read as
      # two nested runs to a consumer counting them
      review_loop_run_ids: (($s.review_loop_run_ids | dflt([]))
        | reduce .[] as $id ([]; if index([$id]) then . else . + [$id] end)),
      escalation_status: $s.escalation_status,
      fallbacks_fired: (($s.fallbacks_fired | dflt([])) | unique)
    }' || { print -u2 -- "build-story-telemetry-record: failed to build payload"; exit 1 }
