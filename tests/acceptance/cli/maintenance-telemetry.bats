#!/usr/bin/env bats
#
# Acceptance cases for "telemetry for the maintenance orchestrator" (#1228,
# epic #741 child (c)) — the `cli`-tooled test_cases[] of its story-spec, one
# test per `tc-*` id:
#
#   tc-happy-full-run-success                         #1267
#   tc-happy-zero-findings-noop                       #1268
#   tc-corner-dry-run-parked                          #1269
#   tc-corner-no-merge-parked                         #1270
#   tc-corner-batch-cap-deferred-success              #1271
#   tc-corner-awaiting-approval-success               #1272
#   tc-error-ci-fixer-exhausted-escalated             #1273
#   tc-error-human-action-required-parked             #1274
#   tc-corner-fold-precedence-escalated-beats-parked  #1275
#   tc-corner-resume-fresh-run-id                     #1276
#   tc-error-emitter-failure-never-fatal              #1277
#   tc-corner-hand-authored-payload-validates         #1278
#
# The use case: timo-maintainer runs /development:maintenance on
# timo-jakob/timos-claude-code-plugins and wants the tuning questions — which
# scanners earn their runtime, which groups need three ci-fixer rounds, where
# the run stops for a human — answered from the telemetry sink, with one
# unambiguous outcome per invocation.
#
# A maintenance run is model-driven, so these cases drive exactly the
# deterministic steps the skill calls: `maintenance-telemetry.zsh start` before
# Phase 1, then `emit` at Phase 9 with the run state, the phase8-stages record
# and the constructed v2 payloads. Nothing reaches GitHub. The default gate's
# tests/build-maintenance-telemetry-record.bats and tests/maintenance-telemetry.bats
# cover the same criteria.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/maintenance/scripts"
  DRIVER="$SCRIPTS/maintenance-telemetry.zsh"
  BUILDER="$SCRIPTS/build-maintenance-telemetry-record.zsh"
  EMITTER="$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

  R="$BATS_TEST_TMPDIR/timos-claude-code-plugins"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" remote add origin git@github.com:timo-jakob/timos-claude-code-plugins.git

  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  CK="$BATS_TEST_TMPDIR/git/claude-maintenance"   # checkpoint.zsh dir
  mkdir -p "$SCRATCH" "$CK"
  SINK="$BATS_TEST_TMPDIR/telemetry/maintenance.jsonl"
  RUN="$SCRATCH/maintenance-run.json"
  STATE="$SCRATCH/maintenance-state.json"
  STAGES="$SCRATCH/phase8-stages.json"

  # The constructed Phase 4 payloads, as dispatched: ruff 12, semgrep 3,
  # sonarcloud 7, dependabot 2 — the data sketch's findings.
  PY="$SCRATCH/payload-python.json"
  jq -nc '{schema_version:"2", language:"python", dispatch_mode:"primary",
    findings_by_tool:{
      ruff:[range(12) | {code:"F401", filename:"development/scripts/check_\(.).py"}],
      semgrep:[range(3) | {check_id:"python.lang.security.audit.subprocess-shell-true"}],
      sonarcloud:[range(7) | {rule:"python:S1192", severity:"MINOR"}],
      dependabot:[{number:301, title:"Bump ruff from 0.6.9 to 0.7.0"},
                  {number:302, title:"Bump pytest from 8.3.2 to 8.3.3"}]}}' > "$PY"
}

# The run state the skill writes at Phase 9. $1 = a jq edit of the live run.
write_state() {
  jq -nc '{run_modifiers:{dry_run:false, no_merge:false, batch:null, tool:null, concern:null,
             no_issues:false, resumed:false},
           resumed_from_run_id:null,
           languages:{detected:["python","markdown"], actionable:["python"]},
           topics:["claude-plugin","docs"], payloads:[], groups_planned:3,
           human_action_required:0, errors:[],
           coverage_preflight:{spawned:false, languages:[]}}' | jq -c "${1:-.}" > "$STATE"
}
write_stages() { printf '%s' "$1" > "$STAGES"; }

# The run, start to Phase 9: stamp past Phase 2's gate, emit at the end.
# $@ = extra `start` flags.
run_maintenance() {
  zsh "$DRIVER" start --run-file "$RUN" --telemetry-file "$SINK" --checkpoint-dir "$CK" \
    --ts 1791280000 "$@" >/dev/null
}
emit_record() {  # $@ = extra emit flags
  local -a st=()
  [ -f "$STAGES" ] && st=(--stages "$STAGES")
  run --separate-stderr zsh "$DRIVER" emit --run-file "$RUN" --state "$STATE" "${st[@]}" \
    --repo-dir "$R" --v2-payload "$PY" --now 1791284132 "$@"
}
record() { tail -n 1 "$SINK"; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

@test "tc-happy-full-run-success" {
  run_maintenance
  write_state
  write_stages '{"stage1":{"group":"ruff","pr":214,"ci_fix_count":1,"status":"merged"},
                 "stage2":{"group":"sonarcloud","pr":215,"ci_fix_count":0,"status":"merged"},
                 "stage3":{"group":"semgrep","pr":216,"ci_fix_count":2,"status":"awaiting_approval"}}'
  emit_record
  [ "$status" -eq 0 ]
  [ "$(lines "$SINK")" = "1" ]
  run zsh "$VALIDATE" "$SINK"
  [ "$status" -eq 0 ]
  local r; r="$(record)"
  [ "$(jq -r .outcome <<<"$r")" = "success" ]
  [ "$(jq -c '[.pipeline,.kind,.issue,.pr,.parent_run_id]' <<<"$r")" = '["maintenance","run",null,null,null]' ]
  [ "$(jq '.wall_s | type == "number" and . == floor and . >= 1' <<<"$r")" = "true" ]
  [ "$(jq -c .payload.findings_by_tool <<<"$r")" = '{"dependabot":2,"ruff":12,"semgrep":3,"sonarcloud":7}' ]
  [ "$(jq -c .payload.groups <<<"$r")" = '{"planned":3,"worked":3,"deferred":0}' ]
  [ "$(jq -c .payload.prs <<<"$r")" = '{"opened":[214,215,216],"merged":[214,215],"awaiting_approval":[216],"escalated":[]}' ]
  [ "$(jq -c .payload.ci_fixer_rounds <<<"$r")" = '{"214":1,"215":0,"216":2}' ]
}

@test "tc-happy-zero-findings-noop" {
  run_maintenance
  write_state '.groups_planned = 0'
  jq -nc '{schema_version:"2", language:"python", findings_by_tool:{ruff:[], semgrep:[]}}' > "$PY"
  emit_record
  [ "$status" -eq 0 ]
  [ "$(lines "$SINK")" = "1" ]
  local r; r="$(record)"
  [ "$(jq -r .outcome <<<"$r")" = "success" ]
  [ "$(jq -c '.payload.findings_by_tool | with_entries(select(.value > 0))' <<<"$r")" = "{}" ]
  [ "$(jq -c .payload.groups <<<"$r")" = '{"planned":0,"worked":0,"deferred":0}' ]
  [ "$(jq -c .payload.prs.opened <<<"$r")" = "[]" ]
}

@test "tc-corner-dry-run-parked" {
  # a dry run never touches the checkpoint store
  zsh "$DRIVER" start --run-file "$RUN" --telemetry-file "$SINK" --ts 1791280000 >/dev/null
  write_state '.run_modifiers.dry_run = true | .groups_planned = null'
  emit_record
  [ "$status" -eq 0 ]
  local r; r="$(record)"
  [ "$(jq -r .outcome <<<"$r")" = "parked" ]
  [ "$(jq .payload.run_modifiers.dry_run <<<"$r")" = "true" ]
  [ "$(jq -c .payload.prs.opened <<<"$r")" = "[]" ]
  [ "$(jq -c .payload.groups <<<"$r")" = '{"planned":null,"worked":0,"deferred":0}' ]
  [ ! -e "$CK/telemetry-run-id" ]
}

@test "tc-corner-no-merge-parked" {
  run_maintenance
  write_state '.run_modifiers.no_merge = true | .groups_planned = 4'
  emit_record
  [ "$status" -eq 0 ]
  local r; r="$(record)"
  [ "$(jq -r .outcome <<<"$r")" = "parked" ]
  [ "$(jq .payload.run_modifiers.no_merge <<<"$r")" = "true" ]
  [ "$(jq -c .payload.prs.opened <<<"$r")" = "[]" ]
  [ "$(jq .payload.groups.planned <<<"$r")" = "4" ]
  [ "$(jq .payload.groups.worked <<<"$r")" = "0" ]
}

@test "tc-corner-batch-cap-deferred-success" {
  run_maintenance
  write_state '.run_modifiers.batch = 3 | .groups_planned = 5
               | .coverage_preflight = {spawned:true, languages:["python"]}'
  write_stages '{"stage0":{"group":"coverage","pr":213,"ci_fix_count":0,"status":"merged"},
                 "stage1":{"group":"ruff","pr":214,"ci_fix_count":1,"status":"merged"},
                 "stage2":{"group":"sonarcloud","pr":215,"status":"merged"},
                 "stage3":{"group":"semgrep","pr":216,"ci_fix_count":2,"status":"awaiting_approval"},
                 "stage4":{"group":"dependabot","status":"deferred"},
                 "stage5":{"group":"code_scanning","status":"deferred"}}'
  emit_record
  [ "$status" -eq 0 ]
  local r; r="$(record)"
  [ "$(jq -r .outcome <<<"$r")" = "success" ]
  [ "$(jq -c .payload.groups <<<"$r")" = '{"planned":5,"worked":3,"deferred":2}' ]
  [ "$(jq .payload.coverage_preflight.pr <<<"$r")" = "213" ]
  # Stage 0 is not a planner group: worked counts the three groups only
  [ "$(jq '.payload.groups.worked == 3' <<<"$r")" = "true" ]
}

@test "tc-corner-awaiting-approval-success" {
  run_maintenance
  write_state
  # PR 216's approver-gate row is {"name":"approver-gate","state":"CANCELLED",
  # "bucket":"cancel"} — cancelled by design, so it is green and waits on a human
  write_stages '{"stage1":{"pr":214,"status":"merged"},"stage2":{"pr":215,"status":"merged"},
                 "stage3":{"pr":216,"ci_fix_count":0,"status":"awaiting_approval"}}'
  emit_record
  local r; r="$(record)"
  [ "$(jq -c .payload.prs.awaiting_approval <<<"$r")" = "[216]" ]
  [ "$(jq '.payload.prs.merged | index(216)' <<<"$r")" = "null" ]
  [ "$(jq -r .outcome <<<"$r")" = "success" ]
}

@test "tc-error-ci-fixer-exhausted-escalated" {
  run_maintenance
  write_state
  write_stages '{"stage1":{"pr":214,"ci_fix_count":1,"status":"merged"},
                 "stage2":{"pr":217,"ci_fix_count":3,"status":"escalated"}}'
  emit_record
  local r; r="$(record)"
  [ "$(jq -c '.payload.ci_fixer_rounds["217"]' <<<"$r")" = "3" ]
  [ "$(jq '[.payload.ci_fixer_rounds[]] | all(. <= 3)' <<<"$r")" = "true" ]
  [ "$(jq -c .payload.escalations.ci_fixer_exhausted <<<"$r")" = "[217]" ]
  [ "$(jq -c .payload.prs.escalated <<<"$r")" = "[217]" ]
  [ "$(jq -r .outcome <<<"$r")" = "escalated" ]
}

@test "tc-error-human-action-required-parked" {
  run_maintenance
  # java's coverage sat below the floor, so its dispatcher halted; python merged
  write_state '.languages = {detected:["python","java"], actionable:["python","java"]}
               | .human_action_required = 1'
  write_stages '{"stage1":{"pr":214,"status":"merged"},"stage2":{"pr":215,"status":"merged"},
                 "stage3":{"pr":216,"status":"merged"}}'
  emit_record
  local r; r="$(record)"
  [ "$(jq .payload.escalations.human_action_required <<<"$r")" = "1" ]
  [ "$(jq -r .outcome <<<"$r")" = "parked" ]
}

@test "tc-corner-fold-precedence-escalated-beats-parked" {
  write_state '.human_action_required = 1'
  write_stages '{"stage1":{"pr":217,"ci_fix_count":3,"status":"escalated"}}'
  run zsh "$BUILDER" --state "$STATE" --stages "$STAGES" --print-outcome
  [ "$status" -eq 0 ]
  [ "$output" = "escalated" ]
  write_state '.human_action_required = 1 | .errors = ["dispatch to development-python failed"]'
  run zsh "$BUILDER" --state "$STATE" --stages "$STAGES" --print-outcome
  [ "$output" = "failed" ]
}

@test "tc-corner-resume-fresh-run-id" {
  # the interrupted run: stamped, opened PR 214, merged it, then the session died
  run_maintenance
  local interrupted; interrupted="$(jq -r .run_id "$RUN")"
  # the resuming invocation
  zsh "$DRIVER" start --run-file "$RUN" --telemetry-file "$SINK" --checkpoint-dir "$CK" \
    --resume --ts 1791290000 >/dev/null
  write_state '.run_modifiers.resumed = true'
  write_stages '{"stage1":{"pr":214,"status":"merged","inherited":true},
                 "stage2":{"pr":215,"ci_fix_count":1,"status":"merged"}}'
  emit_record --now 1791291200
  [ "$status" -eq 0 ]
  [ "$(lines "$SINK")" = "1" ]
  local r; r="$(record)"
  [ "$(jq -r .run_id <<<"$r")" != "$interrupted" ]
  [ "$(jq -r .payload.resumed_from_run_id <<<"$r")" = "$interrupted" ]
  [ "$(jq .payload.run_modifiers.resumed <<<"$r")" = "true" ]
  [ "$(jq .parent_run_id <<<"$r")" = "null" ]
  [ "$(jq .payload.groups.worked <<<"$r")" = "1" ]
  [ "$(jq -c .payload.prs.opened <<<"$r")" = "[215]" ]
}

@test "tc-error-emitter-failure-never-fatal" {
  # Phase 9 as the skill runs it: render the summary, then the emit step.
  phase9() {
    echo "🚀 maintenance run complete — 3 PRs (2 merged, 1 awaiting approval)"
    zsh "$DRIVER" emit --run-file "$RUN" --state "$STATE" --stages "$STAGES" \
      --repo-dir "$R" --v2-payload "$PY"
    echo "Phase 10: tracking issues"
  }
  write_state
  write_stages '{"stage1":{"pr":214,"status":"merged"}}'
  cp "$EMITTER" "$BATS_TEST_TMPDIR/emit-noexec.zsh"; chmod -x "$BATS_TEST_TMPDIR/emit-noexec.zsh"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/emit-fails.sh"; chmod +x "$BATS_TEST_TMPDIR/emit-fails.sh"
  local bin
  for bin in "$BATS_TEST_TMPDIR/emit-noexec.zsh" "$BATS_TEST_TMPDIR/emit-fails.sh" "$BATS_TEST_TMPDIR/absent"; do
    run_maintenance
    MAINTENANCE_TELEMETRY_EMITTER_BIN="$bin" run --separate-stderr phase9
    [ "$status" -eq 0 ]
    contains "$output" "maintenance run complete"
    contains "$output" "Phase 10: tracking issues"
    contains "$stderr" "maintenance record NOT emitted"
    [ ! -e "$SINK" ]
  done
}

@test "tc-corner-hand-authored-payload-validates" {
  # Typed from ARCHITECTURE.md's *Maintenance telemetry* key table alone.
  local hand='{"run_modifiers":{"dry_run":false,"no_merge":false,"batch":3,"tool":null,"concern":null,"no_issues":false,"resumed":false},
    "resumed_from_run_id":null,
    "languages":{"detected":["python"],"actionable":["python"]},
    "topics":["claude-plugin"],
    "findings_by_tool":{"ruff":12},
    "groups":{"planned":5,"worked":1,"deferred":2},
    "prs":{"opened":[214],"merged":[214],"awaiting_approval":[],"escalated":[]},
    "ci_fixer_rounds":{"214":1},
    "escalations":{"human_action_required":0,"ci_fixer_exhausted":[]},
    "coverage_preflight":{"spawned":false,"languages":[],"pr":null}}'
  run --separate-stderr bash -c 'printf "%s" "$1" | zsh "$2" --pipeline maintenance --outcome success \
    --wall-s 1 --payload - --repo-dir "$3" --telemetry-file "$4"' _ "$hand" "$EMITTER" "$R" "$SINK"
  [ "$status" -eq 0 ]
  run zsh "$VALIDATE" "$SINK"
  [ "$status" -eq 0 ]

  # the builder's output for the equivalent run carries the same key paths
  jq -nc '{schema_version:"2", language:"python", findings_by_tool:{ruff:[range(12) | {code:"F401"}]}}' > "$PY"
  write_state '.run_modifiers.batch = 3 | .languages = {detected:["python"], actionable:["python"]}
               | .topics = ["claude-plugin"] | .groups_planned = 5 | .payloads = [{findings_by_tool:{ruff:[range(12) | {}]}}]'
  write_stages '{"stage1":{"pr":214,"ci_fix_count":1,"status":"merged"},
                 "stage2":{"status":"deferred"},"stage3":{"status":"deferred"}}'
  run --separate-stderr zsh "$BUILDER" --state "$STATE" --stages "$STAGES"
  [ "$status" -eq 0 ]
  local built="$output"
  local paths='[paths | map(tostring) | join(".")] | sort'
  [ "$(jq -c "$paths" <<<"$hand")" = "$(jq -c "$paths" <<<"$built")" ]
}
