#!/usr/bin/env bats
#
# Behavioral tests for gather-spring-findings.zsh — the Spring topic findings
# gather. Hermetic (Gradle-free AND gh-free): assert the JSON output contract
# for the spring_api (contract-first API drift audit) tool, including the
# per-major layout awareness (#694).
#
# Scope note: this first spring gather test file covers the spring_api tool
# (#694's delivery). spring_config / spring_container / spring_boot_upgrade
# remain uncovered — not PR-2's scope.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-spring-findings.zsh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  # Hermetic: shadow `gh` so the spring_boot_upgrade tool never shells out to
  # the ambient GitHub CLI (it would otherwise run real `gh pr list` against the
  # host's auth during a unit test). A failing `gh auth status` degrades that
  # tool gracefully, which is what we want here.
  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/gh"
  chmod +x "$STUB/gh"
  PATH="$STUB:$PATH"
  SPRING_WEB='plugins { java }
dependencies { implementation("org.springframework.boot:spring-boot-starter-web") }
'
}

@test "gather-spring: a Spring web app with an OpenAPI spec -> spring_api configured + audit finding" {
  printf '%s' "$SPRING_WEB" > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/src/main/resources"
  printf 'openapi: 3.0.0\n' > "$WORK/src/main/resources/openapi.yaml"
  run zsh "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e . >/dev/null
  [ "$(jq -r .tooling_configured.spring_api <<<"$output")" = "true" ]
  [ "$(jq -r '.findings_by_tool.spring_api[0].rule' <<<"$output")" = "spring:api-audit" ]
}

@test "gather-spring: no Spring web starter -> spring_api not configured" {
  printf 'plugins { java }\n' > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/src/main/resources"
  printf 'openapi: 3.0.0\n' > "$WORK/src/main/resources/openapi.yaml"
  run zsh "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r .tooling_configured.spring_api <<<"$output")" = "false" ]
}

@test "gather-spring #694: multi-major contracts/vN -> spring_api finding notes per-major wiring" {
  printf '%s' "$SPRING_WEB" > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1" "$WORK/contracts/v2"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v1/openapi.yaml"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v2/openapi.yaml"
  run zsh "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  msg="$(jq -r '.findings_by_tool.spring_api[0].message' <<<"$output")"
  [[ "$msg" == *"Multi-major layout detected (v1, v2)"* ]]
  [[ "$msg" == *"per LIVE major"* ]]
}

@test "gather-spring #694: a single major does NOT get the per-major note" {
  printf '%s' "$SPRING_WEB" > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v1/openapi.yaml"
  run zsh "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  # assert the finding EXISTS first — otherwise `jq -r` yields the string
  # "null" and the no-note assertion below would pass vacuously
  [ "$(jq -r '.findings_by_tool.spring_api | length' <<<"$output")" = "1" ]
  msg="$(jq -r '.findings_by_tool.spring_api[0].message' <<<"$output")"
  [[ "$msg" == *"contract-first"* ]]
  [[ "$msg" != *"Multi-major"* ]]
}

@test "gather-spring #694: majors are listed NUMERICALLY (v10 after v2, not lexically)" {
  printf '%s' "$SPRING_WEB" > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1" "$WORK/contracts/v2" "$WORK/contracts/v10"
  for d in v1 v2 v10; do printf 'openapi: 3.0.0\n' > "$WORK/contracts/$d/openapi.yaml"; done
  run zsh "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  msg="$(jq -r '.findings_by_tool.spring_api[0].message' <<<"$output")"
  [[ "$msg" == *"Multi-major layout detected (v1, v2, v10)"* ]]
}

@test "gather-spring #694: a non-canonical filename under contracts/vN does NOT trigger the note" {
  printf '%s' "$SPRING_WEB" > "$WORK/build.gradle.kts"
  mkdir -p "$WORK/contracts/v1" "$WORK/contracts/v2"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v1/api-spec.yaml"
  printf 'openapi: 3.0.0\n' > "$WORK/contracts/v2/api-spec.yaml"
  run zsh "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.findings_by_tool.spring_api | length' <<<"$output")" = "1" ]
  msg="$(jq -r '.findings_by_tool.spring_api[0].message' <<<"$output")"
  [[ "$msg" != *"Multi-major"* ]]
}
