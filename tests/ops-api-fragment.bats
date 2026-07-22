#!/usr/bin/env bats
#
# Structural tests for the ops-api/v1 fragment + its CI discovery (#688).
#
# The fragment (templates/common/contracts/ops/v1/openapi.yaml) is a versioned
# contract artifact linted by Spectral in target-repo CI; its zero-error lint is
# verified against .spectral.yaml at authoring time and by the contracts-lint job
# the checker's discovery must cover. The test toolchain has no spectral/yq (and
# runs offline), so these tests assert the fragment's SHAPE and that both workflow
# templates discover contracts/ops/v[0-9]*/ — the parts that gate correctness here.
# Full spectral linting is the target repo's contracts-lint job.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  COMMON="$REPO_ROOT/development/skills/bootstrap/templates/common"
  FRAG="$COMMON/contracts/ops/v1/openapi.yaml"
}

@test "fragment exists at the contracts/ops/v1 path" {
  [ -f "$FRAG" ]
}

@test "fragment declares /info, /health, /metrics" {
  grep -qE '^\s+/info:' "$FRAG"
  grep -qE '^\s+/health:' "$FRAG"
  grep -qE '^\s+/metrics:' "$FRAG"
}

@test "version triangle: info.version 1.x and servers /v1" {
  grep -qE 'version:\s*"1\.' "$FRAG"
  grep -qE 'url:\s*/v1' "$FRAG"
}

@test "each operation has a unique operationId (spectral operation-operationId)" {
  grep -q 'operationId: getInfo' "$FRAG"
  grep -q 'operationId: getHealth' "$FRAG"
  grep -q 'operationId: getMetrics' "$FRAG"
}

@test "/metrics accepts both prometheus and openmetrics content types" {
  grep -qE '^\s+text/plain:' "$FRAG"
  grep -qE '^\s+application/openmetrics-text:' "$FRAG"
}

@test "Info schema requires build + api; ApiMajor requires major + lifecycle" {
  grep -q 'required: \["build", "api"\]' "$FRAG"
  grep -q 'required: \["major", "lifecycle"\]' "$FRAG"
}

@test "deprecated major requires a sunset date (if/then rule)" {
  # the conditional: if lifecycle == deprecated then required sunset
  grep -q 'const: deprecated' "$FRAG"
  grep -q 'required: \["sunset"\]' "$FRAG"
  grep -qE 'enum:\s*\["active", "deprecated"\]' "$FRAG"
}

@test "contracts-lint discovery covers contracts/ops/v[0-9]* (#688)" {
  local tmpl="$COMMON/.github/workflows/contracts-lint.yml.tmpl"
  grep -q 'contracts/ops/v\[0-9\]\*/openapi.yaml' "$tmpl"
}

@test "contracts-semver discovery covers contracts/ops (#688)" {
  local tmpl="$COMMON/.github/workflows/contracts-semver.yml.tmpl"
  # a second gate invocation scoped to the ops surface, writing its own findings
  grep -q "contracts-dir contracts/ops" "$tmpl"
  grep -q "contracts-ops-semver-findings.json" "$tmpl"
}

@test "contracts-semver runs the ops gate UNCONDITIONALLY (no HEAD-only guard, #688)" {
  local tmpl="$COMMON/.github/workflows/contracts-semver.yml.tmpl"
  # a `git rm -r contracts/ops/` must still be gated (retire-a-live-major),
  # so the ops invocation must not be behind an existence guard.
  run ! grep -q "compgen -G 'contracts/ops" "$tmpl"
}
