#!/usr/bin/env bats
#
# Behavioural tests for scripts/check-styleguide-pin.zsh (#689 AC 8).
#
# That script is the only thing between a dead styleguide pin and every
# bootstrapped repo's contracts-lint, and its whole value rests on ONE polarity
# decision: a pin that resolves but loads no rules must FAIL. Spectral with no
# rules reports "0 problems", so an "expect the lint to fail" check would go
# green on a completely broken pin. The script therefore asserts POSITIVELY that
# all eight org rule ids fire at error severity — and that assertion is what
# these tests pin.
#
# The script is EXECUTED against fixture trees, never grepped: a grep cannot
# tell an arm that fires from one that is unreachable, and the failure mode that
# matters here is a vacuous pass. `npx` and `curl` are replaced by stubs on PATH
# (the tests/no-cluster-deploy.bats pattern) so no case touches the network —
# these run in the default gate, which must stay offline and deterministic.
#
# The live pin IS exercised, but by CI: .github/workflows/styleguide-pin.yml.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  W="$BATS_TEST_TMPDIR/repo"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$W/scripts" "$W/development/skills/bootstrap/templates/common" \
    "$W/tests/fixtures/api-styleguide/nonconforming" \
    "$W/tests/fixtures/api-styleguide/conforming" \
    "$STUB_BIN"

  # The script resolves its own repo root as ${0:A:h:h}, so copying it into
  # $W/scripts/ re-roots every path it reads at the fixture tree.
  cp "$REPO_ROOT/scripts/check-styleguide-pin.zsh" "$W/scripts/"

  shim "https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v1.0.0/styleguide/spectral/ruleset.yaml"
  printf 'openapi: 3.1.0\n' > "$W/tests/fixtures/api-styleguide/nonconforming/openapi.yaml"
  printf 'openapi: 3.1.0\n' > "$W/tests/fixtures/api-styleguide/conforming/openapi.yaml"

  stub_curl 200
  stub_npx_all_eight
  PATH="$STUB_BIN:$PATH"
}

# shim <url> — write the fixture shim with the given extends member.
shim() {
  printf 'extends:\n  - %s\n' "$1" > "$W/development/skills/bootstrap/templates/common/.spectral.yaml"
}

# stub_curl <http-code> — the pin fetch reports this status.
stub_curl() {
  printf '#!/usr/bin/env bash\nprintf %%s %s\n' "$1" > "$STUB_BIN/curl"
  chmod +x "$STUB_BIN/curl"
}

# stub_npx <nonconforming-json> [conforming-json] — spectral's --format json.
# The script lints the non-conforming fixture first, then the conforming one, so
# the stub keys off the path it is handed.
stub_npx() {
  local nc="$1" c="${2:-[]}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do case "$a" in\n'
    printf '  *nonconforming*) printf %%s %s; exit 1 ;;\n' "'$nc'"
    printf '  */conforming/*) printf %%s %s; exit 0 ;;\n' "'$c'"
    printf 'esac; done\nprintf %%s "[]"\n'
  } > "$STUB_BIN/npx"
  chmod +x "$STUB_BIN/npx"
}

# All eight ids at severity 0 — the shape a healthy pin produces.
stub_npx_all_eight() {
  stub_npx '[{"code":"operation-operationId","severity":0},{"code":"operation-operationId-unique","severity":0},{"code":"info-description","severity":0},{"code":"operation-description","severity":0},{"code":"operation-tags","severity":0},{"code":"org-deprecated-operation-has-sunset","severity":0},{"code":"org-resource-naming","severity":0},{"code":"org-problem-json-errors","severity":0}]'
}

check() { run zsh "$W/scripts/check-styleguide-pin.zsh"; }

@test "happy path: a live pin enforcing all eight rules exits 0" {
  check
  [ "$status" -eq 0 ]
  contains "$output" "all 8 org rules at error severity"
  contains "$output" "conforming fixture: 0 error findings"
}

@test "THE case this script exists for: pin resolves but loads NO rules -> exit 1" {
  # HTTP 200 and an empty finding set — exactly what a ruleset that failed to
  # load produces. An "expect failures" check would read this as success.
  stub_npx '[]'
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 8 of 8"
  contains "$output" "fired: <none>"
}

@test "rules DEMOTED to warn are not accepted as enforcement" {
  # severity 1 = warn. Downstream repos would enforce nothing while a
  # severity-agnostic check reported all eight ids present.
  stub_npx '[{"code":"operation-operationId","severity":1},{"code":"operation-operationId-unique","severity":1},{"code":"info-description","severity":1},{"code":"operation-description","severity":1},{"code":"operation-tags","severity":1},{"code":"org-deprecated-operation-has-sunset","severity":1},{"code":"org-resource-naming","severity":1},{"code":"org-problem-json-errors","severity":1}]'
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 8 of 8"
}

@test "a single dropped rule is named, and the survivors are listed" {
  stub_npx '[{"code":"operation-operationId","severity":0},{"code":"operation-operationId-unique","severity":0},{"code":"info-description","severity":0},{"code":"operation-description","severity":0},{"code":"operation-tags","severity":0},{"code":"org-deprecated-operation-has-sunset","severity":0},{"code":"org-resource-naming","severity":0}]'
  check
  [ "$status" -eq 1 ]
  contains "$output" "did not enforce 1 of 8"
  contains "$output" "org-problem-json-errors"
}

@test "a 404 pin fails with the HTTP status, not with eight absent rules" {
  stub_curl 404
  check
  [ "$status" -eq 1 ]
  contains "$output" "pin did not resolve (HTTP 404)"
}

@test "an unreachable CDN reports 000 rather than passing" {
  stub_curl 000
  check
  [ "$status" -eq 1 ]
  contains "$output" "pin did not resolve (HTTP 000)"
}

@test "a shim with no pin fails WITH its diagnostic, not silently" {
  # Regression net for the pipefail trap: `PIN_URL="$(grep … | head -1)"` under
  # set -e aborted before the guard could speak, giving a red run with an empty
  # log. The message is the assertion, not the exit code.
  printf 'extends: []\n' > "$W/development/skills/bootstrap/templates/common/.spectral.yaml"
  check
  [ "$status" -eq 1 ]
  contains "$output" "expected exactly 1 jsDelivr pin"
}

@test "a FLOATING major tag is rejected — the one pin the story forbids" {
  shim "https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v1/styleguide/spectral/ruleset.yaml"
  check
  [ "$status" -eq 1 ]
  contains "$output" "not an exact styleguide-vX.Y.Z tag"
}

@test "a retired pin left in a comment does not shadow the live one" {
  {
    printf '# was: https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v0.9.0/styleguide/spectral/ruleset.yaml\n'
    printf 'extends:\n  - https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v1.0.0/styleguide/spectral/ruleset.yaml\n'
  } > "$W/development/skills/bootstrap/templates/common/.spectral.yaml"
  check
  [ "$status" -eq 0 ]
  contains "$output" "@styleguide-v1.0.0"
  lacks "$output" "@styleguide-v0.9.0"
}

@test "TWO live pins is a defect, not a first-one-wins" {
  printf 'extends:\n  - https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v1.0.0/styleguide/spectral/ruleset.yaml\n  - https://cdn.jsdelivr.net/gh/example/styleguide-fixture@styleguide-v2.0.0/styleguide/spectral/ruleset.yaml\n' \
    > "$W/development/skills/bootstrap/templates/common/.spectral.yaml"
  check
  [ "$status" -eq 1 ]
  contains "$output" "expected exactly 1 jsDelivr pin"
}

@test "the over-fire guard fires: a conforming fixture with an error fails" {
  stub_npx_all_eight
  stub_npx '[{"code":"operation-operationId","severity":0},{"code":"operation-operationId-unique","severity":0},{"code":"info-description","severity":0},{"code":"operation-description","severity":0},{"code":"operation-tags","severity":0},{"code":"org-deprecated-operation-has-sunset","severity":0},{"code":"org-resource-naming","severity":0},{"code":"org-problem-json-errors","severity":0}]' \
    '[{"code":"org-resource-naming","severity":0}]'
  check
  [ "$status" -eq 1 ]
  contains "$output" "conforming fixture produced 1 error finding"
}

@test "a MISSING conforming fixture is exit 2, never a silent green" {
  # It previously defaulted to `[]` -> "0 error findings" -> exit 0, disabling
  # the over-fire guard entirely while reporting success.
  rm "$W/tests/fixtures/api-styleguide/conforming/openapi.yaml"
  check
  [ "$status" -eq 2 ]
  contains "$output" "fixture not found"
}

@test "unparseable spectral output is a TOOLING failure (exit 2), not a verdict" {
  stub_npx 'not json at all'
  check
  [ "$status" -eq 2 ]
  contains "$output" "no parseable JSON"
}

@test "the checker's rule roster matches the published ruleset exactly" {
  # Four copies of the eight ids exist (script, this suite's fixtures, the
  # ruleset, the acceptance lane). This binds the two that decide whether a real
  # regression is caught: adding a ninth org rule without extending the script
  # would leave it proving eight-of-nine forever, green.
  # Parsed, not sourced: the script runs on source (it has no main guard), so a
  # `source && print` form captures its OUTPUT, not its array — non-empty garbage
  # that then satisfies any "did we get something" guard.
  local expected actual
  expected="$(sed -n '/^EXPECTED_RULES=(/,/^)/p' \
    "$REPO_ROOT/scripts/check-styleguide-pin.zsh" | sed '1d;$d' | tr -d ' ' | sort)"
  actual="$(yq -r '.rules | keys | .[]' "$REPO_ROOT/styleguide/spectral/ruleset.yaml" | sort)"
  # Canary: a slice that captured nothing would compare "" to "" on a broken
  # ruleset read and pass.
  [ "$(printf '%s\n' "$expected" | wc -l | tr -d ' ')" = "8" ]
  [ "$expected" = "$actual" ]
}
