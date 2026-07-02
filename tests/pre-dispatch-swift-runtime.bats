#!/usr/bin/env bats
#
# Behavioral tests for development-swift/scripts/pre-dispatch-runtime-upgrade.zsh
# (#447) — the runtime_availability pre-dispatch hook for swift-runtime-upgrade.
# Hermetic paths only: arg validation and the not-found JSON contract (an
# absurd target version can't match any locally installed toolchain). The
# found/install paths need a real toolchain/swiftly and are validated manually.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development-swift/scripts/pre-dispatch-runtime-upgrade.zsh"
}

@test "pre-dispatch-swift: missing args -> usage error, exit 2" {
  run zsh "$S" detect
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "pre-dispatch-swift: unknown subcommand -> usage error, exit 2" {
  run zsh "$S" frobnicate 6.1
  [ "$status" -eq 2 ]
}

@test "pre-dispatch-swift: detect absurd version -> has_toolchain false JSON, exit 1" {
  run zsh "$S" detect 999.99
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.has_toolchain == false and .found_at == null' >/dev/null
}

@test "pre-dispatch-swift: detect output is a single valid JSON line" {
  run zsh "$S" detect 999.99
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "1" ]
  echo "$output" | jq -e . >/dev/null
}
