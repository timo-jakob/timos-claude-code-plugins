#!/usr/bin/env bats
#
# Acceptance cases for "telemetry for bootstrap runs" (#1229, epic #741 child
# (d)) — the `cli`-tooled test_cases[] of its story-spec, one test per `tc-*` id:
#
#   tc-happy-fresh-run                     #2060
#   tc-happy-gap-fill-rerun                #2061
#   tc-corner-ab-siting                    #2062
#   tc-corner-worktree-siting              #2063
#   tc-corner-zero-file-step               #2064
#   tc-error-unknown-step-key              #2065
#   tc-error-files-steps-disagree          #2066
#   tc-corner-refused-403-parked           #2067
#   tc-error-5xx-failed-overlap            #2068
#   tc-corner-escalated-4f                 #2069
#   tc-error-no-stack                      #2070
#   tc-error-xcodeproj-layout              #2071
#   tc-error-maven-only                    #2072
#   tc-corner-groovy-gradle                #2073
#   tc-corner-polyglot-shape               #2074
#   tc-corner-linux-host                   #2075
#   tc-corner-declined-plan                #2076
#   tc-corner-commit-clean                 #2077
#   tc-error-emitter-failure-never-fatal   #2078
#   tc-corner-kept-differing-file          #2080
#
# The use case: nils-unblessed-stack bootstraps the repo he actually has —
# nils/legacy-billing, private, a pom.xml at the root beside a Go service and an
# Angular frontend, on an ubuntu-24.04 box with no Homebrew — and then reads from
# the run's one telemetry record which of his choices made a step fail, skip or
# park.
#
# A bootstrap run is model-driven, so these cases drive exactly the deterministic
# steps the skill calls: `bootstrap-telemetry.zsh start` before Step 1, then
# `emit` with the run state at the ending. Where a case names a fixture repo's
# layout, `detect-stack.sh` reads the real fixture and the state carries what it
# reported. Nothing reaches GitHub. The default gate's
# tests/build-bootstrap-telemetry-record.bats and tests/bootstrap-telemetry.bats
# cover the same criteria.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/bootstrap/scripts"
  DRIVER="$SCRIPTS/bootstrap-telemetry.zsh"
  BUILDER="$SCRIPTS/build-bootstrap-telemetry-record.zsh"
  DETECT="$SCRIPTS/detect-stack.sh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  ZSH="$(command -v zsh)"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

  T="$BATS_TEST_TMPDIR/legacy-billing"
  mkdir -p "$T"
  git -C "$T" init -q
  git -C "$T" remote add origin git@github.com:nils/legacy-billing.git
  SINK="$T/.claude/telemetry/telemetry.jsonl"

  SCRATCH="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$SCRATCH"
  RUN="$SCRATCH/bootstrap-run.json"
  STATE="$SCRATCH/bootstrap-state.json"

  # Nils's host: ubuntu-24.04, no Homebrew — faked through PATH.
  LINUX="$BATS_TEST_TMPDIR/linux-bin"
  MAC="$BATS_TEST_TMPDIR/mac-bin"
  mkdir -p "$LINUX" "$MAC"
  ln -s "$(command -v jq)" "$LINUX/jq"
  ln -s "$(command -v jq)" "$MAC/jq"
  printf '#!/bin/sh\necho Linux\n' > "$LINUX/uname"
  printf '#!/bin/sh\necho Darwin\n' > "$MAC/uname"
  printf '#!/bin/sh\nexit 0\n' > "$MAC/brew"
  chmod +x "$LINUX/uname" "$MAC/uname" "$MAC/brew"

  # A fresh run on a macOS + Homebrew host that wrote everything it applied.
  printf '%s' '{"mode":"fresh","target_repo":"nils/legacy-billing","visibility":"private","languages":{"primary":"go","auxiliary":["typescript"]},"topics":[],"interfaces":["rest"],"host":{"os":"macos","homebrew":true},"steps":{"common_artifacts":"written","quality_workflows":"written","git_hooks":"written"},"files":[{"path":"README.md","step":"common_artifacts","disposition":"written"},{"path":"SECURITY.md","step":"common_artifacts","disposition":"written"},{"path":".github/workflows/quality-private.yml","step":"quality_workflows","disposition":"written"},{"path":".git/hooks/pre-commit","step":"git_hooks","disposition":"written"}],"github_state":{"branch_protection":"applied","secrets":"applied","sonar_project":"applied","apps_installed":"applied"},"stack":"resolved","early_stop":null,"approve_merge":"merged","pr":88}' > "$STATE"
}

edit() { jq -c "$1" "$STATE" > "$STATE.new" && mv "$STATE.new" "$STATE"; }
start_on() { PATH="$1:/usr/bin:/bin" run --separate-stderr "$ZSH" "$DRIVER" start --run-file "$RUN" --ts 1791280000; [ "$status" -eq 0 ]; }
emit() { run --separate-stderr "$ZSH" "$DRIVER" emit --run-file "$RUN" --state "$STATE" --repo-dir "$T" --now 1791280912 "$@"; }
record() { [ "$(wc -l < "$SINK" | tr -d ' ')" = "1" ]; cat "$SINK"; }
outcome() { run --separate-stderr zsh "$BUILDER" --state "$STATE" --print-outcome; [ "$status" -eq 0 ]; [ "$output" = "$1" ]; }
# detect-stack.sh reads GitHub state when a remote is set, so a layout is
# detected in a remote-less fixture (as tests/detect-stack.bats does).
layout() { L="$BATS_TEST_TMPDIR/layout"; mkdir -p "$L"; git -C "$L" init -q; }
detect() { cd "$L"; run --separate-stderr bash "$DETECT"; [ "$status" -eq 0 ]; }

@test "tc-happy-fresh-run (#2060): one valid record, pipeline bootstrap, mode fresh, success, no paths" {
  start_on "$MAC"
  emit
  [ "$status" -eq 0 ]
  local rec; rec="$(record)"
  run zsh "$VALIDATE" "$SINK"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.kind, .pipeline, .outcome, .payload.mode]' <<<"$rec")" = '["run","bootstrap","success","fresh"]' ]
  [ "$(jq '.wall_s >= 1' <<<"$rec")" = "true" ]
  [ "$(jq -c .payload.files <<<"$rec")" = '{"already_present":0,"written":4,"merged":0,"skipped":0,"failed":0}' ]
  lacks "$rec" "README.md"
  lacks "$rec" "quality-private.yml"
}

@test "tc-happy-gap-fill-rerun (#2061): already-satisfied common_artifacts are already_present, success" {
  edit '.mode = "gap_fill" | .steps = {"common_artifacts":"already_present"} | .files = [{"path":"README.md","step":"common_artifacts","disposition":"already_present"},{"path":"SECURITY.md","step":"common_artifacts","disposition":"already_present"},{"path":"CONTRIBUTING.md","step":"common_artifacts","disposition":"already_present"}] | .github_state.branch_protection = "already_present"'
  start_on "$MAC"
  emit
  local rec; rec="$(record)"
  [ "$(jq -r .payload.mode <<<"$rec")" = "gap_fill" ]
  [ "$(jq -r .payload.steps.common_artifacts <<<"$rec")" = "already_present" ]
  [ "$(jq .payload.files.already_present <<<"$rec")" = "3" ]
  [ "$(jq .payload.files.written <<<"$rec")" = "0" ]
  [ "$(jq -r .outcome <<<"$rec")" = "success" ]
}

@test "tc-corner-ab-siting (#2062): from fixture A, emit --repo-dir B lands in B's sink only" {
  local A="$BATS_TEST_TMPDIR/billing-tools"
  mkdir -p "$A/.claude/telemetry"
  git -C "$A" init -q
  git -C "$A" remote add origin git@github.com:nils/billing-tools.git
  printf '%s\n' '{"pipeline":"maintenance"}' > "$A/.claude/telemetry/telemetry.jsonl"
  cp "$A/.claude/telemetry/telemetry.jsonl" "$SCRATCH/a-before"
  start_on "$MAC"
  cd "$A"
  emit
  [ "$status" -eq 0 ]
  local rec; rec="$(record)"
  [ "$(jq -r .repo <<<"$rec")" = "nils/legacy-billing" ]
  [ "$(jq -r .payload.target_repo <<<"$rec")" = "nils/legacy-billing" ]
  cmp -s "$A/.claude/telemetry/telemetry.jsonl" "$SCRATCH/a-before"
}

@test "tc-corner-worktree-siting (#2063): from a linked worktree of B, the record lands in B's main checkout" {
  git -C "$T" -c user.name=nils -c user.email=nils@example.invalid commit -q --allow-empty -m "initial"
  local W="$BATS_TEST_TMPDIR/legacy-billing-bootstrap"
  git -C "$T" worktree add -q "$W" -b chore/bootstrap-gap-fill
  start_on "$MAC"
  cd "$W"
  run --separate-stderr "$ZSH" "$DRIVER" emit --run-file "$RUN" --state "$STATE" --repo-dir "$W"
  [ "$status" -eq 0 ]
  local rec; rec="$(record)"
  [ "$(jq -r .repo <<<"$rec")" = "nils/legacy-billing" ]
  [ ! -e "$W/.claude/telemetry" ]
}

@test "tc-corner-zero-file-step (#2064): an applicable docs_machinery with no entries is skipped and parks" {
  edit '.steps.docs_machinery = "skipped"'
  start_on "$MAC"
  emit
  local rec; rec="$(record)"
  [ "$(jq -r .payload.steps.docs_machinery <<<"$rec")" = "skipped" ]
  [ "$(jq -r .outcome <<<"$rec")" = "parked" ]
}

@test "tc-error-unknown-step-key (#2065): steps.c4_diagrams is refused, nothing appended" {
  edit '.steps.c4_diagrams = "written" | .files += [{"path":"docs/architecture/c4-container.md","step":"c4_diagrams","disposition":"written"}]'
  run --separate-stderr zsh "$BUILDER" --state "$STATE"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  contains "$stderr" "unknown step key: c4_diagrams"
  start_on "$MAC"
  emit
  [ "$status" -eq 0 ]
  [ ! -e "$SINK" ]
}

@test "tc-error-files-steps-disagree (#2066): git_hooks written over a failed entry is refused" {
  edit '.files[3].disposition = "failed"'
  run --separate-stderr zsh "$BUILDER" --state "$STATE"
  [ "$status" -ne 0 ]
  contains "$stderr" 'steps.git_hooks is "written" but its files entries fold to "failed"'
  start_on "$MAC"
  emit
  [ ! -e "$SINK" ]
}

@test "tc-corner-refused-403-parked (#2067): a 403 on branch protection is refused and parks" {
  edit '.github_state.branch_protection = "refused"'
  start_on "$MAC"
  emit
  local rec; rec="$(record)"
  [ "$(jq -r .payload.github_state.branch_protection <<<"$rec")" = "refused" ]
  [ "$(jq -r .outcome <<<"$rec")" = "parked" ]
}

@test "tc-error-5xx-failed-overlap (#2068): a 502 on the Sonar project beside a refused target folds to failed" {
  edit '.github_state.branch_protection = "refused" | .github_state.sonar_project = "failed"'
  start_on "$MAC"
  emit
  local rec; rec="$(record)"
  [ "$(jq -r .payload.github_state.sonar_project <<<"$rec")" = "failed" ]
  [ "$(jq -r .outcome <<<"$rec")" = "failed" ]
}

@test "tc-corner-escalated-4f (#2069): REQUEST_CHANGES beside a refused target escalates; red CI and a failed retry too" {
  edit '.approve_merge = "request_changes" | .github_state.branch_protection = "refused"'
  start_on "$MAC"
  emit
  [ "$(jq -r .outcome "$SINK")" = "escalated" ]
  edit '.approve_merge = "red_ci"'
  outcome escalated
  edit '.approve_merge = "retry_exhausted"'
  outcome escalated
}

@test "tc-error-no-stack (#2070): nothing detected is failed, with languages {primary: null, auxiliary: []}" {
  layout
  detect
  [ "$(jq -c .languages <<<"$output")" = "[]" ]
  edit '.languages = {"primary":null,"auxiliary":[]} | .stack = "none" | .early_stop = "detection" | .steps = {} | .files = [] | .github_state = {"branch_protection":"skipped","secrets":"skipped","sonar_project":"skipped","apps_installed":"skipped"} | .approve_merge = null | .pr = null'
  start_on "$MAC"
  emit
  local rec; rec="$(record)"
  [ "$(jq -c .payload.languages <<<"$rec")" = '{"primary":null,"auxiliary":[]}' ]
  [ "$(jq -r .outcome <<<"$rec")" = "failed" ]
}

@test "tc-error-xcodeproj-layout (#2071): an .xcodeproj with no Package.swift still yields one record, never a silent exit" {
  layout
  mkdir -p "$L/MyApp.xcodeproj"
  printf '// !$*UTF8*$!\n' > "$L/MyApp.xcodeproj/project.pbxproj"
  detect
  # The issue expected this layout to defeat detection; it does not —
  # detect-stack.sh reads an .xcodeproj as a Swift app built by Xcode, and
  # changing detection is out of #1229's scope. So the record says swift, and
  # the case pins what the criterion is about: one record, never a silent exit.
  [ "$(jq -c .languages <<<"$output")" = '["swift"]' ]
  [ "$(jq -r .language_meta.swift.build_system <<<"$output")" = "xcode" ]
  edit '.languages = {"primary":"swift","auxiliary":[]}'
  start_on "$MAC"
  emit
  [ "$status" -eq 0 ]
  local rec; rec="$(record)"
  [ "$(jq -c .payload.languages <<<"$rec")" = '{"primary":"swift","auxiliary":[]}' ]
  [ "$(jq -r .payload.ending.stack <<<"$rec")" = "resolved" ]
}

@test "tc-error-maven-only (#2072): the Java gate's refusal is a failed build_script entry, outcome failed" {
  layout
  printf '<project><modelVersion>4.0.0</modelVersion><artifactId>legacy-billing</artifactId></project>\n' > "$L/pom.xml"
  detect
  [ "$(jq -r '.language_meta.java.build_system' <<<"$output")" = "maven" ]
  edit '.languages = {"primary":"java","auxiliary":[]} | .steps.build_script = "failed" | .files += [{"path":"build.gradle.kts","step":"build_script","disposition":"failed"}]'
  start_on "$MAC"
  emit
  local rec; rec="$(record)"
  [ "$(jq -r .payload.languages.primary <<<"$rec")" = "java" ]
  [ "$(jq -r .payload.steps.build_script <<<"$rec")" = "failed" ]
  [ "$(jq .payload.files.failed <<<"$rec")" = "1" ]
  [ "$(jq -r .outcome <<<"$rec")" = "failed" ]
}

@test "tc-corner-groovy-gradle (#2073): a Groovy build.gradle leaves build_script skipped with zero files, parked" {
  layout
  printf "plugins { id 'java' }\n" > "$L/build.gradle"
  detect
  [ "$(jq -r '.language_meta.java.gradle_dsl' <<<"$output")" = "groovy" ]
  edit '.languages = {"primary":"java","auxiliary":[]} | .steps.build_script = "skipped"'
  start_on "$MAC"
  emit
  local rec; rec="$(record)"
  [ "$(jq -r .payload.steps.build_script <<<"$rec")" = "skipped" ]
  [ "$(jq -r .outcome <<<"$rec")" = "parked" ]
}

@test "tc-corner-polyglot-shape (#2074): Go primary with TypeScript and Python auxiliary" {
  edit '.languages = {"primary":"go","auxiliary":["typescript","python"]}'
  start_on "$MAC"
  emit
  [ "$(jq -c .payload.languages "$SINK")" = '{"primary":"go","auxiliary":["typescript","python"]}' ]
}

@test "tc-corner-linux-host (#2075): ubuntu with no Homebrew skips the Step 4.5 targets and parks" {
  edit '.github_state = {"branch_protection":"applied","secrets":"skipped","sonar_project":"skipped","apps_installed":"skipped"} | .approve_merge = "pending"'
  start_on "$LINUX"
  emit
  local rec; rec="$(record)"
  [ "$(jq -c .payload.host <<<"$rec")" = '{"os":"linux","homebrew":false}' ]
  [ "$(jq -c '[.payload.github_state.secrets, .payload.github_state.sonar_project, .payload.github_state.apps_installed]' <<<"$rec")" = '["skipped","skipped","skipped"]' ]
  [ "$(jq -r .outcome <<<"$rec")" = "parked" ]
}

@test "tc-corner-declined-plan (#2076): a plan declined at Step 2 is one parked record with nothing in it" {
  edit '.early_stop = "plan_declined" | .steps = {} | .files = [] | .github_state = {"branch_protection":"skipped","secrets":"skipped","sonar_project":"skipped","apps_installed":"skipped"} | .approve_merge = null | .pr = null'
  start_on "$MAC"
  emit
  local rec; rec="$(record)"
  [ "$(jq -r .outcome <<<"$rec")" = "parked" ]
  [ "$(jq -c .payload.steps <<<"$rec")" = "{}" ]
  [ "$(jq -c '[.payload.files[]] | unique' <<<"$rec")" = "[0]" ]
  [ "$(jq -c '[.payload.github_state[]] | unique' <<<"$rec")" = '["skipped"]' ]
}

@test "tc-corner-commit-clean (#2077): the 4d commit then emit leaves no telemetry path in HEAD and .gitignore untouched" {
  # An earlier run's record already sits untracked in the target's sink.
  mkdir -p "${SINK%/*}"
  printf '%s\n' '{"pipeline":"bootstrap","note":"an earlier run"}' > "$SINK"
  printf 'target/\n' > "$T/.gitignore"
  git -C "$T" -c user.name=nils -c user.email=nils@example.invalid add .gitignore
  git -C "$T" -c user.name=nils -c user.email=nils@example.invalid commit -q -m "initial"
  local before; before="$(git -C "$T" hash-object .gitignore)"
  # 4d: the generated files are staged by path, never .claude/telemetry/.
  printf '# legacy-billing\n' > "$T/README.md"
  git -C "$T" add README.md
  git -C "$T" -c user.name=nils -c user.email=nils@example.invalid commit -q -m "Bootstrap project with quality and security toolchain"
  start_on "$MAC"
  emit
  [ "$status" -eq 0 ]
  run git -C "$T" show --name-only --format= HEAD
  [ "$output" = "README.md" ]
  [ -z "$(git -C "$T" ls-files .claude/telemetry)" ]
  [ "$(git -C "$T" hash-object .gitignore)" = "$before" ]
  [ "$(wc -l < "$SINK" | tr -d ' ')" = "2" ]
}

@test "tc-error-emitter-failure-never-fatal (#2078): a failing, non-executable or absent emitter exits 0 with a warning" {
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/emit-fails.sh"
  chmod +x "$BATS_TEST_TMPDIR/emit-fails.sh"
  cp "$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh" "$BATS_TEST_TMPDIR/emit-noexec.zsh"
  chmod -x "$BATS_TEST_TMPDIR/emit-noexec.zsh"
  local tree; tree="$(ls -A "$T")"
  local e
  for e in "$BATS_TEST_TMPDIR/emit-fails.sh" "$BATS_TEST_TMPDIR/emit-noexec.zsh" "$BATS_TEST_TMPDIR/emit-absent.zsh"; do
    start_on "$MAC"
    BOOTSTRAP_TELEMETRY_EMITTER_BIN="$e" emit
    [ "$status" -eq 0 ]
    contains "$stderr" "bootstrap record NOT emitted"
    [ ! -e "$SINK" ]
    [ "$(ls -A "$T")" = "$tree" ]
  done
}

@test "tc-corner-kept-differing-file (#2080): a kept differing workflow leaves quality_workflows skipped, parked" {
  edit '.mode = "gap_fill" | .steps.quality_workflows = "skipped" | .files[2].disposition = "skipped"'
  start_on "$MAC"
  emit
  local rec; rec="$(record)"
  [ "$(jq -r .payload.steps.quality_workflows <<<"$rec")" = "skipped" ]
  [ "$(jq -r .outcome <<<"$rec")" = "parked" ]
}
