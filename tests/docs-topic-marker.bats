#!/usr/bin/env bats
#
# The `docs` topic marker (issue #801, epic #746). The orchestrator's topic
# detection recipe is `test -d docs/architecture` — the DIRECTORY, not
# docs/architecture/c4-container.md. Tying the topic to one tool's artifact would
# fail to dispatch a repo that has docs/architecture/ but no container diagram yet
# (the narrow check is c4_drift's own `configured` gate, #793). These tests assert
# the recipe as documented in development/skills/maintenance/SKILL.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK"
}

# the exact recipe from the orchestrator's topic detection table
docs_marker() { test -d docs/architecture; }

@test "docs marker: true on a repo with a docs/architecture/ directory" {
  mkdir -p docs/architecture
  run docs_marker
  [ "$status" -eq 0 ]
}

@test "docs marker: false on a repo without docs/architecture/" {
  mkdir -p docs/how-to
  run docs_marker
  [ "$status" -ne 0 ]
}

@test "docs marker: the marker is the DIRECTORY, not the file — an empty docs/architecture/ still dispatches" {
  # docs/architecture/ exists but has NO c4-container.md yet
  mkdir -p docs/architecture
  [ ! -f docs/architecture/c4-container.md ]
  run docs_marker
  [ "$status" -eq 0 ]
}

@test "docs marker: a docs/ tree without the architecture/ subdir does not match" {
  mkdir -p docs
  printf '# docs\n' > docs/index.md
  run docs_marker
  [ "$status" -ne 0 ]
}

@test "docs marker: a plain FILE named docs/architecture does NOT match (test -d, not test -e)" {
  # the input where test -d and test -e diverge — locks the directory intent
  mkdir -p docs
  printf 'x\n' > docs/architecture
  run docs_marker
  [ "$status" -ne 0 ]
}

@test "the orchestrator's docs topic ROW describes a docs/architecture/ DIRECTORY marker (the row that drives dispatch)" {
  # anchor to the authoritative topics-table row, not just an example snippet: a
  # regression that changed the row to a file-based marker must fail here
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  row="$(grep -E '^\| `docs` \|' "$SKILL")"
  [ -n "$row" ]
  echo "$row" | grep -Fq 'docs/architecture/'
  echo "$row" | grep -Fqi 'directory'
}

@test "the orchestrator's detect recipe for docs is 'test -d docs/architecture'" {
  grep -Fq 'test -d docs/architecture' "$REPO_ROOT/development/skills/maintenance/SKILL.md"
}

@test "the orchestrator documents the directory-not-file contract explicitly (AC2)" {
  # the rationale must say the marker is NOT docs/architecture/c4-container.md
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  grep -Fq 'not' "$SKILL"
  grep -Fq 'docs/architecture/c4-container.md' "$SKILL"
}

@test "the docs topic row names its gather script (gather-docs-findings.zsh, added by #793)" {
  grep -Fq 'gather-docs-findings.zsh' "$REPO_ROOT/development/skills/maintenance/SKILL.md"
}

@test "the development-docs dispatcher SKILL.md exists" {
  [ -f "$REPO_ROOT/development-docs/skills/maintenance/SKILL.md" ]
}

@test "the dispatcher validates a v2 payload (schema_version == \"2\")" {
  grep -Fq 'schema_version == "2"' "$REPO_ROOT/development-docs/skills/maintenance/SKILL.md"
}

@test "the dispatcher's v1 dispatch table is empty (no tool rows yet)" {
  grep -Fq '(none yet)' "$REPO_ROOT/development-docs/skills/maintenance/SKILL.md"
}
