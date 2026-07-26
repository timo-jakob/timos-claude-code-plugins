#!/usr/bin/env bats
#
# Behavioral tests for gather-javascript-findings.sh (#729, the foundation slice
# of the #683 development-javascript epic).
#
# The gather shells out to `npx --no-install prettier --list-different .` and
# then parses a plain newline list of paths, so the whole findings-emission path
# (path extraction, on-disk filtering, the finding schema, the tool-failure
# notes, the npx-absent graceful degradation) is fully testable WITHOUT a Node
# toolchain — via the repo's PATH-shadowing stub convention (mirrors
# tests/gather-go.bats). Only the real Prettier's opinion about what is
# unformatted is out of scope; that is covered by manual validation on a JS
# test-bed.
#
# Every test therefore chooses its branch DELIBERATELY: `no_binary` shadows npx
# with a PATH holding no such command, `stub_prettier` installs a fake one.
# Nothing depends on whether the host happens to have Node installed — without
# that control these tests would take a different branch on CI than on a
# maintainer's Homebrew macOS box, and the assertions would hide it.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-javascript-findings.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  STUB="$BATS_TEST_TMPDIR/bin"
  # ISO holds ONLY the utilities the gather needs — symlinked from wherever
  # they really live — so `command -v npx` provably fails under it even on a
  # Homebrew box. Prepending an empty dir to the real PATH would NOT achieve
  # that: the real npx would still be found further along.
  ISO="$BATS_TEST_TMPDIR/iso-bin"
  mkdir -p "$WORK" "$STUB" "$ISO"
  for util in bash env cat rm mktemp grep sed sort tail jq; do
    ln -sf "$(command -v "$util")" "$ISO/$util"
  done
  printf '{ "name": "testbed", "version": "0.1.0" }\n' > "$WORK/package.json"
}

# Run the gather with npx provably ABSENT (coreutils + jq present).
no_binary() { run env PATH="$ISO" bash "$GATHER" "$@"; }

# Install a fake npx that prints the file list $1 to stdout and exits $2,
# whatever prettier args it is handed. The payload is written to a side file
# rather than interpolated into a heredoc so any $vars/backticks in a path
# survive verbatim.
stub_prettier() {
  printf '%s\n' "$1" > "$STUB/list.txt"
  printf '#!/usr/bin/env bash\ncat %q\nexit %d\n' "$STUB/list.txt" "$2" \
    > "$STUB/npx"
  chmod +x "$STUB/npx"
}
# Run with ONLY the stubbed npx visible (never the host's).
with_stub() { run env PATH="$STUB:$ISO" bash "$GATHER" "$@"; }

# --- guards / usage ----------------------------------------------------------

@test "gather-javascript: missing repo path -> usage error on stderr, exit 2, no JSON on stdout" {
  run bash "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  contains "$output" "usage: gather-javascript-findings.sh"
  # The usage message must go to stderr — stdout is the JSON channel a caller
  # pipes into jq, so polluting it would break the pipeline rather than the guard.
  run bash -c 'bash "$1" "$2" 2>/dev/null' _ "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ -z "$output" ]
}

@test "gather-javascript: no repo path argument at all -> usage error, exit 2" {
  run bash "$GATHER"
  [ "$status" -eq 2 ]
  contains "$output" "usage: gather-javascript-findings.sh"
}

@test "gather-javascript: repo path that exists but is a FILE -> usage error, exit 2" {
  # The guard is `-z || ! -d`; relaxing it to `! -e` would cd into a file.
  printf 'x' > "$BATS_TEST_TMPDIR/afile"
  run bash "$GATHER" "$BATS_TEST_TMPDIR/afile"
  [ "$status" -eq 2 ]
  contains "$output" "usage: gather-javascript-findings.sh"
}

@test "gather-javascript: repo path containing a space is handled (quoting of cd)" {
  spaced="$BATS_TEST_TMPDIR/with space"
  mkdir -p "$spaced"
  printf '{ "name": "x" }\n' > "$spaced/package.json"
  no_binary "$spaced"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
}

@test "gather-javascript: gather script is executable (orchestrator discovery gate)" {
  # The orchestrator gates language support on `test -x` of this exact path —
  # a lost executable bit silently makes JavaScript unsupported.
  [ -x "$GATHER" ]
}

# --- contract shape ----------------------------------------------------------

@test "gather-javascript: output always carries the v2 contract keys, valid JSON" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(jq -r 'has("tooling_configured")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("findings_by_tool")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("coverage")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("notes")' <<<"$output")" = "true" ]
}

@test "gather-javascript: tool universe is format_lint ONLY this slice (#729)" {
  # Later slices add sonarcloud/code_scanning (slice 4) and the vendor sources;
  # emitting them as `false` now would imply this plugin handles them.
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured | keys | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.tooling_configured | has("format_lint")' <<<"$output")" = "true" ]
  for tool in sonarcloud code_scanning semgrep dependabot snyk_prs renovate; do
    [ "$(jq -r ".tooling_configured | has(\"$tool\")" <<<"$output")" = "false" ]
  done
}

@test "gather-javascript: a dependabot.yml does NOT conjure the vendor sources" {
  mkdir -p "$WORK/.github"
  printf 'version: 2\nupdates: []\n' > "$WORK/.github/dependabot.yml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured | has("dependabot")' <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("dependabot")' <<<"$output")" = "false" ]
}

# --- tooling_configured: type-strict so an --argjson->--arg regression bites --

@test "gather-javascript: no format config -> format_lint configured is a JSON boolean false, absent from findings" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  # jq -e '== false' fails on the string "false" — catching a boolean->string regression.
  echo "$output" | jq -e '.tooling_configured.format_lint == false' >/dev/null
  [ "$(jq -r '.findings_by_tool.format_lint // "absent"' <<<"$output")" = "absent" ]
}

@test "gather-javascript: flat eslint.config.js -> format_lint configured is a JSON boolean true" {
  printf 'export default [];\n' > "$WORK/eslint.config.js"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tooling_configured.format_lint == true' >/dev/null
}

@test "gather-javascript: each flat eslint.config.{mjs,cjs,ts} spelling counts as configured" {
  for ext in mjs cjs ts; do
    rm -f "$WORK"/eslint.config.*
    printf 'export default [];\n' > "$WORK/eslint.config.$ext"
    no_binary "$WORK"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.tooling_configured.format_lint == true' >/dev/null
  done
}

@test "gather-javascript: legacy .eslintrc.{json,js,cjs,yml,yaml} also counts as configured" {
  for f in .eslintrc.json .eslintrc.js .eslintrc.cjs .eslintrc.yml .eslintrc.yaml; do
    rm -f "$WORK"/.eslintrc.*
    printf 'root: true\n' > "$WORK/$f"
    no_binary "$WORK"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.tooling_configured.format_lint == true' >/dev/null
  done
}

@test "gather-javascript: a Prettier-only repo (no ESLint config) is configured — the run tool is prettier" {
  # The findings run is `prettier`, so a real Prettier deployment must not be
  # invisible just because ESLint isn't set up.
  for f in .prettierrc .prettierrc.json .prettierrc.yaml prettier.config.js; do
    rm -f "$WORK"/.prettierrc* "$WORK"/prettier.config.*
    printf '{}\n' > "$WORK/$f"
    no_binary "$WORK"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.tooling_configured.format_lint == true' >/dev/null
  done
}

@test "gather-javascript: package.json prettier/eslintConfig key counts as configured" {
  printf '{ "name": "x", "prettier": { "printWidth": 120 } }\n' > "$WORK/package.json"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tooling_configured.format_lint == true' >/dev/null
  printf '{ "name": "x", "eslintConfig": { "root": true } }\n' > "$WORK/package.json"
  no_binary "$WORK"
  echo "$output" | jq -e '.tooling_configured.format_lint == true' >/dev/null
}

# --- format_lint emission path (stubbed npx) ---------------------------------

@test "gather-javascript: unformatted files listed -> one finding each, correct schema" {
  printf 'export default [];\n' > "$WORK/eslint.config.js"
  mkdir -p "$WORK/src/api"
  printf 'export const a = 1;\n' > "$WORK/src/api/client.ts"
  printf 'export const b = 2;\n' > "$WORK/src/app.ts"
  stub_prettier "$(printf '%s\n' 'src/api/client.ts' 'src/app.ts')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "2" ]
  # Schema of every emitted finding.
  echo "$output" | jq -e '.findings_by_tool.format_lint | all(
      .type == "format" and .severity == "MINOR"
      and .rule == "prettier:format" and .line == 0
      and .key == ("format_lint:" + .component))' >/dev/null
  # Each file appears exactly once, in sorted order.
  echo "$output" | jq -e '[.findings_by_tool.format_lint[].component] | sort
      == ["src/api/client.ts","src/app.ts"]' >/dev/null
}

@test "gather-javascript: a listed path NOT present on disk is dropped" {
  # A stray non-path line in the output must not become a finding.
  printf 'export default [];\n' > "$WORK/eslint.config.js"
  printf 'export const a = 1;\n' > "$WORK/real.ts"
  stub_prettier "$(printf '%s\n' 'real.ts' 'phantom.ts')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "real.ts" ]
}

@test "gather-javascript: an absolute listed path is reported repo-relative" {
  printf 'export default [];\n' > "$WORK/eslint.config.js"
  printf 'export const a = 1;\n' > "$WORK/main.ts"
  stub_prettier "$(printf '%s/main.ts\n' "$WORK")" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "main.ts" ]
}

@test "gather-javascript: already-formatted repo (exit 0, empty list) -> no findings, no failure note" {
  printf 'export default [];\n' > "$WORK/eslint.config.js"
  stub_prettier "" 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("format_lint"))] | length == 0' >/dev/null
}

@test "gather-javascript: prettier exit 2 (tool error) is NOT reported as a clean repo" {
  # The silent-false-clean regression: a broken config / parse error returns 2,
  # which must surface as a note, not as "nothing to format".
  printf 'export default [];\n' > "$WORK/eslint.config.js"
  printf 'export const a = 1;\n' > "$WORK/main.ts"
  stub_prettier "[error] Cannot resolve config" 2
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  # Findings key present (configured) but empty — the crash yields nothing.
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("exit 2"))] | length == 1' >/dev/null
}

@test "gather-javascript: exit 1 with NO resolvable file (prettier not installed) surfaces a note, not clean" {
  # npx failing because prettier isn't in node_modules exits 1 with an error and
  # no file list — must NOT be read as a clean repo.
  printf 'export default [];\n' > "$WORK/eslint.config.js"
  stub_prettier 'npm error could not determine executable to run' 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("exited 1"))] | length == 1' >/dev/null
}

@test "gather-javascript: configured but npx absent -> configured, empty findings, explanatory note" {
  # The documented graceful-degradation contract (no Node on PATH).
  printf 'export default [];\n' > "$WORK/eslint.config.js"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tooling_configured.format_lint == true' >/dev/null
  # Key PRESENT and an empty array — not absent, which would mean "unconfigured".
  [ "$(jq -r '.findings_by_tool | has("format_lint")' <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("not on PATH"))] | length == 1' >/dev/null
}

@test "gather-javascript: with npx present, the not-on-PATH note is absent" {
  printf 'export default [];\n' > "$WORK/eslint.config.js"
  stub_prettier "" 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.notes[] | select(test("not on PATH"))] | length == 0' >/dev/null
}

# --- coverage — withheld honestly (#258) -------------------------------------

@test "gather-javascript: coverage is withheld honestly (null, reliable=false) this slice" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.coverage.overall == null' >/dev/null
  # reliable must be a JSON boolean false, not the string "false".
  echo "$output" | jq -e '.coverage.measurement.reliable == false' >/dev/null
  [ "$(jq -r .coverage.measurement.source <<<"$output")" = "none" ]
  [ "$(jq -c .coverage.by_module <<<"$output")" = "{}" ]
}

@test "gather-javascript: coverage carries an empty regions array (region-scoped gate consumes it)" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage | has("regions")' <<<"$output")" = "true" ]
  [ "$(jq -r '.coverage.regions | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.coverage.regions | length' <<<"$output")" = "0" ]
}

@test "gather-javascript: coverage provenance note is always emitted exactly once (#258)" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.notes[] | select(test("coverage measurement:"))] | length == 1' >/dev/null
}
