#!/usr/bin/env bats
#
# The bootstrap OpenTofu IaC path (#1162, epic #1158): the four templates under
# development/skills/bootstrap/templates/opentofu/ — the one-job
# opentofu-ci.yml, the Makefile, the pre-push hook and the gate MECHANISM
# scripts/tofu-gate.zsh — and the end-to-end claim that the REAL rendered
# workflow passes `branch-protection.sh --iac-only opentofu`'s gate-job probe.
#
# THE WIRING half mirrors tests/bootstrap-iac-pipeline.bats: every template is
# rendered through render.zsh, the renderer bootstrap runs, and structure is
# read with yq rather than grepped.
#
# THE MECHANISM half runs the rendered gate script against fixture trees with
# STUB tofu / tflint / trivy / conftest binaries first on PATH. A stub fails a
# stage when a fixture file carries that stage's `STUB:<stage>-bad` token, and
# logs every call to $CALLS. That proves the gate's own logic — stage order, the
# stop at the first red, skips, warnings, root-module discovery, the
# state-encryption classifier, which Conftest subtree each stage reads, the
# plan-policy opt-in — without network or credentials. The tools' own verdicts
# are not this file's subject: the gate runs pinned binaries in CI.
#
# Two AGREEMENT tests tie the gate to the scripts it embeds a copy of: its root
# modules equal tofu-review-gate.zsh's over the same trees, and its
# state-encryption verdict equals gather-opentofu-findings.zsh's over the same
# shapes (ARCHITECTURE.md's invariant 3).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  TMPL="$TEMPLATES/opentofu/.github/workflows/opentofu-ci.yml.tmpl"
  GATE_TMPL="$TEMPLATES/opentofu/scripts/tofu-gate.zsh.tmpl"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  STAMP="$REPO_ROOT/development/skills/bootstrap/scripts/stamp-marker.zsh"
  PROTECT="$REPO_ROOT/development/skills/bootstrap/scripts/branch-protection.sh"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-opentofu-findings.zsh"
  REVIEW_GATE="$REPO_ROOT/development-opentofu/skills/review/scripts/tofu-review-gate.zsh"
  OUT="$BATS_TEST_TMPDIR/out"
  WF="$OUT/opentofu/.github/workflows/opentofu-ci.yml"
  GATE="$OUT/opentofu/scripts/tofu-gate.zsh"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  FIX="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$OUT" "$STUB_BIN" "$FIX"
  : > "$CALLS"
  export CALLS
}

render_tofu() {
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" --primary opentofu --languages "" "$@"
}

# The stub toolchain. Each stub logs `<tool> <args> @ <cwd>` and fails when any
# file under its cwd carries its STUB token.
tool_stubs() {
  local t
  for t in tofu tflint trivy conftest; do
    cat > "$STUB_BIN/$t" <<'EOF'
#!/bin/sh
tool="$(basename "$0")"
printf '%s %s @ %s\n' "$tool" "$*" "$PWD" >> "$CALLS"
has() { grep -rqs -- "$1" . 2>/dev/null; }
case "$tool $1" in
  "tofu fmt") has 'STUB:fmt-bad' && { echo "fmt: unformatted"; exit 3; } ;;
  "tofu init")
    mkdir -p .terraform
    # only a BACKEND init needs credentials; -backend=false never does
    if [ -n "${STUB_NO_CREDS:-}" ]; then
      case " $* " in *" -backend=false "*) ;; *) echo "no credentials"; exit 1 ;; esac
    fi ;;
  "tofu validate") has 'STUB:validate-bad' && { echo "validate: invalid"; exit 1; } ;;
  "tofu plan") : ;;
  "tofu show") echo '{}' ;;
  "tflint --init") : ;;
  "tflint --recursive") has 'STUB:lint-bad' && { echo "tflint: issue"; exit 2; } ;;
  "trivy config") has 'STUB:scan-bad' && { echo "trivy: HIGH"; exit 1; } ;;
  "conftest test") grep -rqs 'STUB:deny' policies 2>/dev/null && { echo "conftest: deny"; exit 1; } ;;
  "conftest verify") grep -rqs 'STUB:verify-bad' policies 2>/dev/null && { echo "verify: fail"; exit 1; } ;;
esac
exit 0
EOF
    chmod +x "$STUB_BIN/$t"
  done
}

# Render the gate script and run it in $FIX with the stubs first on PATH.
run_gate() {
  render_tofu opentofu/scripts/tofu-gate.zsh.tmpl
  tool_stubs
  cd "$FIX"
  run env -u GITHUB_ACTIONS PATH="$STUB_BIN:$PATH" "$@" zsh "$GATE"
}

clean_fixture() {
  mkdir -p "$FIX/environments/dev" "$FIX/environments/prod" "$FIX/modules/network"
  printf 'module "net" {\n  source = "../../modules/network"\n}\nprovider "aws" {}\n' > "$FIX/environments/dev/main.tf"
  printf 'module "net" {\n  source = "../../modules/network"\n}\nprovider "aws" {}\n' > "$FIX/environments/prod/main.tf"
  printf 'terraform {\n  backend "s3" {\n    encrypt = true\n  }\n}\n' > "$FIX/environments/dev/backend.tf"
  printf 'resource "aws_vpc" "this" {}\n' > "$FIX/modules/network/main.tf"
}

# The seven verdict lines a run printed, in order, stage names only.
stages_seen() {
  printf '%s\n' "$output" | sed -n 's/^gate: \([a-z-]*\) .*/\1/p' | paste -sd' ' -
}

# ---------------------------------------------------------------------------
# The workflow
# ---------------------------------------------------------------------------

@test "the four templates live under templates/opentofu/, beside templates/iac/ and never inside it (#1162)" {
  [ -f "$TMPL" ]
  [ -f "$GATE_TMPL" ]
  [ -f "$TEMPLATES/opentofu/Makefile.tmpl" ]
  [ -f "$TEMPLATES/opentofu/hooks/pre-push.tmpl" ]
  run find "$TEMPLATES/iac" -name '*tofu*'
  [ -z "$output" ]
  run find "$TEMPLATES/opentofu" -name '*k8s*' -o -name 'kubernetes-ci*'
  [ -z "$output" ]
}

@test "the UNRENDERED workflow is valid YAML, strict-yamllint clean, and GATE_COMMAND is its one placeholder and last step (#1162)" {
  run yq -o=json -I=0 '.' "$TMPL"
  [ "$status" -eq 0 ]
  run yamllint -c "$REPO_ROOT/.yamllint" --strict "$TMPL"
  [ "$status" -eq 0 ]
  local placeholders
  placeholders="$(grep -oE '\{\{[A-Z][A-Z0-9_]*\}\}' "$TMPL" | LC_ALL=C sort -u)"
  [ "$placeholders" = '{{GATE_COMMAND}}' ]
  [ "$(yq -r '.jobs.gate.steps[-1].run' "$TMPL")" = '{{GATE_COMMAND}}' ]
}

@test "the rendered workflow is ONE job, gate, with no name, matrix or needs, running the gate command last and nothing else (#1162)" {
  run render_tofu --gate-command 'make lint' opentofu/.github/workflows/opentofu-ci.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(yq -r '.jobs | keys | join(" ")' "$WF")" = "gate" ]
  [ "$(yq -r '.jobs.gate | has("name")' "$WF")" = "false" ]
  [ "$(yq -r '.jobs.gate | has("strategy")' "$WF")" = "false" ]
  [ "$(yq -r '.jobs.gate | has("needs")' "$WF")" = "false" ]
  [ "$(yq -r '.on | keys | join(" ")' "$WF")" = "pull_request" ]
  [ "$(yq -r '.jobs.gate.steps[-1].run' "$WF")" = "make lint" ]
  # no earlier step runs a check of its own: only installs and the checkout
  run yq -r '.jobs.gate.steps[:-1][] | .run // ""' "$WF"
  lacks "$output" 'make '
  lacks "$output" 'tofu-gate'
  lacks "$output" 'tofu fmt'
  lacks "$output" 'conftest test'
}

@test "every tool the gate requires is pinned EXACTLY, step-level, into \$RUNNER_TEMP/gate-bin (#1162)" {
  run render_tofu opentofu/.github/workflows/opentofu-ci.yml.tmpl
  [ "$status" -eq 0 ]
  local pin tool key value
  for pin in tofu:TOFU_VERSION tflint:TFLINT_VERSION trivy:TRIVY_VERSION conftest:CONFTEST_VERSION; do
    tool="${pin%%:*}" key="${pin#*:}"
    value="$(yq -r ".jobs.gate.steps[] | select(.name == \"install $tool\") | .env.$key" "$WF")"
    matches "$value" '^[0-9]+\.[0-9]+\.[0-9]+$'
    run yq -r ".jobs.gate.steps[] | select(.name == \"install $tool\") | .run" "$WF"
    contains "$output" '$RUNNER_TEMP/gate-bin'
    # the gate script requires exactly these, so a pin with no requirement (or
    # the reverse) is drift between the two halves
    grep -qE "^require_tool $tool " "$GATE_TMPL"
  done
  [ "$(yq -r '.jobs.gate.steps[] | select(.name == "put the tool directory on PATH") | .run' "$WF" | grep -c 'GITHUB_PATH')" -eq 1 ]
}

@test "the rendered Conftest pin equals gather-opentofu-findings.zsh's CONFTEST_VERSION (#1162)" {
  run render_tofu opentofu/.github/workflows/opentofu-ci.yml.tmpl
  [ "$status" -eq 0 ]
  local rendered gather
  rendered="$(yq -r '.jobs.gate.steps[] | select(.name == "install conftest") | .env.CONFTEST_VERSION' "$WF")"
  gather="$(sed -n 's/^local CONFTEST_VERSION="\([^"]*\)"$/\1/p' "$GATHER")"
  [ -n "$gather" ]
  [ "$rendered" = "$gather" ]
}

@test "the REAL rendered, stamped opentofu-ci.yml passes branch-protection.sh --iac-only opentofu's gate-job probe (#1162)" {
  render_tofu opentofu/.github/workflows/opentofu-ci.yml.tmpl
  local repo="$BATS_TEST_TMPDIR/tofu-repo" data="$BATS_TEST_TMPDIR/curl-data.txt"
  mkdir -p "$repo/.github/workflows"
  cp "$WF" "$repo/.github/workflows/opentofu-ci.yml"
  zsh "$STAMP" --repo "$repo" --target .github/workflows/opentofu-ci.yml \
    --template opentofu/.github/workflows/opentofu-ci.yml.tmpl
  grep -q '^# claude-bootstrap: rendered from opentofu/' "$repo/.github/workflows/opentofu-ci.yml"
  printf '#!/bin/sh\ncase "$1 $2" in\n  "repo view") echo acme/infra ;;\n  "auth token") echo t ;;\nesac\nexit 0\n' > "$STUB_BIN/gh"
  printf '#!/bin/sh\nprev=""\nfor a in "$@"; do [ "$prev" = "--data" ] && printf %%s "$a" | jq -c . >> "%s"; prev="$a"; done\necho 200\n' "$data" > "$STUB_BIN/curl"
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/curl"
  cd "$repo"
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" --has-dockerfile false --has-codeql false \
    --iac-only opentofu --default-branch main
  [ "$status" -eq 0 ]
  [ "$(head -1 "$data" | jq -r '.required_status_checks.contexts | join(",")')" = "gate" ]
}

@test "the Makefile's lint runs the gate script through zsh, and the hook runs the gate command (#1162)" {
  render_tofu --gate-command 'make lint' opentofu/Makefile.tmpl opentofu/hooks/pre-push.tmpl
  run make -n -f "$OUT/opentofu/Makefile" lint
  [ "$status" -eq 0 ]
  [ "$output" = "zsh scripts/tofu-gate.zsh" ]
  run make -n -f "$OUT/opentofu/Makefile" hooks
  [ "$output" = "git config core.hooksPath hooks" ]
  [ "$(sed -n 2p "$OUT/opentofu/hooks/pre-push")" = "make lint" ]
  [ -x "$OUT/opentofu/hooks/pre-push" ]
}

# ---------------------------------------------------------------------------
# The gate mechanism
# ---------------------------------------------------------------------------

@test "the gate template carries no placeholder, is executable and parses (#1162)" {
  run grep -c '{{' "$GATE_TMPL"
  [ "$output" = "0" ]
  [ -x "$GATE_TMPL" ]
  zsh -n "$GATE_TMPL"
}

@test "clean: the gate runs the seven stages in pipeline order and exits 0 (#1162)" {
  clean_fixture
  run_gate
  [ "$status" -eq 0 ]
  [ "$(stages_seen)" = "fmt validate lint config-scan state-encryption policy plan-policy" ]
  contains "$output" 'gate: fmt ok'
  contains "$output" 'gate: validate ok'
  contains "$output" 'gate: lint ok'
  contains "$output" 'gate: config-scan ok'
  contains "$output" 'gate: state-encryption ok'
  contains "$output" 'gate: policy skipped — no policies at policies/conftest/hcl/'
  contains "$output" 'gate: plan-policy skipped — opt-in (opentofu_plan_policy is not true in .maintenance.yml)'
  # the arguments that make fmt and config-scan able to red at all
  grep -q '^tofu fmt -check -recursive @ ' "$CALLS"
  grep -q '^trivy config --skip-check-update --skip-version-check --exit-code 1 --severity HIGH,CRITICAL ' "$CALLS"
}

@test "each credential-free stage reds on its own fixture, and the gate stops there (#1162)" {
  local case stage token expect rest
  # stage|token|the verdict lines printed — the token sits in a ROOT, which every
  # stage's stub reads from its own working directory
  for case in 'fmt|STUB:fmt-bad|fmt' 'validate|STUB:validate-bad|fmt validate' \
              'lint|STUB:lint-bad|fmt validate lint' 'config-scan|STUB:scan-bad|fmt validate lint config-scan'; do
    stage="${case%%|*}"
    rest="${case#*|}"
    token="${rest%%|*}"
    expect="${rest#*|}"
    rm -rf "$FIX"; mkdir -p "$FIX"
    clean_fixture
    printf '# %s\n' "$token" >> "$FIX/environments/dev/main.tf"
    run_gate
    [ "$status" -eq 1 ]
    contains "$output" "gate: $stage FAILED"
    [ "$(stages_seen)" = "$expect" ]
  done
}

@test "policy reds on a denying HCL policy, before plan-policy runs (#1162)" {
  clean_fixture
  mkdir -p "$FIX/policies/conftest/hcl"
  printf 'package main\n# STUB:deny\n' > "$FIX/policies/conftest/hcl/deny.rego"
  run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: policy FAILED'
  lacks "$output" 'gate: plan-policy'
}

@test "state-encryption is red only when its scan cannot run (#1162)" {
  clean_fixture
  # xargs feeds the classifier; a failing one is a scan that could not run
  printf '#!/bin/sh\nexit 1\n' > "$STUB_BIN/xargs"
  chmod +x "$STUB_BIN/xargs"
  render_tofu opentofu/scripts/tofu-gate.zsh.tmpl
  cd "$FIX"
  tool_stubs
  run env -u GITHUB_ACTIONS PATH="$STUB_BIN:$PATH" zsh "$GATE"
  [ "$status" -eq 1 ]
  contains "$output" 'gate: state-encryption FAILED'
  lacks "$output" 'gate: policy'
}

@test "the gate leaves the working tree as it found it — tofu init runs in a scratch copy (#1162)" {
  clean_fixture
  local before after
  before="$(cd "$FIX" && find . | LC_ALL=C sort)"
  run_gate
  [ "$status" -eq 0 ]
  after="$(cd "$FIX" && find . | LC_ALL=C sort)"
  [ "$before" = "$after" ]
  grep -q '^tofu init ' "$CALLS"
}

@test "a missing tool exits 2 before any stage, naming it and its brew line (#1162)" {
  clean_fixture
  render_tofu opentofu/scripts/tofu-gate.zsh.tmpl
  tool_stubs
  rm "$STUB_BIN/conftest"
  local path_no_conftest="$STUB_BIN" d
  local -a parts
  IFS=: read -ra parts <<<"$PATH"
  for d in "${parts[@]}"; do
    if [[ ! -x "$d/conftest" ]]; then path_no_conftest="$path_no_conftest:$d"; fi
  done
  cd "$FIX"
  run env -u GITHUB_ACTIONS PATH="$path_no_conftest" zsh "$GATE"
  [ "$status" -eq 2 ]
  contains "$output" 'tofu-gate: required tool not on PATH: conftest — install it with: brew install conftest'
  lacks "$output" 'gate: fmt'
}

@test "a repo with no OpenTofu sources skips every stage and exits 0 (#1162)" {
  mkdir -p "$FIX/.terraform/modules/x"
  printf 'provider "aws" {}\n' > "$FIX/.terraform/modules/x/main.tf"
  run_gate
  [ "$status" -eq 0 ]
  [ "$(stages_seen)" = "fmt validate lint config-scan state-encryption policy plan-policy" ]
  [ "$(printf '%s\n' "$output" | grep -c 'skipped — no OpenTofu sources')" -eq 7 ]
  [ ! -s "$CALLS" ]
}

# ---------------------------------------------------------------------------
# Root modules — the rule tofu-review-gate.zsh applies
# ---------------------------------------------------------------------------

# The roots the gate's validate stage init-ed, repo-relative, sorted.
gate_roots() {
  sed -n 's/^tofu init -backend=false .* @ //p' "$CALLS" \
    | sed -E "s#^.*/validate/?##; s#^\$#.#" | LC_ALL=C sort | paste -sd' ' -
}

@test "root discovery: repo-root-only, environments/{dev,prod}, a sourced module, .terraform/ and a .tf.json-only root (#1162)" {
  # repo-root-only
  printf 'provider "aws" {}\n' > "$FIX/main.tf"
  run_gate
  [ "$status" -eq 0 ]
  [ "$(gate_roots)" = "." ]

  # environments/{dev,prod} both roots; modules/network called, never a root;
  # a .tf under .terraform/ ignored
  rm -rf "$FIX"; mkdir -p "$FIX"; : > "$CALLS"
  clean_fixture
  mkdir -p "$FIX/environments/dev/.terraform/modules/cached"
  printf 'provider "aws" {}\n' > "$FIX/environments/dev/.terraform/modules/cached/main.tf"
  run_gate
  [ "$status" -eq 0 ]
  [ "$(gate_roots)" = "environments/dev environments/prod" ]

  # a *.tf.json-only root is discovered
  rm -rf "$FIX"; mkdir -p "$FIX/json-root"; : > "$CALLS"
  printf '{"resource": {}}\n' > "$FIX/json-root/main.tf.json"
  run_gate
  [ "$status" -eq 0 ]
  [ "$(gate_roots)" = "json-root" ]
}

@test "root discovery agrees with tofu-review-gate.zsh over the same tree (#1162)" {
  clean_fixture
  mkdir -p "$FIX/json-root"
  printf '{"resource": {}}\n' > "$FIX/json-root/main.tf.json"
  run_gate
  [ "$status" -eq 0 ]
  local ours theirs
  ours="$(gate_roots)"
  run env PATH="$STUB_BIN:$PATH" zsh "$REVIEW_GATE" --repo "$FIX"
  [ "$status" -eq 0 ]
  theirs="$(printf '%s\n' "$output" | jq -r '.roots | sort | join(" ")')"
  [ -n "$theirs" ]
  [ "$ours" = "$theirs" ]
}

# The names in a script's `PRUNE_NAMES=(` … `)` declaration, one line.
prunes_of() {
  sed -n '/PRUNE_NAMES=($/,/^)/p' "$1" | sed '1d;$d' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

@test "the gate's prune set equals gather-opentofu-findings.zsh's and the review gate's PRUNE_NAMES (#1162)" {
  local ours gather review
  ours="$(prunes_of "$GATE_TMPL")"
  gather="$(prunes_of "$GATHER")"
  review="$(prunes_of "$REVIEW_GATE")"
  [ -n "$ours" ]
  [ "$ours" = "$gather" ]
  [ "$ours" = "$review" ]
}

# ---------------------------------------------------------------------------
# state-encryption — report-only, dialect-aware, agreeing with the gather
# ---------------------------------------------------------------------------

# `shape <name>` writes one state-encryption fixture into $FIX.
shape() {
  rm -rf "$FIX"; mkdir -p "$FIX"
  case "$1" in
    unencrypted) printf 'provider "aws" {}\n' > "$FIX/main.tf" ;;
    tofu-encryption) printf 'provider "aws" {}\nterraform {\n  encryption {\n  }\n}\n' > "$FIX/main.tf" ;;
    s3-encrypt) printf 'provider "aws" {}\nterraform {\n  backend "s3" {\n    encrypt = true\n  }\n}\n' > "$FIX/main.tf" ;;
    s3-kms) printf 'terraform {\n  backend "s3" {\n    kms_key_id = "k"\n  }\n}\n' > "$FIX/main.tf" ;;
    library) printf 'variable "x" {}\nresource "aws_vpc" "this" {}\n' > "$FIX/main.tf" ;;
  esac
}

@test "state-encryption warns on unencrypted owned state and is silent for every accepted form and a library (#1162)" {
  local s
  for s in unencrypted tofu-encryption s3-encrypt s3-kms library; do
    shape "$s"
    : > "$CALLS"
    run_gate
    [ "$status" -eq 0 ]
    contains "$output" 'gate: state-encryption ok'
    if [[ "$s" == unencrypted ]]; then
      contains "$output" 'warning: state-encryption: this repository owns OpenTofu/Terraform state and nothing encrypts it at rest'
    else
      lacks "$output" 'state-encryption: this repository owns'
    fi
  done
}

@test "state-encryption agrees with gather-opentofu-findings.zsh's state_encryption finding on every shape (#1162)" {
  local s gate_warns gather_finds
  for s in unencrypted tofu-encryption s3-encrypt s3-kms library; do
    shape "$s"
    run_gate
    [ "$status" -eq 0 ]
    gate_warns="$(printf '%s\n' "$output" | grep -c 'state-encryption: this repository owns OpenTofu/Terraform state and nothing' || true)"
    run zsh "$GATHER" "$FIX"
    [ "$status" -eq 0 ]
    gather_finds="$(printf '%s\n' "$output" | jq '.findings_by_tool.state_encryption | length')"
    [ "$gate_warns" = "$gather_finds" ]
  done
}

# ---------------------------------------------------------------------------
# policy and plan-policy — one Conftest subtree each
# ---------------------------------------------------------------------------

@test "policy notices-and-passes with no .rego under policies/conftest/hcl/ (#1162)" {
  clean_fixture
  mkdir -p "$FIX/policies/conftest/hcl" "$FIX/policies/conftest/plan"
  printf 'package main\n' > "$FIX/policies/conftest/plan/p.rego"
  run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'notice: policy: no policies at policies/conftest/hcl/**/*.rego'
  contains "$output" 'gate: policy skipped'
  run grep -c '^conftest ' "$CALLS"
  [ "$output" = "0" ]
}

@test "policy FAILS on a .rego under policies/conftest/ outside hcl/ and plan/, naming the file (#1162)" {
  clean_fixture
  mkdir -p "$FIX/policies/conftest/hcl" "$FIX/policies/conftest/plan" "$FIX/policies/conftest/misc"
  printf 'package main\ndeny contains msg if { false }\n' > "$FIX/policies/conftest/hcl/p.rego"
  printf 'package main\n' > "$FIX/policies/conftest/plan/p.rego"
  printf 'package main\n' > "$FIX/policies/conftest/naming.rego"
  printf 'package main\n' > "$FIX/policies/conftest/misc/tags.rego"
  run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: policy FAILED'
  contains "$output" 'policies/conftest/naming.rego'
  contains "$output" 'policies/conftest/misc/tags.rego'
  contains "$output" 'move each into policies/conftest/hcl/ (evaluated against the .tf sources) or policies/conftest/plan/ (evaluated against the plan JSON)'
  lacks "$output" 'policies/conftest/hcl/p.rego'
  lacks "$output" 'policies/conftest/plan/p.rego'
  lacks "$output" 'gate: policy skipped'
  run grep -c '^conftest ' "$CALLS"
  [ "$output" = "0" ]
}

@test "policy runs conftest test against hcl/ only, warns and skips verify when the policies have no tests (#1162)" {
  clean_fixture
  mkdir -p "$FIX/policies/conftest/hcl" "$FIX/policies/conftest/plan"
  printf 'package main\ndeny contains msg if { false }\n' > "$FIX/policies/conftest/hcl/p.rego"
  printf 'package main\n' > "$FIX/policies/conftest/plan/p.rego"
  run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'warning: policy: policies/conftest/hcl/ declares policies but no conftest verify tests'
  contains "$output" 'gate: policy ok'
  grep -q '^conftest test --all-namespaces --parser hcl2 --policy policies/conftest/hcl -- ' "$CALLS"
  # The whole file list, not just the prefix (#2552): exactly one conftest test
  # call, naming every fixture .tf file, compared sorted since discovery order
  # is the gate's own. A gate that narrowed tf_files would still pass the prefix.
  run sed -n 's|^conftest test --all-namespaces --parser hcl2 --policy policies/conftest/hcl -- \(.*\) @ .*|\1|p' "$CALLS"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(printf '%s\n' $output | sort | paste -sd' ' -)" = 'environments/dev/backend.tf environments/dev/main.tf environments/prod/main.tf modules/network/main.tf' ]
  run grep -c '^conftest verify' "$CALLS"
  [ "$output" = "0" ]
  run grep -c 'policies/conftest/plan' "$CALLS"
  [ "$output" = "0" ]
}

@test "policy runs conftest verify when a test_ rule exists, and a failing verify reds it (#1162)" {
  clean_fixture
  mkdir -p "$FIX/policies/conftest/hcl"
  printf 'package main\ndeny contains msg if { false }\ntest_nothing if { true }\n' > "$FIX/policies/conftest/hcl/p.rego"
  run_gate
  [ "$status" -eq 0 ]
  grep -q '^conftest verify --policy policies/conftest/hcl ' "$CALLS"
  lacks "$output" 'no conftest verify tests'
  printf '# STUB:verify-bad\n' >> "$FIX/policies/conftest/hcl/p.rego"
  run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: policy FAILED'
}

@test "plan-policy skips unless opentofu_plan_policy is exactly true (#1162)" {
  clean_fixture
  local v
  for v in '' 'opentofu_plan_policy: false' 'opentofu_plan_policy: yes' '# opentofu_plan_policy: true'; do
    printf '%s\n' "$v" > "$FIX/.maintenance.yml"
    : > "$CALLS"
    run_gate
    [ "$status" -eq 0 ]
    contains "$output" 'gate: plan-policy skipped — opt-in (opentofu_plan_policy is not true in .maintenance.yml)'
    run grep -c '^tofu plan' "$CALLS"
    [ "$output" = "0" ]
  done
}

@test "plan-policy, enabled, plans every root and evaluates plan/ only (#1162)" {
  clean_fixture
  mkdir -p "$FIX/policies/conftest/hcl" "$FIX/policies/conftest/plan"
  printf 'package main\n# STUB:hcl-only\n' > "$FIX/policies/conftest/hcl/h.rego"
  printf 'package main\n' > "$FIX/policies/conftest/plan/p.rego"
  printf 'opentofu_plan_policy: true\n' > "$FIX/.maintenance.yml"
  run_gate
  [ "$status" -eq 0 ]
  contains "$output" 'gate: plan-policy ok'
  [ "$(grep -c '^tofu plan ' "$CALLS")" -eq 2 ]
  run grep '^conftest test --all-namespaces --policy ' "$CALLS"
  [ "${#lines[@]}" -eq 2 ]
  contains "$output" '/policies/conftest/plan -- '
  lacks "$output" 'policies/conftest/hcl'
}

@test "plan-policy, enabled without credentials, fails loudly naming the key (#1162)" {
  clean_fixture
  printf 'opentofu_plan_policy: true\n' > "$FIX/.maintenance.yml"
  run_gate STUB_NO_CREDS=1
  [ "$status" -eq 1 ]
  contains "$output" 'plan-policy is enabled (opentofu_plan_policy: true in .maintenance.yml) but tofu init or plan failed'
  contains "$output" 'set opentofu_plan_policy to false to turn the stage off'
  contains "$output" 'gate: plan-policy FAILED'
}

@test "plan-policy, enabled, reds on a denying plan policy (#1162)" {
  clean_fixture
  mkdir -p "$FIX/policies/conftest/plan"
  printf 'package main\n# STUB:deny\n' > "$FIX/policies/conftest/plan/deny.rego"
  printf 'opentofu_plan_policy: true\n' > "$FIX/.maintenance.yml"
  run_gate
  [ "$status" -eq 1 ]
  contains "$output" 'gate: plan-policy FAILED'
}

# ---------------------------------------------------------------------------
# SKILL.md — the OpenTofu path's wiring, stated where bootstrap reads it
# ---------------------------------------------------------------------------

@test "SKILL.md wires the OpenTofu path: topic table, emission, opt-in plan stage, no policy dirs, dual-marker halt (#1162)" {
  local skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md" flat section
  [ -f "$skill" ]
  flat="$(tr -s '[:space:]' ' ' < "$skill")"
  section="$(sed -n '/^### 3l\. Infrastructure-as-code repos/,/^### /p' "$skill" | tr -s '[:space:]' ' ')"
  [ -n "$section" ]
  # the IaC topic table: one row per value bootstrap derives from the topic
  contains "$section" '| `primary:` written | `kubernetes` | `opentofu` |'
  contains "$section" '| `--iac-only` | `kubernetes` | `opentofu` |'
  contains "$section" '| Template tree | `templates/iac/` | `templates/opentofu/` |'
  contains "$section" '| Workflow | `.github/workflows/kubernetes-ci.yml` | `.github/workflows/opentofu-ci.yml` |'
  # what the path emits, and that it never mixes trees
  contains "$section" 'emit `templates/opentofu/.github/workflows/opentofu-ci.yml.tmpl` as `.github/workflows/opentofu-ci.yml`'
  contains "$section" 'write `primary: opentofu`, and render with `--primary opentofu` — never one file of the other tree'
  # the plan stage is opt-in, read by hook and CI alike, and never switched on by bootstrap
  contains "$section" 'it runs only when `.maintenance.yml` records `opentofu_plan_policy: true`, which the hook and CI both read'
  contains "$section" 'Bootstrap never writes that key.'
  contains "$section" 'On the OpenTofu path do not create `policies/conftest/` or either subtree.'
  # the dual-marker repo halts, at Q4 and in the {{PRIMARY}} derivation
  contains "$section" '**The dual-marker repo halts.**'
  contains "$flat" '**When both are `true`** (the dual-marker repo) do not ask it: halt'
  contains "$flat" 'Both markers `true` never reaches here: Q4 halts it (#1394).'
  contains "$flat" '→ that topic, `kubernetes` or `opentofu`'
  # the State-D reading rule maps every kubernetes value onto the opentofu row
  contains "$flat" '`--iac-only opentofu`, `opentofu/`).'
  # every marker condition reads both markers, and the Makefile remedy names the topic's tree
  contains "$section" 'condition yourself from `is_kubernetes` and `is_opentofu` (exactly one `true`) plus the resolved language set'
  contains "$section" 'also applies when both markers are `false` but the user answered Q4 "none"'
  contains "$section" 'for a recorded *language* primary (or the other IaC topic, whose marker did not fire) there is no language path to fall back to'
  contains "$section" 'same halt Q4 takes for "none" with both markers `false`'
  # the conflict branch's two outcomes key on the fired topic, never on kubernetes alone
  contains "$section" 'rewrite `.maintenance.yml`'"'"'s `primary:` to the topic whose marker fired (`kubernetes` or `opentofu`, per the IaC topic table)'
  contains "$section" 'never emit the topic'"'"'s workflow or pass `--iac-only <topic>` (`kubernetes` or `opentofu`)'
  lacks "$section" 'rewrite `.maintenance.yml`'"'"'s `primary:` to `kubernetes`'
  contains "$section" 'A `.rego` under `policies/conftest/` in neither subtree fails `policy`.'
  contains "$flat" 'the lint and hooks targets of iac/Makefile.tmpl (kubernetes) or opentofu/Makefile.tmpl (OpenTofu) first if the Makefile merge was declined'
  lacks "$flat" 'merging `iac/Makefile.tmpl`'
  lacks "$flat" 'from `is_kubernetes` plus the resolved'
  # preflight's OpenTofu tool list, matching preflight.sh's tofu_brews
  contains "$flat" 'With `--iac-only opentofu` it is `gh`, `jq`, `git`, `opentofu`, `tflint`, `trivy` and `conftest`.'
  # the idempotency reviewer's IaC rules name only the kubernetes row (#2426), so the
  # topic is passed in its prompt, stated once in §3l and pointed at by each dispatch site
  contains "$section" 'On the OpenTofu path the prompt says the topic is `opentofu` and that the reviewer reads its kubernetes-tree rules with the opentofu row: `iac/` → `opentofu/`, `kubernetes-ci.yml` → `opentofu-ci.yml`, `scripts/k8s-gate.zsh` → `scripts/tofu-gate.zsh`.'
  contains "$section" 'Its `Makefile` merge then adds `zsh scripts/tofu-gate.zsh` to the `lint` recipe, and a file marked `rendered from opentofu/` counts as plugin-owned.'
  [ "$(printf '%s' "$flat" | grep -o "§3l's \*Pass the topic to the idempotency reviewer\*" | wc -l | tr -d ' ')" = 4 ]
  # the Step 5 IaC checklist prints the primary this run recorded, not kubernetes alone
  contains "$flat" 'even though `.maintenance.yml` records `primary: kubernetes` (or `primary: opentofu` — print the one this run recorded).'
  # Step 3.6 stamps the three OpenTofu files
  contains "$flat" '| `.github/workflows/opentofu-ci.yml` | `opentofu/.github/workflows/opentofu-ci.yml.tmpl` (§3l OpenTofu path only) |'
  contains "$flat" '| `scripts/tofu-gate.zsh` | `opentofu/scripts/tofu-gate.zsh.tmpl` (§3l OpenTofu path only) |'
  contains "$flat" '| `hooks/pre-push` | `opentofu/hooks/pre-push.tmpl` (§3l OpenTofu path only) |'
  # the required-gate workflow stays on: pull_request only, with no paths-ignore
  contains "$flat" '`kubernetes-ci.yml` (and, on the OpenTofu path, `opentofu-ci.yml`) is `on: pull_request` only'
  # State D's gap-fill exception refreshes a refused opentofu-ci.yml too
  contains "$flat" '`kubernetes-ci.yml` refresh above (or `opentofu-ci.yml`'"'"'s), when `branch-protection.sh --iac-only <topic>` refuses it'
  # Step 2.5's consistency reviewer gets the topic workflow
  contains "$flat" 'pass the topic workflow (`kubernetes-ci.yml` or `opentofu-ci.yml`) and the `--iac-only` checks array (the single `gate` context) instead'
  # Step 4b's FATAL refusal covers the OpenTofu flag and workflow
  contains "$flat" '(or, on the OpenTofu path, `--iac-only opentofu` and `opentofu-ci.yml`) the script exits **1**'
  contains "$flat" 'when the topic workflow (`.github/workflows/kubernetes-ci.yml` or `opentofu-ci.yml`) cannot report `gate`'
  # the 403 fallback names the OpenTofu context
  contains "$flat" 'carries (on the OpenTofu path, `opentofu-ci.yml`'"'"'s `gate`).'
  # Step 4.5's preflight invocation, tool list and Docker skip on the OpenTofu path
  contains "$flat" '(`--iac-only opentofu` on the OpenTofu path)'
  contains "$flat" '`opentofu`, `tflint`, `trivy` and `conftest`) — what `make lint` and the pre-push'
  contains "$flat" '`--iac-only <topic>` also skips preflight'"'"'s'
}
