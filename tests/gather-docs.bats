#!/usr/bin/env bats
#
# Behavioral tests for gather-docs-findings.zsh (epic #746 child (d), #793): the
# docs topic gather. v1 emits one tool — c4_drift — a mechanical comparison of the
# containers docs/architecture/c4-container.md DECLARES (#790's parser) against the
# containers detect-stack DETECTS (#799), on the v2 gather contract
# (tooling_configured / findings_by_tool / coverage / notes).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-docs-findings.zsh"
  W="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$W"
  (cd "$W" && git init -q)
}
# declare a container set in the repo's c4-container.md
declare_containers() {
  mkdir -p "$W/docs/architecture"
  {
    printf '```mermaid\nC4Container\n    Container_Boundary(b, "S") {\n'
    local a
    for a in "$@"; do printf '        Container(%s, "%s", "Python 3.12")\n' "$a" "$a"; done
    printf '    }\n```\n'
  } > "$W/docs/architecture/c4-container.md"
}
# make detection find a "<name>" container via a Dockerfile at <name>/Dockerfile
detect_dockerfile() { mkdir -p "$W/$1"; printf 'FROM x\n' > "$W/$1/Dockerfile"; }
gather() { zsh "$GATHER" "$W"; }

@test "declared-but-not-detected: a diagram container detection can't find → exactly one declared_not_detected finding (AC1)" {
  declare_containers api worker
  detect_dockerfile api                 # detects 'api', not 'worker'
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.c4_drift | length')" = "1" ]   # exact total, no spurious other direction
  [ "$(echo "$output" | jq -r '[.findings_by_tool.c4_drift[]|select(.type=="declared_not_detected")]|length')" = "1" ]
  echo "$output" | jq -e '.findings_by_tool.c4_drift[] | select(.type=="declared_not_detected") | .message | contains("worker")' >/dev/null
}

@test "detected-but-not-declared: a real container absent from the diagram → exactly one detected_not_declared finding (AC2)" {
  declare_containers api
  detect_dockerfile api
  detect_dockerfile worker              # detected, but not in the diagram
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.c4_drift | length')" = "1" ]
  [ "$(echo "$output" | jq -r '[.findings_by_tool.c4_drift[]|select(.type=="detected_not_declared")]|length')" = "1" ]
  echo "$output" | jq -e '.findings_by_tool.c4_drift[] | select(.type=="detected_not_declared") | .message | contains("worker")' >/dev/null
}

@test "both directions at once: exactly one of each type fires together (co-occurrence contract)" {
  declare_containers api worker         # 'worker' is declared but not detected
  detect_dockerfile api
  detect_dockerfile spare               # 'spare' is detected but not declared
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_tool.c4_drift | length')" = "2" ]
  echo "$output" | jq -e '[.findings_by_tool.c4_drift[]|select(.type=="declared_not_detected" and (.message|contains("worker")))]|length == 1' >/dev/null
  echo "$output" | jq -e '[.findings_by_tool.c4_drift[]|select(.type=="detected_not_declared" and (.message|contains("spare")))]|length == 1' >/dev/null
}

@test "matching sets → zero c4_drift findings (AC3)" {
  declare_containers api
  detect_dockerfile api
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.findings_by_tool.c4_drift')" = "[]" ]
}

@test "the join folds case and non-identifier chars (declared web_app matches detected 'web-app')" {
  declare_containers web_app
  detect_dockerfile web-app
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.findings_by_tool.c4_drift')" = "[]" ]
}

@test "inconclusive detection → NO declared_not_detected findings, plus a suppression note (AC4)" {
  declare_containers worker
  mkdir -p "$W/.github/workflows"
  printf 'jobs:\n  b:\n    steps:\n      - uses: docker/build-push-action@v5\n' > "$W/.github/workflows/ci.yml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.findings_by_tool.c4_drift[]|select(.type=="declared_not_detected")]|length')" = "0" ]
  echo "$output" | jq -e '[.notes[] | select(test("suppress"))] | length >= 1' >/dev/null
}

@test "docs/architecture/ present → tooling_configured.c4_drift true, findings_by_tool carries the key (AC5)" {
  declare_containers api
  detect_dockerfile api
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.c4_drift')" = "true" ]
  echo "$output" | jq -e '.findings_by_tool | has("c4_drift")' >/dev/null
}

@test "docs/architecture/ absent → tooling_configured false, no c4_drift key, a note, exit 0 (AC6)" {
  printf '[project]\nname="x"\n' > "$W/pyproject.toml"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.c4_drift')" = "false" ]
  [ "$(echo "$output" | jq -r '.findings_by_tool | has("c4_drift")')" = "false" ]
  echo "$output" | jq -e '.notes | length >= 1' >/dev/null
}

@test "a malformed/unparseable c4-container.md degrades to [] + a note, payload valid, exit 0 (AC7)" {
  mkdir -p "$W/docs/architecture"
  printf '```mermaid\nC4Container\n    Container(x, Bad Label, "Y")\n```\n' > "$W/docs/architecture/c4-container.md"
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.findings_by_tool.c4_drift')" = "[]" ]
  echo "$output" | jq -e '.notes | length >= 1' >/dev/null
  # still a well-formed v2 gather payload
  echo "$output" | jq -e 'has("tooling_configured") and has("findings_by_tool") and has("coverage") and has("notes")' >/dev/null
}

@test "every c4_drift finding carries the convention keys id/tool/type/severity/message/fix/files (AC9)" {
  declare_containers api worker
  detect_dockerfile api
  detect_dockerfile spare               # an extra detected container too
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings_by_tool.c4_drift | length >= 1 and all(.[]; has("id") and has("tool") and has("type") and has("severity") and has("message") and has("fix") and has("files"))' >/dev/null
  echo "$output" | jq -e 'all(.findings_by_tool.c4_drift[]; .tool == "c4_drift")' >/dev/null
}

@test "the gather calls #790's parser and does not re-implement the declared parse" {
  grep -Fq 'extract-declared-containers.zsh' "$GATHER"
  # no C4 entry-regex of its own
  run grep -nE 'Container[[:space:]]*\\\(\[' "$GATHER"
  [ "$status" -ne 0 ]
}

@test "the clean fixture (a plugin repo, no containers) is a valid no-drift baseline" {
  run zsh "$GATHER" "$REPO_ROOT/tests/fixtures/clean"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tooling_configured.c4_drift')" = "true" ]
  [ "$(echo "$output" | jq -c '.findings_by_tool.c4_drift')" = "[]" ]
}

@test "coverage is always null (a topic has no app test suite)" {
  declare_containers api
  detect_dockerfile api
  run gather
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.coverage')" = "null" ]
}

@test "a non-directory repo argument is a usage error (exit 2)" {
  run zsh "$GATHER" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
}

@test "every c4_drift finding's severity is MINOR" {
  declare_containers api
  detect_dockerfile api
  detect_dockerfile spare
  run gather
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.findings_by_tool.c4_drift[]; .severity == "MINOR")' >/dev/null
}
