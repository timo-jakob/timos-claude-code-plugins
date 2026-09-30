#!/usr/bin/env bats
#
# Behavioral tests for gather-react-findings.zsh (epic #686, #956, #1947): the React
# topic gather, on the v2 gather contract (tooling_configured / findings_by_tool /
# coverage / notes), mirroring tests/gather-docs.bats.
#
# Two configuration-audit tools, `a11y` and `lighthouse_budget` (#1947), report an
# existing React repo that lacks the WebUI gates the bootstrap React overlay renders
# (#1946). The compliant fixtures are built FROM that overlay's own template files
# (vitest.config.ts, src/test/setup.ts, lighthouserc.json), so "the audit accepts
# exactly the rendered layout" is pinned against the layout itself, not a copy that
# could drift from it.
#
# No `git init` here: unlike the docs gather (which shells out to detect-stack),
# this script never touches git, so a repo fixture would only import the host's
# global git config without any assertion behind it.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-react-findings.zsh"
  RX="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript/react"
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W"
}

# a minimal React fixture repo: no axe package, no Lighthouse config
react_fixture() {
  jq -n '{name: "app", dependencies: {react: "19.0.0"}}' > "$W/package.json"
}
# #1946's rendered a11y layout: bare axe-core + the overlay's vitest config and setup
a11y_fixture() {
  jq -n '{name: "app", dependencies: {react: "19.0.0"}, devDependencies: {"axe-core": "^4.10.0"}}' \
    > "$W/package.json"
  mkdir -p "$W/src/test"
  cp "$RX/vitest.config.ts" "$W/vitest.config.ts"
  cp "$RX/src/test/setup.ts" "$W/src/test/setup.ts"
}
# #1946's rendered Lighthouse config
lighthouse_fixture() { cp "$RX/lighthouserc.json" "$W/lighthouserc.json"; }
# the whole #1946 layout — both tools compliant
compliant_fixture() { a11y_fixture; lighthouse_fixture; }
# write lighthouserc.json with the given `.ci.assert` object
lhrc_assert() { jq -n --argjson a "$1" '{ci: {assert: $a}}' > "$W/lighthouserc.json"; }
# the two #1946 byte budgets, as an assertions object to extend
BUDGETS='{"resource-summary:script:size": ["error", {"maxNumericValue": 307200}],
          "resource-summary:total:size": ["error", {"maxNumericValue": 512000}]}'

gather() { zsh "$GATHER" "$W"; }
# the ids one tool reported, sorted and comma-joined
ids() { echo "$output" | jq -r --arg t "$1" '[.findings_by_tool[$t][].id] | sort | join(",")'; }
severity_of() { echo "$output" | jq -r --arg id "$1" '[.findings_by_tool[][] | select(.id == $id) | .severity] | join(",")'; }

@test "the gather script exists and is executable (topic support is gated on its presence)" {
  [ -f "$GATHER" ]
  [ -x "$GATHER" ]
}

@test "a React fixture yields a well-formed v2 payload and exit 0" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "tooling_configured and findings_by_tool always carry BOTH tool keys" {
  # replaces the v0.1 empty-universe pins: the universe is now exactly these two
  # tools, on a repo with nothing configured as much as on a compliant one
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured | keys | join(",")')" = "a11y,lighthouse_budget" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | keys | join(",")')" = "a11y,lighthouse_budget" ]
  echo "$output" | jq -e '.findings_by_tool | all(.[]; type == "array")' >/dev/null
  echo "$output" | jq -e '.tooling_configured | all(.[]; type == "boolean")' >/dev/null
}

@test "coverage is null (a topic has no test suite of its own)" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.coverage == null' >/dev/null
}

@test "the payload carries exactly the four v2 gather keys (order-independent)" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  # sorted, so reordering the jq -n template is not a spurious failure; the real
  # contract is 'exactly these four keys', which consumers read by name
  [ "$(echo "$output" | jq -r 'keys | join(",")')" = "coverage,findings_by_tool,notes,tooling_configured" ]
}

@test "#1946's rendered layout yields no finding at all, both tools configured and no note" {
  compliant_fixture
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "" ]
  [ "$(ids lighthouse_budget)" = "" ]
  echo "$output" | jq -e '.tooling_configured == {a11y: true, lighthouse_budget: true}' >/dev/null
  echo "$output" | jq -e '.notes == []' >/dev/null
}

@test "every finding has exactly the seven keys and an id of <tool>:<type>[:<assertion-id>]" {
  # a fixture that trips every finding type the two tools can emit together
  jq -n '{devDependencies: {"jest-axe": "^9"}}' > "$W/package.json"
  lhrc_assert '{"preset": "lighthouse:recommended", "assertions": {
      "resource-summary:script:size": ["error", {"maxNumericValue": 400000}],
      "resource-summary:total:size": "warn",
      "total-blocking-time": "error"}}'
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.findings_by_tool[][]] | length')" -ge 5 ]
  echo "$output" | jq -e '[.findings_by_tool[][]] | all(keys == ["files","fix","id","message","severity","tool","type"])' >/dev/null
  echo "$output" | jq -e '[.findings_by_tool | to_entries[] | .key as $t | .value[] | "\(.tool):\(.type)" as $p
      | .tool == $t and (.id == $p or (.id | startswith($p + ":")))] | all' >/dev/null
  echo "$output" | jq -e '[.findings_by_tool[][]] | all((.files | type == "array" and length > 0)
      and (.message | length > 0) and (.fix | length > 0))' >/dev/null
}

# --- a11y ------------------------------------------------------------------------

@test "a11y: no axe package yields exactly a11y:no_axe_package (MAJOR), tooling_configured.a11y false" {
  react_fixture
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "a11y:no_axe_package" ]
  [ "$(severity_of a11y:no_axe_package)" = "MAJOR" ]
  echo "$output" | jq -e '.tooling_configured.a11y == false' >/dev/null
}

@test "a11y: an axe package only in runtime dependencies does not count (devDependencies is the rule)" {
  jq -n '{dependencies: {react: "19.0.0", "axe-core": "^4.10.0"}}' > "$W/package.json"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "a11y:no_axe_package" ]
}

@test "a11y: each listed axe package name counts as present, including an @axe-core/ scope" {
  mkdir -p "$W/src/test"
  printf 'export default { test: { setupFiles: ["./src/test/setup.ts"] } }\n' > "$W/vitest.config.ts"
  printf 'expect.extend({ toHaveNoViolations() {} });\n' > "$W/src/test/setup.ts"
  for pkg in axe-core vitest-axe jest-axe @axe-core/playwright; do
    jq -n --arg p "$pkg" '{devDependencies: {($p): "1.0.0"}}' > "$W/package.json"
    run gather
    [ "$status" -eq 0 ]
    [ "$(ids a11y)" = "" ]
    echo "$output" | jq -e '.tooling_configured.a11y == true' >/dev/null
  done
  # a name that merely CONTAINS axe is not one of them
  jq -n '{devDependencies: {"axe-core-lookalike": "1.0.0"}}' > "$W/package.json"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "a11y:no_axe_package" ]
}

@test "a11y: an axe package whose setupFiles registers no matcher yields exactly a11y:matcher_not_registered (MAJOR)" {
  a11y_fixture
  printf 'import "@testing-library/jest-dom/vitest";\n' > "$W/src/test/setup.ts"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "a11y:matcher_not_registered" ]
  [ "$(severity_of a11y:matcher_not_registered)" = "MAJOR" ]
  echo "$output" | jq -e '.tooling_configured.a11y == true' >/dev/null
  echo "$output" | jq -e '.findings_by_tool.a11y[0].files == ["vitest.config.ts"]' >/dev/null
}

@test "a11y: a listed setup file that does not exist does not register the matcher" {
  a11y_fixture
  rm "$W/src/test/setup.ts"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "a11y:matcher_not_registered" ]
}

@test "a11y: no vitest/vite config, or a config with no setupFiles, is matcher_not_registered" {
  a11y_fixture
  rm "$W/vitest.config.ts"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "a11y:matcher_not_registered" ]
  echo "$output" | jq -e '.findings_by_tool.a11y[0].files == ["package.json"]' >/dev/null

  printf 'export default { test: { environment: "jsdom" } }\n' > "$W/vitest.config.ts"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "a11y:matcher_not_registered" ]
  echo "$output" | jq -e '.notes == []' >/dev/null
}

@test "a11y: an extend-expect import from vitest-axe or jest-axe registers the matcher" {
  a11y_fixture
  for imp in vitest-axe/extend-expect jest-axe/extend-expect; do
    printf 'import "%s";\n' "$imp" > "$W/src/test/setup.ts"
    run gather
    [ "$status" -eq 0 ]
    [ "$(ids a11y)" = "" ]
  done
}

@test "a11y: a single-string setupFiles and a multi-entry array (with a comment) are both read" {
  a11y_fixture
  printf 'export default { test: { setupFiles: "./src/test/setup.ts" } }\n' > "$W/vitest.config.ts"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "" ]
  # the registering file is the SECOND literal, after a comment and a non-registering one
  printf 'import "@testing-library/jest-dom/vitest";\n' > "$W/src/test/other.ts"
  printf 'export default {\n  test: {\n    setupFiles: [\n      "./src/test/other.ts", // first\n      /* then */ '"'"'src/test/setup.ts'"'"',\n    ],\n  },\n}\n' \
    > "$W/vitest.config.ts"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "" ]
}

@test "a11y: vitest.config.* wins over vite.config.*, and vite.config.* is the fallback" {
  a11y_fixture
  # vite.config registers, vitest.config does not: the vitest config is the one read
  printf 'export default { test: { setupFiles: ["./src/test/none.ts"] } }\n' > "$W/vitest.config.mjs"
  rm "$W/vitest.config.ts"
  printf 'export default { test: { setupFiles: ["./src/test/setup.ts"] } }\n' > "$W/vite.config.ts"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "a11y:matcher_not_registered" ]
  contains "$(echo "$output" | jq -r '.findings_by_tool.a11y[0].message')" 'vitest.config.mjs'
  # with no vitest config at all, the vite config is read
  rm "$W/vitest.config.mjs"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "" ]
}

@test "a11y: a setupFiles with no extractable string literal yields a note and no a11y finding" {
  a11y_fixture
  printf 'import "@testing-library/jest-dom/vitest";\n' > "$W/src/test/other.ts"
  # a mixed array whose only literal does not register is unjudged too: the
  # skipped entry may be the registering one
  for value in 'setupFiles: files' 'setupFiles: [setupPath]' 'setupFiles: [`${dir}/setup.ts`]' 'setupFiles' \
      'setupFiles: [setupPath, "./src/test/other.ts"]'; do
    printf 'const files = [];\nexport default { test: { %s } }\n' "$value" > "$W/vitest.config.ts"
    run gather
    [ "$status" -eq 0 ]
    [ "$(ids a11y)" = "" ]
    notes="$(echo "$output" | jq -r '.notes | join(" ")')"
    contains "$notes" 'no string literal'
    contains "$notes" 'vitest.config.ts'
  done
  # …but a registering literal beside a non-literal entry settles it
  printf 'export default { test: { setupFiles: [setupPath, "./src/test/setup.ts"] } }\n' > "$W/vitest.config.ts"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "" ]
  echo "$output" | jq -e '.notes == []' >/dev/null
}

@test "a11y: a missing or invalid package.json yields a note and no a11y finding" {
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "" ]
  echo "$output" | jq -e '.tooling_configured.a11y == false' >/dev/null
  contains "$(echo "$output" | jq -r '.notes | join(" ")')" 'package.json'

  for body in '{ not json' '["an", "array"]'; do
    printf '%s\n' "$body" > "$W/package.json"
    run gather
    [ "$status" -eq 0 ]
    [ "$(ids a11y)" = "" ]
    contains "$(echo "$output" | jq -r '.notes | join(" ")')" 'package.json'
  done
}

# --- lighthouse_budget ------------------------------------------------------------

@test "lighthouse_budget: no root lighthouserc.json yields exactly missing_config (MAJOR)" {
  a11y_fixture
  # a config the audit deliberately does NOT read is still "missing"
  printf 'module.exports = {};\n' > "$W/lighthouserc.js"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "lighthouse_budget:missing_config" ]
  [ "$(severity_of lighthouse_budget:missing_config)" = "MAJOR" ]
  echo "$output" | jq -e '.tooling_configured.lighthouse_budget == false' >/dev/null
}

@test "lighthouse_budget: invalid JSON yields exactly invalid_config (MAJOR), and the gather exits 0" {
  a11y_fixture
  for body in '{ "ci": ' '' '{} {}'; do
    printf '%s' "$body" > "$W/lighthouserc.json"
    run gather
    [ "$status" -eq 0 ]
    [ "$(ids lighthouse_budget)" = "lighthouse_budget:invalid_config" ]
    [ "$(severity_of lighthouse_budget:invalid_config)" = "MAJOR" ]
    echo "$output" | jq -e '.tooling_configured.lighthouse_budget == false' >/dev/null
  done
}

@test "lighthouse_budget: #1946's lighthouserc.json yields [] with tooling_configured true" {
  lighthouse_fixture
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "" ]
  echo "$output" | jq -e '.tooling_configured.lighthouse_budget == true' >/dev/null
}

@test "lighthouse_budget: an absent byte budget is budget_missing (MAJOR), each key on its own" {
  lhrc_assert '{"assertions": {"resource-summary:total:size": ["error", {"maxNumericValue": 512000}]}}'
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "lighthouse_budget:budget_missing:resource-summary:script:size" ]
  [ "$(severity_of lighthouse_budget:budget_missing:resource-summary:script:size)" = "MAJOR" ]
  # a valid file with no assertions at all is missing both — not invalid_config
  printf '{}\n' > "$W/lighthouserc.json"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "lighthouse_budget:budget_missing:resource-summary:script:size,lighthouse_budget:budget_missing:resource-summary:total:size" ]
  echo "$output" | jq -e '.tooling_configured.lighthouse_budget == true' >/dev/null
}

@test "lighthouse_budget: a budget at warn, or without a numeric maxNumericValue, is budget_not_blocking (MINOR)" {
  lhrc_assert "$(jq -c '.["resource-summary:total:size"] = ["warn", {"maxNumericValue": 512000}]' <<<"$BUDGETS" \
    | jq -c '{assertions: .}')"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "lighthouse_budget:budget_not_blocking:resource-summary:total:size" ]
  [ "$(severity_of lighthouse_budget:budget_not_blocking:resource-summary:total:size)" = "MINOR" ]

  for entry in '"warn"' '"error"' '["error", {}]' '["error", {"maxNumericValue": "512000"}]'; do
    lhrc_assert "$(jq -c --argjson e "$entry" '.["resource-summary:total:size"] = $e | {assertions: .}' <<<"$BUDGETS")"
    run gather
    [ "$status" -eq 0 ]
    [ "$(ids lighthouse_budget)" = "lighthouse_budget:budget_not_blocking:resource-summary:total:size" ]
  done
}

@test "lighthouse_budget: a budget over the limit is budget_too_loose (MINOR); exactly the limit passes" {
  lhrc_assert "$(jq -c '.["resource-summary:script:size"][1].maxNumericValue = 307201 | {assertions: .}' <<<"$BUDGETS")"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "lighthouse_budget:budget_too_loose:resource-summary:script:size" ]
  [ "$(severity_of lighthouse_budget:budget_too_loose:resource-summary:script:size)" = "MINOR" ]

  lhrc_assert "$(jq -c '.["resource-summary:total:size"][1].maxNumericValue = 512001 | {assertions: .}' <<<"$BUDGETS")"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "lighthouse_budget:budget_too_loose:resource-summary:total:size" ]

  # exactly 307200 / 512000, and tighter, yield no finding
  lhrc_assert "$(jq -c '{assertions: .}' <<<"$BUDGETS")"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "" ]
  lhrc_assert "$(jq -c '.["resource-summary:script:size"][1].maxNumericValue = 100000 | {assertions: .}' <<<"$BUDGETS")"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "" ]
}

@test "lighthouse_budget: a timing assertion at error is timing_assertion_blocking (MINOR), one per assertion" {
  for key in largest-contentful-paint total-blocking-time cumulative-layout-shift categories:performance; do
    lhrc_assert "$(jq -c --arg k "$key" '.[$k] = ["error", {"maxNumericValue": 2500}] | {assertions: .}' <<<"$BUDGETS")"
    run gather
    [ "$status" -eq 0 ]
    [ "$(ids lighthouse_budget)" = "lighthouse_budget:timing_assertion_blocking:$key" ]
    [ "$(severity_of "lighthouse_budget:timing_assertion_blocking:$key")" = "MINOR" ]
  done
  # the bare-string form of the level is read too
  lhrc_assert "$(jq -c '.["categories:performance"] = "error" | {assertions: .}' <<<"$BUDGETS")"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "lighthouse_budget:timing_assertion_blocking:categories:performance" ]
}

@test "lighthouse_budget: the same timing assertions at warn or off yield no finding" {
  lhrc_assert "$(jq -c '.["largest-contentful-paint"] = ["warn", {"maxNumericValue": 2500}]
      | .["categories:performance"] = "warn" | .["total-blocking-time"] = "off"
      | .["cumulative-layout-shift"] = ["off"] | {assertions: .}' <<<"$BUDGETS")"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "" ]
}

@test "lighthouse_budget: a non-empty preset is preset_present (MINOR); an empty one is not" {
  lhrc_assert "$(jq -c '{preset: "lighthouse:recommended", assertions: .}' <<<"$BUDGETS")"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "lighthouse_budget:preset_present" ]
  [ "$(severity_of lighthouse_budget:preset_present)" = "MINOR" ]
  contains "$(echo "$output" | jq -r '.findings_by_tool.lighthouse_budget[0].message')" 'lighthouse:recommended'

  lhrc_assert "$(jq -c '{preset: "", assertions: .}' <<<"$BUDGETS")"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids lighthouse_budget)" = "" ]
}

@test "lighthouse_budget: a valid but oddly-shaped document is audited, never a crash" {
  for doc in '[]' '"x"' '{"ci": {"assert": {"assertions": ["not", "an", "object"]}}}'; do
    printf '%s\n' "$doc" > "$W/lighthouserc.json"
    run gather
    [ "$status" -eq 0 ]
    [ "$(ids lighthouse_budget)" = "lighthouse_budget:budget_missing:resource-summary:script:size,lighthouse_budget:budget_missing:resource-summary:total:size" ]
  done
}

# --- the gather's own contract ------------------------------------------------------

@test "a non-React repo is audited the same way — the marker gates dispatch, not the gather" {
  # the gather makes no detection claim: a repo with no package.json at all gets the
  # package.json note and the missing Lighthouse config, not a special empty payload
  printf '# readme\n' > "$W/README.md"
  run gather
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "" ]
  [ "$(ids lighthouse_budget)" = "lighthouse_budget:missing_config" ]
  contains "$(echo "$output" | jq -r '.notes | join(" ")')" 'package.json'
}

@test "notes is an ARRAY OF non-empty STRINGS (a bare string would satisfy length and join)" {
  a11y_fixture
  printf 'export default { test: { setupFiles: files } }\n' > "$W/vitest.config.ts"
  rm -f "$W/package.json"
  printf '{ bad\n' > "$W/package.json"
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.notes | type == "array" and length > 0' >/dev/null
  # pins the builder's map(select(length > 0)): without it printf's trailing
  # newline yields a trailing "" element
  echo "$output" | jq -e 'all(.notes[]; type == "string" and length > 0)' >/dev/null
}

@test "defaults to the current directory when no repo path is given" {
  # the payload is repo-dependent, so the default must read THIS directory: a
  # compliant repo in the cwd yields no finding, where the orchestrator's own
  # cwd would not
  compliant_fixture
  cd "$W"
  run zsh "$GATHER"
  [ "$status" -eq 0 ]
  [ "$(ids a11y)" = "" ]
  [ "$(ids lighthouse_budget)" = "" ]
  echo "$output" | jq -e '.tooling_configured == {a11y: true, lighthouse_budget: true}' >/dev/null
}

@test "a non-directory path is a usage error (exit 2) with NO payload on stdout" {
  run --separate-stderr zsh "$GATHER" "$W/does-not-exist"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'not a directory'
}

@test "a FILE passed as the repo path is also a usage error (exit 2) with NO payload on stdout" {
  printf 'x\n' > "$W/afile"
  run --separate-stderr zsh "$GATHER" "$W/afile"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'not a directory'
}

@test "a missing jq is the documented RUNTIME error (exit 3), not a silent empty payload" {
  # the script's own guard: without this test, deleting `command -v jq` would
  # redden nothing, and the failure would surface as a bare set -e abort
  react_fixture
  stub="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$stub"
  zsh_bin="$(command -v zsh)"
  run --separate-stderr env PATH="$stub" "$zsh_bin" "$GATHER" "$W"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'jq not found'
}

@test "extra arguments are a usage error (exit 2)" {
  react_fixture
  run --separate-stderr zsh "$GATHER" "$W" extra
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'too many arguments'
}

@test "an explicitly EMPTY argument is a usage error, not a silent fallback to the cwd" {
  # guards the deliberate ${1-.} vs ${1:-.} choice: a regression to ${1:-.} would
  # make '' succeed against the orchestrator's cwd with nothing reddening
  run --separate-stderr zsh "$GATHER" ""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'empty repo path'
}

# A jq stub that fails (exit 2) only on calls whose arguments match a glob, and
# execs the real jq otherwise. jq's own 2 would be indistinguishable from this
# script's documented 'not a directory' usage error, hence the mapping onto 3.
selective_jq() {
  local real_jq; real_jq="$(command -v jq)"
  stub="$BATS_TEST_TMPDIR/selectivejq"
  mkdir -p "$stub"
  cat > "$stub/jq" <<EOF
#!/bin/sh
case "\$*" in
  $1) exit 2 ;;
  *) exec "$real_jq" "\$@" ;;
esac
EOF
  chmod +x "$stub/jq"
}
run_with_stub() {
  local zsh_bin; zsh_bin="$(command -v zsh)"
  run --separate-stderr env PATH="$stub:$PATH" "$zsh_bin" "$GATHER" "$W"
}

@test "a FAILING jq is mapped onto exit 3 at the self-check, not read as the target's invalid files" {
  # without the self-check, an all-failing jq would make package.json read as
  # invalid and lighthouserc.json as invalid_config — a confident, wrong payload
  compliant_fixture
  stub="$BATS_TEST_TMPDIR/badjq"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 2\n' > "$stub/jq"
  chmod +x "$stub/jq"
  run_with_stub
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'jq failed its self-check'
}

@test "a jq that fails only on the NOTES builder is mapped onto exit 3" {
  react_fixture
  selective_jq '*-R*'
  run_with_stub
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'jq failed building notes'
}

@test "a jq that fails only on the PAYLOAD call is also mapped onto exit 3" {
  react_fixture
  selective_jq '*--argjson*'
  run_with_stub
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'jq failed emitting the payload'
}

@test "a jq that fails only on the lighthouserc.json AUDIT is mapped onto exit 3" {
  compliant_fixture
  selective_jq '*"def obj"*'
  run_with_stub
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'jq failed auditing lighthouserc.json'
}

@test "a jq that fails only on a FINDING builder is mapped onto exit 3, for each tool" {
  react_fixture
  selective_jq '*no_axe_package*'
  run_with_stub
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'jq failed building an a11y finding'

  selective_jq '*missing_config*'
  run_with_stub
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'jq failed building a lighthouse_budget finding'
}

@test "an unenterable repo directory is exit 3 (the documented 'could not be entered' cause)" {
  if [ "$(id -u)" -eq 0 ]; then skip "root bypasses directory permissions"; fi
  locked="$BATS_TEST_TMPDIR/locked"
  mkdir -p "$locked"
  chmod 000 "$locked"
  run --separate-stderr zsh "$GATHER" "$locked"
  chmod 755 "$locked"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" 'cannot enter'
}

@test "the payload goes to STDOUT, with nothing on stderr on the happy path" {
  compliant_fixture
  run --separate-stderr gather
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "runs via its own shebang (the orchestrator's test -x partition implies direct execution)" {
  react_fixture
  run "$GATHER" "$W"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.' >/dev/null
}

@test "a repo path containing a space is handled (quoting regression guard on cd)" {
  spaced="$BATS_TEST_TMPDIR/my repo"
  mkdir -p "$spaced"
  jq -n '{name: "app", dependencies: {react: "19.0.0"}}' > "$spaced/package.json"
  run zsh "$GATHER" "$spaced"
  [ "$status" -eq 0 ]
  # the repo was really read: its package.json (no axe package) is judged
  [ "$(echo "$output" | jq -r '[.findings_by_tool.a11y[].id] | join(",")')" = "a11y:no_axe_package" ]
}
