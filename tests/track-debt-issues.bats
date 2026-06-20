#!/usr/bin/env bats
#
# Argument-validation tests for track-debt-issues.zsh — the maintenance issue
# tracker (#58, #384). The script's main path needs `gh` (network + auth), so
# these cover only the validation paths that exit BEFORE any gh call: required
# args, missing files, unknown flags, and that the new --run-ref flag (#384) is
# recognized rather than rejected as unknown.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TRACK="$REPO_ROOT/development/skills/maintenance/scripts/track-debt-issues.zsh"
}

@test "track-debt-issues: --findings is required (exit 2)" {
  run zsh "$TRACK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--findings is required"* ]]
}

@test "track-debt-issues: nonexistent findings file (exit 1)" {
  run zsh "$TRACK" --findings "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"findings file not found"* ]]
}

@test "track-debt-issues: unknown arg (exit 2)" {
  run zsh "$TRACK" --bogus x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}

@test "track-debt-issues: --run-ref is recognized, not treated as unknown (#384)" {
  # With --run-ref parsed and --findings still absent, it must fail on the
  # missing --findings — NOT complain about an unknown arg.
  run zsh "$TRACK" --run-ref "2026-06-20 (branch test)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--findings is required"* ]]
  [[ "$output" != *"unknown arg"* ]]
}
