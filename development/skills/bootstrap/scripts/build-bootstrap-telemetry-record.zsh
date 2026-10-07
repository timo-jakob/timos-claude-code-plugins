#!/usr/bin/env zsh
# build-bootstrap-telemetry-record.zsh — build the bootstrap `payload` for ONE
# `telemetry/v1` record from a /development:bootstrap run (epic #741, child (d)
# — issue #1229).
#
# A PAYLOAD builder, per ARCHITECTURE.md's *Per-pipeline telemetry
# instrumentation* conventions: it emits no envelope key (the envelope is
# `development/scripts/telemetry/emit-telemetry.zsh`'s), and it owns the
# pipeline's outcome fold behind --print-outcome, so the fold is tested code
# rather than skill prose. It is PURE: one JSON state in, the payload out — no
# clock, no git, no network. `bootstrap-telemetry.zsh emit` is its caller.
#
# Input — --state FILE (or `-` for stdin), the run state the skill writes at its
# ending (ARCHITECTURE.md, *Bootstrap telemetry (#1229)*, is the normative
# statement of every key):
#   { "mode": "fresh" | "gap_fill",
#     "target_repo": "owner/name" | null,
#     "visibility": "public" | "private" | null,
#     "languages": { "primary": str | null, "auxiliary": [str] },
#     "topics": [str], "interfaces": [str],
#     "host": { "os": str, "homebrew": bool },
#     "steps": { "<step key>": <disposition> },
#     "files": [ { "path": str, "step": "<step key>", "disposition": <disposition> } ],
#     "github_state": { "branch_protection" | "secrets" | "sonar_project" |
#                       "apps_installed": <target disposition> },
#     "stack": "resolved" | "none" | "detection_failed" | "not_reached",
#     "early_stop": null | "plan_declined" | "detection" | "precondition",
#     "approve_merge": null | "merged" | "pending" | "request_changes" |
#                      "red_ci" | "retry_exhausted",
#     "pr": int | null }
#   <disposition>        written | merged | skipped | failed | already_present
#   <target disposition> applied | already_present | skipped | refused | failed
#
# The per-file list is builder INPUT only: the payload carries its counts, never
# a path. `steps.<k>` must equal the worst disposition among the entries with
# `step: <k>`, by failed > skipped > merged > written > already_present, and an
# applicable step with zero entries must be `skipped`.
#
# The outcome fold — first match from the top, which is the worst-wins fold over
# failed > escalated > parked > success:
#   failed     a step is failed; a github_state target is failed; the stack is
#              `none` or `detection_failed` (no usable stack)
#   escalated  approve_merge is request_changes, red_ci or retry_exhausted
#   parked     a step is skipped; a github_state target is refused; the run
#              stopped early on plan_declined or precondition; the host is not
#              macOS with Homebrew
#   success    none of the above
#
# A state whose facts contradict each other is REFUSED (exit 1), never filed
# under a guessed outcome: such a record would validate (payload is open) and
# count the run wrongly for good. Every rule is checked and reported at once.
#
# Usage:
#   build-bootstrap-telemetry-record.zsh --state FILE|- [--print-outcome]
#
# Exit codes: 0 ok · 2 usage (an unknown/dangling flag, a positional, a missing
# --state, an operand that is a directory, missing or unreadable) · 1 internal
# (an input that is not one JSON object, a state that breaks a rule, jq missing).

emulate -L zsh
setopt nounset pipefail

local usage="usage: build-bootstrap-telemetry-record.zsh --state FILE|- [--print-outcome]
  --state          the run state JSON (- reads it from stdin)
  --print-outcome  print the folded envelope outcome instead of the payload"

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "build-bootstrap-telemetry-record: $1 requires a value"; exit 2 }
  [[ -n "$3" && ( "$3" == "-" || "$3" != -* ) ]] || {
    print -u2 -- "build-bootstrap-telemetry-record: $1 requires a non-empty value"; exit 2 }
}

local state_file="" print_outcome=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  --state) _need_val "$1" $# "${2:-}"; state_file="$2"; shift 2 ;;
  --print-outcome) print_outcome=1; shift ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  -*) print -u2 -- "build-bootstrap-telemetry-record: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "build-bootstrap-telemetry-record: unexpected argument: $1"; exit 2 ;;
  esac
done

[[ -n "$state_file" ]] || {
  print -u2 -- "build-bootstrap-telemetry-record: --state is required"; print -u2 -- "$usage"; exit 2 }

if [[ "$state_file" != "-" ]]; then
  [[ ! -d "$state_file" ]] || {
    print -u2 -- "build-bootstrap-telemetry-record: --state is a directory: $state_file"; exit 2 }
  [[ -e "$state_file" ]] || {
    print -u2 -- "build-bootstrap-telemetry-record: --state file does not exist: $state_file"; exit 2 }
  [[ -r "$state_file" ]] || {
    print -u2 -- "build-bootstrap-telemetry-record: --state file not readable: $state_file"; exit 2 }
fi

command -v jq >/dev/null 2>&1 || {
  print -u2 -- "build-bootstrap-telemetry-record: jq not found on PATH"; exit 1 }

local state=""
if [[ "$state_file" == "-" ]]; then
  state="$(cat)" || { print -u2 -- "build-bootstrap-telemetry-record: failed to read the state from stdin"; exit 1 }
else
  state="$(<"$state_file")" || {
    print -u2 -- "build-bootstrap-telemetry-record: failed to read the state: $state_file"; exit 1 }
fi
print -r -- "$state" | jq -e -s 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 || {
  print -u2 -- "build-bootstrap-telemetry-record: the state must be a single JSON object"; exit 1 }

# One jq program computes the errors, the payload and the outcome together, so
# the rules and the payload can never read the state two different ways.
local result
result="$(print -r -- "$state" | jq -c '
  . as $s
  # The closed step-key list, in SKILL.md order. tests/build-bootstrap-telemetry-record.bats
  # pins each key to its SKILL.md heading.
  | ["common_artifacts", "toolchain_artifacts", "quality_workflows", "container_publishing",
     "language_fragments", "approver_artifacts", "language_artifacts", "acceptance_workflow",
     "docs_machinery", "api_contracts", "anti_corruption_adapter", "contract_consumer",
     "react_overlay", "react_query", "iac", "composition", "provenance_markers",
     "git_hooks", "build_script"] as $keys
  | ["already_present", "written", "merged", "skipped", "failed"] as $disps   # worst last
  | ["applied", "already_present", "skipped", "refused", "failed"] as $tdisps
  | ["branch_protection", "secrets", "sonar_project", "apps_installed"] as $targets
  | def isbool: type == "boolean";
    def strs: type == "array" and all(.[]; type == "string");
    def worst: map(. as $d | $disps | index($d)) | max | $disps[.];

  ($s.steps // null) as $steps
  | ($s.files // null) as $files
  | ($s.github_state // null) as $gh
  | (($steps | type) == "object") as $steps_ok
  | (($files | type) == "array"
     and all($files[]; type == "object" and (.path | type == "string" and length > 0)
                       and (.step | type == "string") and (.disposition | type == "string")))
      as $files_ok
  | (($gh | type) == "object") as $gh_ok
  | (if $steps_ok then $steps else {} end) as $st
  | (if $files_ok then $files else [] end) as $fl
  | (if $gh_ok then $gh else {} end) as $g
  | ($s.host // null) as $host
  | (($host | type) == "object" and ($host.os | type == "string" and length > 0)
     and ($host.homebrew | isbool)) as $host_ok
  | ($host_ok and $host.os == "macos" and $host.homebrew == true) as $supported_host

  # --- rule checks: each yields zero or more messages --------------------------
  | [
      (select(($s.mode | IN("fresh", "gap_fill")) | not)
        | "mode must be \"fresh\" or \"gap_fill\" (got \($s.mode | tojson))"),
      (select(($s.target_repo == null
               or ($s.target_repo | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))) | not)
        | "target_repo must be an owner/name string or null"),
      (select(($s.visibility | IN("public", "private", null)) | not)
        | "visibility must be \"public\", \"private\" or null"),
      (select(($s.languages | type) != "object"
              or ((($s.languages.primary == null) or ($s.languages.primary | type == "string" and length > 0))
                  and ($s.languages.auxiliary | strs) | not)
              or ($s.languages | keys) != ["auxiliary", "primary"])
        | "languages must be {primary: str|null, auxiliary: [str]}"),
      (select(($s.topics | strs) | not) | "topics must be an array of strings"),
      (select(($s.interfaces | strs) | not) | "interfaces must be an array of strings"),
      (select($host_ok | not) | "host must be {os: non-empty str, homebrew: bool}"),
      (select($steps_ok | not) | "steps must be an object"),
      (select($files_ok | not) | "files must be an array of {path: non-empty str, step: str, disposition: str}"),
      (select($gh_ok | not) | "github_state must be an object"),
      ($st | to_entries[]
        | (select(.key as $k | $keys | index($k) | not) | "unknown step key: \(.key)"),
          (select(.value as $v | $disps | index($v) | not)
            | "steps.\(.key) has unknown disposition \(.value | tojson)")),
      ($fl[]
        | (select(.step as $k | $keys | index($k) | not) | "files entry \(.path) has unknown step key: \(.step)"),
          (select(.disposition as $v | $disps | index($v) | not)
            | "files entry \(.path) has unknown disposition \(.disposition | tojson)")),
      (select(($fl | map([.path, .step]) | length) != ($fl | map([.path, .step]) | unique | length))
        | "the same path appears twice under one step in files"),
      # files <-> steps: a touched step must be in steps, at its entries worst disposition
      ($fl | map(.step) | unique[] as $k
        | select($keys | index($k))
        | ($fl | map(select(.step == $k) | .disposition)) as $ds
        | select(all($ds[]; . as $d | $disps | index($d)))
        | ($ds | worst) as $w
        | if ($st | has($k) | not) then "files has entries for step \($k), which is absent from steps"
          elif $st[$k] != $w then "steps.\($k) is \($st[$k] | tojson) but its files entries fold to \($w | tojson)"
          else empty end),
      ($st | to_entries[] | .key as $k
        | select($keys | index($k))
        | select(($fl | any(.step == $k)) | not)
        | select(.value != "skipped")
        | "steps.\($k) is \(.value | tojson) with zero files entries (an applicable step with none is skipped)"),
      (select((($g | keys) | sort) != ($targets | sort))
        | "github_state must have exactly the keys branch_protection, secrets, sonar_project, apps_installed"),
      ($g | to_entries[] | select(.value as $v | $tdisps | index($v) | not)
        | "github_state.\(.key) has unknown disposition \(.value | tojson)"),
      (select(($s.stack | IN("resolved", "none", "detection_failed", "not_reached")) | not)
        | "stack must be resolved | none | detection_failed | not_reached"),
      (select(($s.early_stop | IN(null, "plan_declined", "detection", "precondition")) | not)
        | "early_stop must be null | plan_declined | detection | precondition"),
      (select(($s.approve_merge | IN(null, "merged", "pending", "request_changes", "red_ci", "retry_exhausted")) | not)
        | "approve_merge must be null | merged | pending | request_changes | red_ci | retry_exhausted"),
      (select(($s.pr == null or ($s.pr | type == "number" and . == floor and . >= 1)) | not)
        | "pr must be a positive integer or null"),
      # cross-field consistency
      (select($s.stack != "resolved" and $s.languages != {primary: null, auxiliary: []})
        | "stack \($s.stack | tojson) resolved no language, so languages must be {primary: null, auxiliary: []}"),
      (select(($s.stack | IN("none", "detection_failed")) and $s.early_stop != "detection")
        | "stack \($s.stack | tojson) stops the run at detection, so early_stop must be \"detection\""),
      (select($s.early_stop == "detection" and (($s.stack | IN("none", "detection_failed")) | not))
        | "early_stop \"detection\" needs stack none or detection_failed"),
      (select($s.stack == "not_reached" and $s.early_stop != "precondition")
        | "stack \"not_reached\" needs early_stop \"precondition\""),
      (select(($s.early_stop | IN("plan_declined", "detection")) and (($st | length) > 0 or ($fl | length) > 0))
        | "a run that stopped at \($s.early_stop) wrote nothing, so steps and files must be empty"),
      (select($s.early_stop == "plan_declined" and ($g | to_entries | any(.value != "skipped")))
        | "a declined plan reconciled nothing, so every github_state target must be skipped"),
      (select($s.early_stop != null and ($s.pr != null or $s.approve_merge != null))
        | "a run that stopped early opened no PR, so pr and approve_merge must be null"),
      (select($s.approve_merge != null and $s.pr == null)
        | "approve_merge is set but no pr is recorded"),
      (select($host_ok and ($supported_host | not)
              and (["secrets", "sonar_project", "apps_installed"] | any(. as $t | $g[$t] != "skipped")))
        | "Step 4.5 cannot run on this host, so secrets, sonar_project and apps_installed must be skipped")
    ] as $errs

  | if ($errs | length) > 0 then {errors: $errs} else
    # --- payload -----------------------------------------------------------------
    { mode: $s.mode,
      target_repo: $s.target_repo,
      visibility: $s.visibility,
      languages: {primary: $s.languages.primary, auxiliary: $s.languages.auxiliary},
      topics: $s.topics,
      interfaces: $s.interfaces,
      host: {os: $host.os, homebrew: $host.homebrew},
      steps: $st,
      files: ($disps | map(. as $d | {key: $d, value: ($fl | map(select(.disposition == $d)) | length)})
              | from_entries),
      github_state: ($targets | map({key: ., value: $g[.]}) | from_entries),
      ending: {stack: $s.stack, early_stop: $s.early_stop, approve_merge: $s.approve_merge}
    } as $payload
    # --- the fold: first match from the top ----------------------------------------
    | ($st | to_entries | map(.value)) as $sv
    | ($g | to_entries | map(.value)) as $gv
    | {payload: $payload,
       outcome: (
         if ($sv | index("failed")) or ($gv | index("failed"))
            or ($s.stack | IN("none", "detection_failed")) then "failed"
         elif $s.approve_merge | IN("request_changes", "red_ci", "retry_exhausted") then "escalated"
         elif ($sv | index("skipped")) or ($gv | index("refused"))
              or ($s.early_stop | IN("plan_declined", "precondition"))
              or ($supported_host | not) then "parked"
         else "success" end)}
    end
')" || { print -u2 -- "build-bootstrap-telemetry-record: failed to evaluate the state"; exit 1 }

if [[ "$(print -r -- "$result" | jq -r 'has("errors")')" == "true" ]]; then
  print -r -- "$result" | jq -r '.errors[] | "build-bootstrap-telemetry-record: state refused — \(.)"' >&2
  exit 1
fi

if (( print_outcome )); then
  print -r -- "$result" | jq -r '.outcome'
else
  print -r -- "$result" | jq -c '.payload'
fi
