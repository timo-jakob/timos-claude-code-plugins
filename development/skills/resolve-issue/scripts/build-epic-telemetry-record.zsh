#!/usr/bin/env zsh
# build-epic-telemetry-record.zsh — build the resolve-issue EPIC-mode `payload`
# for ONE `telemetry/v1` record from an epic invocation's summary (epic #741,
# child (b) — issue #1227).
#
# The story-mode sibling is build-story-telemetry-record.zsh; this one describes
# one invocation of the Epic flow: which E1 row it took, what became of the
# children it found, whether the parallel path earned its cost, and whether E4
# caught what the per-child gates could not. One record per INVOCATION, not per
# epic lifetime — a resumed epic produces one record per run.
#
# It is a PAYLOAD builder, not a record builder, exactly as its sibling is: the
# envelope belongs to development/scripts/telemetry/emit-telemetry.zsh, and
# `story-telemetry.zsh emit --epic` pipes the two together. PURE — state in,
# payload out, no clock, no filesystem beyond its one operand.
#
# The --state FILE (or stdin) is the invocation summary:
#   { "outcome": "failed" | "escalated" | "parked" | "success",     REQUIRED
#         the row the skill picked; it must equal the FIRST matching row of the
#         precedence below, computed here from the facts, or the state is refused
#     "e1_classification": one of the ten values below,             REQUIRED
#     "children": { "total", "completed_before", "resolved_this_run",
#                   "escalated", "parked", "queued" },               REQUIRED
#         non-negative integers over the invocation's FIRST read of
#         read-sub-issues.zsh; the five buckets must sum to total
#     "split": { "parallel", "sequential" },     only children whose PR E3
#                                                opened this run (default 0, 0)
#     "child_run_ids": ["resolve-issue-…", …],   every child run started, in
#                                                start order (default [])
#     "e4": { "ran": bool, "result": "green" | "regression" | null },
#                                                (default {ran:false,result:null})
#     "e5_closed": bool,                         (default false)
#     "readiness_preflight": { "gated", "needs_refinement" } | null,
#                                                null when E1b was never reached
#     "failure_cause": "e4_regression" | "e4_error" | "e5_error" | "error"
#                      | null }                  why a run that broke after E1b
#                                                broke (default null)
#
# e1_classification (the closed table, ARCHITECTURE.md *Resolve-issue
# telemetry*): native_children, backfilled, inline_slices, halt_undecomposed,
# halt_unrealized_slices, halt_near_miss, halt_backfill_vet,
# halt_backfill_error, halt_backfill_partial, halt_unclassified.
#
# Outcome — the FIRST matching row (worst state wins):
#   1 failed     e4.result is "regression", or failure_cause is set
#   2 escalated  children.escalated > 0
#   3 parked     a halt_* classification; readiness_preflight.needs_refinement
#                > 0; children.parked + children.queued > 0; or e5_closed false
#   4 success    e5_closed is true
#
# A state whose facts contradict each other is REFUSED (exit 1, nothing on
# stdout), so `emit` appends nothing: a record that validates and then counts
# the run under the wrong outcome is worse than no record.
#
# Usage:
#   build-epic-telemetry-record.zsh --state FILE [--print-outcome]
#   … | build-epic-telemetry-record.zsh [--state -]      # state on stdin
#
#     --print-outcome  print the envelope outcome instead of the payload
#
# Exit codes: 0 ok · 2 usage (an unknown/dangling flag, an empty or `--`-shaped
# value, an unexpected positional, a --state that is a directory, missing or
# unreadable, or no --state with stdin on a terminal) · 1 internal (not exactly
# one JSON object, a field of the wrong type or outside its enum, facts that
# contradict each other or the outcome, a failed read, or a missing jq).

emulate -L zsh
setopt nounset pipefail

local usage="usage: build-epic-telemetry-record.zsh [--state FILE|-] [--print-outcome]
  --state          the invocation summary; omit it (or pass -) to read from stdin
  --print-outcome  print the envelope outcome (success|parked|escalated|failed)
                   instead of the payload"

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "build-epic-telemetry-record: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "build-epic-telemetry-record: $1 requires a non-empty value"; exit 2 }
}

local state_file="" print_outcome=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --state) _need_val "$1" $# "${2:-}"; state_file="$2"; shift 2 ;;
  --print-outcome) print_outcome=1; shift ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -u2 -- "build-epic-telemetry-record: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "build-epic-telemetry-record: unexpected argument: $1"; exit 2 ;;
  esac
done

[[ "$state_file" != "-" ]] || state_file=""

if [[ -n "$state_file" ]]; then
  [[ ! -d "$state_file" ]] || {
    print -u2 -- "build-epic-telemetry-record: --state is a directory: $state_file"; exit 2 }
  [[ -e "$state_file" ]] || {
    print -u2 -- "build-epic-telemetry-record: --state file does not exist: $state_file"; exit 2 }
  [[ -r "$state_file" ]] || {
    print -u2 -- "build-epic-telemetry-record: --state file not readable: $state_file"; exit 2 }
else
  [[ ! -t 0 ]] || {
    print -u2 -- "build-epic-telemetry-record: no --state and stdin is a terminal"
    print -u2 -- "$usage"; exit 2 }
fi

command -v jq >/dev/null 2>&1 || {
  print -u2 -- "build-epic-telemetry-record: jq not found on PATH"; exit 1 }

local state=""
if [[ -n "$state_file" ]]; then
  state="$(<"$state_file")" || {
    print -u2 -- "build-epic-telemetry-record: failed to read state file: $state_file"; exit 1 }
else
  state="$(cat)" || {
    print -u2 -- "build-epic-telemetry-record: failed to read state from stdin"; exit 1 }
fi

print -r -- "$state" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || {
  print -u2 -- "build-epic-telemetry-record: state must be a single JSON object"; exit 1 }

# The defaults applied ONCE, so validation, the outcome and the payload all read
# the same normalised document. A wrong-typed value is kept as given (only an
# absent or null key takes its default) and refused below.
local norm=""
norm=$(print -r -- "$state" | jq -c '
  def dflt(d): if . == null then d else . end;
  .split = (.split | dflt({parallel:0, sequential:0}))
  | .child_run_ids = (.child_run_ids | dflt([]))
  | .e4 = (.e4 | dflt({ran:false, result:null}))
  | .e5_closed = (.e5_closed | dflt(false))
  | .readiness_preflight = (.readiness_preflight | dflt(null))
  | .failure_cause = (.failure_cause | dflt(null))') || {
  print -u2 -- "build-epic-telemetry-record: failed to normalise the state"; exit 1 }

# Two passes: the SHAPE first (types and enums), then — only on a well-formed
# state — the consistency rules and the outcome, which do arithmetic on the
# shape and would otherwise fail on it with a jq error instead of a diagnostic.
# Every violation of a pass is reported, not just the first. (No apostrophes
# inside the jq programs: they are single-quoted.)
local problems=""
problems=$(print -r -- "$norm" | jq -r '
  def enum(vals): . as $v | (vals | index([$v])) != null;
  def count: type == "number" and . == floor and . >= 0;
  def counts(obj; ks): (obj | type) == "object" and all(ks[]; . as $k | obj[$k] | count);
  . as $s
  | [
      ( if $s.outcome == null then "state.outcome is required"
        elif ($s.outcome | type) != "string"
          or ($s.outcome | enum(["failed","escalated","parked","success"]) | not)
        then "unknown outcome: \($s.outcome | tojson)" else empty end ),
      ( if $s.e1_classification == null then "state.e1_classification is required"
        elif ($s.e1_classification | type) != "string"
          or ($s.e1_classification | enum(["native_children","backfilled","inline_slices",
               "halt_undecomposed","halt_unrealized_slices","halt_near_miss",
               "halt_backfill_vet","halt_backfill_error","halt_backfill_partial",
               "halt_unclassified"]) | not)
        then "unknown e1_classification: \($s.e1_classification | tojson)" else empty end ),
      ( if counts($s.children; ["total","completed_before","resolved_this_run","escalated","parked","queued"]) | not
        then "children must be an object of non-negative integers: total, completed_before, resolved_this_run, escalated, parked, queued" else empty end ),
      ( if counts($s.split; ["parallel","sequential"]) | not
        then "split must be an object of non-negative integers: parallel, sequential" else empty end ),
      ( if ($s.child_run_ids | type) != "array"
          or ([ $s.child_run_ids[] | select((type != "string") or (length == 0)) ] | length > 0)
        then "child_run_ids must be an array of non-empty strings" else empty end ),
      ( if ($s.e4 | type) != "object" or ($s.e4.ran | type) != "boolean"
          or (($s.e4.result == null or ($s.e4.result | type == "string" and enum(["green","regression"]))) | not)
        then "e4 must be {ran: bool, result: green | regression | null}" else empty end ),
      ( if ($s.e5_closed | type) != "boolean" then "e5_closed must be a boolean" else empty end ),
      ( if $s.readiness_preflight != null and (counts($s.readiness_preflight; ["gated","needs_refinement"]) | not)
        then "readiness_preflight must be null or an object of non-negative integers: gated, needs_refinement" else empty end ),
      ( if ($s.failure_cause == null or ($s.failure_cause | type == "string" and enum(["e4_regression","e4_error","e5_error","error"]))) | not
        then "failure_cause must be e4_regression | e4_error | e5_error | error | null" else empty end )
    ] | .[]') || {
  print -u2 -- "build-epic-telemetry-record: failed to validate the state"; exit 1 }
if [[ -n "$problems" ]]; then
  print -rlu2 -- "${(@)${(f)problems}/#/build-epic-telemetry-record: }"
  exit 1
fi

# The first matching row of the precedence table, from the facts alone.
local derive='
  def derived:
    . as $s
    | if $s.e4.result == "regression" or $s.failure_cause != null then "failed"
      elif $s.children.escalated > 0 then "escalated"
      elif ($s.e1_classification | startswith("halt_"))
        or (($s.readiness_preflight // {needs_refinement:0}).needs_refinement > 0)
        or ($s.children.parked + $s.children.queued > 0)
        or ($s.e5_closed | not) then "parked"
      else "success" end;'

problems=$(print -r -- "$norm" | jq -r "$derive"'
  . as $s
  | $s.children as $c
  | ($s.child_run_ids | unique | length) as $nruns
  | ($s.e1_classification | startswith("halt_")) as $halt
  | ($s.split.parallel + $s.split.sequential) as $opened
  | [
      ( if $s.outcome == "success" and ($s.e5_closed | not)
        then "success needs e5_closed: true" else empty end ),
      ( if $s.e5_closed and $s.e4.result != "green"
        then "e5_closed needs a green E4 (closed-after-final-testing)" else empty end ),
      ( if $s.e5_closed and ($c.escalated + $c.parked + $c.queued > 0)
        then "e5_closed with escalated, parked or queued children" else empty end ),
      ( if $halt and $c.resolved_this_run > 0
        then "a \($s.e1_classification) halt resolves no child" else empty end ),
      ( if $halt and $s.e4.ran
        then "a \($s.e1_classification) halt never runs E4" else empty end ),
      ( if $halt and $opened > 0
        then "a \($s.e1_classification) halt opens no child PR, so split must be zeros" else empty end ),
      ( if $halt and ($s.child_run_ids | length) > 0
        then "a \($s.e1_classification) halt starts no child run" else empty end ),
      ( if $halt and $s.readiness_preflight != null
        then "a \($s.e1_classification) halt never reaches E1b, so readiness_preflight must be null" else empty end ),
      ( if $halt and $s.failure_cause != null
        then "a \($s.e1_classification) halt is parked, never failed, so failure_cause must be null" else empty end ),
      ( if ($s.readiness_preflight // {needs_refinement:0}).needs_refinement > 0
          and ($c.resolved_this_run > 0 or $s.e4.ran)
        then "an E1b halt (needs_refinement > 0) builds nothing: no resolved child, no E4" else empty end ),
      ( if $s.readiness_preflight != null and $s.readiness_preflight.needs_refinement > $s.readiness_preflight.gated
        then "readiness_preflight.needs_refinement exceeds gated" else empty end ),
      ( if ($s.e4.ran | not) and $s.e4.result != null
        then "e4.ran is false, so e4.result must be null" else empty end ),
      ( if $s.e4.ran and $s.e4.result == null
        then "e4.ran is true, so e4.result must be green or regression" else empty end ),
      ( if $s.failure_cause == "e4_regression" and $s.e4.result != "regression"
        then "a failure attributed to an E4 regression needs e4.result: regression" else empty end ),
      ( if $s.failure_cause == "e4_error" and $s.e4.ran
        then "an E4 that could not reach a verdict has e4.ran: false" else empty end ),
      ( if $s.failure_cause == "e5_error" and $s.e5_closed
        then "a failed E5 close has e5_closed: false" else empty end ),
      ( if ($c.completed_before + $c.resolved_this_run + $c.escalated + $c.parked + $c.queued) != $c.total
        then "children do not sum to total: completed_before + resolved_this_run + escalated + parked + queued must equal \($c.total)" else empty end ),
      ( if $opened > $nruns
        then "split.parallel + split.sequential (\($opened)) exceeds the child runs started (\($nruns))" else empty end ),
      ( ($s | derived) as $d
        | if $s.outcome != $d
          then "outcome \($s.outcome) is not the first matching row (\($d))" else empty end )
    ] | .[]') || {
  print -u2 -- "build-epic-telemetry-record: failed to check the state"; exit 1 }
if [[ -n "$problems" ]]; then
  print -rlu2 -- "${(@)${(f)problems}/#/build-epic-telemetry-record: }"
  exit 1
fi

if (( print_outcome )); then
  print -r -- "$norm" | jq -r '.outcome' || {
    print -u2 -- "build-epic-telemetry-record: failed to read state.outcome"; exit 1 }
  exit 0
fi

# PAYLOAD ONLY — no envelope key (issue, pr, ts, wall_s, tokens).
print -r -- "$norm" | jq -c '
  . as $s
  | {
      mode: "epic",
      e1_classification: $s.e1_classification,
      children: ($s.children | {total, completed_before, resolved_this_run, escalated, parked, queued}),
      split: ($s.split | {parallel, sequential}),
      # de-duplicated, start order kept: an id listed twice would read as two
      # child runs to a consumer counting them
      child_run_ids: ($s.child_run_ids
        | reduce .[] as $id ([]; if index([$id]) then . else . + [$id] end)),
      e4: ($s.e4 | {ran, result}),
      e5_closed: $s.e5_closed,
      readiness_preflight: (if $s.readiness_preflight == null then null
                            else ($s.readiness_preflight | {gated, needs_refinement}) end),
      failure_cause: $s.failure_cause
    }' || { print -u2 -- "build-epic-telemetry-record: failed to build payload"; exit 1 }
