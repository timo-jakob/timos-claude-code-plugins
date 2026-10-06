#!/usr/bin/env bats
#
# build-maintenance-telemetry-record.zsh (#1228): the pure payload builder for
# /development:maintenance's one `telemetry/v1` record, and the outcome fold
# behind --print-outcome. Every row of ARCHITECTURE.md's two contribution tables
# (A: per stage, B: per run) has a case here, plus the fold's precedence
# (failed > escalated > parked > success), the payload's shape and the states it
# refuses. The never-fatal emit and the sink are tests/maintenance-telemetry.bats.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  B="$REPO_ROOT/development/skills/maintenance/scripts/build-maintenance-telemetry-record.zsh"
  ST="$BATS_TEST_TMPDIR/state.json"
  SG="$BATS_TEST_TMPDIR/stages.json"
  # A live run on a python + claude-plugin repo: --batch=3 over 5 planned groups.
  BASE_STATE='{"run_modifiers":{"dry_run":false,"no_merge":false,"batch":3,"tool":null,
    "concern":null,"no_issues":false,"resumed":false},
    "resumed_from_run_id":null,
    "languages":{"detected":["python","markdown"],"actionable":["python"]},
    "topics":["claude-plugin"],
    "payloads":[{"findings_by_tool":{"ruff":[{"code":"F401"},{"code":"E501"}],"semgrep":[{"id":"x"}]}},
                {"findings_by_tool":{"ruff":[{"code":"B006"}],"plugin_version_check":[]}}],
    "groups_planned":5,"human_action_required":0,"errors":[],
    "coverage_preflight":{"spawned":false,"languages":[]}}'
  printf '%s' "$BASE_STATE" > "$ST"
  printf '{}' > "$SG"
}

state() { jq -c "$1" <<<"$BASE_STATE" > "$ST"; }        # $1 = jq edit of the base state
stages() { printf '%s' "$1" > "$SG"; }
build() { run --separate-stderr zsh "$B" --state "$ST" --stages "$SG" "$@"; }
outcome() { build --print-outcome; }

# ------------------------------------------------------------- table A rows

@test "table A: a merged stage contributes success" {
  stages '{"stage1":{"group":"ruff","pr":214,"ci_fix_count":1,"status":"merged"}}'
  outcome
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
}

@test "table A: an awaiting_approval stage contributes success and lists its PR there, not in merged" {
  stages '{"stage1":{"pr":214,"ci_fix_count":0,"status":"merged"},
           "stage2":{"pr":216,"ci_fix_count":2,"status":"awaiting_approval"}}'
  outcome
  [ "$output" = "success" ]
  build
  [ "$status" -eq 0 ]
  [ "$(jq -c '.prs.awaiting_approval' <<<"$output")" = "[216]" ]
  [ "$(jq -c '.prs.merged' <<<"$output")" = "[214]" ]
}

@test "table A: a deferred stage contributes success" {
  stages '{"stage1":{"pr":214,"status":"merged"},"stage2":{"group":"semgrep","status":"deferred"}}'
  outcome
  [ "$output" = "success" ]
}

@test "table A: an escalated stage contributes escalated" {
  stages '{"stage1":{"pr":217,"ci_fix_count":1,"status":"escalated"}}'
  outcome
  [ "$output" = "escalated" ]
}

# ------------------------------------------------------------- table B rows

@test "table B: a run that exhausted its plan is success" {
  stages '{"stage1":{"pr":214,"status":"merged"}}'
  outcome
  [ "$output" = "success" ]
}

@test "table B: a zero-finding no-op run is success, with empty collections" {
  state '.payloads = [{"findings_by_tool":{}}] | .groups_planned = 0'
  build
  [ "$status" -eq 0 ]
  [ "$(jq -c '.findings_by_tool' <<<"$output")" = "{}" ]
  [ "$(jq -c '.groups' <<<"$output")" = '{"planned":0,"worked":0,"deferred":0}' ]
  [ "$(jq -c '.prs.opened' <<<"$output")" = "[]" ]
  outcome
  [ "$output" = "success" ]
}

@test "table B: a --dry-run is parked, with planned null and no PRs" {
  state '.run_modifiers.dry_run = true | .groups_planned = null'
  outcome
  [ "$output" = "parked" ]
  build
  [ "$(jq -c '.groups' <<<"$output")" = '{"planned":null,"worked":0,"deferred":0}' ]
  [ "$(jq -c '.prs.opened' <<<"$output")" = "[]" ]
  [ "$(jq '.run_modifiers.dry_run' <<<"$output")" = "true" ]
}

@test "table B: a --no-merge run is parked, with planned set from the plan" {
  state '.run_modifiers.no_merge = true | .groups_planned = 4'
  outcome
  [ "$output" = "parked" ]
  build
  [ "$(jq -c '.groups' <<<"$output")" = '{"planned":4,"worked":0,"deferred":0}' ]
  [ "$(jq -c '.prs.opened' <<<"$output")" = "[]" ]
}

@test "table B: a human_action_required halt parks the run even when every stage merged" {
  state '.human_action_required = 1'
  stages '{"stage1":{"pr":214,"status":"merged"},"stage2":{"pr":215,"status":"merged"}}'
  outcome
  [ "$output" = "parked" ]
  build
  [ "$(jq '.escalations.human_action_required' <<<"$output")" = "1" ]
}

@test "table B: an observed error fails the run" {
  state '.errors = ["gather-python-findings.sh exited 1"]'
  outcome
  [ "$output" = "failed" ]
}

# ------------------------------------------------------------- the fold

@test "fold: escalated beats parked (an escalated stage AND a human_action_required halt)" {
  state '.human_action_required = 1'
  stages '{"stage1":{"pr":217,"ci_fix_count":3,"status":"escalated"}}'
  outcome
  [ "$output" = "escalated" ]
}

@test "fold: failed beats escalated and parked" {
  state '.human_action_required = 1 | .errors = ["dispatch to development-python failed"]'
  stages '{"stage1":{"pr":217,"ci_fix_count":3,"status":"escalated"}}'
  outcome
  [ "$output" = "failed" ]
}

@test "fold: parked beats success (a --no-merge run with nothing else)" {
  state '.run_modifiers.no_merge = true'
  outcome
  [ "$output" = "parked" ]
}

@test "fold: a run with only success contributions is success" {
  stages '{"stage1":{"pr":214,"status":"merged"},"stage2":{"pr":216,"status":"awaiting_approval"},
           "stage3":{"status":"deferred"}}'
  outcome
  [ "$output" = "success" ]
}

# ------------------------------------------------------------- payload shape

@test "payload carries exactly the documented keys and no envelope key" {
  build
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys' <<<"$output")" = '["ci_fixer_rounds","coverage_preflight","escalations","findings_by_tool","groups","languages","prs","resumed_from_run_id","run_modifiers","topics"]' ]
  [ "$(jq -c '.run_modifiers | keys' <<<"$output")" = '["batch","concern","dry_run","no_issues","no_merge","resumed","tool"]' ]
}

@test "findings_by_tool sums each tool's findings across every payload" {
  build
  [ "$(jq -c '.findings_by_tool' <<<"$output")" = '{"plugin_version_check":0,"ruff":3,"semgrep":1}' ]
}

@test "prs: merged, awaiting_approval and escalated partition opened" {
  stages '{"stage0":{"pr":213,"status":"merged"},"stage1":{"pr":215,"ci_fix_count":1,"status":"merged"},
           "stage2":{"pr":216,"status":"awaiting_approval"},"stage3":{"pr":217,"ci_fix_count":3,"status":"escalated"},
           "stage4":{"group":"dependabot","pr":null,"status":"merged"}}'
  state '.coverage_preflight = {"spawned":true,"languages":["python"]}'
  build
  [ "$status" -eq 0 ]
  [ "$(jq -c '.prs.opened' <<<"$output")" = "[213,215,216,217]" ]
  [ "$(jq '(.prs.merged + .prs.awaiting_approval + .prs.escalated | sort) == .prs.opened' <<<"$output")" = "true" ]
  [ "$(jq '[.prs.merged, .prs.awaiting_approval, .prs.escalated] | add | length == (unique | length)' <<<"$output")" = "true" ]
}

@test "--batch: worked and deferred count planner groups, and Stage 0 is in neither" {
  state '.coverage_preflight = {"spawned":true,"languages":["python"]}'
  stages '{"stage0":{"pr":213,"status":"merged"},"stage1":{"pr":214,"status":"merged"},
           "stage2":{"pr":215,"status":"merged"},"stage3":{"pr":216,"status":"awaiting_approval"},
           "stage4":{"status":"deferred"},"stage5":{"status":"deferred"}}'
  build
  [ "$(jq -c '.groups' <<<"$output")" = '{"planned":5,"worked":3,"deferred":2}' ]
  [ "$(jq -c '.coverage_preflight' <<<"$output")" = '{"spawned":true,"languages":["python"],"pr":213}' ]
}

@test "ci_fixer_rounds per opened PR; only an escalated PR at the ceiling is ci_fixer_exhausted" {
  stages '{"stage1":{"pr":214,"ci_fix_count":1,"status":"merged"},
           "stage2":{"pr":217,"ci_fix_count":3,"status":"escalated"},
           "stage3":{"pr":218,"ci_fix_count":0,"status":"escalated"}}'
  build
  [ "$(jq -c '.ci_fixer_rounds' <<<"$output")" = '{"214":1,"217":3,"218":0}' ]
  [ "$(jq -c '.escalations.ci_fixer_exhausted' <<<"$output")" = "[217]" ]
  [ "$(jq -c '.prs.escalated' <<<"$output")" = "[217,218]" ]
}

@test "resume: inherited stages are counted neither as worked nor as opened, and still fold" {
  state '.run_modifiers.resumed = true | .resumed_from_run_id = "maintenance-1791200000-ab12"'
  stages '{"stage0":{"pr":213,"status":"merged","inherited":true},
           "stage1":{"pr":214,"status":"merged","inherited":true},
           "stage2":{"pr":215,"status":"merged"}}'
  build
  [ "$status" -eq 0 ]
  [ "$(jq -c '.prs.opened' <<<"$output")" = "[215]" ]
  [ "$(jq -c '.coverage_preflight.pr' <<<"$output")" = "null" ]
  [ "$(jq '.groups.worked' <<<"$output")" = "1" ]
  [ "$(jq -r '.resumed_from_run_id' <<<"$output")" = "maintenance-1791200000-ab12" ]
  [ "$(jq -c '.ci_fixer_rounds' <<<"$output")" = '{"215":0}' ]
}

@test "omitting --stages reads as no stages" {
  run --separate-stderr zsh "$B" --state "$ST"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.groups' <<<"$output")" = '{"planned":5,"worked":0,"deferred":0}' ]
}

# ------------------------------------------------------------- refused states

refused() {  # $1 = a substring the refusal must name
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "state refused"
  contains "$stderr" "$1"
}

@test "refuses planned non-null under --dry-run" {
  state '.run_modifiers.dry_run = true'
  build
  refused "groups_planned must be null under --dry-run"
}

@test "refuses planned null on a run that was not --dry-run" {
  state '.groups_planned = null'
  build
  refused "groups_planned is null on a run that was not --dry-run"
}

@test "refuses stages on a --no-merge run" {
  state '.run_modifiers.no_merge = true'
  stages '{"stage1":{"pr":214,"status":"merged"}}'
  build
  refused "never enters Phase 8"
}

@test "refuses a ci_fix_count above the ceiling of 3" {
  stages '{"stage1":{"pr":214,"ci_fix_count":4,"status":"escalated"}}'
  build
  refused "ci_fix_count must be an integer 0..3"
}

@test "refuses a non-terminal stage status" {
  stages '{"stage1":{"pr":214,"status":"pr_opened"}}'
  build
  refused "is not terminal"
}

@test "refuses a deferred stage that records a PR" {
  stages '{"stage1":{"pr":214,"status":"deferred"}}'
  build
  refused "is deferred but records a PR"
}

@test "refuses one PR recorded by two stages" {
  stages '{"stage1":{"pr":214,"status":"merged"},"stage2":{"pr":214,"status":"escalated"}}'
  build
  refused "the same PR is recorded by two stages"
}

@test "refuses resume facts on a run that did not resume" {
  state '.resumed_from_run_id = "maintenance-1791200000-ab12"'
  stages '{"stage1":{"pr":214,"status":"merged","inherited":true}}'
  build
  refused "resumed_from_run_id is set on a run that did not resume"
  contains "$stderr" "inherited stages on a run that did not resume"
}

@test "refuses a resumed --dry-run and a human_action_required halt under --dry-run" {
  state '.run_modifiers.dry_run = true | .run_modifiers.resumed = true | .groups_planned = null | .human_action_required = 1'
  build
  refused "--dry-run never resumes"
  contains "$stderr" "nothing can halt on human_action_required"
}

@test "refuses a stage0 without a spawned coverage improver" {
  stages '{"stage0":{"pr":213,"status":"merged"}}'
  build
  refused "a stage0 is recorded but coverage_preflight.spawned is false"
}

@test "refuses a deferred stage0" {
  state '.coverage_preflight.spawned = true'
  stages '{"stage0":{"status":"deferred"}}'
  build
  refused "stage0 (the coverage pre-flight) is never deferred"
}

@test "refuses more groups worked or deferred than were planned" {
  state '.groups_planned = 1'
  stages '{"stage1":{"pr":214,"status":"merged"},"stage2":{"status":"deferred"}}'
  build
  refused "more groups were worked or deferred than were planned"
}

@test "refuses a findings_by_tool value that is not an array" {
  state '.payloads = [{"findings_by_tool":{"ruff":3}}]'
  build
  refused "findings_by_tool.ruff is not an array of findings"
}

@test "refuses mistyped modifiers and fields, reporting every breach at once" {
  state '.run_modifiers.batch = 0 | .run_modifiers.tool = 3 | .human_action_required = -1 | .errors = "x" | .topics = "y"'
  build
  refused "run_modifiers.batch must be a positive integer or null"
  contains "$stderr" "run_modifiers.tool must be a string or null"
  contains "$stderr" "human_action_required must be a non-negative integer"
  contains "$stderr" "errors must be an array of strings"
  contains "$stderr" "topics must be an array of strings"
}

@test "--print-outcome also refuses a contradictory state rather than fold it" {
  state '.run_modifiers.dry_run = true'
  outcome
  refused "groups_planned must be null under --dry-run"
}

# ------------------------------------------------------------- usage

@test "usage: --state is required, and a bad operand or flag is exit 2" {
  run --separate-stderr zsh "$B"
  [ "$status" -eq 2 ]
  contains "$stderr" "--state is required"
  run --separate-stderr zsh "$B" --state "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
  contains "$stderr" "--state file does not exist"
  run --separate-stderr zsh "$B" --state "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  contains "$stderr" "--state is a directory"
  run --separate-stderr zsh "$B" --state "$ST" --stages
  [ "$status" -eq 2 ]
  contains "$stderr" "--stages requires a value"
  run --separate-stderr zsh "$B" --state "$ST" --bogus
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown flag: --bogus"
  run --separate-stderr zsh "$B" --state "$ST" extra
  [ "$status" -eq 2 ]
  contains "$stderr" "unexpected argument: extra"
}

@test "an input that is not one JSON object is exit 1" {
  printf '[1,2]' > "$ST"
  build
  [ "$status" -eq 1 ]
  contains "$stderr" "state must be a single JSON object"
  printf '%s' "$BASE_STATE" > "$ST"
  printf '{}{}' > "$SG"
  build
  [ "$status" -eq 1 ]
  contains "$stderr" "stages must be a single JSON object"
}

@test "--help prints usage and exits 0" {
  run zsh "$B" --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage: build-maintenance-telemetry-record.zsh"
}
