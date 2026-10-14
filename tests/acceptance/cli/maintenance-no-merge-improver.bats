#!/usr/bin/env bats
#
# Acceptance cases for "maintenance: Stage 0 under --no-merge" (#2151) — the
# `cli`-tooled test_cases[] of its story-spec, one test per `tc-*` id:
#
#   tc-happy-no-merge-improver-left-local      #2176
#   tc-corner-no-merge-no-improver-unchanged   #2177
#   tc-corner-no-merge-mixed-targets           #2178
#   tc-error-no-merge-stage0-still-refused     #2179
#
# The use case: sam-operator runs /development:maintenance --no-merge on
# timo-jakob/ai-doc-organizer, whose python coverage is below Required. They
# get local branches only and no PR, see from the summary alone why python was
# not planned, and get one consistent telemetry record.
#
# A maintenance run is model-driven. These cases drive the deterministic steps
# it reaches under --no-merge: `maintenance-telemetry.zsh start`, then `emit`
# at Phase 9 with the run state and no phase8-stages record, since Phase 8
# never runs. The instructions the model follows on the way are pinned as the
# SKILL.md text it reads. The default gate's
# tests/build-maintenance-telemetry-record.bats and
# tests/maintenance-telemetry.bats cover the same criteria.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/maintenance/scripts"
  DRIVER="$SCRIPTS/maintenance-telemetry.zsh"
  BUILDER="$SCRIPTS/build-maintenance-telemetry-record.zsh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

  R="$BATS_TEST_TMPDIR/ai-doc-organizer"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" remote add origin git@github.com:timo-jakob/ai-doc-organizer.git

  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  CK="$BATS_TEST_TMPDIR/git/claude-maintenance"
  mkdir -p "$SCRATCH" "$CK"
  SINK="$BATS_TEST_TMPDIR/telemetry/maintenance.jsonl"
  RUN="$SCRATCH/maintenance-run.json"
  STATE="$SCRATCH/maintenance-state.json"
  PY="$SCRATCH/payload-python.json"
  jq -nc '{schema_version:"2", language:"python", dispatch_mode:"primary",
    findings_by_tool:{ruff:[{code:"F401"}], coverage:[{file:"src/organizer/index.py", coverage:61.0}]}}' > "$PY"
}

# The --no-merge run state the skill writes at Phase 9. $1 = a jq edit.
write_state() {
  jq -nc '{run_modifiers:{dry_run:false, no_merge:true, batch:null, tool:null, concern:null,
             no_issues:false, resumed:false},
           resumed_from_run_id:null,
           languages:{detected:["python"], actionable:["python"]},
           topics:[], payloads:[], groups_planned:0,
           human_action_required:0, errors:[],
           coverage_preflight:{spawned:false, languages:[]}}' | jq -c "${1:-.}" > "$STATE"
}
run_maintenance() {
  zsh "$DRIVER" start --run-file "$RUN" --telemetry-file "$SINK" --checkpoint-dir "$CK" \
    --ts 1791280000 >/dev/null
}
emit_record() {  # no --stages: a --no-merge run never enters Phase 8
  run --separate-stderr zsh "$DRIVER" emit --run-file "$RUN" --state "$STATE" \
    --repo-dir "$R" --v2-payload "$PY" --now 1791284132
}
record() { tail -n 1 "$SINK"; }

@test "tc-happy-no-merge-improver-left-local: python's improver stays local, no Stage 0, a parked record" {
  local doc
  doc="$(tr -s '[:space:]' ' ' < "$SKILL")"
  contains "$doc" '**Under `--no-merge`, Stage 0 does not run** (no push, no PR, no CI cycle, no merge), and the plugin is **not** re-invoked'
  contains "$doc" "Keep the improver's worktree branch for Phase 9's manual-review list."
  contains "$doc" '<lang>: planner did not run — the coverage pre-flight waits on the merge of <improver branch>.'
  contains "$doc" '**An improver-only language under `--no-merge` is never reported clean.**'
  run_maintenance
  write_state '.coverage_preflight = {spawned: true, languages: ["python"]}'
  emit_record
  [ "$status" -eq 0 ]
  zsh "$VALIDATE" "$SINK"
  local r; r="$(record)"
  [ "$(jq -r .outcome <<<"$r")" = "parked" ]
  [ "$(jq -c .payload.coverage_preflight <<<"$r")" = '{"spawned":true,"languages":["python"],"pr":null}' ]
  [ "$(jq -c .payload.prs.opened <<<"$r")" = "[]" ]
  [ "$(jq .payload.groups.planned <<<"$r")" = "0" ]
}

@test "tc-corner-no-merge-no-improver-unchanged: a plan on the first dispatch skips Phase 8 as before" {
  run_maintenance
  write_state '.groups_planned = 3'
  emit_record
  [ "$status" -eq 0 ]
  local r; r="$(record)"
  [ "$(jq -r .outcome <<<"$r")" = "parked" ]
  [ "$(jq -c .payload.coverage_preflight <<<"$r")" = '{"spawned":false,"languages":[],"pr":null}' ]
  [ "$(jq .payload.groups.planned <<<"$r")" = "3" ]
  [ "$(jq -c .payload.prs.opened <<<"$r")" = "[]" ]
}

@test "tc-corner-no-merge-mixed-targets: the topic's groups are planned, python's improver is not counted" {
  run_maintenance
  write_state '.topics = ["claude-plugin"] | .groups_planned = 2 | .coverage_preflight = {spawned: true, languages: ["python"]}'
  emit_record
  [ "$status" -eq 0 ]
  local r; r="$(record)"
  [ "$(jq -r .outcome <<<"$r")" = "parked" ]
  [ "$(jq -c .payload.groups <<<"$r")" = '{"planned":2,"worked":0,"deferred":0}' ]
  [ "$(jq -c .payload.coverage_preflight <<<"$r")" = '{"spawned":true,"languages":["python"],"pr":null}' ]
  [ "$(jq -c .payload.prs.opened <<<"$r")" = "[]" ]
}

@test "tc-error-no-merge-stage0-still-refused: a recorded stage0 on a --no-merge run is refused" {
  write_state '.coverage_preflight = {spawned: true, languages: ["python"]}'
  printf '%s' '{"stage0":{"pr":213,"status":"merged"}}' > "$SCRATCH/phase8-stages.json"
  run --separate-stderr zsh "$BUILDER" --state "$STATE" --stages "$SCRATCH/phase8-stages.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "a --dry-run or --no-merge run never enters Phase 8, yet stages are recorded"
}
