#!/usr/bin/env zsh
# build-maintenance-telemetry-record.zsh — build the maintenance `payload` for
# ONE `telemetry/v1` record from a /development:maintenance run (epic #741,
# child (c) — issue #1228).
#
# A PAYLOAD builder, per ARCHITECTURE.md's *Per-pipeline telemetry
# instrumentation* conventions: it emits no envelope key (the envelope is
# `development/scripts/telemetry/emit-telemetry.zsh`'s), and it owns the
# pipeline's outcome fold behind --print-outcome, so the fold is tested code
# rather than skill prose. It is PURE: two JSON files in, the payload out — no
# clock, no git, no network. `maintenance-telemetry.zsh emit` is its caller.
#
# Inputs:
#   --state FILE   the run state (the skill writes it at Phase 9):
#     { "run_modifiers": { "dry_run": bool, "no_merge": bool, "batch": int|null,
#                          "tool": str|null, "concern": str|null,
#                          "no_issues": bool, "resumed": bool },
#       "resumed_from_run_id": str|null,
#       "languages": { "detected": [str], "actionable": [str] },
#       "topics": [str],
#       "payloads": [ <constructed v2 payload> … ],   # only .findings_by_tool is read
#       "groups_planned": int|null,                  # null exactly under --dry-run
#       "human_action_required": int,                # dispatch targets that halted (Phase 7)
#       "errors": [str],                             # errors the orchestrator observed
#       "coverage_preflight": { "spawned": bool, "languages": [str] } }
#   --stages FILE  the Phase 8 `phase8-stages` checkpoint record —
#     { "stage0": {…}, "<stage>": { "group", "branch", "pr", "ci_fix_count",
#       "status", "inherited" } }. Omitted → {} (a --dry-run or --no-merge run
#     never enters Phase 8). `pr` is the PR the stage OPENED — a vendor-PR stage
#     acts on standing PRs and opens none, so it records `pr: null` whatever its
#     status. `inherited: true` marks a stage a --resume restored from an earlier
#     invocation that had already opened its PR or merged it.
#
# The outcome fold (ARCHITECTURE.md, *Maintenance telemetry (#1228)*): every
# stage contributes by table A, the run contributes by table B, and the record's
# outcome is the WORST contribution, over failed > escalated > parked > success.
#   A  merged | awaiting_approval | deferred → success;  escalated → escalated
#   B  errors non-empty → failed; dry_run, no_merge or a human_action_required
#      halt → parked; otherwise → success
#
# A state whose facts contradict each other is REFUSED (exit 1), never filed
# under a guessed outcome: such a record would validate (payload is open) and
# count the run wrongly for good. Every rule is checked and reported at once.
#
# Usage:
#   build-maintenance-telemetry-record.zsh --state FILE [--stages FILE] [--print-outcome]
#
# Exit codes: 0 ok · 2 usage (an unknown/dangling flag, a positional, a missing
# --state, an operand that is a directory, missing or unreadable) · 1 internal
# (an input that is not one JSON object, a state that breaks a rule, jq missing).

emulate -L zsh
setopt nounset pipefail

local usage="usage: build-maintenance-telemetry-record.zsh --state FILE [--stages FILE] [--print-outcome]
  --state          the run state JSON
  --stages         the phase8-stages checkpoint record (omitted: no stages)
  --print-outcome  print the folded envelope outcome instead of the payload"

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "build-maintenance-telemetry-record: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "build-maintenance-telemetry-record: $1 requires a non-empty value"; exit 2 }
}

local state_file="" stages_file="" print_outcome=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --state) _need_val "$1" $# "${2:-}"; state_file="$2"; shift 2 ;;
  --stages) _need_val "$1" $# "${2:-}"; stages_file="$2"; shift 2 ;;
  --print-outcome) print_outcome=1; shift ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -u2 -- "build-maintenance-telemetry-record: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "build-maintenance-telemetry-record: unexpected argument: $1"; exit 2 ;;
  esac
done

[[ -n "$state_file" ]] || {
  print -u2 -- "build-maintenance-telemetry-record: --state is required"; print -u2 -- "$usage"; exit 2 }

_check_operand() {  # $1 = flag, $2 = path
  [[ ! -d "$2" ]] || { print -u2 -- "build-maintenance-telemetry-record: $1 is a directory: $2"; exit 2 }
  [[ -e "$2" ]] || { print -u2 -- "build-maintenance-telemetry-record: $1 file does not exist: $2"; exit 2 }
  [[ -r "$2" ]] || { print -u2 -- "build-maintenance-telemetry-record: $1 file not readable: $2"; exit 2 }
}
_check_operand --state "$state_file"
[[ -z "$stages_file" ]] || _check_operand --stages "$stages_file"

command -v jq >/dev/null 2>&1 || {
  print -u2 -- "build-maintenance-telemetry-record: jq not found on PATH"; exit 1 }

_read_object() {  # $1 = label, $2 = path; prints the single JSON object
  local doc
  doc="$(<"$2")" || { print -u2 -- "build-maintenance-telemetry-record: failed to read $1: $2"; exit 1 }
  print -r -- "$doc" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
    || { print -u2 -- "build-maintenance-telemetry-record: $1 must be a single JSON object"; exit 1 }
  print -r -- "$doc"
}

local state stages='{}'
state="$(_read_object state "$state_file")" || exit 1
if [[ -n "$stages_file" ]]; then
  stages="$(_read_object stages "$stages_file")" || exit 1
fi

# One jq program computes the errors, the payload and the outcome together, so
# the rules and the payload can never read the state two different ways.
local result
result="$(jq -c -n --argjson s "$state" --argjson st "$stages" '
  def isbool: type == "boolean";
  def isint: type == "number" and . == floor and . >= 0;
  def strs: type == "array" and all(.[]; type == "string");
  def nullable(f): . == null or f;
  def rank: {"success":0, "parked":1, "escalated":2, "failed":3}[.];

  ($s.run_modifiers // null) as $m
  | ($st | to_entries) as $stages
  | ($stages | map(select(.value.inherited != true))) as $own
  | ($own | map(select(.key != "stage0"))) as $groups_own
  | ($own | map(select(.value.pr != null))) as $own_pr

  # --- rule checks: each yields zero or more messages ------------------------
  | [
      (if ($m | type) != "object" then "run_modifiers must be an object" else
        ( (["dry_run","no_merge","no_issues","resumed"][] as $k
            | select(($m[$k] | isbool) | not) | "run_modifiers.\($k) must be a boolean"),
          (select(($m.batch | nullable(isint and . >= 1)) | not)
            | "run_modifiers.batch must be a positive integer or null"),
          (["tool","concern"][] as $k
            | select(($m[$k] | nullable(type == "string")) | not)
            | "run_modifiers.\($k) must be a string or null") )
       end),
      (select(($s.resumed_from_run_id | nullable(type == "string" and length > 0)) | not)
        | "resumed_from_run_id must be a non-empty string or null"),
      (select(($s.languages | type) != "object"
              or (($s.languages.detected | strs) and ($s.languages.actionable | strs) | not))
        | "languages must be {detected: [str], actionable: [str]}"),
      (select(($s.topics | strs) | not) | "topics must be an array of strings"),
      (select(($s.payloads | type) != "array") | "payloads must be an array"),
      (($s.payloads // [] | if type == "array" then . else [] end)[]
        | (.findings_by_tool // {}) as $f
        | if ($f | type) != "object" then "a payload findings_by_tool is not an object"
          else ($f | to_entries[] | select((.value | type) != "array")
                | "findings_by_tool.\(.key) is not an array of findings") end),
      (select(($s.groups_planned | nullable(isint)) | not)
        | "groups_planned must be a non-negative integer or null"),
      (select(($s.human_action_required | isint) | not)
        | "human_action_required must be a non-negative integer"),
      (select(($s.errors | strs) | not) | "errors must be an array of strings"),
      (select(($s.coverage_preflight | type) != "object"
              or (($s.coverage_preflight.spawned | isbool)
                  and ($s.coverage_preflight.languages | strs) | not))
        | "coverage_preflight must be {spawned: bool, languages: [str]}"),
      ($stages[] | .key as $k | .value as $v
        | if ($v | type) != "object" then "stage \($k) is not an object" else
          ( (select(($v.status | IN("merged","awaiting_approval","escalated","deferred")) | not)
              | "stage \($k) status \($v.status | tojson) is not terminal (merged | awaiting_approval | escalated | deferred)"),
            (select(($v.pr | nullable(isint and . >= 1)) | not)
              | "stage \($k) pr must be a positive integer or null"),
            (select(($v.ci_fix_count // 0 | isint and . <= 3) | not)
              | "stage \($k) ci_fix_count must be an integer 0..3 (the per-PR ceiling)"),
            (select(($v.inherited // false | isbool) | not)
              | "stage \($k) inherited must be a boolean"),
            (select($v.status == "deferred" and $v.pr != null)
              | "stage \($k) is deferred but records a PR"),
            (select($k == "stage0" and $v.status == "deferred")
              | "stage0 (the coverage pre-flight) is never deferred") )
          end),
      # cross-field consistency
      (if ($m | type) == "object" then
        ( (select($m.dry_run == true and $s.groups_planned != null)
            | "groups_planned must be null under --dry-run (the planner never ran)"),
          (select($m.dry_run == false and $s.groups_planned == null)
            | "groups_planned is null on a run that was not --dry-run"),
          (select(($m.dry_run == true or $m.no_merge == true) and ($stages | length) > 0)
            | "a --dry-run or --no-merge run never enters Phase 8, yet stages are recorded"),
          (select($m.dry_run == true and $m.resumed == true)
            | "--dry-run never resumes"),
          (select($m.dry_run == true and ($s.human_action_required // 0) > 0)
            | "--dry-run stops before dispatch, so nothing can halt on human_action_required"),
          (select($m.resumed != true and $s.resumed_from_run_id != null)
            | "resumed_from_run_id is set on a run that did not resume"),
          (select($m.resumed != true and ($stages | any(.value.inherited == true)))
            | "inherited stages on a run that did not resume") )
       else empty end),
      (select(($s.coverage_preflight.spawned // false) == false and ($own | any(.key == "stage0")))
        | "a stage0 is recorded but coverage_preflight.spawned is false"),
      (select(($own_pr | map(.value.pr) | length) != ($own_pr | map(.value.pr) | unique | length))
        | "the same PR is recorded by two stages"),
      (select(($s.groups_planned | type) == "number"
              and (($groups_own | length) > $s.groups_planned))
        | "more groups were worked or deferred than were planned")
    ] as $errs

  | if ($errs | length) > 0 then {errors: $errs} else
    # --- payload ---------------------------------------------------------------
    ( [ $s.payloads[] | (.findings_by_tool // {}) | to_entries[] ]
      | group_by(.key) | map({key: .[0].key, value: (map(.value | length) | add)})
      | from_entries ) as $fbt
    | ($own_pr | map(select(.value.status == "merged") | .value.pr)) as $merged
    | ($own_pr | map(select(.value.status == "awaiting_approval") | .value.pr)) as $awaiting
    | ($own_pr | map(select(.value.status == "escalated") | .value.pr)) as $escalated
    | {
        run_modifiers: ($m | {dry_run, no_merge, batch, tool, concern, no_issues, resumed}),
        resumed_from_run_id: $s.resumed_from_run_id,
        languages: {detected: $s.languages.detected, actionable: $s.languages.actionable},
        topics: $s.topics,
        findings_by_tool: $fbt,
        groups: {
          planned: $s.groups_planned,
          worked: ($groups_own | map(select(.value.status != "deferred")) | length),
          deferred: ($groups_own | map(select(.value.status == "deferred")) | length)
        },
        prs: {
          opened: ($merged + $awaiting + $escalated | sort),
          merged: ($merged | sort),
          awaiting_approval: ($awaiting | sort),
          escalated: ($escalated | sort)
        },
        ci_fixer_rounds: ($own_pr | map({key: (.value.pr | tostring),
                                        value: (.value.ci_fix_count // 0)}) | from_entries),
        escalations: {
          human_action_required: $s.human_action_required,
          ci_fixer_exhausted: ($own_pr | map(select(.value.status == "escalated"
                                                    and (.value.ci_fix_count // 0) == 3)
                                             | .value.pr) | sort)
        },
        coverage_preflight: {
          spawned: $s.coverage_preflight.spawned,
          languages: $s.coverage_preflight.languages,
          pr: (first($own[] | select(.key == "stage0") | .value.pr) // null)
        }
      } as $payload
    # --- the fold: worst contribution wins --------------------------------------
    | ( [ $stages[] | .value.status
          | if . == "escalated" then "escalated" else "success" end ]
        + [ if ($s.errors | length) > 0 then "failed"
            elif $m.dry_run or $m.no_merge or $s.human_action_required > 0 then "parked"
            else "success" end ] ) as $contrib
    | {payload: $payload,
       outcome: ($contrib | max_by(rank))}
    end
')" || { print -u2 -- "build-maintenance-telemetry-record: failed to evaluate the state"; exit 1 }

if [[ "$(print -r -- "$result" | jq -r 'has("errors")')" == "true" ]]; then
  print -r -- "$result" | jq -r '.errors[] | "build-maintenance-telemetry-record: state refused — \(.)"' >&2
  exit 1
fi

if (( print_outcome )); then
  print -r -- "$result" | jq -r '.outcome'
else
  print -r -- "$result" | jq -c '.payload'
fi
