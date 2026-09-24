#!/usr/bin/env bats
#
# The three size-preflight.zsh thresholds (#1437), each straddled in BOTH
# directions — one case just under, one just over — and nothing else: exactly
# six cases, so a reader can see that every trigger fires independently and
# that its boundary sits where the script says. Everything else about the
# script (exit taxonomy, ownership, ties, the #1435 corner) lives in
# size-preflight-contract.bats; the numbers restated in prose are pinned by
# size-preflight-threshold-consistency.bats.
#
# Each "just over" case adds ONE file to its "just under" twin, so the only
# difference between a pass and a stop is the threshold under test.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/size-preflight.zsh"
  MANIFEST="$REPO_ROOT/.claude-plugin/marketplace.json"
  INV="$BATS_TEST_TMPDIR/inventory.json"
}

# Write an inventory from the given paths.
inventory() {
  printf '%s\n' "$@" | jq -R . | jq -s '{files: .}' > "$INV"
}

# N files, all owned by the development plugin, none under bootstrap.
n_development_files() {
  local i
  for (( i = 1; i <= $1; i++ )); do
    printf 'development/skills/resolve-issue/scripts/f%02d.zsh\n' "$i"
  done
}

preflight() {
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$MANIFEST"
}


@test "files: 20 owned files in one plugin pass" {
  # shellcheck disable=SC2046
  inventory $(n_development_files 20)
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verdict == "pass" and .files == 20 and .triggers == []' >/dev/null
}

@test "files: 21 owned files in one plugin stop on the files trigger" {
  # shellcheck disable=SC2046
  inventory $(n_development_files 21)
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.verdict == "stop" and .files == 21 and .triggers == ["files"]' >/dev/null
}

@test "plugin: an inventory wholly inside one plugin passes" {
  inventory development/skills/resolve-issue/SKILL.md \
    development/skills/resolve-issue/scripts/size-preflight.zsh \
    development/.claude-plugin/plugin.json
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verdict == "pass" and .plugins == 1 and .primary_plugin == "development"' >/dev/null
}

@test "plugin: one file owned by a second plugin stops on the plugin trigger" {
  inventory development/skills/resolve-issue/SKILL.md \
    development/skills/resolve-issue/scripts/size-preflight.zsh \
    development/.claude-plugin/plugin.json \
    development-claude-plugin/agents/claude-plugin-prose-logic.md
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.verdict == "stop" and .triggers == ["plugin"] and .plugins == 2 and .primary_plugin == "development"' >/dev/null
}

@test "bootstrap-straddle: templates plus the bootstrap skill and its version bump pass" {
  inventory development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl \
    development/skills/bootstrap/SKILL.md \
    development/.claude-plugin/plugin.json
  preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verdict == "pass" and .triggers == []' >/dev/null
}

@test "bootstrap-straddle: templates plus one owned file outside the bootstrap skill stop" {
  inventory development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl \
    development/skills/bootstrap/SKILL.md \
    development/.claude-plugin/plugin.json \
    development/skills/resolve-issue/SKILL.md
  preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.verdict == "stop" and .triggers == ["bootstrap-straddle"]' >/dev/null
}
