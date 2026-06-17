#!/usr/bin/env bats
#
# Behavioral tests for gather-java-findings.sh — the Java/Gradle findings
# gather script (#306, first slice of the #296 Java/Gradle epic).
#
# These cover the hermetic, Gradle-free paths: the JSON output contract and
# the not-configured case. The Spotless-configured + violation paths require a
# JDK + Gradle and are exercised by manual validation on a real repo, not here
# (CI runners don't ship Gradle).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-java-findings.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
}

@test "gather-java: no Spotless config -> format_lint not configured, valid JSON" {
  printf 'plugins { java }\n' > "$WORK/build.gradle"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  # Output is valid JSON.
  echo "$output" | jq -e . >/dev/null
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "false" ]
  # Unconfigured tool is absent from findings_by_tool.
  [ "$(jq -r '.findings_by_tool.format_lint // "absent"' <<<"$output")" = "absent" ]
}

@test "gather-java: output always carries the contract keys" {
  printf 'plugins { java }\n' > "$WORK/build.gradle"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("tooling_configured")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("findings_by_tool")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("coverage")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("notes")' <<<"$output")" = "true" ]
}

@test "gather-java: coverage is withheld honestly (null, reliable=false) this slice" {
  printf 'plugins { java }\n' > "$WORK/build.gradle"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage.overall // "null"' <<<"$output")" = "null" ]
  [ "$(jq -r .coverage.measurement.reliable <<<"$output")" = "false" ]
}

@test "gather-java: missing repo path -> usage error, exit 2" {
  run bash "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}
