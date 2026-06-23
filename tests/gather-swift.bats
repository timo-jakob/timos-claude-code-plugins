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

@test "gather-swift: coverage is withheld honestly (null, reliable=false) this slice" {
  printf '// swift-tools-version:6.0\n' > "$WORK/Package.swift"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage.overall // "null"' <<<"$output")" = "null" ]
  [ "$(jq -r .coverage.measurement.reliable <<<"$output")" = "false" ]
  # The reason names the slice where coverage arrives, so it isn't read as a bug.
  echo "$output" | jq -e '.coverage.measurement.reason | test("Slice D")' >/dev/null
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
