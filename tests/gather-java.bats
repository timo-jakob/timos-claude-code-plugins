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

@test "gather-java: bare project -> all tools report not-configured" {
  printf 'plugins { java }\n' > "$WORK/build.gradle"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  for tool in format_lint sonarcloud code_scanning semgrep dependabot snyk_prs grpc; do
    [ "$(jq -r ".tooling_configured.$tool" <<<"$output")" = "false" ]
  done
}

@test "gather-java: .proto present -> grpc configured + a proto-audit finding" {
  printf 'plugins { java }\n' > "$WORK/build.gradle"
  mkdir -p "$WORK/src/main/proto"
  printf 'syntax = "proto3";\nmessage X {}\n' > "$WORK/src/main/proto/x.proto"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.grpc <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.grpc | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.findings_by_tool.grpc[0].rule' <<<"$output")" = "grpc:proto-audit" ]
}

@test "gather-java: no sonar-project.properties -> sonarcloud not configured" {
  printf 'plugins { java }\n' > "$WORK/build.gradle"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.sonarcloud <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool.sonarcloud // "absent"' <<<"$output")" = "absent" ]
}

@test "gather-java: no JaCoCo -> coverage withheld with a JaCoCo reason" {
  printf 'plugins { java }\n' > "$WORK/build.gradle"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage.overall // "null"' <<<"$output")" = "null" ]
  [ "$(jq -r .coverage.measurement.reliable <<<"$output")" = "false" ]
  echo "$output" | jq -e '.coverage.measurement.reason | test("JaCoCo")' >/dev/null
}

# --- parse-jacoco.py unit checks --------------------------------------------

@test "parse-jacoco: aggregates LINE coverage, resolves on-disk source paths" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-jacoco.py"
  mkdir -p "$WORK/src/main/java/com/example"
  printf 'class Foo {}\n' > "$WORK/src/main/java/com/example/Foo.java"
  cat > "$WORK/report.xml" <<'EOF'
<report name="demo"><package name="com/example">
<sourcefile name="Foo.java"><counter type="LINE" missed="2" covered="8"/></sourcefile>
<sourcefile name="Bar.java"><counter type="LINE" missed="5" covered="5"/></sourcefile>
</package></report>
EOF
  out=$(cd "$WORK" && python3 "$PARSE" report.xml)
  # Numeric comparison — jq renders the value as 65.0, not 65.
  [ "$(jq '.overall == 65' <<<"$out")" = "true" ]
  # Foo resolves to its real source path; Bar (no file on disk) keeps the JaCoCo path.
  [ "$(jq '.by_module["src/main/java/com/example/Foo.java"] == 80' <<<"$out")" = "true" ]
  [ "$(jq '.by_module["com/example/Bar.java"] == 50' <<<"$out")" = "true" ]
}

@test "parse-jacoco: empty report -> overall null" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-jacoco.py"
  printf '<report name="empty"></report>\n' > "$WORK/empty.xml"
  out=$(cd "$WORK" && python3 "$PARSE" empty.xml)
  [ "$(jq -r .overall <<<"$out")" = "null" ]
}
