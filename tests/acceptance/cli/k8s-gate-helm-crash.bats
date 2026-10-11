#!/usr/bin/env bats
#
# Acceptance cases for "k8s-gate's 'helm dependency build || true' swallows a
# helm crash as 'no dependencies'" (#1874) — the `cli`-tooled test_cases[] of
# its story-spec, one test per `tc-*` id:
#
#   tc-happy-dep-build-ok-renders         #1875
#   tc-corner-exit1-dump-tolerated        #1876
#   tc-error-crash-status-fails-render    #1877
#   tc-error-crash-dump-above-message     #1878
#   tc-error-crash-actions-annotation     #1879
#
# The use case: sam-operator watches the gate of a GitOps repo whose charts/app
# chart renders fine. When `helm dependency build` aborts with `fatal error:
# concurrent map writes` and a goroutine trace, the workflow log alone must say
# it was a helm crash, not a chart defect, and that a re-run comes first.
#
# What runs for real: the bootstrapped gate script, k8s-gate.zsh.tmpl, over a
# copy of tests/fixtures/kubernetes-repo with the pinned IaC toolchain from
# tests/iac-tools.zsh. Only `helm dependency build` is stubbed, and only in the
# cases that need it to fail; every other helm call reaches the real binary.
# The default gate's tests/kubernetes-ci-fixtures.bats covers the same
# criteria clause by clause.

bats_require_minimum_version 1.5.0
load ../../assertions

setup_file() {
  local repo_root
  repo_root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  zsh "$repo_root/tests/iac-tools.zsh" > "$BATS_FILE_TMPDIR/bin-dir"
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GATE="$REPO_ROOT/development/skills/bootstrap/templates/iac/scripts/k8s-gate.zsh.tmpl"
  IAC_BIN="$(cat "$BATS_FILE_TMPDIR/bin-dir")"
  [ -d "$IAC_BIN" ]
  W="$BATS_TEST_TMPDIR/gitops-clusters"
  cp -R "$REPO_ROOT/tests/fixtures/kubernetes-repo" "$W"
  RENDERED="$BATS_TEST_TMPDIR/rendered"
  CALLS="$BATS_TEST_TMPDIR/calls.txt"
  : > "$CALLS"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  GATE_EXTRA_PATH=""
}

# A helm whose `dependency build` writes the dump sam-operator saw and exits
# $1; every other call goes to the pinned helm.
crashing_dependency_build() {
  cat > "$STUB_BIN/helm" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$CALLS"
if [ "$1 $2" = "dependency build" ]; then
  cat >&2 <<'DUMP'
fatal error: concurrent map writes

goroutine 1 [running]:
helm.sh/helm/v3/pkg/downloader.(*Manager).Build(0x14000418000)
	/home/runner/work/helm/helm/pkg/downloader/manager.go:91 +0x2c
DUMP
  exit "$DEP_EXIT"
fi
exec "$REAL_HELM" "$@"
EOF
  chmod +x "$STUB_BIN/helm"
  GATE_EXTRA_PATH="$STUB_BIN:"
  DEP_EXIT="$1"
}

# Run the gate in the copy; extra NAME=value pairs go to the gate's environment.
gate() {
  run env -u GITHUB_ACTIONS -u GITHUB_REPOSITORY \
    PATH="$GATE_EXTRA_PATH$IAC_BIN:$PATH" \
    REPO_SLUG="fixture-org/kubernetes-repo" K8S_GATE_RENDER_DIR="$RENDERED" \
    CALLS="$CALLS" REAL_HELM="$IAC_BIN/helm" DEP_EXIT="${DEP_EXIT:-0}" \
    "$@" sh -c 'cd "$1" && zsh "$2"' _ "$W" "$GATE"
}

message() {
  printf '%s' "helm dependency build crashed on charts/app (exit $1) — a helm runtime abort, not a chart defect; its dump is above. Re-run once before touching the chart."
}

line_no() {
  WANT="$2" awk '$0 == ENVIRON["WANT"] { print NR; exit }' <<< "$1"
}

@test "tc-happy-dep-build-ok-renders (#1875)" {
  gate
  [ "$status" -eq 0 ]
  contains "$output" 'gate: render ok'
  contains "$output" 'gate: argocd ok'
  lacks "$output" 'crashed on'
}

@test "tc-corner-exit1-dump-tolerated (#1876)" {
  crashing_dependency_build 1
  gate
  [ "$status" -eq 0 ]
  contains "$output" 'fatal error: concurrent map writes'
  contains "$output" 'gate: render ok'
  lacks "$output" 'crashed on'
  # helm template still ran after the tolerated dependency build
  [ "$(cat "$CALLS")" = "$(printf '%s\n' 'dependency build' 'template charts-app')" ]
}

@test "tc-error-crash-status-fails-render (#1877)" {
  local code
  for code in 2 134 130 143; do
    rm -rf "$RENDERED"
    : > "$CALLS"
    crashing_dependency_build "$code"
    gate
    [ "$status" -eq 1 ]
    [ "$(grep -cxF -- "error: $(message "$code")" <<< "$output")" -eq 1 ]
    [ "$(grep '^gate: ' <<< "$output")" = 'gate: render FAILED' ]
    [ "$(cat "$CALLS")" = 'dependency build' ]
  done
}

@test "tc-error-crash-dump-above-message (#1878)" {
  crashing_dependency_build 2
  gate
  [ "$status" -eq 1 ]
  local dump_at msg_at
  dump_at="$(line_no "$output" 'fatal error: concurrent map writes')"
  msg_at="$(line_no "$output" "error: $(message 2)")"
  [ -n "$dump_at" ]
  [ -n "$msg_at" ]
  [ "$dump_at" -lt "$msg_at" ]
  # byte-identical: every dump line is in the output as a whole line
  [ -n "$(line_no "$output" 'goroutine 1 [running]:')" ]
  [ -n "$(line_no "$output" 'helm.sh/helm/v3/pkg/downloader.(*Manager).Build(0x14000418000)')" ]
  [ -n "$(line_no "$output" '	/home/runner/work/helm/helm/pkg/downloader/manager.go:91 +0x2c')" ]
}

@test "tc-error-crash-actions-annotation (#1879)" {
  crashing_dependency_build 2
  gate GITHUB_ACTIONS=true
  [ "$status" -eq 1 ]
  [ "$(grep -cxF -- "::error::$(message 2)" <<< "$output")" -eq 1 ]
  [ "$(grep '^gate: ' <<< "$output")" = 'gate: render FAILED' ]
}
