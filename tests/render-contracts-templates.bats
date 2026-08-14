#!/usr/bin/env bats
#
# Integration tests for the bootstrap API-contracts machinery templates (#692) —
# render the REAL templates the way SKILL.md §3i instructs and prove the
# installed set is coherent: the per-major layout starter, a replaceable Spectral
# ruleset, and the lint + per-major npm publish workflows. The publish workflow's
# APIM governance step must be a clean, skip-when-absent extension point (#706).

bats_require_minimum_version 1.5.0
load assertions

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
  common/CONTRACTS.md.tmpl
  common/.github/scripts/check-contracts-semver.sh
  common/.github/workflows/contracts-lint.yml.tmpl
  common/.github/workflows/spec-publish.yml.tmpl
  common/.github/workflows/contracts-semver.yml.tmpl
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

@test "#692 contracts: the templates render to their deploy paths" {
  run render_contracts
  [ "$status" -eq 0 ]
  [ -f "$OUT/common/contracts/v1/openapi.yaml" ]
  [ -f "$OUT/common/.spectral.yaml" ]
  [ -f "$OUT/common/.github/workflows/contracts-lint.yml" ]
  [ -f "$OUT/common/.github/workflows/spec-publish.yml" ]
  # #693 semver gate
  [ -f "$OUT/common/.github/workflows/contracts-semver.yml" ]
  [ -f "$OUT/common/.github/scripts/check-contracts-semver.sh" ]
  # #695 policy index
  [ -f "$OUT/common/CONTRACTS.md" ]
}

@test "#695 contracts: CONTRACTS.md documents the versioning + deprecation policy and the 6-month window" {
  render_contracts
  local md="$OUT/common/CONTRACTS.md"
  # project name substituted, not left as a token
  grep -q 'Demo Project' "$md"
  # deprecation spec signal
  grep -q 'deprecated: true' "$md"
  grep -q 'x-sunset' "$md"
  # runtime headers with their RFCs
  grep -q 'Deprecation' "$md" && grep -q 'RFC 9745' "$md"
  grep -q 'Sunset' "$md" && grep -q 'RFC 8594' "$md"
  # the minimum-deprecation-window knob, default 6 months
  grep -qi '6 months' "$md"
  # versioning policy present
  grep -qi 'version triangle' "$md"
}

@test "#695 contracts: the Spectral deprecation-has-sunset rule is structurally sound" {
  render_contracts
  local rs="$OUT/common/.spectral.yaml"
  assert_valid_yaml "$rs"
  # parse the rule (not substring greps) so a neutered rule fails the test
  [ "$(yq -r '.rules.deprecation-has-sunset.then.field' "$rs")" = "x-sunset" ]
  [ "$(yq -r '.rules.deprecation-has-sunset.then.function' "$rs")" = "truthy" ]
  [ "$(yq -r '.rules.deprecation-has-sunset.severity' "$rs")" = "warn" ]
  yq -r '.rules.deprecation-has-sunset.given' "$rs" | grep -q '@.deprecated === true'
}

# Executable Spectral check when the CLI is present (it is NOT in the plugin's
# macOS toolchain, so this skips locally — the rule's runtime behaviour is
# validated by the target repo's contracts-lint CI, mirroring the oasdiff seam).
@test "#695 contracts: a deprecated+x-sunset spec passes Spectral lint (when spectral is present)" {
  command -v spectral >/dev/null 2>&1 || skip "spectral not installed (validated in the target repo's contracts-lint CI)"
  render_contracts
  local rs="$OUT/common/.spectral.yaml"
  cat > "$OUT/ok.yaml" <<'EOF'
openapi: 3.1.0
info:
  title: T
  version: "1.0.0"
servers:
  - url: /v1
paths:
  /w:
    get:
      operationId: getW
      deprecated: true
      x-sunset: "2026-12-31"
      responses:
        "200":
          description: ok
EOF
  run spectral lint --ruleset "$rs" --fail-severity error "$OUT/ok.yaml"
  [ "$status" -eq 0 ]
}

@test "#693 contracts: the semver workflow gates via the wrapper, installs pinned oasdiff, and is path-conditional" {
  render_contracts
  local wf="$OUT/common/.github/workflows/contracts-semver.yml"
  assert_valid_yaml "$wf"
  # oasdiff is installed pinned (not floating), and the wrapper produces the verdict
  grep -Eq 'OASDIFF_VERSION: "[0-9]+\.[0-9]+\.[0-9]+"' "$wf"
  grep -q 'bash .github/scripts/check-contracts-semver.sh' "$wf"
  grep -q -- '--base-ref "origin/main"' "$wf"
  # path-conditional (never a required context)
  grep -q 'contracts/\*\*' "$wf"
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
  # The per-major glob is parameterised by family since #1330 (newest-major-only
  # scoping), so the family name is no longer part of the literal — but the per-major
  # shape still is, and both families are still selected.
  grep -q 'v\[0-9\]\*/' "$wf"
  grep -q 'for family in contracts contracts/ops' "$wf"
  # The spec filename still reaches the selector — as newest_major's argument.
  grep -q 'newest_major_num "\$1" openapi.yaml' "$wf"
  # PR trigger wired to the default branch (placeholder substituted).
  grep -q 'branches: \["main"\]' "$wf"
}

@test "#1330 contracts: the lint workflow lints only the NEWEST major per family" {
  # A frozen older major is immutable by contract, so linting it against a ruleset
  # cut after it froze can only produce red nobody may fix — which is exactly what
  # org-problem-json-errors (#689) does to every ops/v1 fragment.
  #
  # Executed, not grepped: the selection is shell logic, and a `sort` that picks v9
  # over v10 reads perfectly fine in a diff.
  render_contracts
  local wf="$OUT/common/.github/workflows/contracts-lint.yml"
  assert_valid_yaml "$wf"
  grep -q 'newest_major()' "$wf"
  # NO sort -V: BSD sort (macOS) accepts the flag, exits 0 and does not reorder,
  # so a maintainer verifying locally and the Ubuntu runner would disagree about
  # v9 vs v10. The majors are integers and are compared arithmetically instead.
  # Counted on the USAGE form (a pipe into sort), not the bare string: the comment
  # above the selector names sort -V precisely to explain why it is not used.
  run grep -c '| sort -V' "$wf"
  [ "$output" -eq 0 ]

  # Slice the selector between its own sentinels. An anchor like /done/ closes
  # inside the first helper that happens to contain a loop — which is exactly how
  # an earlier version of this test failed, silently truncating the slice and
  # turning every case below into a shell error that read like a logic bug.
  local probe="$BATS_TEST_TMPDIR/select.bash" slice="$BATS_TEST_TMPDIR/slice.bash"
  sed -n '/# --- selector-start/,/# --- selector-end/p' "$wf" \
    | sed 's/^[[:space:]]\{1,10\}//' > "$slice"
  # Prove the slice really spans the whole selector before trusting it.
  run cat "$slice"
  contains "$output" 'newest_major_num()'
  contains "$output" 'for family in contracts contracts/ops'
  contains "$output" 'nothing to lint'
  {
    echo 'set -euo pipefail'
    echo 'shopt -s nullglob'
    cat "$slice"
    # The slice carries the workflow's own zero-spec guard (which echoes and
    # exits 0), so this only has to report a non-empty selection.
    echo 'printf "%s\n" "${specs[@]}"'
  } > "$probe"

  local tree="$BATS_TEST_TMPDIR/both"
  mkdir -p "$tree/contracts/v1" "$tree/contracts/v2" "$tree/contracts/ops/v1" "$tree/contracts/ops/v2"
  touch "$tree/contracts/v1/openapi.yaml" "$tree/contracts/v2/openapi.yaml" \
    "$tree/contracts/ops/v1/openapi.yaml" "$tree/contracts/ops/v2/openapi.yaml"
  run bash -c "cd '$tree' && bash '$probe'"
  [ "$status" -eq 0 ]
  contains "$output" 'contracts/v2/openapi.yaml'
  contains "$output" 'contracts/ops/v2/openapi.yaml'
  lacks "$output" 'contracts/v1/openapi.yaml'
  lacks "$output" 'contracts/ops/v1/openapi.yaml'

  # v10 must beat v9 — the reason for sort -V rather than a plain sort.
  local vtree="$BATS_TEST_TMPDIR/vsort"
  mkdir -p "$vtree/contracts/v9" "$vtree/contracts/v10"
  touch "$vtree/contracts/v9/openapi.yaml" "$vtree/contracts/v10/openapi.yaml"
  run bash -c "cd '$vtree' && bash '$probe'"
  [ "$status" -eq 0 ]
  contains "$output" 'contracts/v10/openapi.yaml'
  lacks "$output" 'contracts/v9/openapi.yaml'

  # THE DOCUMENTED TRAP: a repo that never adopts v2 keeps v1 as its newest, and it
  # IS still linted. Migration is mandatory, not optional — this pins that the
  # scoping is not a silent exemption for old majors.
  local trap_tree="$BATS_TEST_TMPDIR/trap"
  mkdir -p "$trap_tree/contracts/ops/v1"
  touch "$trap_tree/contracts/ops/v1/openapi.yaml"
  run bash -c "cd '$trap_tree' && bash '$probe'"
  [ "$status" -eq 0 ]
  contains "$output" 'contracts/ops/v1/openapi.yaml'

  # A NON-MAJOR directory must never shadow the real newest major: v[0-9]* also
  # matches v3-draft, and under newest-only selection that is a silent
  # substitution, not noise — the live spec would go unlinted, green.
  local draft="$BATS_TEST_TMPDIR/draft"
  mkdir -p "$draft/contracts/v2" "$draft/contracts/v3-draft" "$draft/contracts/v2.bak"
  touch "$draft/contracts/v2/openapi.yaml" "$draft/contracts/v3-draft/openapi.yaml" \
    "$draft/contracts/v2.bak/openapi.yaml"
  run bash -c "cd '$draft' && bash '$probe'"
  [ "$status" -eq 0 ]
  contains "$output" 'contracts/v2/openapi.yaml'
  lacks "$output" 'v3-draft'
  lacks "$output" 'v2.bak'

  # A newest vN DIRECTORY whose spec is missing or misnamed must fail LOUDLY
  # rather than regress to linting a frozen older major — the exact "red nobody
  # may fix" file this scoping exists to stop linting.
  local misnamed="$BATS_TEST_TMPDIR/misnamed"
  mkdir -p "$misnamed/contracts/ops/v1" "$misnamed/contracts/ops/v2"
  touch "$misnamed/contracts/ops/v1/openapi.yaml" "$misnamed/contracts/ops/v2/openapi.yml"
  run bash -c "cd '$misnamed' && bash '$probe'"
  [ "$status" -eq 1 ]
  contains "$output" 'refusing to fall back to an older, frozen major'
  lacks "$output" 'contracts/ops/v1/openapi.yaml'

  # …and an empty tree exits cleanly with the WORKFLOW's own message — the slice
  # includes that guard, so this is the shipped text, not a stand-in.
  local empty="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$empty"
  run bash -c "cd '$empty' && bash '$probe'"
  [ "$status" -eq 0 ]
  contains "$output" 'nothing to lint'
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

@test "#706 APIM: portal-publish + proxy-deploy are steps of the SAME publish job, each presence-gated" {
  render_contracts
  local wf="$OUT/common/.github/workflows/spec-publish.yml"
  assert_valid_yaml "$wf"
  # AC4: both APIM steps are MEMBERS of the existing `publish` job (yq proves job
  # membership, not merely presence-somewhere-in-the-file).
  local names
  names="$(yq -r '.jobs.publish.steps[].name' "$wf")"
  grep -q 'APIM governance portal' <<<"$names"
  grep -q 'API proxy from apim/' <<<"$names"
  # AC4: spec-publish.yml is the ONLY workflow that references APIM — no separate
  # governance pipeline was added under any name (the guessed-filename check a
  # regression could dodge is replaced by an exhaustive reference scan).
  [ "$(grep -rlE 'APIM|apim/' "$OUT/common/.github/workflows" | wc -l | tr -d ' ')" -eq 1 ]
  grep -rlE 'APIM|apim/' "$OUT/common/.github/workflows" | grep -q 'spec-publish.yml'
  # each step's `if:` is bound to the presence gate in the run-when-present
  # direction — a step losing the guard, or regressing to == '', fails HERE
  # (binding guard->step, which a whole-file line count cannot).
  local step ifval
  for step in 'APIM governance portal' 'API proxy from apim'; do
    ifval="$(yq -r ".jobs.publish.steps[] | select(.name | test(\"$step\")) | .if" "$wf")"
    contains "$ifval" "hashFiles('apim/**') != ''"
  done
}

@test "#706 APIM: the PORTAL STEP reads the same spec as npm (no drift) and stays honest" {
  render_contracts
  local wf="$OUT/common/.github/workflows/spec-publish.yml"
  # AC3: assert on the PORTAL STEP'S run body — the npm step has the identical
  # spec= line, so a whole-file grep would pass even if the portal step read a
  # stripped spec. Slice the portal step's run via yq, then assert within it.
  local portal
  portal="$(yq -r '.jobs.publish.steps[] | select(.name | test("APIM governance portal")) | .run' "$wf")"
  grep -Fq 'spec="contracts/${MAJOR}/openapi.yaml"' <<<"$portal"
  # honest placeholder WITHIN the portal step: logs "Would publish" + carries a
  # REFERENCE PLACEHOLDER, and must NOT claim it actually published.
  grep -Fq 'REFERENCE PLACEHOLDER' <<<"$portal"
  grep -Fq 'Would publish' <<<"$portal"
  run ! grep -qiE 'Published .* to the APIM' <<<"$portal"
  # the APIM_* secrets contract is on the portal step's env
  local penv
  penv="$(yq -r '.jobs.publish.steps[] | select(.name | test("APIM governance portal")) | .env | keys | .[]' "$wf")"
  grep -q 'APIM_ENDPOINT' <<<"$penv"
  grep -q 'APIM_TOKEN' <<<"$penv"
  # the proxy step is likewise an honest placeholder
  local proxy_run
  proxy_run="$(yq -r '.jobs.publish.steps[] | select(.name | test("API proxy from apim")) | .run' "$wf")"
  grep -Fq 'Would deploy' <<<"$proxy_run"
  grep -Fq 'REFERENCE PLACEHOLDER' <<<"$proxy_run"
}

@test "#706 APIM: the apim/ config-as-code scaffold renders coherently (opt-in)" {
  # apim/ is opt-in (not in the core CONTRACTS_SET) — render it explicitly.
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" \
    --project-name "Demo Project" --default-branch "main" \
    common/apim/apiproxy.yaml.tmpl common/apim/README.md.tmpl
  local proxy="$OUT/common/apim/apiproxy.yaml"
  local readme="$OUT/common/apim/README.md"
  [ -f "$proxy" ]
  [ -f "$readme" ]
  assert_valid_yaml "$proxy"
  # the load-bearing config-as-code model, PARSED (not substring-grepped) so a
  # scaffold that drops the routes[] / target model fails.
  [ "$(yq -r '.proxy.name' "$proxy")" = "api-proxy" ]
  # one route per live major: basePath (== the seed spec's servers url /v1), major, target
  [ "$(yq -r '.routes[0].basePath' "$proxy")" = "/v1" ]
  [ "$(yq -r '.routes[0].major' "$proxy")" = "v1" ]
  yq -r '.routes[0].target' "$proxy" | grep -qE '^https?://'
  # gateway policies present as a mapping
  local pols
  pols="$(yq -r '.policies | keys | .[]' "$proxy")"
  grep -q cors <<<"$pols"
  grep -q quota <<<"$pols"
  grep -q auth <<<"$pols"
  # no leftover placeholders survived the render
  run ! grep -q '{{' "$proxy"
  run ! grep -q '{{' "$readme"
  # the README states the two-channel model + the org-wires-the-platform seam
  grep -q 'config-as-code' "$readme"
  grep -qi 'APIM_ENDPOINT' "$readme"
}

@test "#708 contracts: CONTRACTS.md documents the mechanical retirement path + 410" {
  render_contracts
  local md="$OUT/common/CONTRACTS.md"
  # major-level sunset convention (distinct from the per-operation one)
  grep -qi 'major-level' "$md"
  # the enforcement finding is named, and matches the rule the gathers emit
  grep -q 'sunset-passed' "$md"
  # Assert the numbered procedure itself, extracted from the Retirement section —
  # loose whole-file greps would still pass if the steps were deleted and only
  # the surrounding prose kept the tokens.
  local steps
  steps="$(awk '/^### 3\. Retirement/{f=1} /^## Minimum deprecation window/{f=0} f' "$md")"
  [ -n "$steps" ]
  grep -q 'src/api/<vN>/' <<<"$steps"          # 1. adapter removal
  grep -q 'openApiGenerate<Vn>' <<<"$steps"    # 2. generate wiring removal
  grep -q 'contracts/<vN>/' <<<"$steps"        # 3. spec removal
  grep -q '410 Gone' <<<"$steps"               # 4. gateway
}
