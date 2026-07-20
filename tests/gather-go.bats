#!/usr/bin/env bats
#
# Behavioral tests for gather-go-findings.sh — the Go findings gather script
# (#871, the core-loop slice of the #868 development-go epic).
#
# The gather shells out to `golangci-lint fmt --diff` and then parses TEXT, so
# the findings-emission path (header-anchored path extraction, on-disk
# filtering, the finding schema, the tool-failure notes) is fully testable
# without a Go toolchain — via the repo's PATH-shadowing stub convention (see
# tests/track-debt-issues.bats). Only the real binary's diff *content* is out of
# scope; that is covered by manual validation on the dedicated Go test-bed.
#
# Every test therefore chooses its branch DELIBERATELY: `no_binary` shadows
# golangci-lint with a PATH holding no such command, `stub` installs a fake one.
# Nothing depends on whether the host happens to have golangci-lint installed —
# without that control these tests would take a different branch on CI than on
# a maintainer's Homebrew macOS box, and the assertions would hide it.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-go-findings.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  STUB="$BATS_TEST_TMPDIR/bin"
  # ISO holds ONLY the utilities the gather needs — symlinked from wherever
  # they really live — so `command -v golangci-lint` provably fails under it
  # even on a Homebrew box. Prepending an empty dir to the real PATH would NOT
  # achieve that: the real binary would still be found further along.
  ISO="$BATS_TEST_TMPDIR/iso-bin"
  mkdir -p "$WORK" "$STUB" "$ISO"
  # bash/env/cat are needed to *launch* the gather (and the stub) under the
  # isolated PATH, not just by the gather's own body.
  for util in bash env cat rm mktemp grep sed sort tail jq; do
    ln -sf "$(command -v "$util")" "$ISO/$util"
  done
  printf 'module github.com/timo-jakob/testbed\n\ngo 1.24\n' > "$WORK/go.mod"
}

# Run the gather with golangci-lint provably ABSENT (coreutils + jq present).
no_binary() { run env PATH="$ISO" bash "$GATHER" "$@"; }

# Install a fake golangci-lint emitting $1 on stdout and exiting $2.
# The payload is written to a side file rather than interpolated into a
# heredoc: real Go hunks contain backticks (raw strings, `json:"id"` struct
# tags) and $vars, which an unquoted heredoc would execute at stub-write time.
stub_golangci() {
  printf '%s\n' "$1" > "$STUB/diff.txt"
  printf '#!/usr/bin/env bash\ncat %q\nexit %d\n' "$STUB/diff.txt" "$2" \
    > "$STUB/golangci-lint"
  chmod +x "$STUB/golangci-lint"
}
# Run with ONLY the stubbed golangci-lint visible (never the host's).
with_stub() { run env PATH="$STUB:$ISO" bash "$GATHER" "$@"; }

@test "gather-go: no golangci config -> format_lint not configured, valid JSON" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "false" ]
  # Unconfigured tool is absent from findings_by_tool.
  [ "$(jq -r '.findings_by_tool.format_lint // "absent"' <<<"$output")" = "absent" ]
}

@test "gather-go: output always carries the contract keys" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("tooling_configured")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("findings_by_tool")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("coverage")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("notes")' <<<"$output")" = "true" ]
}

@test "gather-go: missing repo path -> usage error on stderr, exit 2, no JSON on stdout" {
  run bash "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: gather-go-findings.sh"* ]]
  # The usage message must go to stderr — stdout is the JSON channel a caller
  # pipes into jq, so polluting it would break the pipeline rather than the guard.
  run bash -c 'bash "$1" "$2" 2>/dev/null' _ "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ -z "$output" ]
}

@test "gather-go: no repo path argument at all -> usage error, exit 2" {
  run bash "$GATHER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: gather-go-findings.sh"* ]]
}

@test "gather-go: repo path that exists but is a FILE -> usage error, exit 2" {
  # The guard is `-z || ! -d`; relaxing it to `! -e` would cd into a file and
  # exit with an unexpected status the orchestrator does not handle.
  printf 'x' > "$BATS_TEST_TMPDIR/afile"
  run bash "$GATHER" "$BATS_TEST_TMPDIR/afile"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: gather-go-findings.sh"* ]]
}

@test "gather-go: repo path containing a space is handled (quoting of cd)" {
  spaced="$BATS_TEST_TMPDIR/with space"
  mkdir -p "$spaced"
  printf 'module x\n' > "$spaced/go.mod"
  no_binary "$spaced"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
}

@test "gather-go: .golangci.yml present -> format_lint configured, findings an array" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "true" ]
  # Configured -> the format_lint key is present in findings_by_tool (array,
  # possibly empty when there's nothing to format / no binary).
  [ "$(jq -r '.findings_by_tool.format_lint | type' <<<"$output")" = "array" ]
}

@test "gather-go: .golangci.yaml (the other YAML spelling) also counts as configured" {
  printf 'version: "2"\n' > "$WORK/.golangci.yaml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "true" ]
}

@test "gather-go: .golangci.toml also counts as configured" {
  printf 'version = "2"\n' > "$WORK/.golangci.toml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "true" ]
}

@test "gather-go: .golangci.json also counts as configured" {
  printf '{ "version": "2" }\n' > "$WORK/.golangci.json"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "true" ]
}

@test "gather-go: tool universe is format_lint ONLY this slice (#871)" {
  # Slice B declares exactly the tools development-go can actually process.
  # Later slices add sonarcloud/code_scanning/semgrep (#873), coverage (#874),
  # and the vendor-PR sources (#876) — emitting them as `false` now would imply
  # this plugin handles them once configured.
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured | keys | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.tooling_configured | has("format_lint")' <<<"$output")" = "true" ]
  for tool in sonarcloud code_scanning semgrep dependabot snyk_prs renovate; do
    [ "$(jq -r ".tooling_configured | has(\"$tool\")" <<<"$output")" = "false" ]
  done
}

@test "gather-go: a dependabot.yml does NOT make the vendor sources appear (#876 not this slice)" {
  # Guards the boundary above against a copy-paste of the Swift gather's
  # vendor-PR block landing early: config presence must not conjure a tool key.
  mkdir -p "$WORK/.github"
  printf 'version: 2\nupdates: []\n' > "$WORK/.github/dependabot.yml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured | has("dependabot")' <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("dependabot")' <<<"$output")" = "false" ]
}

@test "gather-go: coverage is withheld honestly (null, reliable=false) until Slice E (#874)" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage.overall // "null"' <<<"$output")" = "null" ]
  [ "$(jq -r .coverage.measurement.reliable <<<"$output")" = "false" ]
  echo "$output" | jq -e '.coverage.measurement.reason | test("Slice E")' >/dev/null
}

@test "gather-go: coverage carries a regions array (empty while withheld)" {
  # The region-scoped gate consumes coverage.regions; the gather always emits
  # the key (empty [] while coverage is unmeasured).
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage | has("regions")' <<<"$output")" = "true" ]
  [ "$(jq -r '.coverage.regions | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.coverage.regions | length' <<<"$output")" = "0" ]
}

@test "gather-go: coverage provenance note is always emitted (#258)" {
  # A figure's trust level is never silent — even a withheld one.
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.notes[] | select(test("coverage measurement:"))] | length == 1' >/dev/null
}

@test "gather-go: gather script is executable (orchestrator discovery gate)" {
  # Phase 2 of the orchestrator gates language support on `test -x` of this
  # exact path — a non-executable file silently makes Go unsupported.
  [ -x "$GATHER" ]
}

# --- format_lint emission path (stubbed golangci-lint) -----------------------
# The gather parses TEXT, so all of this is testable without a Go toolchain.

@test "gather-go: unformatted files in the diff -> one finding each, correct schema" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  mkdir -p "$WORK/cmd/server" "$WORK/internal/tenant"
  printf 'package main\n' > "$WORK/cmd/server/main.go"
  printf 'package tenant\n' > "$WORK/internal/tenant/store.go"
  stub_golangci "$(printf '%s\n' \
    '--- a/cmd/server/main.go' \
    '+++ b/cmd/server/main.go' \
    '@@ -1 +1 @@' \
    '-package  main' \
    '+package main' \
    '--- a/internal/tenant/store.go' \
    '+++ b/internal/tenant/store.go')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "2" ]
  # Schema of every emitted finding.
  echo "$output" | jq -e '.findings_by_tool.format_lint | all(
      .type == "format" and .severity == "MINOR"
      and .rule == "golangci-lint:fmt" and .line == 0
      and .key == ("format_lint:" + .component))' >/dev/null
  # a/ and b/ prefixes are stripped, and each file appears exactly once.
  echo "$output" | jq -e '[.findings_by_tool.format_lint[].component] | sort
      == ["cmd/server/main.go","internal/tenant/store.go"]' >/dev/null
}

@test "gather-go: .go tokens inside hunk bodies do NOT become findings" {
  # The regression the header-anchored extraction exists to prevent: a
  # //go:generate directive, a generated-code banner and a string literal all
  # name .go paths inside the diff body.
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  mkdir -p "$WORK/cmd"
  printf 'package main\n' > "$WORK/cmd/real.go"
  printf 'package main\n' > "$WORK/cmd/phantom.go"
  printf 'package main\n' > "$WORK/gen.go"
  stub_golangci "$(printf '%s\n' \
    '--- a/cmd/real.go' \
    '+++ b/cmd/real.go' \
    '@@ -1,3 +1,3 @@' \
    '-// Code generated by gen.go; DO NOT EDIT.' \
    '+//go:generate go run gen.go' \
    ' var p = "cmd/phantom.go"')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | sort | join(",")' <<<"$output")" = "cmd/real.go" ]
}

@test "gather-go: a header naming a nonexistent file is dropped, with an honest note" {
  # Dropping is right, but the note must say WHY — calling this a "v1 binary"
  # (the other exit-1 fault) would send a maintainer down the wrong path.
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  stub_golangci "$(printf '%s\n' '--- a/does/not/exist.go' '+++ b/does/not/exist.go')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("none named a .go file present"))] | length == 1' >/dev/null
  echo "$output" | jq -e '[.notes[] | select(test("v1 binary"))] | length == 0' >/dev/null
}

@test "gather-go: a header path containing a space is NOT truncated to a wrong file" {
  # A character-class extractor would yield "pkg/main.go" here; if that file
  # existed it would be reported as unformatted while the real file is missed.
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  mkdir -p "$WORK/internal/my pkg" "$WORK/pkg"
  printf 'package a\n' > "$WORK/internal/my pkg/main.go"
  printf 'package b\n' > "$WORK/pkg/main.go"
  stub_golangci "$(printf '%s\n' '--- a/internal/my pkg/main.go' '+++ b/internal/my pkg/main.go')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "internal/my pkg/main.go" ]
}

@test "gather-go: an absolute header path is reported repo-relative" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  printf 'package main\n' > "$WORK/main.go"
  stub_golangci "$(printf -- '--- %s/main.go\n' "$WORK")" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "main.go" ]
}

@test "gather-go: a partial diff from a CRASHED run yields no findings (exit >1 wins)" {
  # rc>1 means the log is not a trustworthy diff; emitting findings from it
  # would mix a failed run's partial output into the plan.
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  printf 'package main\n' > "$WORK/main.go"
  stub_golangci "$(printf '%s\n' '--- a/main.go' '+++ b/main.go' 'panic: internal error')" 3
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("failed \\(exit 3\\)"))] | length == 1' >/dev/null
}

@test "gather-go: backticks and \$vars in hunk bodies survive the stub verbatim" {
  # Guards the stub helper itself: a heredoc-interpolated payload would
  # execute these at write time and silently change the fixture.
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  printf 'package main\n' > "$WORK/tag.go"
  stub_golangci "$(printf '%s\n' '--- a/tag.go' '+++ b/tag.go' '+  ID int `json:"id"`' '+  s := $HOME')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "tag.go" ]
}

@test "gather-go: gofmt-style .orig headers resolve to the real file" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  printf 'package main\n' > "$WORK/main.go"
  stub_golangci "$(printf '%s\n' '--- main.go.orig' '+++ main.go')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "main.go" ]
}

@test "gather-go: already-formatted repo (exit 0, empty diff) -> no findings, no failure note" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  stub_golangci "" 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("format_lint"))] | length == 0' >/dev/null
}

@test "gather-go: tool failure (exit >1) is NOT reported as a clean repo" {
  # The silent-false-clean regression: a broken config must surface as a note,
  # not as "nothing to format".
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  printf 'package main\n' > "$WORK/main.go"
  stub_golangci "level=error msg=\"can't load config: main.go\"" 3
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("failed \\(exit 3\\)"))] | length == 1' >/dev/null
}

@test "gather-go: a v1 binary (exit 1, no diff header) surfaces a note, not a clean verdict" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  stub_golangci 'Error: unknown command "fmt" for "golangci-lint"' 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("v1 binary"))] | length == 1' >/dev/null
}

@test "gather-go: configured but binary absent -> configured, empty findings, explanatory note" {
  # The documented graceful-degradation contract.
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "true" ]
  # Key PRESENT and an empty array — not absent, which would mean "unconfigured".
  [ "$(jq -r '.findings_by_tool | has("format_lint")' <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.format_lint | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("not on PATH"))] | length == 1' >/dev/null
}

@test "gather-go: with the binary present, the not-on-PATH note is absent" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  stub_golangci "" 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.notes[] | select(test("not on PATH"))] | length == 0' >/dev/null
}

@test "gather-go: two config files present -> still exactly one format_lint key" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  printf 'version = "2"\n' > "$WORK/.golangci.toml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured | keys | length' <<<"$output")" = "1" ]
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "true" ]
}

@test "gather-go: withheld coverage pins source and by_module too" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.coverage.overall == null' >/dev/null
  [ "$(jq -r .coverage.measurement.source <<<"$output")" = "none" ]
  [ "$(jq -c .coverage.by_module <<<"$output")" = "{}" ]
}

@test "gather-go: a real top-level b/ directory is not double-stripped" {
  # `--- a/b/tool.go` must resolve to b/tool.go. A sequential a/-then-b/ strip
  # would yield `tool.go` — dropping the real violator, or naming the decoy.
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  mkdir -p "$WORK/b"
  printf 'package b\n' > "$WORK/b/tool.go"
  printf 'package main\n' > "$WORK/tool.go"
  stub_golangci "$(printf '%s\n' '--- a/b/tool.go' '+++ b/b/tool.go')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "b/tool.go" ]
}

@test "gather-go: a 'diff' command line with a spaced path adds no wrong finding" {
  # The diff arm is deliberately unparsed: its last-token split would yield
  # the truncated tail `pkg/x.go`, which exists here as a decoy.
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  mkdir -p "$WORK/my pkg" "$WORK/pkg"
  printf 'package a\n' > "$WORK/my pkg/x.go"
  printf 'package b\n' > "$WORK/pkg/x.go"
  stub_golangci "$(printf '%s\n' 'diff -u a/my pkg/x.go b/my pkg/x.go' '--- a/my pkg/x.go' '+++ b/my pkg/x.go')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "my pkg/x.go" ]
}

@test "gather-go: gofmt-style .orig header under a real top-level a/ dir picks the real file" {
  # `a/` is a genuine directory here, not a VCS prefix. Treating it as one
  # would strip to `tool.go` and report the root decoy instead.
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  mkdir -p "$WORK/a"
  printf 'package a\n' > "$WORK/a/tool.go"
  printf 'package main\n' > "$WORK/tool.go"
  stub_golangci "$(printf '%s\n' '--- a/tool.go.orig' '+++ a/tool.go')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "a/tool.go" ]
}

@test "gather-go: gofmt-style +++ header under a real top-level b/ dir picks the real file" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  mkdir -p "$WORK/b"
  printf 'package b\n' > "$WORK/b/tool.go"
  printf 'package main\n' > "$WORK/tool.go"
  stub_golangci "$(printf '%s\n' '--- b/tool.go.orig' '+++ b/tool.go')" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.format_lint[].component] | join(",")' <<<"$output")" = "b/tool.go" ]
}
