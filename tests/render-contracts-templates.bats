#!/usr/bin/env bats
#
# Integration tests for the bootstrap API-contracts machinery templates (#692) —
# render the REAL templates the way SKILL.md §3i instructs and prove the
# installed set is coherent: the per-major layout starter, a replaceable Spectral
# ruleset, and the lint + per-major npm publish workflows. The publish workflow's
# APIM governance step must be a clean, skip-when-absent extension point (#706).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
}

CONTRACTS_SET=(
  common/contracts/v1/openapi.yaml.tmpl
  common/.spectral.yaml
  common/.github/workflows/contracts-lint.yml.tmpl
  common/.github/workflows/spec-publish.yml.tmpl
)

render_contracts() {
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" \
    --project-name "Demo Project" --default-branch "main" \
    "${CONTRACTS_SET[@]}"
}

# Parse a YAML file when a PyYAML-capable python3 is available; a no-op pass
# otherwise (jq/zsh are the only hard test deps, and the source templates'
# YAML validity is independently enforced by the repo's yamllint CI gate on
# *.yml.tmpl / *.yaml.tmpl).
assert_valid_yaml() {
  python3 -c 'import yaml' >/dev/null 2>&1 || return 0
  python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$1"
}

@test "#692 contracts: the four templates render to their deploy paths" {
  run render_contracts
  [ "$status" -eq 0 ]
  [ -f "$OUT/common/contracts/v1/openapi.yaml" ]
  [ -f "$OUT/common/.spectral.yaml" ]
  [ -f "$OUT/common/.github/workflows/contracts-lint.yml" ]
  [ -f "$OUT/common/.github/workflows/spec-publish.yml" ]
}

@test "#692 contracts: no {{PLACEHOLDER}} survives the render (render.zsh leftover check)" {
  render_contracts
  run ! grep -REn '\{\{[A-Z_]+\}\}' "$OUT/common"
}

@test "#692 contracts: the starter spec establishes the version triangle (info.version 1.0.0 == /v1)" {
  render_contracts
  local spec="$OUT/common/contracts/v1/openapi.yaml"
  assert_valid_yaml "$spec"
  grep -Eq '^  version: "1\.0\.0"' "$spec"
  grep -Eq '^  - url: /v1' "$spec"
  # PROJECT_NAME is substituted, not left as a token.
  grep -q 'Demo Project API' "$spec"
}

@test "#692 contracts: the Spectral ruleset is valid, extends spectral:oas, and is replaceable-by-path" {
  render_contracts
  local rs="$OUT/common/.spectral.yaml"
  assert_valid_yaml "$rs"
  grep -q 'spectral:oas' "$rs"
  grep -q 'operation-operationId' "$rs"
}

@test "#692 contracts: the lint workflow runs Spectral over contracts/ referencing .spectral.yaml by path" {
  render_contracts
  local wf="$OUT/common/.github/workflows/contracts-lint.yml"
  assert_valid_yaml "$wf"
  grep -q 'spectral' "$wf"
  grep -q -- '--ruleset .spectral.yaml' "$wf"
  grep -q 'contracts/v\[0-9\]\*/openapi.yaml' "$wf"
  # PR trigger wired to the default branch (placeholder substituted).
  grep -q 'branches: \["main"\]' "$wf"
}

@test "#692 contracts: the publish workflow publishes per live major (runtime discovery + matrix)" {
  render_contracts
  local wf="$OUT/common/.github/workflows/spec-publish.yml"
  assert_valid_yaml "$wf"
  # majors discovered at runtime from a per-major glob, basename'd into a JSON
  # matrix — assert the load-bearing loop, not just that 'matrix:' appears
  grep -Eq 'for d in contracts/v\[0-9\]\*/' "$wf"
  grep -q 'majors+=("$(basename "$d")")' "$wf"
  grep -q 'jq -R . | jq -cs .' "$wf"
  grep -q 'major: \${{ fromJson(needs.discover.outputs.majors) }}' "$wf"
  # version == the spec's info.version, read via yq (js-yaml's CLI is NOT JSON);
  # assert the exact extraction line, not a comment mention of "info.version"
  grep -q "version=\"\$(yq -r '.info.version' \"\$spec\")\"" "$wf"
  # the version triangle is enforced at publish (major must match the vN dir)
  grep -q 'disagrees with directory' "$wf"
  # one dist-tag per major, tied to the major; "major-vN" (a bare "vN" is a
  # valid semver range npm rejects as a dist-tag)
  grep -q 'npm publish "$pkgdir" --tag "major-${MAJOR}"' "$wf"
}

@test "#692 contracts: re-publishing an already-published version is a clean no-op" {
  render_contracts
  local wf="$OUT/common/.github/workflows/spec-publish.yml"
  # a routine app release with no contract change must not fail the publish job
  grep -q 'npm view "${pkg}@${version}" version' "$wf"
}

@test "#692 contracts: the APIM governance step is a clean skip-when-absent extension point (#706)" {
  render_contracts
  local wf="$OUT/common/.github/workflows/spec-publish.yml"
  # the guard must be on the PORTAL step and pin the direction: run only when
  # apim/ EXISTS (!= ''). The inverse (== '') would run it when apim/ is absent
  # — the exact regression a bare hashFiles() grep can't catch.
  grep -A2 'APIM governance portal' "$wf" | grep -Eq "if: .*hashFiles\('apim/\*\*'\) != ''"
}
