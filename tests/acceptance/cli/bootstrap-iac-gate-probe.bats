#!/usr/bin/env bats
#
# Acceptance cases for "harden the --iac-only gate-job probe's remaining edges"
# (#1641) — the `cli`-tooled test_cases[] of its story-spec, one test per `tc-*`
# id:
#
#   tc-happy-bare-pull-request            #1949
#   tc-corner-trigger-list-and-siblings   #1950
#   tc-error-filtered-trigger             #1951
#   tc-error-wrong-trigger                #1952
#   tc-error-flow-or-anchored-gate        #1953
#   tc-error-strategy-no-matrix           #1954
#   tc-error-awk-read-failure             #1955
#   tc-corner-sibling-job-renamed         #1956
#   tc-error-gate-deeper-child-indent     #1957
#   tc-corner-column0-comment-in-jobs     #1958
#
# The use case: nils-unblessed-stack runs bootstrap's branch protection on a
# GitOps repo whose hand-edited kubernetes-ci.yml uses legal-but-unusual YAML —
# `on: [push, pull_request]`, a sibling `render:` job carrying `name: Render
# manifests` — and gets either a rule that cannot wedge PRs or a refusal naming
# the exact shape to change.
#
# What runs for real: branch-protection.sh --iac-only true against that repo,
# with `gh` and `curl` stubbed (no GitHub is touched; the PUT payload is
# recorded so the applied rule is asserted, not inferred). The default gate's
# tests/bootstrap-iac-pipeline.bats covers the same criteria clause by clause,
# each case against a named mutation.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PROTECT="$REPO_ROOT/development/skills/bootstrap/scripts/branch-protection.sh"
  TMPL="$REPO_ROOT/development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  CURL_DATA="$BATS_TEST_TMPDIR/curl-data.txt"
  : > "$CURL_DATA"
  export CURL_DATA
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "repo view") echo "nils-platform/gitops-clusters" ;;
  "auth token") echo "stub-token" ;;
esac
exit 0
EOF
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "--data" ]; then
    printf '%s' "$a" | jq -c . >> "$CURL_DATA" 2>/dev/null || printf '%s\n' "$a" >> "$CURL_DATA"
  fi
  prev="$a"
done
echo 200
exit 0
EOF
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/curl"
  GITOPS="$BATS_TEST_TMPDIR/gitops-clusters"
  WF="$GITOPS/.github/workflows/kubernetes-ci.yml"
  mkdir -p "$GITOPS/.github/workflows"
  cd "$GITOPS"
}

protect() {
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --has-dockerfile false --has-codeql false --iac-only true --default-branch main
}

# the applied rule's required contexts, or nothing when no rule was written
applied_contexts() {
  head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")'
}

assert_refused() {
  [ "$status" -eq 1 ]
  contains "$output" "$1"
  contains "$output" 'NOT applying branch protection'
  [ ! -s "$CURL_DATA" ]
}

# nils' workflow: one plain `gate` job under the `on:` block given as $1
write_wf() {
  printf 'name: kubernetes-ci\n%bjobs:\n  gate:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: make lint\n' "$1" > "$WF"
}

@test "tc-happy-bare-pull-request (#1949): the rendered template gets the gate rule" {
  # the template's own shape, with its one placeholder filled as bootstrap would
  sed 's/{{GATE_COMMAND}}/make lint/' "$TMPL" > "$WF"
  protect
  [ "$status" -eq 0 ]
  [ "$(applied_contexts)" = "gate" ]
}

@test "tc-corner-trigger-list-and-siblings (#1950): every bare pull_request shape is accepted" {
  local on
  for on in 'on: pull_request\n' 'on: [push, pull_request]\n' \
    'on:\n  - push\n  - pull_request\n' 'on:\n  push:\n    branches: [main]\n  pull_request: {}\n'; do
    : > "$CURL_DATA"
    write_wf "$on"
    protect
    [ "$status" -eq 0 ]
    [ "$(applied_contexts)" = "gate" ]
  done
}

@test "tc-error-filtered-trigger (#1951): a filtered pull_request is refused" {
  local filter
  for filter in 'types: [opened]' 'branches: [main]' 'branches-ignore: [wip/**]' \
    'paths: ["clusters/**"]' 'paths-ignore: ["docs/**"]'; do
    write_wf "on:\n  pull_request:\n    $filter\n"
    protect
    assert_refused 'does not run on every pull request'
    contains "$output" 'on a bare `pull_request` with no `types:`'
  done
}

@test "tc-error-wrong-trigger (#1952): pull_request_target, push alone, or no on: is refused" {
  local on
  for on in 'on: pull_request_target\n' 'on: push\n' ''; do
    write_wf "$on"
    protect
    assert_refused 'does not run on every pull request'
  done
}

@test "tc-error-flow-or-anchored-gate (#1953): a gate job the probe cannot read line by line is refused" {
  local jobs
  for jobs in '  gate: {runs-on: ubuntu-latest, steps: [{run: make lint}]}\n' \
    '  gate: &g\n    runs-on: ubuntu-latest\n    steps:\n      - run: make lint\n' \
    '  render: &g\n    runs-on: ubuntu-latest\n    steps:\n      - run: make render\n  gate: *g\n' \
    '  render: &base\n    runs-on: ubuntu-latest\n    steps:\n      - run: make render\n  gate:\n    <<: *base\n    steps:\n      - run: make lint\n'; do
    printf 'name: kubernetes-ci\non: [push, pull_request]\njobs:\n%b' "$jobs" > "$WF"
    protect
    assert_refused 'written in flow style'
    lacks "$output" 'has no `gate` job'
    lacks "$output" 'carries `name:`'
  done
}

@test "tc-error-strategy-no-matrix (#1954): a strategy: with no matrix: stays refused, saying why" {
  printf 'name: kubernetes-ci\non: pull_request\njobs:\n  gate:\n    runs-on: ubuntu-latest\n    strategy:\n      fail-fast: false\n    steps:\n      - run: make lint\n' > "$WF"
  protect
  assert_refused 'carries `name:`, a `strategy:` block or a reusable-workflow `uses:`'
  contains "$output" 'a `strategy:` without `matrix:` does nothing for a lone job'
  contains "$output" '`gate (<leg>)` per matrix entry'
}

@test "tc-error-awk-read-failure (#1955): an awk that cannot read the file is reported as that" {
  local real program
  real="$(command -v awk)"
  cat > "$STUB_BIN/awk" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in *"\$AWK_FAIL_ON"*) exit 2 ;; esac
done
exec "$real" "\$@"
EOF
  chmod +x "$STUB_BIN/awk"
  # the marker probe runs only when there is no gate job; the gate-state probe
  # always runs — so each gets the workflow that reaches it
  printf 'name: kubernetes-ci\non: pull_request\njobs:\n  render:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make render\n' > "$WF"
  for program in 'claude-bootstrap: rendered from' 'in_jobs'; do
    AWK_FAIL_ON="$program" protect
    assert_refused 'could not read `'"$WF"'`'
    contains "$output" 'awk exited 2'
    lacks "$output" 'user-owned'
  done
}

@test "tc-corner-sibling-job-renamed (#1956): a render job's name/strategy/uses never counts against gate" {
  local sibling='  render:\n    name: Render manifests\n    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        env: [staging, prod]\n    steps:\n      - run: make render\n  notify:\n    uses: ./.github/workflows/notify.yml\n'
  local gate='  gate:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make lint\n'
  local jobs
  for jobs in "$sibling$gate" "$gate$sibling"; do
    : > "$CURL_DATA"
    printf 'name: kubernetes-ci\non: [push, pull_request]\njobs:\n%b' "$jobs" > "$WF"
    protect
    [ "$status" -eq 0 ]
    [ "$(applied_contexts)" = "gate" ]
  done
}

@test "tc-error-gate-deeper-child-indent (#1957): gate's own name: at a deeper indent than a sibling's is still read" {
  printf 'name: kubernetes-ci\non: pull_request\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make build\n  gate:\n      name: Gate\n      runs-on: ubuntu-latest\n      steps:\n        - run: make lint\n' > "$WF"
  protect
  assert_refused 'carries `name:`, a `strategy:` block or a reusable-workflow `uses:`'
}

@test "tc-corner-column0-comment-in-jobs (#1958): a column-0 comment inside jobs: does not end the block" {
  printf 'name: kubernetes-ci\non: pull_request\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make build\n# gate is the one required check\n  gate:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make lint\n' > "$WF"
  protect
  [ "$status" -eq 0 ]
  [ "$(applied_contexts)" = "gate" ]
}
