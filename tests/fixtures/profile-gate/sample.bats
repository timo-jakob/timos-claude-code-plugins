#!/usr/bin/env bats
#
# Fixture for tests/profile-gate.bats (#3004), not a suite file: bats runs
# tests/*.bats only, so the gate never picks it up. The first test starts
# exactly jq twice and git once through PATH; the second starts nothing. When
# SAMPLE_OUT is set, the first test writes what the tools printed there, so
# the suite can check the real tools ran through the shim.

@test "jq twice and git once" {
  run jq -n '1 + 1'
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  local name
  name=$(jq -r .name <<< '{"name":"ledger-export"}')
  [ "$name" = ledger-export ]
  local version
  version=$(git --version)
  if [ -n "${SAMPLE_OUT:-}" ]; then
    printf '%s\n' "$output" "$name" "$version" > "$SAMPLE_OUT"
  fi
}

@test "starts nothing" {
  :
}
