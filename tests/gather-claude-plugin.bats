#!/usr/bin/env bats
#
# Behavioral tests for gather-claude-plugin-findings.zsh — the topic gather that
# drives the five development-claude-plugin validators. Each test starts from the
# finding-free `clean` fixture, applies ONE mutation, and asserts the matching
# validator (and only it) reports the expected finding. This is the regression
# net the coverage-misreporting incident (#258/#259) showed these scripts need.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-claude-plugin-findings.zsh"
  WORK="$BATS_TEST_TMPDIR/repo"
  cp -R "$REPO_ROOT/tests/fixtures/clean" "$WORK"
}

# gather <repo> -> prints the findings JSON
gather() { zsh "$GATHER" "$1"; }
# count <repo> <tool> -> number of findings for that tool
count() { zsh "$GATHER" "$1" | jq ".findings_by_tool.$2 // [] | length"; }
# type0 <repo> <tool> -> the first finding's type for that tool
type0() { zsh "$GATHER" "$1" | jq -r ".findings_by_tool.$2[0].type"; }

@test "clean fixture: zero findings across all five validators" {
  run gather "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    (.findings_by_tool.plugin_version_check // []) == [] and
    (.findings_by_tool.skill_validation     // []) == [] and
    (.findings_by_tool.reference_checking   // []) == [] and
    (.findings_by_tool.structure_validation // []) == [] and
    (.findings_by_tool.script_quality       // []) == []'
}

@test "clean fixture: all five tools advertised as configured" {
  run bash -c "zsh '$GATHER' '$WORK' | jq -e '.tooling_configured | .plugin_version_check and .skill_validation and .reference_checking and .structure_validation and .script_quality'"
  [ "$status" -eq 0 ]
}

@test "version drift: plugin_version_check reports version_mismatch" {
  jq '.version="2.0.0"' "$WORK/development-fixture/.claude-plugin/plugin.json" > "$WORK/t"
  mv "$WORK/t" "$WORK/development-fixture/.claude-plugin/plugin.json"
  [ "$(count "$WORK" plugin_version_check)" -eq 1 ]
  [ "$(type0 "$WORK" plugin_version_check)" = "version_mismatch" ]
}

@test "broken SKILL frontmatter: skill_validation reports missing_field" {
  # drop the description line from the demo skill's frontmatter
  grep -v '^description:' "$WORK/development-fixture/skills/demo/SKILL.md" > "$WORK/t"
  mv "$WORK/t" "$WORK/development-fixture/skills/demo/SKILL.md"
  [ "$(count "$WORK" skill_validation)" -ge 1 ]
  run bash -c "zsh '$GATHER' '$WORK' | jq -e '[.findings_by_tool.skill_validation[].type] | index(\"missing_field\")'"
  [ "$status" -eq 0 ]
}

@test "orphaned reference: reference_checking reports orphan_command" {
  printf '\nSee /development-fixture:nonexistent for details.\n' >> "$WORK/development-fixture/skills/demo/SKILL.md"
  [ "$(count "$WORK" reference_checking)" -eq 1 ]
  [ "$(type0 "$WORK" reference_checking)" = "orphan_command" ]
}

@test "stray skill file: structure_validation reports skill_layout" {
  echo "stray" > "$WORK/development-fixture/skills/stray.md"
  [ "$(count "$WORK" structure_validation)" -ge 1 ]
  [ "$(type0 "$WORK" structure_validation)" = "skill_layout" ]
}

@test "zsh script named .sh: script_quality reports shebang_extension_mismatch" {
  printf '#!/usr/bin/env zsh\nprint hi\n' > "$WORK/development-fixture/scripts/mislabeled.sh"
  run bash -c "zsh '$GATHER' '$WORK' | jq -e '[.findings_by_tool.script_quality[].type] | index(\"shebang_extension_mismatch\")'"
  [ "$status" -eq 0 ]
}

@test "coverage is always null for a topic gather" {
  run bash -c "zsh '$GATHER' '$WORK' | jq -e '.coverage == null'"
  [ "$status" -eq 0 ]
}
