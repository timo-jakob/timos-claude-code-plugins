#!/usr/bin/env bats
#
# Behavioral tests for check-marketplace-sync.zsh — the plugin.json <-> marketplace.json
# version-sync gate (the CI check). The script derives its repo root from its own
# location (${0:A:h:h}), so each test runs a COPY of it placed inside the fixture
# tree, where its root resolves to the fixture.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$BATS_TEST_TMPDIR/repo"
  cp -R "$REPO_ROOT/tests/fixtures/clean" "$WORK"
  mkdir -p "$WORK/scripts"
  cp "$REPO_ROOT/scripts/check-marketplace-sync.zsh" "$WORK/scripts/check-marketplace-sync.zsh"
  SYNC="$WORK/scripts/check-marketplace-sync.zsh"
}

@test "in-sync fixture: exits 0" {
  run zsh "$SYNC"
  [ "$status" -eq 0 ]
}

@test "version mismatch: exits 1" {
  jq '.version="2.0.0"' "$WORK/development-fixture/.claude-plugin/plugin.json" > "$WORK/t"
  mv "$WORK/t" "$WORK/development-fixture/.claude-plugin/plugin.json"
  run zsh "$SYNC"
  [ "$status" -eq 1 ]
}

@test "plugin.json present but missing from marketplace: exits 1" {
  jq '.plugins = []' "$WORK/.claude-plugin/marketplace.json" > "$WORK/t"
  mv "$WORK/t" "$WORK/.claude-plugin/marketplace.json"
  run zsh "$SYNC"
  [ "$status" -eq 1 ]
}

@test "marketplace lists a plugin with no plugin.json: exits 1" {
  jq '.plugins += [{"name":"ghost","description":"x","version":"1.0.0","source":"./ghost","category":"development"}]' \
    "$WORK/.claude-plugin/marketplace.json" > "$WORK/t"
  mv "$WORK/t" "$WORK/.claude-plugin/marketplace.json"
  run zsh "$SYNC"
  [ "$status" -eq 1 ]
}
