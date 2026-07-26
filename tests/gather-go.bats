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

load assertions

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
  for util in bash env cat rm dirname ls find mktemp grep sed sort tail cut head tr jq; do
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

# Install a fake `govulncheck` that emits $1 (a canned -json message stream) on
# stdout and exits $2 — lets a test drive the gather's govulncheck jq parse
# (streaming slurp, osv-join, called-over-imported preference, finding schema)
# with no Go toolchain or network. Payload to a side file (the stream contains
# braces/quotes an unquoted heredoc would mangle).
stub_govulncheck() {
  printf '%s\n' "$1" > "$STUB/gv-stream.json"
  printf '#!/usr/bin/env bash\ncat %q\nexit %d\n' "$STUB/gv-stream.json" "$2" \
    > "$STUB/govulncheck"
  chmod +x "$STUB/govulncheck"
}

# Install a fake `zsh` that IGNORES the helper script it's handed and prints $1,
# exiting $2. The sonar/code_scanning helpers carry a `#!/usr/bin/env zsh`
# shebang, so shadowing `zsh` on PATH lets a test exercise the gather's
# helper-invocation + parse path deterministically — without the real zsh
# helpers, `gh`, a keychain token, or the network. (`with_stub`'s PATH is
# `$STUB:$ISO`, so `env zsh` finds this stub.)
stub_zsh() {
  printf '%s\n' "$1" > "$STUB/zsh-out.json"
  printf '#!/usr/bin/env bash\ncat %q\nexit %d\n' "$STUB/zsh-out.json" "$2" > "$STUB/zsh"
  chmod +x "$STUB/zsh"
}

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
  [ "$(jq -r 'has("sonar_quality_gate")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("notes")' <<<"$output")" = "true" ]
}

@test "gather-go: missing repo path -> usage error on stderr, exit 2, no JSON on stdout" {
  run bash "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  contains "$output" "usage: gather-go-findings.sh"
  # The usage message must go to stderr — stdout is the JSON channel a caller
  # pipes into jq, so polluting it would break the pipeline rather than the guard.
  run bash -c 'bash "$1" "$2" 2>/dev/null' _ "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ -z "$output" ]
}

@test "gather-go: no repo path argument at all -> usage error, exit 2" {
  run bash "$GATHER"
  [ "$status" -eq 2 ]
  contains "$output" "usage: gather-go-findings.sh"
}

@test "gather-go: repo path that exists but is a FILE -> usage error, exit 2" {
  # The guard is `-z || ! -d`; relaxing it to `! -e` would cd into a file and
  # exit with an unexpected status the orchestrator does not handle.
  printf 'x' > "$BATS_TEST_TMPDIR/afile"
  run bash "$GATHER" "$BATS_TEST_TMPDIR/afile"
  [ "$status" -eq 2 ]
  contains "$output" "usage: gather-go-findings.sh"
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

@test "gather-go: tool universe is format_lint + triple + govulncheck + vendor-PR + proto advisors (#878)" {
  # Slice B: format_lint. Slice D: sonarcloud/code_scanning/semgrep. Slice G
  # (#876): govulncheck plus the vendor-PR sources dependabot/snyk_prs/renovate.
  # Slice I (#878): the proto-first config-audit advisors grpc + api_contract —
  # ten keys, all always present in the map.
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured | keys | length' <<<"$output")" = "10" ]
  for tool in format_lint sonarcloud code_scanning semgrep govulncheck dependabot snyk_prs renovate grpc api_contract; do
    [ "$(jq -r ".tooling_configured | has(\"$tool\")" <<<"$output")" = "true" ]
  done
}

@test "gather-go #876: govulncheck is configured whenever the repo is a Go module (go.mod present)" {
  # setup() writes a go.mod, so govulncheck is 'configured'; its binary is absent
  # under the isolated PATH, so findings degrade to [] with an honest note.
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.govulncheck <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.govulncheck | type' <<<"$output")" = "array" ]
  echo "$output" | jq -e '[.notes[] | select(test("govulncheck is the Go vulnerability source of truth but its binary is not on PATH"))] | length == 1' >/dev/null
}

@test "gather-go #876: govulncheck -json stream is parsed into the finding-shape contract" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"   # keep other tools quiet/off
  stub_golangci "" 0
  # Two distinct vulns: GO-2024-0001 is CALLED (top trace frame has a function),
  # GO-2024-0002 is only imported (no function). Streamed osv + finding messages.
  stream='{"osv":{"id":"GO-2024-0001","summary":"vuln in x/net"}}
{"osv":{"id":"GO-2024-0002","summary":"vuln in foo/bar"}}
{"finding":{"osv":"GO-2024-0001","fixed_version":"v0.23.0","trace":[{"module":"golang.org/x/net","version":"v0.17.0","package":"golang.org/x/net/http2","function":"readFrame"}]}}
{"finding":{"osv":"GO-2024-0002","fixed_version":"v1.9.1","trace":[{"module":"github.com/foo/bar","version":"v1.9.0"}]}}'
  stub_govulncheck "$stream" 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.govulncheck | length' <<<"$output")" = "2" ]
  # The called vuln: severity called, module/versions/fixed carried, key + cve.
  called="$(jq -c '.findings_by_tool.govulncheck[] | select(.rule=="GO-2024-0001")' <<<"$output")"
  [ "$(jq -r '.severity' <<<"$called")" = "called" ]
  [ "$(jq -r '.component' <<<"$called")" = "golang.org/x/net" ]
  [ "$(jq -r '.package' <<<"$called")" = "golang.org/x/net" ]
  [ "$(jq -r '.current_version' <<<"$called")" = "v0.17.0" ]
  [ "$(jq -r '.target_version' <<<"$called")" = "v0.23.0" ]
  [ "$(jq -r '.key' <<<"$called")" = "govulncheck:GO-2024-0001" ]
  [ "$(jq -r '.cve_reference' <<<"$called")" = "GO-2024-0001" ]
  [ "$(jq -r '.message' <<<"$called")" = "vuln in x/net" ]
  # The imported-only vuln: severity imported.
  [ "$(jq -r '.findings_by_tool.govulncheck[] | select(.rule=="GO-2024-0002") | .severity' <<<"$output")" = "imported" ]
}

@test "gather-go #876: a vuln seen both called and imported collapses to ONE 'called' record" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  stub_golangci "" 0
  # Same osv appears twice — once imported (no function), once called. group_by
  # + sort_by(.called)|reverse must keep exactly the called one.
  stream='{"osv":{"id":"GO-2024-0009","summary":"dup vuln"}}
{"finding":{"osv":"GO-2024-0009","fixed_version":"v2.0.1","trace":[{"module":"github.com/x/y","version":"v1.5.0"}]}}
{"finding":{"osv":"GO-2024-0009","fixed_version":"v2.0.1","trace":[{"module":"github.com/x/y","version":"v1.5.0","package":"github.com/x/y","function":"Do"}]}}'
  stub_govulncheck "$stream" 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.govulncheck | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.findings_by_tool.govulncheck[0].severity' <<<"$output")" = "called" ]
}

@test "gather-go #876: govulncheck exit!=0 (and !=3) is WITHHELD as [] with a diagnostic note, not reported clean" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  stub_golangci "" 0
  # A real failure (e.g. no network to the vuln DB) exits 1 under -json (found
  # vulns exit 0). The gather must WITHHOLD, never report a clean [].
  stub_govulncheck "" 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.govulncheck | length' <<<"$output")" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("govulncheck: exited 1"))] | length == 1' >/dev/null
}

@test "gather-go #876: no go.mod -> govulncheck not configured, findings key absent" {
  rm -f "$WORK/go.mod"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.govulncheck <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("govulncheck")' <<<"$output")" = "false" ]
}

@test "gather-go #876: a lone .snyk flips ONLY snyk_prs" {
  printf 'version: v1.25.0\nignore: {}\n' > "$WORK/.snyk"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured.snyk_prs' <<<"$output")" = "true" ]
  [ "$(jq -r '.tooling_configured.dependabot' <<<"$output")" = "false" ]
  [ "$(jq -r '.tooling_configured.renovate' <<<"$output")" = "false" ]
}

@test "gather-go #876: a lone renovate config flips ONLY renovate (any of the accepted spellings)" {
  # Exercise a non-default spelling to guard the whole filename matrix, not just
  # renovate.json.
  mkdir -p "$WORK/.github"
  printf '{ "extends": ["config:base"] }\n' > "$WORK/.github/renovate.json5"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured.renovate' <<<"$output")" = "true" ]
  [ "$(jq -r '.tooling_configured.dependabot' <<<"$output")" = "false" ]
  [ "$(jq -r '.tooling_configured.snyk_prs' <<<"$output")" = "false" ]
}

@test "gather-go #876: no vendor config -> dependabot/snyk_prs/renovate configured=false, findings keys absent" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  for tool in dependabot snyk_prs renovate; do
    [ "$(jq -r ".tooling_configured.$tool" <<<"$output")" = "false" ]
    [ "$(jq -r ".findings_by_tool | has(\"$tool\")" <<<"$output")" = "false" ]
  done
}

@test "gather-go #876: vendor config files flip dependabot/snyk_prs/renovate to configured" {
  # Config-file presence is what drives 'configured' (the gh PR listing needs a
  # network/auth we don't have here, so findings degrade to [] with a note).
  mkdir -p "$WORK/.github"
  printf 'version: 2\nupdates: []\n' > "$WORK/.github/dependabot.yml"
  printf 'version: v1.25.0\nignore: {}\n'   > "$WORK/.snyk"
  printf '{ "extends": ["config:base"] }\n' > "$WORK/renovate.json"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  for tool in dependabot snyk_prs renovate; do
    [ "$(jq -r ".tooling_configured.$tool" <<<"$output")" = "true" ]
    [ "$(jq -r ".findings_by_tool.$tool | type" <<<"$output")" = "array" ]
  done
  # gh is absent under the isolated PATH, so each vendor source records an
  # honest can't-list note rather than silently reporting an empty PR set.
  echo "$output" | jq -e '[.notes[] | select(test("dependabot is configured but .gh."))] | length == 1' >/dev/null
  echo "$output" | jq -e '[.notes[] | select(test(".snyk file present but .gh."))] | length == 1' >/dev/null
  echo "$output" | jq -e '[.notes[] | select(test("renovate is configured but .gh."))] | length == 1' >/dev/null
}

@test "gather-go: semgrep SHIPS for Go (not deferred like Swift) — configured when a hook is present (#873)" {
  # The Swift lesson (#443) was semgrep's EMPTY Swift registry. Go's semgrep is
  # GA, so unlike Swift the tool is real: a semgrep hook makes it configured,
  # and with the binary absent the key is present as an empty array.
  printf 'repos:\n  - repo: https://github.com/semgrep/semgrep\n' > "$WORK/.pre-commit-config.yaml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.semgrep <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.semgrep | type' <<<"$output")" = "array" ]
  echo "$output" | jq -e '[.notes[] | select(test("semgrep is configured but"))] | length == 1' >/dev/null
}

@test "gather-go: sonar-project.properties present -> sonarcloud configured; helper unavailable degrades to [] (#873)" {
  printf 'sonar.organization=acme\nsonar.projectKey=acme_svc\n' > "$WORK/sonar-project.properties"
  # no_binary: zsh is absent from the isolated PATH, so the zsh-shebang'd helper
  # can't exec (env exits 127) and the gather takes its else branch — configured
  # true, findings an empty array. This is the deliberate degraded branch.
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.sonarcloud <<<"$output")" = "true" ]
  [ "$(jq -c '.findings_by_tool.sonarcloud' <<<"$output")" = "[]" ]
}

@test "gather-go: sonarcloud helper output is parsed — findings + quality gate propagate (#873)" {
  printf 'sonar.organization=acme\nsonar.projectKey=acme_svc\n' > "$WORK/sonar-project.properties"
  stub_zsh '{"findings":[{"type":"CODE_SMELL","severity":"MAJOR","rule":"go:S1192","component":"main.go","line":3,"message":"m","key":"k"}],"quality_gate":{"status":"ERROR"}}' 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.sonarcloud | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.findings_by_tool.sonarcloud[0].rule' <<<"$output")" = "go:S1192" ]
  # The top-level sonar_quality_gate propagates from the helper.
  [ "$(jq -r '.sonar_quality_gate.status' <<<"$output")" = "ERROR" ]
}

@test "gather-go: a failing sonarcloud helper (exit 1) degrades to [] without aborting the gather (#873)" {
  printf 'sonar.organization=acme\nsonar.projectKey=acme_svc\n' > "$WORK/sonar-project.properties"
  stub_zsh '' 1
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.findings_by_tool.sonarcloud' <<<"$output")" = "[]" ]
  [ "$(jq -r '.sonar_quality_gate' <<<"$output")" = "null" ]
}

@test "gather-go: a helper that exits 0 with EMPTY stdout still yields valid JSON (#873)" {
  # The slurp guard: non-slurped jq on empty input emits nothing and exits 0,
  # so the || fallback wouldn't fire and the final --argjson would abort the
  # whole emit. jq -s makes empty input resolve to []/null.
  printf 'sonar.organization=acme\nsonar.projectKey=acme_svc\n' > "$WORK/sonar-project.properties"
  stub_zsh '' 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(jq -c '.findings_by_tool.sonarcloud' <<<"$output")" = "[]" ]
  [ "$(jq -r '.sonar_quality_gate' <<<"$output")" = "null" ]
}

@test "gather-go: sonar-project.properties missing org/key -> configured but an honest note (#873)" {
  printf '# no org or projectKey here\n' > "$WORK/sonar-project.properties"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.sonarcloud <<<"$output")" = "true" ]
  echo "$output" | jq -e '[.notes[] | select(test("missing .sonar.organization. or .sonar.projectKey."))] | length == 1' >/dev/null
}

@test "gather-go: a CodeQL workflow present -> code_scanning configured; helper unavailable degrades to [] (#873)" {
  mkdir -p "$WORK/.github/workflows"
  printf 'name: CodeQL\non: [push]\njobs: {}\n' > "$WORK/.github/workflows/codeql.yml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.code_scanning <<<"$output")" = "true" ]
  # The findings key is code_scanning_alerts, not code_scanning.
  [ "$(jq -c '.findings_by_tool.code_scanning_alerts' <<<"$output")" = "[]" ]
}

@test "gather-go: code_scanning helper output is parsed into code_scanning_alerts (#873)" {
  mkdir -p "$WORK/.github/workflows"
  printf 'name: CodeQL\non: [push]\njobs: {}\n' > "$WORK/.github/workflows/codeql.yml"
  stub_zsh '{"code_scanning_alerts":[{"number":7,"rule_id":"go/sql-injection","severity":"high","tool":"CodeQL","file":"internal/store/orders.go","line":81,"message":"m","html_url":"u"}]}' 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.code_scanning_alerts | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.findings_by_tool.code_scanning_alerts[0].rule_id' <<<"$output")" = "go/sql-injection" ]
}

@test "gather-go: bare project -> the static-analysis triple reports not-configured, no findings keys (#873)" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  for tool in sonarcloud code_scanning semgrep; do
    [ "$(jq -r ".tooling_configured.$tool" <<<"$output")" = "false" ]
  done
  # Unconfigured -> absent from findings_by_tool (contract for the whole family).
  [ "$(jq -r '.findings_by_tool | has("sonarcloud")' <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("code_scanning_alerts")' <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("semgrep")' <<<"$output")" = "false" ]
}

@test "gather-go #876: a dependabot.yml makes ONLY dependabot configured (snyk_prs/renovate stay false)" {
  # Slice G landed vendor-PR sources: dependabot config presence flips just its
  # own key; the other two stay false without their own config files.
  mkdir -p "$WORK/.github"
  printf 'version: 2\nupdates: []\n' > "$WORK/.github/dependabot.yml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured.dependabot' <<<"$output")" = "true" ]
  [ "$(jq -r '.tooling_configured.snyk_prs' <<<"$output")" = "false" ]
  [ "$(jq -r '.tooling_configured.renovate' <<<"$output")" = "false" ]
  # findings degrade to [] (gh absent under the isolated PATH), key present.
  [ "$(jq -r '.findings_by_tool.dependabot | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.findings_by_tool | has("snyk_prs")' <<<"$output")" = "false" ]
}

@test "gather-go #878: no .proto -> grpc + api_contract not configured, findings keys absent" {
  # setup() writes only go.mod, no protos — the default state for most repos.
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured.grpc' <<<"$output")" = "false" ]
  [ "$(jq -r '.tooling_configured.api_contract' <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("grpc")' <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("api_contract")' <<<"$output")" = "false" ]
}

@test "gather-go #878: a .proto present -> grpc configured, ONE proto-audit finding" {
  mkdir -p "$WORK/proto/job/v1"
  printf 'syntax = "proto3";\npackage job.v1;\nservice JobService {\n  rpc List(ListReq) returns (ListResp);\n}\n' \
    > "$WORK/proto/job/v1/job.proto"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured.grpc' <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.grpc | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.findings_by_tool.grpc[0].rule' <<<"$output")" = "grpc:proto-audit" ]
  # No buf config -> component falls back to the first .proto (repo-relative).
  [ "$(jq -r '.findings_by_tool.grpc[0].component' <<<"$output")" = "proto/job/v1/job.proto" ]
  [ "$(jq -r '.findings_by_tool.grpc[0].key' <<<"$output")" = "grpc:proto-audit:proto/job/v1/job.proto" ]
}

@test "gather-go #878: a .proto WITHOUT google.api.http -> api_contract stays false (internal-only gRPC)" {
  # The "gRPC internal, REST external" policy: an internal-only service declares
  # no REST surface, so api_contract must NOT be flagged as a missing pipeline.
  mkdir -p "$WORK/proto"
  printf 'syntax = "proto3";\npackage internal.v1;\nservice Ledger {\n  rpc Post(PostReq) returns (PostResp);\n}\n' \
    > "$WORK/proto/ledger.proto"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured.grpc' <<<"$output")" = "true" ]
  [ "$(jq -r '.tooling_configured.api_contract' <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("api_contract")' <<<"$output")" = "false" ]
}

@test "gather-go #878: a .proto WITH google.api.http -> api_contract configured, ONE contract-audit finding" {
  mkdir -p "$WORK/proto/job/v1"
  printf 'syntax = "proto3";\npackage job.v1;\nimport "google/api/annotations.proto";\nservice JobService {\n  rpc CreateJob(CreateJobRequest) returns (Job) {\n    option (google.api.http) = { post: "/v1/jobs" body: "*" };\n  }\n}\n' \
    > "$WORK/proto/job/v1/job.proto"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tooling_configured.api_contract' <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.api_contract | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.findings_by_tool.api_contract[0].rule' <<<"$output")" = "api_contract:contract-audit" ]
  # grpc is configured too (protos exist) — both advisors fire on an external service.
  [ "$(jq -r '.tooling_configured.grpc' <<<"$output")" = "true" ]
}

@test "gather-go #878: buf.gen.yaml is preferred as the audit finding's component" {
  mkdir -p "$WORK/proto"
  printf 'syntax = "proto3";\npackage a.v1;\nservice A { rpc P(R) returns (S); }\n' \
    > "$WORK/proto/a.proto"
  printf 'version: v2\nplugins:\n  - remote: buf.build/protocolbuffers/go:v1.36.6\n    out: gen\n' \
    > "$WORK/buf.gen.yaml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  # The advisor Reads buf.gen.yaml, so the finding points there, not at a .proto.
  [ "$(jq -r '.findings_by_tool.grpc[0].component' <<<"$output")" = "buf.gen.yaml" ]
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
  # Scope to the format_lint note specifically — other tools (govulncheck, #876)
  # also legitimately emit a "not on PATH" note under the isolated PATH.
  echo "$output" | jq -e '[.notes[] | select(test("format_lint is configured but"))] | length == 1' >/dev/null
}

@test "gather-go: with the binary present, the format_lint not-on-PATH note is absent" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  stub_golangci "" 0
  with_stub "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.notes[] | select(test("format_lint is configured but"))] | length == 0' >/dev/null
}

@test "gather-go: two golangci config files present -> format_lint still configured once" {
  printf 'version: "2"\n' > "$WORK/.golangci.yml"
  printf 'version = "2"\n' > "$WORK/.golangci.toml"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  # tooling_configured keys are unique by construction; the guard is that two
  # config spellings don't confuse the boolean or add a spurious key.
  [ "$(jq -r '.tooling_configured | keys | length' <<<"$output")" = "10" ]
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

# --- coverage: withheld paths (hermetic, no Go toolchain) --------------------

@test "gather-go: no *_test.go -> coverage withheld honestly (null, reliable=false) (#874)" {
  # Measurement is gated on test presence, so a repo with nothing to cover
  # withholds rather than running a heavy, pointless `go test`.
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.coverage.overall == null' >/dev/null
  [ "$(jq -r .coverage.measurement.reliable <<<"$output")" = "false" ]
  [ "$(jq -r .coverage.measurement.source <<<"$output")" = "none" ]
  echo "$output" | jq -e '.coverage.measurement.reason | test("nothing to cover")' >/dev/null
}

@test "gather-go: *_test.go present but no toolchain -> coverage withheld with the honest reason (#874)" {
  # ISO has no `go`, so a repo WITH a test still withholds — measured only where
  # the toolchain exists (the Go test-bed), never guessed.
  mkdir -p "$WORK/calc"
  printf 'package calc\nfunc Add(a,b int) int { return a+b }\n' > "$WORK/calc/calc.go"
  printf 'package calc\nimport "testing"\nfunc TestAdd(t *testing.T){ if Add(1,2)!=3 {t.Fatal("x")} }\n' > "$WORK/calc/calc_test.go"
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.coverage.overall == null' >/dev/null
  [ "$(jq -r .coverage.measurement.reliable <<<"$output")" = "false" ]
  echo "$output" | jq -e '.coverage.measurement.reason | test("go. is not on PATH")' >/dev/null
}

@test "gather-go: coverage always carries the region-gate keys (#874)" {
  no_binary "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage | has("overall") and has("by_module") and has("regions")' <<<"$output")" = "true" ]
  [ "$(jq -r '.coverage.regions | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.coverage.by_module | type' <<<"$output")" = "object" ]
}

# --- parse-go-coverage.py unit checks (#874) --------------------------------
# The measured `go test` path needs the Go toolchain (exercised on the test-bed),
# but the PARSER is toolchain-free text parsing — fully covered here with real
# `go test -coverprofile` + `go tool cover -func` output captured as fixtures.

@test "parse-go-coverage: per-package by_module + overall, generated files excluded (#874)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  printf 'mode: set\n%s\n%s\n%s\n' \
    'github.com/acme/svc/internal/store/persons.go:10.20,13.2 2 1' \
    'github.com/acme/svc/internal/store/persons.go:15.30,20.2 4 0' \
    'github.com/acme/svc/internal/gen/api.pb.go:5.1,9.2 3 0' > "$WORK/cover.out"
  printf '%s\n%s\n%s\n%s\n' \
    'github.com/acme/svc/internal/store/persons.go:10:	List	100.0%' \
    'github.com/acme/svc/internal/store/persons.go:15:	Save	0.0%' \
    'github.com/acme/svc/internal/gen/api.pb.go:5:	Marshal	0.0%' \
    'total:					(statements)	33.3%' > "$WORK/cover.func.txt"
  out=$(python3 "$PARSE" "$WORK/cover.out" "$WORK/cover.func.txt" github.com/acme/svc)
  # by_module: 2 covered of 6 total statements in persons.go = 33.3; .pb.go dropped.
  [ "$(jq -r '.by_module | keys | join(",")' <<<"$out")" = "internal/store/persons.go" ]
  [ "$(jq '.by_module["internal/store/persons.go"] == 33.3' <<<"$out")" = "true" ]
  # overall counts only non-generated statements.
  [ "$(jq '.overall == 33.3' <<<"$out")" = "true" ]
  # generated Marshal region excluded.
  [ "$(jq '[.regions[] | select(.name=="Marshal")] | length == 0' <<<"$out")" = "true" ]
}

@test "parse-go-coverage: per-function regions with derived end_line and pct (#874)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  printf 'mode: set\n%s\n%s\n' \
    'github.com/acme/svc/calc.go:10.1,14.2 3 1' \
    'github.com/acme/svc/calc.go:15.1,25.2 6 0' > "$WORK/cover.out"
  printf '%s\n%s\n%s\n' \
    'github.com/acme/svc/calc.go:10:	Add	100.0%' \
    'github.com/acme/svc/calc.go:15:	Sub	0.0%' \
    'total:					(statements)	33.3%' > "$WORK/cover.func.txt"
  out=$(python3 "$PARSE" "$WORK/cover.out" "$WORK/cover.func.txt" github.com/acme/svc)
  # Add: start 10, end = next func start - 1 = 14; pct from -func.
  [ "$(jq '[.regions[] | select(.name=="Add")][0] | .start_line==10 and .end_line==14 and .pct==100.0' <<<"$out")" = "true" ]
  # Sub: last func in file, end = max block end-line the profile shows (25).
  [ "$(jq '[.regions[] | select(.name=="Sub")][0] | .start_line==15 and .end_line==25 and .pct==0.0' <<<"$out")" = "true" ]
  [ "$(jq -r '.regions[0].file' <<<"$out")" = "calc.go" ]
}

@test "parse-go-coverage: empty profile -> overall null, empty by_module/regions (#874)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  printf 'mode: set\n' > "$WORK/cover.out"
  printf 'total:\t(statements)\t0.0%%\n' > "$WORK/cover.func.txt"
  out=$(python3 "$PARSE" "$WORK/cover.out" "$WORK/cover.func.txt" github.com/acme/svc)
  [ "$(jq -r '.overall' <<<"$out")" = "null" ]
  [ "$(jq -c '.by_module' <<<"$out")" = "{}" ]
  [ "$(jq -c '.regions' <<<"$out")" = "[]" ]
}

@test "parse-go-coverage: missing args -> valid empty JSON, exit 0 (#874)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  run python3 "$PARSE"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.overall == null and (.by_module == {}) and (.regions == [])' >/dev/null
}

@test "parse-go-coverage: a nonexistent profile path -> withheld, not a crash (#874)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  run python3 "$PARSE" "$WORK/nope.out" "$WORK/nope.func.txt" github.com/acme/svc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.overall == null' >/dev/null
}

@test "parse-go-coverage: tabwriter multi-tab padding in -func output is parsed (#874)" {
  # Real `go tool cover -func` pads columns with tabs (tabwriter, padchar \t),
  # so short names get 2+ tabs. The parser must tolerate that, not assume one.
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  printf 'mode: set\n%s\n' 'github.com/acme/svc/calc.go:10.1,14.2 3 1' > "$WORK/cover.out"
  printf 'github.com/acme/svc/calc.go:10:\tAdd\t\t100.0%%\n' > "$WORK/cover.func.txt"
  out=$(python3 "$PARSE" "$WORK/cover.out" "$WORK/cover.func.txt" github.com/acme/svc)
  [ "$(jq -r '.regions[0].name' <<<"$out")" = "Add" ]
  [ "$(jq '.regions[0].pct == 100.0' <<<"$out")" = "true" ]
}

@test "parse-go-coverage: single-function file -> end_line from the profile's max block (#874)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  printf 'mode: set\n%s\n' 'github.com/acme/svc/only.go:5.1,40.2 8 1' > "$WORK/cover.out"
  printf 'github.com/acme/svc/only.go:5:\tSolo\t100.0%%\n' > "$WORK/cover.func.txt"
  out=$(python3 "$PARSE" "$WORK/cover.out" "$WORK/cover.func.txt" github.com/acme/svc)
  [ "$(jq '.regions[0] | .start_line==5 and .end_line==40' <<<"$out")" = "true" ]
}

@test "parse-go-coverage: out-of-source-order -func lines still sort into correct spans (#874)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  printf 'mode: set\n%s\n%s\n' \
    'github.com/acme/svc/x.go:10.1,14.2 2 1' \
    'github.com/acme/svc/x.go:20.1,30.2 4 0' > "$WORK/cover.out"
  # Second function listed FIRST in the -func output (%% -> % in the format).
  printf 'github.com/acme/svc/x.go:20:\tSecond\t0.0%%\ngithub.com/acme/svc/x.go:10:\tFirst\t100.0%%\n' > "$WORK/cover.func.txt"
  out=$(python3 "$PARSE" "$WORK/cover.out" "$WORK/cover.func.txt" github.com/acme/svc)
  # First: end = Second's start - 1 = 19, despite being listed second.
  [ "$(jq '[.regions[] | select(.name=="First")][0] | .start_line==10 and .end_line==19' <<<"$out")" = "true" ]
}

@test "parse-go-coverage: empty module path -> paths left unstripped, no crash (#874)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  printf 'mode: set\n%s\n' 'github.com/acme/svc/calc.go:10.1,14.2 3 1' > "$WORK/cover.out"
  printf 'github.com/acme/svc/calc.go:10:\tAdd\t100.0%%\n' > "$WORK/cover.func.txt"
  out=$(python3 "$PARSE" "$WORK/cover.out" "$WORK/cover.func.txt" "")
  # Unstripped import-path key (the gather notes this degradation).
  [ "$(jq -r '.by_module | keys | join(",")' <<<"$out")" = "github.com/acme/svc/calc.go" ]
}

@test "parse-go-coverage: non-UTF-8 bytes in a profile don't crash the parser (#874)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-go-coverage.py"
  printf 'mode: set\n' > "$WORK/cover.out"
  printf 'github.com/acme/svc/calc.go:10.1,14.2 3 1\n' >> "$WORK/cover.out"
  printf '\xff\xfe bad bytes\n' >> "$WORK/cover.out"
  printf 'github.com/acme/svc/calc.go:10:\tAdd\t100.0%%\n' > "$WORK/cover.func.txt"
  run python3 "$PARSE" "$WORK/cover.out" "$WORK/cover.func.txt" github.com/acme/svc
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.by_module["calc.go"] == 100' >/dev/null
}

@test "gather-go: build-failure detection matches a real build-failed line, not red-suite metrics output (#874)" {
  # The withhold-on-compile-failure grep must not misfire on a merely-red suite
  # that replays `# HELP`/`# TYPE` metrics or `# comment` diff lines. This pins
  # the anchored pattern (extracted verbatim from the gather) directly.
  pat='^(FAIL|ok|----)[[:space:]].*\[(build|setup) failed\]$|^# [^[:space:]]*[./][^[:space:]]*([[:space:]]\[[^]]+\])?$|^go: .*cannot find|build constraints exclude all Go files'
  # Real compile/setup-failure shapes -> MATCH.
  printf 'FAIL\tgithub.com/acme/svc/broken [build failed]\n' | grep -qE "$pat"
  printf 'FAIL\tgithub.com/acme/svc/broken [setup failed]\n' | grep -qE "$pat"
  printf '# github.com/acme/svc/broken\n' | grep -qE "$pat"
  printf '# github.com/acme/svc/broken [github.com/acme/svc/broken.test]\n' | grep -qE "$pat"
  printf 'build constraints exclude all Go files in /x\n' | grep -qE "$pat"
  # Red-suite / metrics / prose output a naive `^# ` or bare `[build failed]`
  # would wrongly match -> must NOT match (the `^# ` arm requires a /-or-.
  # import-path token, which these lack).
  run grep -qE "$pat" <<<'# HELP http_requests_total The total number of HTTP requests.'
  [ "$status" -ne 0 ]
  run grep -qE "$pat" <<<'# TYPE http_requests_total counter'
  [ "$status" -ne 0 ]
  run grep -qE "$pat" <<<'# TODO'
  [ "$status" -ne 0 ]
  run grep -qE "$pat" <<<'# Overview'
  [ "$status" -ne 0 ]
  run grep -qE "$pat" <<<'    got: "the [build failed] marker in a string literal"'
  [ "$status" -ne 0 ]
}
