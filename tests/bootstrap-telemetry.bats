#!/usr/bin/env bats
#
# bootstrap-telemetry.zsh (#1229): the /development:bootstrap run's own
# telemetry — stamping the start, pre-minting the run_id, reading the host,
# siting the record in the TARGET repo's main checkout, and the never-fatal
# build + emit through the shared emitter. The payload's shape and the outcome
# fold are tests/build-bootstrap-telemetry-record.bats. The last block pins the
# SKILL.md procedure that calls these steps.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  D="$REPO_ROOT/development/skills/bootstrap/scripts/bootstrap-telemetry.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  ZSH="$(command -v zsh)"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

  # A = the directory bootstrap is invoked from; B = the target it bootstraps.
  A="$BATS_TEST_TMPDIR/alpha"
  B="$BATS_TEST_TMPDIR/legacy-billing"
  mkdir -p "$A" "$B"
  git -C "$A" init -q
  git -C "$A" remote add origin git@github.com:acme/alpha.git
  git -C "$B" init -q
  git -C "$B" remote add origin git@github.com:nils/legacy-billing.git
  SINK_A="$A/.claude/telemetry/telemetry.jsonl"
  SINK_B="$B/.claude/telemetry/telemetry.jsonl"

  S="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$S"
  RUN="$S/bootstrap-run.json"
  STATE="$S/bootstrap-state.json"
  printf '%s' '{"mode":"fresh","target_repo":"nils/legacy-billing","visibility":"private","languages":{"primary":"python","auxiliary":[]},"topics":[],"interfaces":["cli"],"host":{"os":"macos","homebrew":true},"steps":{"common_artifacts":"written"},"files":[{"path":"README.md","step":"common_artifacts","disposition":"written"}],"github_state":{"branch_protection":"applied","secrets":"applied","sonar_project":"applied","apps_installed":"applied"},"stack":"resolved","early_stop":null,"approve_merge":"merged","pr":57}' > "$STATE"

  # A host is faked through PATH: a stub uname, and brew present or absent.
  HOSTBIN="$BATS_TEST_TMPDIR/hostbin"
  mkdir -p "$HOSTBIN"
  ln -s "$(command -v jq)" "$HOSTBIN/jq"
  fake_host Darwin yes
}

fake_host() {  # $1 = uname -s output, $2 = yes|no for brew on PATH
  printf '#!/bin/sh\necho %s\n' "$1" > "$HOSTBIN/uname"
  chmod +x "$HOSTBIN/uname"
  rm -f "$HOSTBIN/brew"
  if [ "$2" = yes ]; then printf '#!/bin/sh\nexit 0\n' > "$HOSTBIN/brew"; chmod +x "$HOSTBIN/brew"; fi
}
start() { PATH="$HOSTBIN:/usr/bin:/bin" run --separate-stderr "$ZSH" "$D" start --run-file "$RUN" "$@"; }
emit() { run --separate-stderr "$ZSH" "$D" emit --run-file "$RUN" --state "$STATE" --repo-dir "$B" "$@"; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# ------------------------------------------------------------------- start

@test "start pre-mints a bootstrap run_id in the emitter's format and writes the run file" {
  start --ts 1791284000
  [ "$status" -eq 0 ]
  matches "$(jq -r .run_id <<<"$output")" '^bootstrap-1791284000-[0-9a-f]{4}$'
  [ "$(jq -c . "$RUN")" = "$(jq -c . <<<"$output")" ]
  [ "$(jq -c '[.telemetry_file, .telemetry_dir]' "$RUN")" = "[null,null]" ]
}

@test "start reads the host: Darwin with brew is macos+homebrew, Linux without is linux" {
  fake_host Darwin yes
  start
  [ "$status" -eq 0 ]
  [ "$(jq -c .host "$RUN")" = '{"os":"macos","homebrew":true}' ]
  fake_host Linux no
  start
  [ "$(jq -c .host "$RUN")" = '{"os":"linux","homebrew":false}' ]
  fake_host FreeBSD no
  start
  [ "$(jq -r .host.os "$RUN")" = "freebsd" ]
}

@test "start makes the sink paths absolute and expands a leading ~" {
  cd "$S"
  HOME="$BATS_TEST_TMPDIR/home" start --telemetry-file rel/sink.jsonl --telemetry-dir '~/telemetry'
  [ "$status" -eq 0 ]
  starts_with "$(jq -r .telemetry_file "$RUN")" "/"
  ends_with "$(jq -r .telemetry_file "$RUN")" "/scratch/rel/sink.jsonl"
  [ "$(jq -r .telemetry_dir "$RUN")" = "$BATS_TEST_TMPDIR/home/telemetry" ]
}

@test "start: usage errors are exit 2, an unwritable run file is exit 1" {
  run --separate-stderr "$ZSH" "$D" start
  [ "$status" -eq 2 ]
  contains "$stderr" "--run-file is required"
  start --ts abc
  [ "$status" -eq 2 ]
  start --telemetry-dir
  [ "$status" -eq 2 ]
  contains "$stderr" "--telemetry-dir requires a value"
  start --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr "$ZSH" "$D" start --run-file "$BATS_TEST_TMPDIR/no/such/run.json"
  [ "$status" -eq 1 ]
  contains "$stderr" "cannot write the run file"
}

# ------------------------------------------------------------------- emit

@test "emit appends exactly one valid bootstrap record with the documented envelope" {
  start --ts 1791280000
  emit --now 1791280377
  [ "$status" -eq 0 ]
  [ "$(lines "$SINK_B")" = "1" ]
  run zsh "$VALIDATE" "$SINK_B"
  [ "$status" -eq 0 ]
  local rec; rec="$(cat "$SINK_B")"
  [ "$(jq -c '[.kind, .pipeline, .issue, .pr, .parent_run_id, .tokens, .outcome]' <<<"$rec")" = '["run","bootstrap",null,57,null,null,"success"]' ]
  [ "$(jq '.wall_s' <<<"$rec")" = "377" ]
  [ "$(jq '.wall_s | type == "number" and . == floor and . >= 1' <<<"$rec")" = "true" ]
  [ "$(jq -r .run_id <<<"$rec")" = "$(jq -r .run_id "$RUN")" ]
  [ "$(jq '.ts' <<<"$rec")" = "1791280000" ]
}

@test "emit with no PR leaves the envelope pr null" {
  jq '.approve_merge = null | .pr = null' "$STATE" > "$STATE.new"; mv "$STATE.new" "$STATE"
  start
  emit
  [ "$(jq -c .pr "$SINK_B")" = "null" ]
}

@test "emit takes the host from the run file, never from the state" {
  fake_host Linux no
  start
  jq '.github_state.secrets = "skipped" | .github_state.sonar_project = "skipped" | .github_state.apps_installed = "skipped"' "$STATE" > "$STATE.new"; mv "$STATE.new" "$STATE"
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -c .payload.host "$SINK_B")" = '{"os":"linux","homebrew":false}' ]
  [ "$(jq -r .outcome "$SINK_B")" = "parked" ]
}

@test "siting: called from repo A with --repo-dir B, the record lands in B's sink with B's repo" {
  mkdir -p "${SINK_A%/*}"
  printf '%s\n' '{"existing":"line"}' > "$SINK_A"
  cp "$SINK_A" "$S/a-before"
  start
  cd "$A"
  emit
  [ "$status" -eq 0 ]
  [ "$(lines "$SINK_B")" = "1" ]
  [ "$(jq -r .repo "$SINK_B")" = "nils/legacy-billing" ]
  [ "$(jq -r .payload.target_repo "$SINK_B")" = "nils/legacy-billing" ]
  cmp -s "$SINK_A" "$S/a-before"
}

@test "siting: from a linked worktree of B, the record lands in B's main checkout" {
  git -C "$B" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$B" worktree add -q "$BATS_TEST_TMPDIR/legacy-billing-wt" -b chore/bootstrap-gap-fill
  start
  cd "$BATS_TEST_TMPDIR/legacy-billing-wt"
  run --separate-stderr "$ZSH" "$D" emit --run-file "$RUN" --state "$STATE" --repo-dir .
  [ "$status" -eq 0 ]
  [ "$(lines "$SINK_B")" = "1" ]
  [ "$(jq -r .repo "$SINK_B")" = "nils/legacy-billing" ]
  [ ! -e "$BATS_TEST_TMPDIR/legacy-billing-wt/.claude" ]
}

@test "siting: a folder that is not its own git checkout is used as it is, even nested in a repo" {
  local F="$BATS_TEST_TMPDIR/empty-folder"
  mkdir -p "$F"
  start
  run --separate-stderr "$ZSH" "$D" emit --run-file "$RUN" --state "$STATE" --repo-dir "$F"
  [ "$status" -eq 0 ]
  [ "$(lines "$F/.claude/telemetry/telemetry.jsonl")" = "1" ]
  [ "$(jq -r .repo "$F/.claude/telemetry/telemetry.jsonl")" = "empty-folder" ]
  mkdir -p "$A/nested-folder"
  start
  run --separate-stderr "$ZSH" "$D" emit --run-file "$RUN" --state "$STATE" --repo-dir "$A/nested-folder"
  [ "$(lines "$A/nested-folder/.claude/telemetry/telemetry.jsonl")" = "1" ]
  [ "$(jq -r .repo "$A/nested-folder/.claude/telemetry/telemetry.jsonl")" = "nested-folder" ]
  [ ! -e "$SINK_A" ]
}

@test "sink precedence: --telemetry-file beats --telemetry-dir beats the target's default" {
  start --telemetry-file "$S/one.jsonl" --telemetry-dir "$S/dir"
  emit
  [ "$(lines "$S/one.jsonl")" = "1" ]
  [ ! -e "$SINK_B" ]
  mkdir -p "$S/dir"
  start --telemetry-dir "$S/dir"
  emit
  [ "$(lines "$S/dir/nils-legacy-billing.jsonl")" = "1" ]
  [ ! -e "$SINK_B" ]
}

@test "a repeated emit is refused with the advisory and appends nothing" {
  start
  emit
  [ "$(jq .emitted "$RUN")" = "true" ]
  emit
  [ "$status" -eq 0 ]
  contains "$stderr" "bootstrap record NOT emitted"
  contains "$stderr" "already emitted"
  [ "$(lines "$SINK_B")" = "1" ]
}

never_fatal() {  # asserts exit 0, the advisory, and an untouched sink
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  contains "$stderr" "bootstrap record NOT emitted"
  contains "$stderr" "the run's result is unaffected"
  [ ! -e "$SINK_B" ]
  [ ! -f "$RUN" ] || [ "$(jq '.emitted // false' "$RUN")" = "false" ]
}

@test "never fatal: an absent emitter" {
  start
  BOOTSTRAP_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/absent" emit
  never_fatal
  contains "$stderr" "emitter missing or not executable"
}

@test "never fatal: a non-executable emitter" {
  start
  cp "$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh" "$BATS_TEST_TMPDIR/emit.zsh"
  chmod -x "$BATS_TEST_TMPDIR/emit.zsh"
  BOOTSTRAP_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/emit.zsh" emit
  never_fatal
}

@test "never fatal: an emitter that exits non-zero" {
  start
  printf '#!/bin/sh\necho "stub emitter: boom" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/fail.sh"
  chmod +x "$BATS_TEST_TMPDIR/fail.sh"
  BOOTSTRAP_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/fail.sh" emit
  never_fatal
  contains "$stderr" "the emitter exited 1"
}

@test "never fatal: an absent or failing builder" {
  start
  BOOTSTRAP_TELEMETRY_BUILDER_BIN="$BATS_TEST_TMPDIR/absent" emit
  never_fatal
  contains "$stderr" "payload builder missing or not executable"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/nobuild.sh"
  chmod +x "$BATS_TEST_TMPDIR/nobuild.sh"
  BOOTSTRAP_TELEMETRY_BUILDER_BIN="$BATS_TEST_TMPDIR/nobuild.sh" emit
  never_fatal
  contains "$stderr" "the payload builder refused the state"
}

@test "never fatal: a state the builder refuses" {
  start
  jq '.steps.c4_diagrams = "written"' "$STATE" > "$STATE.new"; mv "$STATE.new" "$STATE"
  emit
  never_fatal
  contains "$stderr" "the payload builder refused the state"
  contains "$stderr" "unknown step key: c4_diagrams"
}

@test "never fatal: no run file, a missing state, a state that is not an object, a missing repo dir" {
  emit
  never_fatal
  contains "$stderr" "no readable run file"
  start
  run --separate-stderr "$ZSH" "$D" emit --run-file "$RUN" --state "$S/missing.json" --repo-dir "$B"
  never_fatal
  contains "$stderr" "no readable state file"
  printf '[]' > "$STATE"
  emit
  never_fatal
  contains "$stderr" "the state file is not a JSON object"
  run --separate-stderr "$ZSH" "$D" emit --run-file "$RUN" --state "$STATE" --repo-dir "$BATS_TEST_TMPDIR/gone"
  never_fatal
  contains "$stderr" "--repo-dir is not a directory"
}

@test "never fatal: a run file with no run_id or no start stamp" {
  printf '%s' '{"ts":1}' > "$RUN"
  emit
  never_fatal
  contains "$stderr" "no well-formed run_id"
  printf '%s' '{"run_id":"bootstrap-1-abcd"}' > "$RUN"
  emit
  never_fatal
  contains "$stderr" "no start stamp"
}

@test "--help prints both subcommands' usage and exits 0; emit usage errors are exit 2" {
  run "$ZSH" "$D" --help
  [ "$status" -eq 0 ]
  contains "$output" "bootstrap-telemetry.zsh start --run-file FILE"
  contains "$output" "bootstrap-telemetry.zsh emit --run-file FILE --state FILE --repo-dir DIR"
  run --separate-stderr "$ZSH" "$D" emit --run-file "$RUN" --state "$STATE"
  [ "$status" -eq 2 ]
  contains "$stderr" "--repo-dir is required"
  run --separate-stderr "$ZSH" "$D" emit --run-file "$RUN" --state "$STATE" --repo-dir "$B" --now x
  [ "$status" -eq 2 ]
  run --separate-stderr "$ZSH" "$D" emit --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr "$ZSH" "$D"
  [ "$status" -eq 2 ]
  run --separate-stderr "$ZSH" "$D" nope
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown subcommand: nope"
}

# ------------------------------------------------------------------- the skill

@test "SKILL.md: both sink flags are accepted, with the emitter's precedence" {
  run cat "$SKILL"
  contains "$output" '- `--telemetry-file PATH` / `--telemetry-dir DIR` — where this run'"'"'s one'
  contains "$output" "emitter's: \`--telemetry-file\` > \`--telemetry-dir\` > that default."
}

@test "SKILL.md: the start is stamped once, before Step 1, and its failure never stops the run" {
  run cat "$SKILL"
  contains "$output" "## Telemetry — stamp the run's start (#1229)"
  contains "$output" "hand-roll an envelope, a run_id or a payload. Before Step 1, stamp the start"
  contains "$output" "**once per invocation**, with the run file in the session scratch directory,"
  contains "$output" "same invocation re-reads the run file and never calls \`start\` again — a second"
  contains "$output" "and **skip the emit**. A failed \`start\` never stops the bootstrap."
  contains "$output" "worktree is never it: Step 4g deletes the worktree before Step 5 emits."
  local stamp s1
  stamp=$(grep -n "^## Telemetry — stamp the run's start" "$SKILL" | cut -d: -f1)
  s1=$(grep -n '^## Step 1: Detect Repo State' "$SKILL" | cut -d: -f1)
  [ -n "$stamp" ] && [ -n "$s1" ] && [ "$stamp" -lt "$s1" ]
}

@test "SKILL.md: every ending reaches the one emit, early stops included" {
  run cat "$SKILL"
  contains "$output" "**Every ending emits, through the one emit at the end of Step 5**"
  contains "$output" "path, which keeps that emit and no other Step 5 action; State D's no-drift"
  contains "$output" '"toolchain is current" stop, which commits nothing), each early stop'
  contains "$output" "**before** you stop — a plan declined at Step 2, a detection that aborted or"
  contains "$output" "found no stack Q4 could resolve, and a precondition park, which is every other"
  contains "$output" "stop before the plan is confirmed (State A's \`git init\` declined, State B's"
  contains "$output" "stop at a non-GitHub remote, the composition guard's stop, a toolchain or"
  contains "$output" "approval model that would not resolve, §3m's stops before its scaffold, a"
  contains "$output" "human-only choice that ends the run at Step 2) — and a failed step that ends"
  contains "$output" "the run (§3m's non-zero scaffold exit, Step 3's \`--record\` exiting non-zero),"
  contains "$output" "which keeps \`early_stop\` \`null\` and records the step's \`failed\` entry. An early"
  contains "$output" "stop skips the rest of Step 5 but not its emit."
  contains "$output" "   it applies, and Step 5's *Emit the run's record* — the one Step 5 action this"
  contains "$output" "5's checklist, not its emit."
  contains "$output" "decline ends the run: emit its record (\`early_stop: \"plan_declined\"\`, *Emit the"
  contains "$output" "run's record*) and stop. That record is the decline alone — \`steps\` \`{}\`, no"
  contains "$output" "\`files\` entry, every \`github_state\` target \`skipped\`. The decline governs the"
  contains "$output" "record, so what State D rendered or reconciled before the plan is not recorded;"
  contains "$output" "emit its record (\`stack: \"detection_failed\"\`, \`early_stop: \"detection\"\`, *Emit"
  contains "$output" "yes / no — if no, emit the record (\`early_stop: \"precondition\"\`, *Emit the"
  contains "$output" "If they want to stop, emit the record (\`early_stop:"
  [ "$(grep -c 'bootstrap-telemetry.zsh" emit' "$SKILL")" = "1" ]
  [ "$(grep -c 'bootstrap-telemetry.zsh" start' "$SKILL")" = "1" ]
}

@test "SKILL.md: the emit comes after 4d in Step 5, and no commit carries a telemetry path" {
  run cat "$SKILL"
  contains "$output" "### Emit the run's record (#1229)"
  contains "$output" "commit never carries a \`.claude/telemetry/\` path; bootstrap **never** edits"
  contains "$output" "**Never stage a \`.claude/telemetry/\`"
  local s4d s5 emit rules
  s4d=$(grep -n '^### 4d. Initial commit' "$SKILL" | cut -d: -f1)
  s5=$(grep -n '^## Step 5: Print the Manual-Setup Checklist' "$SKILL" | cut -d: -f1)
  emit=$(grep -n "^### Emit the run's record (#1229)" "$SKILL" | cut -d: -f1)
  rules=$(grep -n '^## Important Rules' "$SKILL" | cut -d: -f1)
  [ "$s4d" -lt "$s5" ] && [ "$s5" -lt "$emit" ] && [ "$emit" -lt "$rules" ]
}

@test "SKILL.md: the run facts, the per-file vocabulary and the never-fatal rule are stated" {
  run cat "$SKILL"
  contains "$output" "rendered template, a hook 4a installed under \`.git/hooks/\`, or \`.git/config\`"
  contains "$output" "when §3l's 4a sets \`core.hooksPath\` (\`already_present\` whenever it read"
  contains "$output" "\`hooks\` before 4a, whatever the gate said or the script did; otherwise"
  contains "$output" "script was skipped, \`failed\` when the script exited non-zero) —"
  contains "$output" "touched it — \`quality-<visibility>.yml\` and its \`-noop\` companion are §3c's"
  contains "$output" "(\`quality_workflows\`), and their \`DOCKER\` blocks, when kept, are a second"
  contains "$output" "entry each under \`container_publishing\` — one entry per step for a file two"
  contains "$output" "steps touch (the table in *Emit the run's record*) and \`disposition\` is the"
  contains "$output" "absent or overwritten → \`written\`; content matches"
  contains "$output" "→ \`already_present\`; differs and skipped (the default answer) → \`skipped\`;"
  contains "$output" "merged by hand or by the \`.gitignore\` merge → \`merged\`; a write error, **or the"
  contains "$output" "step rejected by a bootstrap gate** → \`failed\`;"
  contains "$output" "left out, and an applicable step that wrote no file (a declined Groovy"
  contains "$output" "and \`apps_installed\`, recorded wherever the target was done — State D's"
  contains "$output" "\`skipped\` (not run; on a host Step 4.5 cannot run on, \`secrets\`, \`sonar_project\`"
  contains "$output" "and \`apps_installed\` are \`skipped\`, the one value the builder takes there),"
  contains "$output" "answered 401 or 403 — missing credentials or admin rights) or \`failed\` (any"
  contains "$output" "\`red_ci\`, or \`retry_exhausted\` (the credits gate failed its one retry); or"
  contains "$output" "first match wins — so never pick it yourself. **Telemetry is never fatal**: past"
  contains "$output" "\`bootstrap record NOT emitted\` advisory and appends nothing. Relay that line and"
  contains "$output" "own malformed call: fix it and re-run once; a second costs the record."
  contains "$output" "- \`host\` — leave it as you like: \`emit\` takes it from the run file."
}

@test "SKILL.md: the state keys and the siting rule the emit depends on are stated" {
  run cat "$SKILL"
  contains "$output" 'Each takes a value — halt on a'
  contains "$output" 'missing, empty or `--`-shaped one.'
  contains "$output" 'A failed `start` never stops the bootstrap.'
  contains "$output" "Note the target's **main checkout** now — \`dirname\` of the absolute"
  contains "$output" "when it is not its own checkout's root (before State A's \`git init\`, even"
  contains "$output" 'That is the `--repo-dir` the emit takes.'
  contains "$output" "**Keep the run's facts as you go**, each where it is decided, never"
  contains "$output" "each \`github_state\` target's result as you run it;"
  contains "$output" 'kept since the start (*Telemetry'
  contains "$output" '`<scratch>/bootstrap-state.json`:'
  contains "$output" '`mode` — `gap_fill` on a re-run over a repo a prior bootstrap already stamped'
  contains "$output" '`fresh` — a first bootstrap through State D'"'"'s missing-file render included.'
  contains "$output" '`target_repo` — the `owner/name` this run bootstrapped (`null` before it has a'
  contains "$output" 'GitHub remote); `visibility` — `public` | `private`, `null` if never decided.'
  contains "$output" '`languages` — `{primary, auxiliary}`: the declared primary and every other'
  contains "$output" 'detected language; `{primary: null, auxiliary: []}` whenever no stack'
  contains "$output" '`host` — leave it as you like'
  contains "$output" '`steps` — one key per **applicable** step, from this closed list:'
  contains "$output" "Its value is the **worst** disposition among that step's \`files\` entries, by"
  contains "$output" 'entry is `skipped` — it chose not to write. A step that failed before writing'
  contains "$output" '— is one `failed` entry for the file it would have written: the Maven refusal'
  contains "$output" 'at the Java build-system gate is `{"path": "build.gradle.kts", "step":'
  contains "$output" '`files` — the per-file entries.'
  contains "$output" 'They are builder input only: the record'
  contains "$output" 'resolved. `topics` — the topic name of each `is_<topic>` key the final,'
  contains "$output" 'user-confirmed detection (the one §3h reads) reports `true` (`is_kubernetes`'
  contains "$output" '→ `kubernetes`); `interfaces` — the `interface` of each of its `interfaces`'
  contains "$output" 'entries, `library` included.'
  contains "$output" '`stack` — `resolved` once the primary is known — as `{{PRIMARY}}` determines'
  contains "$output" 'it (the placeholder table in Step 3: a language detected or answered at Q4,'
  contains "$output" "\`claude-plugin\`, §3l's \`kubernetes\` as Q4's IaC answer), as §3m's"
  contains "$output" '`composition` (the request that enters that path), or as an existing'
  contains "$output" '`.maintenance.yml` records it — and `languages.primary` is that primary;'
  contains "$output" '`none` when detection and Q4 resolved no primary; `detection_failed` when'
  contains "$output" '`detect-stack.sh` aborted; `not_reached` for a precondition stop before the'
  contains "$output" 'primary is known (several detected languages, none yet declared), and for the'
  contains "$output" 'composition guard'"'"'s stop, which declares nothing.'
  contains "$output" '`early_stop` — `null` unless the run stopped at `plan_declined`, `detection`'
  contains "$output" 'step ended keeps `null` — its `failed` entry is the record.'
  contains "$output" 'hold, the Approver App missing) — a human-only repo'"'"'s armed PR included; `null`'
  contains "$output" 'only when 4e opened no armed bot PR (arming failed, blocked before a PR, no'
  contains "$output" '`pr` — the PR 4e opened, else `null`.'
  contains "$output" 'Then emit, with `--repo-dir` the main checkout noted at the start:'
}
