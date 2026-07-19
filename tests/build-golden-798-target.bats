#!/usr/bin/env bats
#
# Behavioral tests for build-golden-798-target.zsh (#808, epic #810) — the
# script that materializes the #798 golden fixture as a throwaway target repo
# for /development-claude-plugin:test. The contract that matters:
#   - the last stdout line is a path to a git repo holding the pre-#798
#     SKILL.md snapshot at its original repo-relative path;
#   - the snapshot really is the defective version (the terminal case with no
#     failure branch), proven by the marker phrase absent from the fixed file;
#   - argument abuse and running outside a git worktree fail with typed codes
#     (2 usage, 3 runtime), never a half-built target on stdout.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development-claude-plugin/skills/review/scripts/build-golden-798-target.zsh"
}

teardown() {
  # Each passing run creates one mktemp dir; remove the one the test captured.
  if [ -n "${TARGET:-}" ] && [ -d "$(dirname "$TARGET")" ]; then
    rm -rf "$(dirname "$TARGET")"
  fi
}

@test "builds a git repo whose last stdout line is the target path" {
  run "$S"
  [ "$status" -eq 0 ]
  TARGET="$(echo "$output" | tail -1)"
  [ -d "$TARGET/.git" ]
}

@test "target holds the snapshot at its original repo-relative path" {
  run "$S"
  [ "$status" -eq 0 ]
  TARGET="$(echo "$output" | tail -1)"
  [ -f "$TARGET/development/skills/resolve-issue/SKILL.md" ]
}

@test "snapshot is the defective pre-#798 version, not today's fixed one" {
  run "$S"
  [ "$status" -eq 0 ]
  TARGET="$(echo "$output" | tail -1)"
  # The pre-fix terminal case licenses E4+E5 straight from "zero open
  # children"; the fixed version replaced this phrasing entirely.
  grep -q 'skip straight to \*\*E4\*\*' "$TARGET/development/skills/resolve-issue/SKILL.md"
  # And the fix's positive-evidence rule must NOT be present.
  run ! grep -q 'Positive-evidence rule' "$TARGET/development/skills/resolve-issue/SKILL.md"
}

@test "target repo has exactly one commit containing the fixture" {
  run "$S"
  [ "$status" -eq 0 ]
  TARGET="$(echo "$output" | tail -1)"
  [ "$(git -C "$TARGET" rev-list --count HEAD)" -eq 1 ]
  [ -z "$(git -C "$TARGET" status --porcelain)" ]
}

@test "rejects arguments with usage error (exit 2)" {
  run "$S" --unexpected
  [ "$status" -eq 2 ]
}

@test "fails typed (exit 3) outside a git worktree" {
  cd "$BATS_TEST_TMPDIR"
  run env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" "$S"
  [ "$status" -eq 3 ]
}
