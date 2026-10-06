#!/usr/bin/env bats
#
# maintenance-telemetry.zsh (#1228): the /development:maintenance run's own
# telemetry — stamping the start, pre-minting the run_id, remembering it for a
# later --resume, and the never-fatal build + emit through the shared emitter.
# The payload's shape and the outcome fold are
# tests/build-maintenance-telemetry-record.bats. The last block pins the
# SKILL.md procedure that calls these steps.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  D="$REPO_ROOT/development/skills/maintenance/scripts/maintenance-telemetry.zsh"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

  R="$BATS_TEST_TMPDIR/plugins-repo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" remote add origin git@github.com:timo-jakob/timos-claude-code-plugins.git
  DEFAULT_SINK="$R/.claude/telemetry/telemetry.jsonl"

  S="$BATS_TEST_TMPDIR/scratch"
  CK="$BATS_TEST_TMPDIR/ckpt"
  mkdir -p "$S" "$CK"
  RUN="$S/maintenance-run.json"
  STATE="$S/maintenance-state.json"
  STAGES="$S/phase8-stages.json"
  P1="$S/payload-python.json"
  P2="$S/payload-claude-plugin.json"
  printf '%s' '{"schema_version":"2","language":"python","findings_by_tool":{"ruff":[{"code":"F401"},{"code":"E501"}],"semgrep":[{"check_id":"py.sqli"}]}}' > "$P1"
  printf '%s' '{"schema_version":"2","language":"claude-plugin","findings_by_tool":{"plugin_version_check":[{"plugin":"development"}]}}' > "$P2"
  printf '%s' '{"run_modifiers":{"dry_run":false,"no_merge":false,"batch":null,"tool":null,"concern":null,"no_issues":false,"resumed":false},"resumed_from_run_id":null,"languages":{"detected":["python"],"actionable":["python"]},"topics":["claude-plugin"],"payloads":[],"groups_planned":2,"human_action_required":0,"errors":[],"coverage_preflight":{"spawned":false,"languages":[]}}' > "$STATE"
  printf '%s' '{"stage1":{"group":"ruff","pr":214,"ci_fix_count":1,"status":"merged"},"stage2":{"group":"semgrep","pr":215,"ci_fix_count":0,"status":"awaiting_approval"}}' > "$STAGES"
}

start() { run --separate-stderr zsh "$D" start --run-file "$RUN" "$@"; }
emit() {
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$STATE" --stages "$STAGES" \
    --repo-dir "$R" --v2-payload "$P1" --v2-payload "$P2" "$@"
}
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# ------------------------------------------------------------------- start

@test "start pre-mints a maintenance run_id in the emitter's format and writes the run file" {
  start --ts 1791284000
  [ "$status" -eq 0 ]
  matches "$(jq -r .run_id <<<"$output")" '^maintenance-1791284000-[0-9a-f]{4}$'
  [ "$(jq -c . "$RUN")" = "$(jq -c . <<<"$output")" ]
  [ "$(jq -c '[.telemetry_file, .telemetry_dir, .resumed_from_run_id]' "$RUN")" = "[null,null,null]" ]
}

@test "start makes the sink paths absolute and expands a leading ~" {
  cd "$S"
  HOME="$BATS_TEST_TMPDIR/home" start --telemetry-file rel/sink.jsonl --telemetry-dir '~/telemetry'
  [ "$status" -eq 0 ]
  # absolute against the cwd (spelled however the platform spells $S — macOS
  # may report it through /private), never left relative
  starts_with "$(jq -r .telemetry_file "$RUN")" "/"
  ends_with "$(jq -r .telemetry_file "$RUN")" "/scratch/rel/sink.jsonl"
  [ "$(jq -r .telemetry_dir "$RUN")" = "$BATS_TEST_TMPDIR/home/telemetry" ]
}

@test "start records the run_id in the checkpoint store, and a --resume names the interrupted run" {
  start --checkpoint-dir "$CK" --ts 1791280000
  local first; first="$(jq -r .run_id "$RUN")"
  [ "$(cat "$CK/telemetry-run-id")" = "$first" ]
  [ "$(jq -r .resumed_from_run_id "$RUN")" = "null" ]
  start --checkpoint-dir "$CK" --resume --ts 1791284000
  [ "$status" -eq 0 ]
  [ "$(jq -r .resumed_from_run_id "$RUN")" = "$first" ]
  [ "$(jq -r .run_id "$RUN")" != "$first" ]
  [ "$(cat "$CK/telemetry-run-id")" = "$(jq -r .run_id "$RUN")" ]
}

@test "a --resume with no recoverable id records resumed_from_run_id null" {
  start --checkpoint-dir "$CK" --resume
  [ "$(jq -r .resumed_from_run_id "$RUN")" = "null" ]
  printf 'not-a-run-id\n' > "$CK/telemetry-run-id"
  start --checkpoint-dir "$CK" --resume
  [ "$(jq -r .resumed_from_run_id "$RUN")" = "null" ]
}

@test "without --resume a recorded id is never taken as resumed_from" {
  printf 'maintenance-1791280000-ab12\n' > "$CK/telemetry-run-id"
  start --checkpoint-dir "$CK"
  [ "$(jq -r .resumed_from_run_id "$RUN")" = "null" ]
}

@test "an unwritable checkpoint store warns and still starts the run" {
  start --checkpoint-dir "$BATS_TEST_TMPDIR/no/such/dir"
  [ "$status" -eq 0 ]
  contains "$stderr" "could not record the run_id"
  [ -f "$RUN" ]
}

@test "start: usage errors are exit 2, an unwritable run file is exit 1" {
  run --separate-stderr zsh "$D" start
  [ "$status" -eq 2 ]
  contains "$stderr" "--run-file is required"
  start --ts abc
  [ "$status" -eq 2 ]
  start --telemetry-dir
  [ "$status" -eq 2 ]
  contains "$stderr" "--telemetry-dir requires a value"
  start --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$D" start --run-file "$BATS_TEST_TMPDIR/no/such/run.json"
  [ "$status" -eq 1 ]
  contains "$stderr" "cannot write the run file"
}

# ------------------------------------------------------------------- emit

@test "emit appends exactly one valid maintenance record with the documented envelope" {
  start --ts 1791280000
  emit --now 1791284132
  [ "$status" -eq 0 ]
  [ "$(lines "$DEFAULT_SINK")" = "1" ]
  run zsh "$VALIDATE" "$DEFAULT_SINK"
  [ "$status" -eq 0 ]
  local rec; rec="$(cat "$DEFAULT_SINK")"
  [ "$(jq -c '[.kind, .pipeline, .issue, .pr, .parent_run_id, .tokens, .outcome]' <<<"$rec")" = '["run","maintenance",null,null,null,null,"success"]' ]
  [ "$(jq '.wall_s' <<<"$rec")" = "4132" ]
  [ "$(jq '.wall_s | type == "number" and . == floor and . >= 1' <<<"$rec")" = "true" ]
  [ "$(jq -r .run_id <<<"$rec")" = "$(jq -r .run_id "$RUN")" ]
  [ "$(jq '.ts' <<<"$rec")" = "1791280000" ]
  [ "$(jq -r .repo <<<"$rec")" = "timo-jakob/timos-claude-code-plugins" ]
}

@test "emit counts findings_by_tool from the --v2-payload files, as dispatched" {
  start
  emit
  [ "$(jq -c .payload.findings_by_tool "$DEFAULT_SINK")" = '{"plugin_version_check":1,"ruff":2,"semgrep":1}' ]
}

@test "emit takes resumed_from_run_id from the run file, never from the state" {
  printf 'maintenance-1791280000-ab12\n' > "$CK/telemetry-run-id"
  start --checkpoint-dir "$CK" --resume
  jq '.run_modifiers.resumed = true | .resumed_from_run_id = "maintenance-1-0000"' "$STATE" > "$STATE.new"
  mv "$STATE.new" "$STATE"
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -r .payload.resumed_from_run_id "$DEFAULT_SINK")" = "maintenance-1791280000-ab12" ]
  [ "$(jq -r .run_id "$DEFAULT_SINK")" != "maintenance-1791280000-ab12" ]
}

@test "sink precedence: --telemetry-file beats --telemetry-dir beats the local default" {
  start --telemetry-file "$S/one.jsonl" --telemetry-dir "$S/dir"
  emit
  [ "$(lines "$S/one.jsonl")" = "1" ]
  [ ! -e "$S/dir/timo-jakob-timos-claude-code-plugins.jsonl" ]
  [ ! -e "$DEFAULT_SINK" ]
  mkdir -p "$S/dir"
  start --telemetry-dir "$S/dir"
  emit
  [ "$(lines "$S/dir/timo-jakob-timos-claude-code-plugins.jsonl")" = "1" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "a repeated emit is refused with the advisory and appends nothing" {
  start
  emit
  [ "$(jq .emitted "$RUN")" = "true" ]
  emit
  [ "$status" -eq 0 ]
  contains "$stderr" "maintenance record NOT emitted"
  contains "$stderr" "already emitted"
  [ "$(lines "$DEFAULT_SINK")" = "1" ]
}

never_fatal() {  # asserts exit 0, the advisory, and an untouched sink
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  contains "$stderr" "maintenance record NOT emitted"
  contains "$stderr" "the run's result is unaffected"
  [ ! -e "$DEFAULT_SINK" ]
  [ ! -f "$RUN" ] || [ "$(jq '.emitted // false' "$RUN")" = "false" ]
}

@test "never fatal: an absent emitter" {
  start
  MAINTENANCE_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/absent" emit
  never_fatal
  contains "$stderr" "emitter missing or not executable"
}

@test "never fatal: a non-executable emitter" {
  start
  cp "$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh" "$BATS_TEST_TMPDIR/emit.zsh"
  chmod -x "$BATS_TEST_TMPDIR/emit.zsh"
  MAINTENANCE_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/emit.zsh" emit
  never_fatal
}

@test "never fatal: an emitter that exits non-zero" {
  start
  printf '#!/bin/sh\necho "stub emitter: boom" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/fail.sh"
  chmod +x "$BATS_TEST_TMPDIR/fail.sh"
  MAINTENANCE_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/fail.sh" emit
  never_fatal
  contains "$stderr" "the emitter exited 1"
}

@test "never fatal: a state the builder refuses" {
  start
  jq '.run_modifiers.dry_run = true' "$STATE" > "$STATE.new"; mv "$STATE.new" "$STATE"
  emit
  never_fatal
  contains "$stderr" "the payload builder refused the state"
}

@test "never fatal: no run file, a malformed v2 payload, a missing state" {
  emit
  never_fatal
  contains "$stderr" "no readable run file"
  start
  printf 'not json' > "$P2"
  emit
  never_fatal
  contains "$stderr" "is not one readable JSON object"
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$S/missing.json" --repo-dir "$R"
  never_fatal
  contains "$stderr" "no readable state file"
}

@test "emit forwards --repo-type onto the envelope, and drops a literal null" {
  start
  emit --repo-type claude-plugin
  [ "$(jq -r .repo_type "$DEFAULT_SINK")" = "claude-plugin" ]
  rm -f "$DEFAULT_SINK"
  start
  emit --repo-type null
  [ "$status" -eq 0 ]
  # a `jq -r` of an absent repo_type is the string `null`; it must never land
  [ "$(jq -c .repo_type "$DEFAULT_SINK")" != '"null"' ]
}

@test "--help prints both subcommands' usage and exits 0" {
  run zsh "$D" --help
  [ "$status" -eq 0 ]
  contains "$output" "maintenance-telemetry.zsh start --run-file FILE"
  contains "$output" "maintenance-telemetry.zsh emit --run-file FILE"
}

@test "emit: a missing required flag is exit 2" {
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$STATE"
  [ "$status" -eq 2 ]
  contains "$stderr" "--repo-dir is required"
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$STATE" --repo-dir "$R" --now x
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$D" nope
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown subcommand: nope"
}

# ------------------------------------------------------------------- the skill

@test "SKILL.md: Phase 0 accepts both sink flags and states the emitter's precedence" {
  run cat "$SKILL"
  contains "$output" '`--telemetry-file PATH` / `--telemetry-dir DIR`'
  contains "$output" "Precedence is the emitter's: \`--telemetry-file\` >"
}

@test "SKILL.md: the start stamp runs once per invocation, past Phase 2's gate, and a stop before it emits none" {
  run cat "$SKILL"
  contains "$output" "### Telemetry — stamp the run's start (#1228)"
  contains "$output" "When Phase 2's gate lets the run proceed, stamp the start **once per invocation**"
  contains "$output" "Phase 1 or Phase 2 — emits **none**."
  contains "$output" "Otherwise stamp the run's start (Phase 0, *Telemetry — stamp the run's start*),"
  contains "$output" '[--checkpoint-dir "$("<skill-base-dir>/scripts/checkpoint.zsh" dir)"] [--resume]'
  contains "$output" "A resume is its own run: a **fresh** \`run_id\`"
  # the heading precedes Phase 1
  local stamp p1
  stamp=$(grep -n "^### Telemetry — stamp the run's start" "$SKILL" | cut -d: -f1)
  p1=$(grep -n '^## Phase 1 — detect' "$SKILL" | cut -d: -f1)
  [ -n "$stamp" ] && [ -n "$p1" ] && [ "$stamp" -lt "$p1" ]
}

@test "SKILL.md: a --resume re-walks Phase 2's gate and stamps there before continuing" {
  run cat "$SKILL"
  contains "$output" "state. **Phase 2's *Proceed / halt* gate is always walked again**,"
  contains "$output" "jumped over — because that gate is where every run, a resumed one"
  contains "$output" "mint a second run). A \`--resume\` reaches this gate too: the resume entry"
  contains "$output" "re-walks Phase 2 from the restored partition, stamps here, and only **then**"
  contains "$output" "at Phase 6 or Phase 8 has a run file by the time Phase 9 emits:"
}

@test "SKILL.md: a --dry-run emits from the kept payload files before Phase 5 removes them" {
  run cat "$SKILL"
  contains "$output" "to \`parked\`; it reads the kept payload files, so emit **before** the removal"
  local emit_line rm_line
  emit_line=$(grep -n "so emit \*\*before\*\* the removal" "$SKILL" | cut -d: -f1)
  rm_line=$(awk -v s="$emit_line" 'NR > s && /^rm -rf -- "<payload-dir>"$/ { print NR; exit }' "$SKILL")
  [ -n "$emit_line" ] && [ -n "$rm_line" ] && [ "$emit_line" -lt "$rm_line" ]
}

@test "SKILL.md: every ending reaches the one Phase 9 emit, and errors are recorded" {
  run cat "$SKILL"
  contains "$output" "### Emit the run's record (#1228)"
  contains "$output" "(Phase 5), a \`--no-merge\` run (Phase 8 skipped), a Phase 7"
  contains "$output" "emit the run's record (Phase 9, *Emit the"
  contains "$output" "Count each halted target for the run's record"
  contains "$output" "is noted in the run state's \`errors\` as you report it"
  local emit p10
  emit=$(grep -n "^### Emit the run's record" "$SKILL" | cut -d: -f1)
  p10=$(grep -n '^## Phase 10' "$SKILL" | cut -d: -f1)
  [ "$emit" -lt "$p10" ]
  [ "$(grep -c "maintenance-telemetry.zsh\" emit" "$SKILL")" = "1" ]
}

@test "SKILL.md: the emit is never fatal and the outcome is never picked by hand" {
  run cat "$SKILL"
  contains "$output" "so never pick it yourself"
  contains "$output" "**Telemetry is never"
  contains "$output" "prints one \`maintenance record NOT emitted\` advisory and appends nothing"
  contains "$output" "Skip it only when"
}

@test "SKILL.md: the run-state and flag rules the emit depends on are stated" {
  run cat "$SKILL"
  contains "$output" "Each takes a value — halt on a missing, empty or \`--\`-shaped one, or"
  contains "$output" "Every invocation that gets past Phase 2's *Proceed / halt* gate appends **exactly"
  contains "$output" "Pass \`--checkpoint-dir\` on every run except \`--dry-run\` (which never touches"
  contains "$output" "re-spawned \`agent_spawned\` stage is this run's work and is not marked."
  contains "$output" "from facts noted where each was decided, never reconstructed at the end:"
  contains "$output" "\`languages\` — Phase 2's partition; \`topics\` — the topic plugins that"
  contains "$output" "targets (before any \`--batch\` cap), \`0\` when none returned a plan; \`null\`"
  contains "$output" "**exactly** under \`--dry-run\`, where the planner never runs. Stage 0 is never"
  contains "$output" "\`errors\` — one line per error you observed and reported (gather, dispatch,"
  contains "$output" "\`escalated\` in the scratch copy below, never in the store."
  contains "$output" "- \`payloads\` — leave \`[]\` and pass each kept payload file as a \`--v2-payload\`"
  contains "$output" "instead: \`<payload-dir>/payload-<target>.json\`, one per target Phase 4 wrote"
  contains "$output" "\`phase4-payload\` — the checkpoint copies in \`checkpoint.zsh dir\` that its"
  contains "$output" "used. Pass none only when no payload was built."
  contains "$output" "- \`coverage_preflight\` — whether **this invocation** spawned Stage 0's improver,"
  contains "$output" "never hand-roll an envelope, a run_id or a payload."
  contains "$output" "re-entry re-reads the run file, never calls \`start\` again — a second call would"
  contains "$output" "- Pass a sink flag only when Phase 0 was given it. A resumed run takes **this**"
  contains "$output" "the store), and \`--resume\` exactly when the resume entry resumed."
  contains "$output" "one line and **skip the Phase 9 emit**."
  contains "$output" "The last step of Phase 9, **after** the summary is rendered, on every ending"
  contains "$output" "\`resumed_from_run_id\` may stay \`null\`: \`emit\` takes it from the run file."
  contains "$output" "phase8-stages\` into a scratch file; omit \`--stages\` when there is none (a"
  contains "$output" "that line and carry on — the run's summary, exit and PRs stand. An exit 2 is"
  contains "$output" "your own malformed call: fix it and re-run once; a second costs the record."
}

@test "SKILL.md: phase8-stages records deferred groups, opened PRs only, and inherited stages" {
  run cat "$SKILL"
  contains "$output" '`{ "group": …, "status": "deferred" }` with no'
  contains "$output" "a vendor-PR stage acts on"
  contains "$output" 'with `"inherited": true`'
  contains "$output" "as a \`deferred\`"
}

@test "ARCHITECTURE.md: the fold is a cross-pipeline convention and the maintenance keys are documented" {
  run cat "$ARCH"
  contains "$output" "8. **A multi-ending run folds its outcome, worst state wins (#1228).**"
  contains "$output" "## Maintenance telemetry (#1228)"
  local k
  for k in run_modifiers resumed_from_run_id languages topics findings_by_tool groups prs \
           ci_fixer_rounds escalations coverage_preflight; do
    contains "$output" "| \`$k\` |"
  done
}
