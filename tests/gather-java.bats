#!/usr/bin/env bats
#
# Behavioral tests for gather-java-findings.sh — the Java/Gradle findings
# gather script (#306, first slice of the #296 Java/Gradle epic).
#
# These cover the hermetic, Gradle-free paths: the JSON output contract and
# the not-configured case. The Spotless-configured + violation paths require a
# JDK + Gradle and are exercised by manual validation on a real repo, not here
# (CI runners don't ship Gradle).

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-java-findings.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
}

@test "gather-java: no Spotless config -> format_lint not configured, valid JSON" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  # Output is valid JSON.
  echo "$output" | jq -e . >/dev/null
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "false" ]
  # Unconfigured tool is absent from findings_by_tool.
  [ "$(jq -r '.findings_by_tool.format_lint // "absent"' <<<"$output")" = "absent" ]
}

@test "gather-java: output always carries the contract keys" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("tooling_configured")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("findings_by_tool")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("coverage")' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("notes")' <<<"$output")" = "true" ]
}

@test "gather-java: coverage is withheld honestly (null, reliable=false) this slice" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage.overall // "null"' <<<"$output")" = "null" ]
  [ "$(jq -r .coverage.measurement.reliable <<<"$output")" = "false" ]
}

@test "gather-java: coverage carries a regions array (empty when withheld) (#466)" {
  # The region-scoped gate consumes coverage.regions; the gather always emits
  # the key (empty [] when coverage is withheld — no JaCoCo run in this hermetic
  # no-Gradle case).
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage | has("regions")' <<<"$output")" = "true" ]
  [ "$(jq -r '.coverage.regions | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.coverage.regions | length' <<<"$output")" = "0" ]
}

@test "gather-java: missing repo path -> usage error, exit 2" {
  run bash "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}

@test "gather-java: bare project -> all tools report not-configured" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  for tool in format_lint sonarcloud code_scanning semgrep dependabot snyk_prs renovate grpc openapi; do
    [ "$(jq -r ".tooling_configured.$tool" <<<"$output")" = "false" ]
  done
}

@test "gather-java: #343 Groovy build.gradle is NOT scanned (Kotlin DSL only)" {
  # A Groovy build with a hardcoded version + Spotless: the gather targets
  # build.gradle.kts only, so it sees nothing. (The dispatcher halts Groovy
  # repos; the gather doesn't double-handle the format.)
  printf "plugins {\n  id 'com.diffplug.spotless'\n}\nversion = '1.2.3'\n" > "$WORK/build.gradle"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(jq -r .tooling_configured.format_lint <<<"$output")" = "false" ]
  [ "$(jq -r .tooling_configured.versioning <<<"$output")" = "false" ]
}

@test "gather-java: .proto present -> grpc configured + a proto-audit finding" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/src/main/proto"
  printf 'syntax = "proto3";\nmessage X {}\n' > "$WORK/src/main/proto/x.proto"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.grpc <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.grpc | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.findings_by_tool.grpc[0].rule' <<<"$output")" = "grpc:proto-audit" ]
}

@test "gather-java: OpenAPI spec in a non-Spring repo -> openapi configured + finding" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/src/main/resources"
  printf 'openapi: 3.0.0\n' > "$WORK/src/main/resources/openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.openapi <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.openapi[0].rule' <<<"$output")" = "openapi:contract-audit" ]
}

@test "gather-java: OpenAPI spec in a Spring repo -> openapi deferred (not configured)" {
  printf 'plugins { java }\ndependencies { implementation "org.springframework.boot:spring-boot-starter-web" }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/src/main/resources"
  printf 'openapi: 3.0.0\n' > "$WORK/src/main/resources/openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.openapi <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool | has("openapi")' <<<"$output")" = "false" ]
}

@test "gather-java: no Renovate config -> renovate not configured" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.renovate <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool.renovate // "absent"' <<<"$output")" = "absent" ]
}

@test "gather-java: renovate.json present -> renovate configured" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  printf '{ "extends": ["config:recommended"] }\n' > "$WORK/renovate.json"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.renovate <<<"$output")" = "true" ]
  # tooling_configured always carries the renovate key.
  [ "$(jq -r '.tooling_configured | has("renovate")' <<<"$output")" = "true" ]
}

@test "gather-java: .github/renovate.json present -> renovate configured" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/.github"
  printf '{ "extends": ["config:recommended"] }\n' > "$WORK/.github/renovate.json"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.renovate <<<"$output")" = "true" ]
}

@test "gather-java: no sonar-project.properties -> sonarcloud not configured" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.sonarcloud <<<"$output")" = "false" ]
  [ "$(jq -r '.findings_by_tool.sonarcloud // "absent"' <<<"$output")" = "absent" ]
}

@test "gather-java: no JaCoCo -> coverage withheld with a JaCoCo reason" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
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

@test "parse-jacoco: per-method regions with line spans + pct (#466)" {
  PARSE="$REPO_ROOT/development/skills/maintenance/scripts/parse-jacoco.py"
  mkdir -p "$WORK/src/main/java/com/example"
  printf 'class Foo {}\n' > "$WORK/src/main/java/com/example/Foo.java"
  cat > "$WORK/report.xml" <<'EOF'
<report name="demo"><package name="com/example">
<class name="com/example/Foo" sourcefilename="Foo.java">
<method name="covered" desc="()V" line="10"><counter type="LINE" missed="0" covered="5"/></method>
<method name="uncovered" desc="()V" line="20"><counter type="LINE" missed="4" covered="0"/></method>
</class>
<sourcefile name="Foo.java"><counter type="LINE" missed="4" covered="5"/></sourcefile>
</package></report>
EOF
  out=$(cd "$WORK" && python3 "$PARSE" report.xml)
  [ "$(jq '.regions | length' <<<"$out")" = "2" ]
  # covered method: lines 10..19 (next method start - 1), pct 100
  [ "$(jq '[.regions[] | select(.name=="covered")][0] | .start_line==10 and .end_line==19 and .pct==100' <<<"$out")" = "true" ]
  # uncovered method: last method, start 20 (start + total-1 = 23), pct 0
  [ "$(jq '[.regions[] | select(.name=="uncovered")][0] | .start_line==20 and .end_line>=.start_line and .pct==0' <<<"$out")" = "true" ]
  # region file resolves to the on-disk source path
  [ "$(jq -r '.regions[0].file' <<<"$out")" = "src/main/java/com/example/Foo.java" ]
  # by_module/overall unchanged by the regions addition
  [ "$(jq '.overall' <<<"$out")" = "55.6" ]
}

@test "gather-java #694: multi-major contracts/vN -> openapi finding notes per-major wiring" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1" "$WORK/contracts/v2"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v1/openapi.yaml"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v2/openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.openapi <<<"$output")" = "true" ]
  msg="$(jq -r '.findings_by_tool.openapi[0].message' <<<"$output")"
  contains "$msg" "Multi-major layout detected (v1, v2)"
  contains "$msg" "per LIVE major"
}

@test "gather-java #694: a single major does NOT get the per-major note" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v1/openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  # assert the finding EXISTS first — otherwise `jq -r` yields the string
  # "null" and the no-note assertion below would pass vacuously
  [ "$(jq -r '.findings_by_tool.openapi | length' <<<"$output")" = "1" ]
  msg="$(jq -r '.findings_by_tool.openapi[0].message' <<<"$output")"
  contains "$msg" "contract-first"
  lacks "$msg" "Multi-major"
}

@test "gather-java #694: majors are listed NUMERICALLY (v10 after v2, not lexically)" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1" "$WORK/contracts/v2" "$WORK/contracts/v10"
  for d in v1 v2 v10; do printf 'openapi: 3.0.0\n' > "$WORK/contracts/$d/openapi.yaml"; done
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  msg="$(jq -r '.findings_by_tool.openapi[0].message' <<<"$output")"
  contains "$msg" "Multi-major layout detected (v1, v2, v10)"
}

@test "gather-java #694: a non-canonical filename under contracts/vN does NOT trigger the note" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  # a canonical spec elsewhere configures the tool (the finding must exist)...
  mkdir -p "$WORK/src/main/resources"
  printf 'openapi: 3.0.0\n' > "$WORK/src/main/resources/openapi.yaml"
  # ...while the per-major dirs hold NON-canonical filenames, so they are not
  # live majors and must not produce the per-major note
  mkdir -p "$WORK/contracts/v1" "$WORK/contracts/v2"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v1/orders.openapi.yaml"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v2/orders.openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.openapi | length' <<<"$output")" = "1" ]
  msg="$(jq -r '.findings_by_tool.openapi[0].message' <<<"$output")"
  lacks "$msg" "Multi-major"
}

@test "gather-java #708: a major past its x-sunset -> sunset-passed finding" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1" "$WORK/contracts/v2"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\ninfo:\n  title: T\n  version: "1.0.0"\n' > "$WORK/contracts/v1/openapi.yaml"
  printf 'openapi: 3.1.0\ninfo:\n  title: T\n  version: "2.0.0"\n' > "$WORK/contracts/v2/openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed")] | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed") | .component' <<<"$output")" = "contracts/v1/openapi.yaml" ]
  [ "$(jq -r '.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed") | .severity' <<<"$output")" = "MAJOR" ]
  msg="$(jq -r '.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed") | .message' <<<"$output")"
  contains "$msg" "410 Gone"
}

@test "gather-java #708: a not-yet-expired sunset produces NO sunset-passed finding" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1"
  printf 'openapi: 3.1.0\nx-sunset: "2099-12-31"\ninfo:\n  title: T\n  version: "1.0.0"\n' > "$WORK/contracts/v1/openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  # the audit finding is still there; only the sunset one must be absent
  [ "$(jq -r '[.findings_by_tool.openapi[] | select(.rule=="openapi:contract-audit")] | length' <<<"$output")" = "1" ]
  [ "$(jq -r '[.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed")] | length' <<<"$output")" = "0" ]
}

@test "gather-java #708: mixed majors — ONLY the expired one is reported (non-vacuous)" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1" "$WORK/contracts/v2"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\ninfo:\n  title: T\n  version: "1.0.0"\n' > "$WORK/contracts/v1/openapi.yaml"
  printf 'openapi: 3.1.0\nx-sunset: "2099-12-31"\ninfo:\n  title: T\n  version: "2.0.0"\n' > "$WORK/contracts/v2/openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  # proves the scan RAN (one finding), that polarity is right, and that the
  # future-dated major was excluded — none of which a bare "count == 0" shows
  [ "$(jq -r '[.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed")] | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed") | .component' <<<"$output")" = "contracts/v1/openapi.yaml" ]
}

@test "gather-java #708: sunset findings are emitted even with NO root build.gradle.kts" {
  # the sunset finding's component is the spec, not the build file — so it must
  # not be lost in repos whose build file sits deeper than the maxdepth-2 scan
  mkdir -p "$WORK/app/sub" "$WORK/contracts/v1"
  printf 'plugins { java }\n' > "$WORK/app/sub/build.gradle.kts"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\ninfo:\n  title: T\n  version: "1.0.0"\n' > "$WORK/contracts/v1/openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed")] | length' <<<"$output")" = "1" ]
}

@test "gather-java #708: two expired majors -> one finding each, with unique keys" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1" "$WORK/contracts/v2"
  printf 'openapi: 3.1.0\nx-sunset: "2020-01-01"\ninfo:\n  title: T\n  version: "1.0.0"\n' > "$WORK/contracts/v1/openapi.yaml"
  printf 'openapi: 3.1.0\nx-sunset: "2021-01-01"\ninfo:\n  title: T\n  version: "2.0.0"\n' > "$WORK/contracts/v2/openapi.yaml"
  run bash "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed")] | length' <<<"$output")" = "2" ]
  # key is the downstream dedup identity — it must differ per major
  [ "$(jq -r '[.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed") | .key] | unique | length' <<<"$output")" = "2" ]
  [ "$(jq -r '[.findings_by_tool.openapi[] | select(.rule=="openapi:sunset-passed") | .key] | index("openapi:sunset-passed:v1")' <<<"$output")" != "null" ]
}
