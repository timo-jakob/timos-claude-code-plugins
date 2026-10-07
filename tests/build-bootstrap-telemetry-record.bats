#!/usr/bin/env bats
#
# build-bootstrap-telemetry-record.zsh (#1229): the pure payload builder for the
# /development:bootstrap run's one telemetry record — the payload's shape, the
# files <-> steps rule, the worst-wins outcome fold behind --print-outcome, and
# every consistency refusal. The start/emit run script and the target-repo
# siting are tests/bootstrap-telemetry.bats.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  B="$REPO_ROOT/development/skills/bootstrap/scripts/build-bootstrap-telemetry-record.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  ST="$BATS_TEST_TMPDIR/state.json"
  # A fresh run on a supported host: two steps written, branch protection applied.
  printf '%s' '{"mode":"fresh","target_repo":"acme/billing","visibility":"private","languages":{"primary":"python","auxiliary":["typescript"]},"topics":["kubernetes"],"interfaces":["rest"],"host":{"os":"macos","homebrew":true},"steps":{"common_artifacts":"written","git_hooks":"written"},"files":[{"path":"README.md","step":"common_artifacts","disposition":"written"},{"path":"SECURITY.md","step":"common_artifacts","disposition":"written"},{"path":".git/hooks/pre-commit","step":"git_hooks","disposition":"written"}],"github_state":{"branch_protection":"applied","secrets":"applied","sonar_project":"applied","apps_installed":"already_present"},"stack":"resolved","early_stop":null,"approve_merge":"merged","pr":412}' > "$ST"
}

edit() { jq -c "$1" "$ST" > "$ST.new" && mv "$ST.new" "$ST"; }
build() { run --separate-stderr zsh "$B" --state "$ST" "$@"; }
outcome() { build --print-outcome; [ "$status" -eq 0 ]; [ "$output" = "$1" ]; }
refused() {  # $1 = the refusal text expected on stderr
  build
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "state refused — $1"
}

# ------------------------------------------------------------------- payload

@test "a fresh run's payload carries every documented key and no envelope key" {
  build
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys' <<<"$output")" = '["ending","files","github_state","host","interfaces","languages","mode","steps","target_repo","topics","visibility"]' ]
  [ "$(jq -r .mode <<<"$output")" = "fresh" ]
  [ "$(jq -r .target_repo <<<"$output")" = "acme/billing" ]
  [ "$(jq -c '[.visibility, .topics, .interfaces]' <<<"$output")" = '["private",["kubernetes"],["rest"]]' ]
  [ "$(jq -c .languages <<<"$output")" = '{"primary":"python","auxiliary":["typescript"]}' ]
  [ "$(jq -c .host <<<"$output")" = '{"os":"macos","homebrew":true}' ]
  [ "$(jq -c .ending <<<"$output")" = '{"stack":"resolved","early_stop":null,"approve_merge":"merged"}' ]
  [ "$(jq -c .github_state <<<"$output")" = '{"branch_protection":"applied","secrets":"applied","sonar_project":"applied","apps_installed":"already_present"}' ]
  outcome success
}

@test "files counts each of the five dispositions, and the payload carries no path" {
  edit '.steps.docs_machinery = "skipped" | .files += [{"path":"mkdocs.yml","step":"docs_machinery","disposition":"skipped"},{"path":".gitignore","step":"common_artifacts","disposition":"merged"},{"path":"docs/index.md","step":"docs_machinery","disposition":"already_present"}] | .steps.common_artifacts = "merged"'
  build
  [ "$status" -eq 0 ]
  [ "$(jq -c .files <<<"$output")" = '{"already_present":1,"written":3,"merged":1,"skipped":1,"failed":0}' ]
  lacks "$output" "README.md"
  lacks "$output" "mkdocs.yml"
  lacks "$output" '"path"'
}

@test "a gap-fill re-run records already_present steps, and an absent step stays absent" {
  edit '.mode = "gap_fill" | .steps = {"common_artifacts":"already_present"} | .files = [{"path":"README.md","step":"common_artifacts","disposition":"already_present"},{"path":"SECURITY.md","step":"common_artifacts","disposition":"already_present"}]'
  build
  [ "$(jq -r .mode <<<"$output")" = "gap_fill" ]
  [ "$(jq -c .steps <<<"$output")" = '{"common_artifacts":"already_present"}' ]
  [ "$(jq .files.already_present <<<"$output")" = "2" ]
  [ "$(jq '.steps | has("git_hooks")' <<<"$output")" = "false" ]
  outcome success
}

@test "steps.<k> is the worst of its entries by failed > skipped > merged > written > already_present" {
  edit '.files = [{"path":"a","step":"common_artifacts","disposition":"already_present"},{"path":"b","step":"common_artifacts","disposition":"written"}] | .steps = {"common_artifacts":"written"}'
  build; [ "$status" -eq 0 ]
  edit '.files += [{"path":"c","step":"common_artifacts","disposition":"merged"}] | .steps.common_artifacts = "merged"'
  build; [ "$status" -eq 0 ]
  edit '.files += [{"path":"d","step":"common_artifacts","disposition":"skipped"}] | .steps.common_artifacts = "skipped"'
  build; [ "$status" -eq 0 ]
  edit '.files += [{"path":"e","step":"common_artifacts","disposition":"failed"}] | .steps.common_artifacts = "failed"'
  build; [ "$status" -eq 0 ]
  edit '.steps.common_artifacts = "skipped"'
  refused 'steps.common_artifacts is "skipped" but its files entries fold to "failed"'
}

@test "--state - reads the state from stdin" {
  run --separate-stderr zsh -c '"$1" --state - --print-outcome < "$2"' _ "$B" "$ST"
  [ "$status" -eq 0 ]
  [ "$output" = "success" ]
}

# ------------------------------------------------------------------- the fold

@test "fold: a failed step folds to failed (the Maven gate rejection)" {
  edit '.steps.build_script = "failed" | .files += [{"path":"build.gradle.kts","step":"build_script","disposition":"failed"}] | .languages = {"primary":"java","auxiliary":[]}'
  outcome failed
  build
  [ "$(jq -r .steps.build_script <<<"$output")" = "failed" ]
  [ "$(jq -r .languages.primary <<<"$output")" = "java" ]
}

@test "fold: a failed github_state target folds to failed, a refused one to parked" {
  edit '.github_state.branch_protection = "refused"'
  outcome parked
  edit '.github_state.sonar_project = "failed"'
  outcome failed
}

@test "fold: no usable stack folds to failed with languages {primary: null, auxiliary: []}" {
  edit '.stack = "none" | .early_stop = "detection" | .languages = {"primary":null,"auxiliary":[]} | .steps = {} | .files = [] | .approve_merge = null | .pr = null'
  outcome failed
  build
  [ "$(jq -c .languages <<<"$output")" = '{"primary":null,"auxiliary":[]}' ]
  edit '.stack = "detection_failed"'
  outcome failed
}

@test "fold: each 4f stop for a human escalates, and merged or pending does not" {
  local s
  for s in request_changes red_ci retry_exhausted; do
    edit ".approve_merge = \"$s\""
    outcome escalated
  done
  edit '.approve_merge = "pending"'
  outcome success
  edit '.approve_merge = null'
  outcome success
}

@test "fold: a skipped step parks the run (a kept differing file, a declined Groovy conversion)" {
  edit '.mode = "gap_fill" | .steps.quality_workflows = "skipped" | .files += [{"path":".github/workflows/quality-private.yml","step":"quality_workflows","disposition":"skipped"}]'
  outcome parked
  edit '.steps = {"build_script":"skipped"} | .files = []'
  outcome parked
}

@test "fold: an applicable step with zero entries is skipped and parks" {
  edit '.steps.docs_machinery = "skipped"'
  outcome parked
}

@test "fold: a declined plan and a precondition stop park" {
  edit '.early_stop = "plan_declined" | .steps = {} | .files = [] | .github_state = {"branch_protection":"skipped","secrets":"skipped","sonar_project":"skipped","apps_installed":"skipped"} | .approve_merge = null | .pr = null'
  outcome parked
  build
  [ "$(jq -c .steps <<<"$output")" = "{}" ]
  [ "$(jq -c '[.files[]] | unique' <<<"$output")" = "[0]" ]
  edit '.early_stop = "precondition" | .stack = "not_reached" | .languages = {"primary":null,"auxiliary":[]}'
  outcome parked
}

@test "fold: a host without macOS + Homebrew parks, with the Step 4.5 targets skipped" {
  edit '.host = {"os":"linux","homebrew":false} | .github_state = {"branch_protection":"applied","secrets":"skipped","sonar_project":"skipped","apps_installed":"skipped"}'
  outcome parked
  edit '.host = {"os":"macos","homebrew":false}'
  outcome parked
}

@test "fold overlap: a failed step beside a refused target folds to failed" {
  edit '.steps.git_hooks = "failed" | .files[2].disposition = "failed" | .github_state.branch_protection = "refused"'
  outcome failed
}

@test "fold overlap: an escalated 4f drive beside a refused target folds to escalated" {
  edit '.approve_merge = "request_changes" | .github_state.branch_protection = "refused"'
  outcome escalated
}

# ------------------------------------------------------------------- refusals

@test "refused: an unknown step key, in steps or in files" {
  edit '.steps.c4_diagrams = "written"'
  refused "unknown step key: c4_diagrams"
  lacks "$stderr" "steps.c4_diagrams is"
  setup
  edit '.files[0].step = "c4_diagrams"'
  refused "files entry README.md has unknown step key: c4_diagrams"
}

@test "refused: an unknown disposition, in steps, files or github_state" {
  edit '.steps.git_hooks = "done"'
  refused 'steps.git_hooks has unknown disposition "done"'
  setup
  edit '.files[2].disposition = "done"'
  refused 'files entry .git/hooks/pre-commit has unknown disposition "done"'
  setup
  edit '.github_state.secrets = "done"'
  refused 'github_state.secrets has unknown disposition "done"'
}

@test "refused: files and steps disagree" {
  edit '.files[2].disposition = "failed"'
  refused 'steps.git_hooks is "written" but its files entries fold to "failed"'
  setup
  edit 'del(.steps.git_hooks)'
  refused "files has entries for step git_hooks, which is absent from steps"
  setup
  edit '.steps.docs_machinery = "written"'
  refused 'steps.docs_machinery is "written" with zero files entries'
  setup
  edit '.files += [.files[0]]'
  refused "the same path appears twice under one step in files"
  setup
  edit '.files += [.files[0] | .step = "provenance_markers"] | .steps.provenance_markers = "written"'
  build
  [ "$status" -eq 0 ]
}

@test "refused: malformed top-level fields" {
  edit '.mode = "partial"'
  refused "mode must be"
  setup; edit '.target_repo = "billing"'
  refused "target_repo must be an owner/name string or null"
  setup; edit '.visibility = "internal"'
  refused "visibility must be"
  setup; edit '.languages = ["python"]'
  refused "languages must be {primary: str|null, auxiliary: [str]}"
  setup; edit '.languages.extra = 1'
  refused "languages must be {primary: str|null, auxiliary: [str]}"
  setup; edit '.topics = "k8s"'
  refused "topics must be an array of strings"
  setup; edit '.interfaces = null'
  refused "interfaces must be an array of strings"
  setup; edit '.host = {"os":"","homebrew":true}'
  refused "host must be {os: non-empty str, homebrew: bool}"
  setup; edit '.steps = []'
  refused "steps must be an object"
  setup; edit '.files = [{"path":"","step":"git_hooks","disposition":"written"}]'
  refused "files must be an array of"
  setup; edit '.github_state = []'
  refused "github_state must be an object"
  setup; edit 'del(.github_state.apps_installed)'
  refused "github_state must have exactly the keys"
  setup; edit '.stack = "maybe"'
  refused "stack must be"
  setup; edit '.early_stop = "tired"'
  refused "early_stop must be"
  setup; edit '.approve_merge = "approved"'
  refused "approve_merge must be"
  setup; edit '.pr = 0'
  refused "pr must be a positive integer or null"
}

@test "refused: ending facts that contradict each other" {
  edit '.stack = "none"'
  refused 'stack "none" resolved no language'
  refused 'stack "none" stops the run at detection, so early_stop must be "detection"'
  setup; edit '.early_stop = "detection"'
  refused 'early_stop "detection" needs stack none or detection_failed'
  setup; edit '.stack = "not_reached" | .languages = {"primary":null,"auxiliary":[]}'
  refused 'stack "not_reached" needs early_stop "precondition"'
  setup; edit '.early_stop = "plan_declined" | .approve_merge = null | .pr = null'
  refused "a run that stopped at plan_declined wrote nothing, so steps and files must be empty"
  refused "a declined plan reconciled nothing, so every github_state target must be skipped"
  setup; edit '.early_stop = "precondition" | .approve_merge = null'
  refused "a run that stopped early opened no PR, so pr and approve_merge must be null"
  setup; edit '.pr = null'
  refused "approve_merge is set but no pr is recorded"
  setup; edit '.host = {"os":"linux","homebrew":false}'
  refused "Step 4.5 cannot run on this host, so secrets, sonar_project and apps_installed must be skipped"
}

@test "usage: exit 2 on a bad invocation, exit 1 on a state that is not one JSON object" {
  run --separate-stderr zsh "$B"
  [ "$status" -eq 2 ]
  contains "$stderr" "--state is required"
  run --separate-stderr zsh "$B" --state
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" --state "$ST" extra
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$B" --state "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  contains "$stderr" "is a directory"
  run --separate-stderr zsh "$B" --state "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
  contains "$stderr" "does not exist"
  printf '[1]' > "$ST"
  build
  [ "$status" -eq 1 ]
  contains "$stderr" "the state must be a single JSON object"
  run zsh "$B" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: build-bootstrap-telemetry-record.zsh --state FILE|-"
}

# ------------------------------------------------------------------- step keys

@test "the 19 step keys are the builder's closed list, each pinned to its SKILL.md heading" {
  local -a pairs=(
    "common_artifacts|### 3a. Common artifacts"
    "toolchain_artifacts|### 3b. Tool-scoped artifacts"
    "quality_workflows|### 3c. The quality workflows are composed per tool"
    "container_publishing|### Container image publishing"
    "language_fragments|### 3d. Per-language fragments"
    "approver_artifacts|### 3e. Claude Approver artifacts"
    "language_artifacts|### 3f. Language-specific bootstrap artifacts"
    "acceptance_workflow|### 3g. Acceptance-test workflow"
    "docs_machinery|### 3h. End-user docs machinery"
    "api_contracts|### 3i. API contracts machinery"
    "anti_corruption_adapter|### 3j. Multi-major anti-corruption adapter"
    "contract_consumer|### 3k. API contract-consumer machinery"
    "react_overlay|### 3k.5. React overlay"
    "react_query|### 3k.6. React Query binding"
    "iac|### 3l. Infrastructure-as-code repos"
    "composition|### 3m. Composition repos"
    "provenance_markers|## Step 3.6: Stamp provenance markers on tracked files"
    "git_hooks|### 4a. Install git hooks"
    "build_script|### 4c (Java). Build script"
  )
  [ "${#pairs[@]}" -eq 19 ]
  local p k h
  for p in "${pairs[@]}"; do
    k="${p%%|*}"; h="${p#*|}"
    # the heading exists in SKILL.md, as the start of a heading line
    [ -n "$(awk -v h="$h" 'index($0, h) == 1 { print NR; exit }' "$SKILL")" ]
    # the emit section's table maps the key to that heading's text
    contains "$(cat "$SKILL")" "| \`$k\` | ${h#\#* }"
    # and the builder accepts it
    printf '%s' "{\"mode\":\"fresh\",\"target_repo\":null,\"visibility\":null,\"languages\":{\"primary\":\"go\",\"auxiliary\":[]},\"topics\":[],\"interfaces\":[],\"host\":{\"os\":\"macos\",\"homebrew\":true},\"steps\":{\"$k\":\"skipped\"},\"files\":[],\"github_state\":{\"branch_protection\":\"skipped\",\"secrets\":\"skipped\",\"sonar_project\":\"skipped\",\"apps_installed\":\"skipped\"},\"stack\":\"resolved\",\"early_stop\":null,\"approve_merge\":null,\"pr\":null}" > "$ST"
    build
    [ "$status" -eq 0 ]
  done
  # the builder's list has exactly these 19 keys and no other
  local listed expected
  listed="$(awk '/\["common_artifacts"/,/"build_script"\] as \$keys/' "$B" | grep -o '"[a-z_]*"' | tr -d '"' | LC_ALL=C sort | tr '\n' ' ')"
  expected="$(for p in "${pairs[@]}"; do printf '%s\n' "${p%%|*}"; done | LC_ALL=C sort | tr '\n' ' ')"
  [ "$listed" = "$expected" ]
}

@test "ARCHITECTURE.md documents the bootstrap keys, the step keys, the files <-> steps rule and the fold" {
  run cat "$ARCH"
  contains "$output" "## Bootstrap telemetry (#1229)"
  contains "$output" "the normal finish (a run a failed step ended, and State D's no-drift stop, which"
  contains "$output" "commits nothing, included), and each early stop (a plan declined at Step 2, a"
  local k
  for k in mode target_repo visibility languages host steps files github_state ending; do
    contains "$output" "| \`$k\` |"
  done
  contains "$output" "| \`topics\` / \`interfaces\` |"
  contains "$output" "**Step keys — a closed list.**"
  contains "$output" "**Files ↔ steps.**"
  contains "$output" "\`step: <k>\`, by \`failed\` > \`skipped\` > \`merged\` > \`written\` > \`already_present\`;"
  contains "$output" "an applicable step with **zero** entries is \`skipped\`."
  contains "$output" "| \`escalated\` | \`approve_merge\` is \`request_changes\`, \`red_ci\` or \`retry_exhausted\` |"
  contains "$output" "**Refused states.**"
}
