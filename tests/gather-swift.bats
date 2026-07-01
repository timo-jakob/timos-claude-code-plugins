#!/usr/bin/env bats
#
# Behavioral tests for gather-swift-findings.sh — the Swift findings gather
# script (#442, first slice of the #297 Swift full-maintenance epic).
#
# These cover the hermetic paths: the JSON output contract, the not-configured
# case, and config detection. The swift-format-configured + violation paths
# need the swift-format binary and real .swift sources; those are exercised by
# manual validation on the Xcode test-bed, not here (CI runners don't ship the
# Swift toolchain).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-swift-findings.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
}

@test "gather-swift: no format/lint config -> format_lint not configured, valid JSON" {
  printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "false" ]
  # Unconfigured tool is absent from findings_by_tool.
  [ "$(jq -r '.findings_by_tool.format_lint // "absent"' <<<"$output")" = "absent" ]
}

@test "gather-swift: output always carries the contract keys" {
  printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("tooling_configured")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("findings_by_tool")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("coverage")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("notes")' <<<"$output")" = "true" ]
}

@test "gather-swift: no test targets -> coverage withheld honestly (null, reliable=false), no toolchain run" {
  # A bare Package.swift with no .testTarget / Tests/ / *Tests.swift: measurement
  # is gated on test presence, so the gather withholds rather than running a
  # heavy, pointless `swift test`. This keeps the test hermetic even on a host
  # that HAS the Swift toolchain.
  printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage.overall // "null"' <<<"$output")" = "null" ]
  [ "$(jq -r .coverage.measurement.reliable <<<"$output")" = "false" ]
  echo "$output" | jq -e '.coverage.measurement.reason | test("nothing to cover")' >/dev/null
}

@test "gather-swift: coverage carries a regions array (empty when withheld) (#463)" {
  # The region-scoped gate consumes coverage.regions; the gather always emits
  # the key (empty [] when coverage is withheld/unmeasured, as in this hermetic
  # no-tests case).
  printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage | has("regions")' <<<"$output")" = "true" ]
  [ "$(jq -r '.coverage.regions | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.coverage.regions | length' <<<"$output")" = "0" ]
}

@test "gather-swift: missing repo path -> usage error, exit 2" {
  run bash "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}

@test "gather-swift: .swiftlint.yml present -> format_lint configured" {
  printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
  printf 'line_length: 120\n' > "$WORK/.swiftlint.yml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "true" ]
  # tooling_configured always carries the format_lint key.
  [ "$(jq -r '.tooling_configured | has("format_lint")' <<<"$output")" = "true" ]
  # Configured -> the format_lint key is present in findings_by_tool (array,
  # possibly empty when there's nothing to format / no binary).
  [ "$(jq -r '.findings_by_tool.format_lint | type' <<<"$output")" = "array" ]
}

@test "gather-swift: .swift-format present -> format_lint configured" {
  printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
  printf '{ "version": 1, "lineLength": 120 }\n' > "$WORK/.swift-format"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "true" ]
}

@test "gather-swift: bare project -> all four tools report not-configured (#443)" {
  printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  for tool in format_lint sonarcloud code_scanning semgrep; do
    [ "$(jq -r ".tooling_configured.$tool" <<<"$output")" = "false" ]
  done
  # tooling_configured always carries every key, even when false.
  [ "$(jq -r '.tooling_configured | keys | length' <<<"$output")" = "4" ]
}

@test "gather-swift: semgrep is always deferred (false) even when a semgrep config is present (#443)" {
  # Semgrep's Swift support is experimental with an empty rule registry, so it
  # is hardcoded not-configured — never fetched, never an empty findings array.
  printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
  printf 'repos:\n  - repo: https://github.com/semgrep/semgrep\n' > "$WORK/.pre-commit-config.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.semgrep <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("semgrep")' <<<"$output")" = "false" ]
}

# --- parse-swift-coverage.py unit checks (#444) -----------------------------

@test "parse-swift-coverage: xccov format -> per-file LINE coverage, drops build artifacts" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-swift-coverage.py"
  cat > "$WORK/xccov.json" <<EOF
{"lineCoverage":0.5,"targets":[{"name":"App","files":[
  {"name":"Foo.swift","path":"$WORK/Sources/App/Foo.swift","coveredLines":46,"executableLines":50},
  {"name":"dep.swift","path":"$WORK/.build/checkouts/X/dep.swift","coveredLines":0,"executableLines":100}
]}]}
EOF
  out=$(cd "$WORK" && python3 "$PARSE" xccov.json)
  # .build vendored file dropped; overall reflects only project source.
  [ "$(jq '.overall == 92' <<<"$out")" = "true" ]
  [ "$(jq '.by_module["Sources/App/Foo.swift"] == 92' <<<"$out")" = "true" ]
  [ "$(jq '.by_module | has("Sources/App/Foo.swift")' <<<"$out")" = "true" ]
  [ "$(jq '.by_module | length' <<<"$out")" = "1" ]
}

@test "parse-swift-coverage: llvm-cov export format -> per-file coverage, drops SDK files" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-swift-coverage.py"
  cat > "$WORK/llvm.json" <<EOF
{"data":[{"files":[
  {"filename":"$WORK/Sources/App/Bar.swift","summary":{"lines":{"count":10,"covered":5,"percent":50.0}}},
  {"filename":"/Applications/Xcode.app/SDK/System.swift","summary":{"lines":{"count":999,"covered":0,"percent":0}}}
]}]}
EOF
  out=$(cd "$WORK" && python3 "$PARSE" llvm.json)
  [ "$(jq '.overall == 50' <<<"$out")" = "true" ]
  [ "$(jq '.by_module["Sources/App/Bar.swift"] == 50' <<<"$out")" = "true" ]
  [ "$(jq '.by_module | length' <<<"$out")" = "1" ]
}

@test "parse-swift-coverage: empty / no measurable source -> overall null" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-swift-coverage.py"
  printf '{}\n' > "$WORK/empty.json"
  out=$(cd "$WORK" && python3 "$PARSE" empty.json)
  [ "$(jq -r .overall <<<"$out")" = "null" ]
}

@test "parse-swift-coverage: xccov multi-line function span (#464)" {
  # A function at line 10 with the next at line 50 spans 10..49 — a real
  # multi-line region (the earlier fixtures used adjacent single-line funcs).
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-swift-coverage.py"
  cat > "$WORK/xccov.json" <<EOF
{"targets":[{"name":"A","files":[{"name":"Big.swift","path":"$WORK/Big.swift","functions":[
  {"name":"first()","lineNumber":10,"executableLines":20,"coveredLines":10},
  {"name":"second()","lineNumber":50,"executableLines":4,"coveredLines":4}
]}]}]}
EOF
  out=$(cd "$WORK" && python3 "$PARSE" xccov.json)
  # first() spans many lines: end_line = next function's start - 1 = 49
  [ "$(jq '[.regions[] | select(.name=="first()")][0] | .start_line==10 and .end_line==49' <<<"$out")" = "true" ]
  [ "$(jq '[.regions[] | select(.name=="first()")][0].pct == 50' <<<"$out")" = "true" ]
}

@test "demangle-swift-regions: already-readable names pass through unchanged" {
  H="$REPO_ROOT/development/skills/maintenance/scripts/demangle-swift-regions.py"
  in='[{"file":"a.swift","name":"save(_:)","start_line":1,"end_line":4,"pct":80}]'
  out=$(printf '%s' "$in" | python3 "$H")
  [ "$(jq -r '.[0].name' <<<"$out")" = "save(_:)" ]
  [ "$(jq '.[0].pct' <<<"$out")" = "80" ]
}

@test "demangle-swift-regions: empty array stays empty; the schema is preserved" {
  H="$REPO_ROOT/development/skills/maintenance/scripts/demangle-swift-regions.py"
  out=$(printf '[]' | python3 "$H")
  [ "$(jq 'type' <<<"$out")" = '"array"' ]
  [ "$(jq 'length' <<<"$out")" = "0" ]
}

@test "demangle-swift-regions: mangled SwiftPM names become readable (needs xcrun)" {
  command -v xcrun >/dev/null 2>&1 || skip "xcrun not available"
  H="$REPO_ROOT/development/skills/maintenance/scripts/demangle-swift-regions.py"
  in='[{"file":"a.swift","name":"$s4DemoAAV7coveredyS2iF","start_line":1,"end_line":4,"pct":100}]'
  out=$(printf '%s' "$in" | python3 "$H")
  # readable form, no leading $s mangling
  [ "$(jq -r '.[0].name | startswith("$s") | not' <<<"$out")" = "true" ]
  echo "$out" | jq -e '.[0].name | test("covered")' >/dev/null
}

# --- per-function regions (#463) --------------------------------------------

@test "parse-swift-coverage: xccov -> per-function regions with line spans" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-swift-coverage.py"
  out=$(cd "$REPO_ROOT" && python3 "$PARSE" tests/fixtures/coverage/xcode-xccov.json)
  [ "$(jq '.regions | length >= 2' <<<"$out")" = "true" ]
  [ "$(jq '[.regions[] | select(.name | test("covered"))][0].pct >= 99' <<<"$out")" = "true" ]
  [ "$(jq '[.regions[] | select(.name | test("uncovered"))][0].pct == 0' <<<"$out")" = "true" ]
  [ "$(jq '.regions[0] | has("start_line") and has("end_line")' <<<"$out")" = "true" ]
}

@test "parse-swift-coverage: llvm-cov -> per-function regions with pct" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-swift-coverage.py"
  out=$(cd "$REPO_ROOT" && python3 "$PARSE" tests/fixtures/coverage/swiftpm-llvmcov.json)
  [ "$(jq '.regions | length >= 2' <<<"$out")" = "true" ]
  [ "$(jq '[.regions[] | select(.name | test("covered"))][0].pct >= 99' <<<"$out")" = "true" ]
  [ "$(jq '[.regions[] | select(.name | test("uncovered"))][0].pct == 0' <<<"$out")" = "true" ]
  [ "$(jq '.regions[0] | has("start_line") and has("end_line")' <<<"$out")" = "true" ]
  [ "$(jq '[.regions[] | select(.start_line >= 1 and .end_line >= .start_line)] | length >= 1' <<<"$out")" = "true" ]
}

@test "parse-swift-coverage: containment - line inside covered function resolves to region, line above all functions does not" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-swift-coverage.py"
  out=$(cd "$REPO_ROOT" && python3 "$PARSE" tests/fixtures/coverage/xcode-xccov.json)
  # Line 2 is inside covered(_:) which has lineNumber=2
  [ "$(jq '[.regions[] | select(.start_line <= 2 and .end_line >= 2)] | length > 0' <<<"$out")" = "true" ]
  # Line 1 is above all functions (first function starts at line 2)
  [ "$(jq '[.regions[] | select(.start_line <= 1 and .end_line >= 1)] | length == 0' <<<"$out")" = "true" ]
}
