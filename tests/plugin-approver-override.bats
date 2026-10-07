#!/usr/bin/env bats
#
# plugin-approver-override.zsh (#2131): may the Claude Approver approve PRs on
# this claude-plugin repo in this session? Off unless CLAUDE_PLUGIN_APPROVER is
# exactly 1. "No Approver App" (not registered / not installed) is a supported
# way to forbid AI approvals: exit 0 and EMPTY stderr, with or without the ENV.

bats_require_minimum_version 1.5.0
load assertions
load claude-apps-stubs

setup() {
  claude_apps_stubs
  write_registry
  in_personal_repo "timo-jakob"
  git init -q "$BATS_TEST_TMPDIR/repo" && cd "$BATS_TEST_TMPDIR/repo"
  mkdir -p .claude-plugin && printf '{}' > .claude-plugin/marketplace.json
  export OVERRIDE="$REPO_ROOT/development/scripts/approval/plugin-approver-override.zsh"
  unset CLAUDE_PLUGIN_APPROVER
}

# No stub was called: no gh, Keychain or GitHub API request was made.
assert_nothing_probed() {
  [ ! -e "$STUB_DIR/gh.log" ]
  [ ! -e "$STUB_DIR/security.log" ]
  [ ! -e "$STUB_DIR/curl.log" ]
}

# A copy of the helper beside stub probes at the same relative paths, so a
# probe exit the real scripts cannot be driven to under the shared stubs is
# reachable. $1 is the owner probe's body, $2 the mint probe's.
override_with_stub_probes() {
  local root="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$root/scripts/approval" "$root/skills/bootstrap/scripts" "$root/skills/maintenance/scripts"
  cp "$OVERRIDE" "$root/scripts/approval/"
  printf '%s\n' "$1" > "$root/skills/bootstrap/scripts/claude-apps-owner.zsh"
  printf '%s\n' "$2" > "$root/skills/maintenance/scripts/mint-approver-token.zsh"
  OVERRIDE="$root/scripts/approval/plugin-approver-override.zsh"
}

@test "env unset: off/env-unset, silent, and nothing is probed" {
  run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'override=off\nreason=env-unset' ]
  [ -z "$stderr" ]
  assert_nothing_probed
}

@test "only the exact value 1 enables it: 0, true, yes, ' 1', '1 ' and empty are env-unset" {
  for v in 0 true yes " 1" "1 " ""; do
    CLAUDE_PLUGIN_APPROVER="$v" run --separate-stderr zsh "$OVERRIDE"
    [ "$status" -eq 0 ]
    [ "$output" = $'override=off\nreason=env-unset' ]
    [ -z "$stderr" ]
  done
  assert_nothing_probed
}

@test "env unset in a non-plugin repo is still env-unset: the variable is checked first" {
  rm -rf .claude-plugin
  run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'override=off\nreason=env-unset' ]
  [ -z "$stderr" ]
}

@test "a repo without the claude-plugin marker is off/not-plugin-repo, silent, unprobed" {
  rm -rf .claude-plugin
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'override=off\nreason=not-plugin-repo' ]
  [ -z "$stderr" ]
  assert_nothing_probed
}

@test "an individual plugin (plugin.json alone) counts as a plugin repo" {
  rm .claude-plugin/marketplace.json && printf '{}' > .claude-plugin/plugin.json
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = "override=on" ]
  [ -z "$stderr" ]
}

@test "run from a subdirectory of the plugin repo: the marker is found at the repo root, on" {
  mkdir sub && cd sub
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$output" = "override=on" ]
}

@test "all checks pass: on, and the installation was looked up without minting a token" {
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = "override=on" ]
  [ -z "$stderr" ]
  grep -q '/repos/timo-jakob/widget/installation' "$STUB_DIR/curl.log"
  run grep -c 'access_tokens' "$STUB_DIR/curl.log"
  [ "$output" = "0" ]
}

@test "company setup — Approver not registered: off, exit 0, empty stderr, no GitHub call" {
  in_org_repo "acme-corp"   # writer-only organisation
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'override=off\nreason=approver-not-registered' ]
  [ -z "$stderr" ]
  [ ! -e "$STUB_DIR/curl.log" ]
}

@test "company setup — Approver registered but not installed: off, exit 0, empty stderr" {
  export CURL_NO_INSTALL=1
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'override=off\nreason=approver-not-installed' ]
  [ -z "$stderr" ]
}

@test "broken setup — key missing: exit 1, approver-key-missing, the fix line relayed" {
  rm "$KC_DIR/claude-plugins.timo-jakob.claude-approver"
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 1 ]
  [ "$output" = $'override=off\nreason=approver-key-missing' ]
  contains "$stderr" "Keychain key is missing"
  contains "$stderr" "fix: "
  contains "$stderr" "install-claude-apps.zsh --verify --fix"
}

@test "broken setup — owner unresolvable (owner probe exit 4): exit 1, registry-unusable, diagnostic relayed" {
  export GH_REPO_FAIL=1
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 1 ]
  [ "$output" = $'override=off\nreason=approver-registry-unusable' ]
  local relayed="$stderr"
  run --separate-stderr zsh "$HELPER" status claude-approver
  [ "$status" -eq 4 ]
  [ "$relayed" = "$stderr" ]
}

@test "broken setup — schema-1 registry (owner probe exit 1): exit 1, registry-unusable, diagnostic relayed" {
  write_schema1_registry
  run zsh "$HELPER" status claude-approver
  [ "$status" -eq 1 ]
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 1 ]
  [ "$output" = $'override=off\nreason=approver-registry-unusable' ]
  contains "$stderr" "register-claude-apps.zsh --list"
}

@test "broken setup — GitHub unreachable (--check-installed exit 2): exit 1, lookup-failed, never not-installed" {
  export CURL_OFFLINE=1
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 1 ]
  [ "$output" = $'override=off\nreason=approver-lookup-failed' ]
  contains "$stderr" "Could not reach GitHub"
}

@test "broken setup — a rejected installation lookup (--check-installed exit 2): exit 1, lookup-failed" {
  export CURL_INSTALL_REJECTED=1
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 1 ]
  [ "$output" = $'override=off\nreason=approver-lookup-failed' ]
  contains "$stderr" "GitHub rejected the claude-approver installation lookup"
}

@test "--check-installed exit 1 (a missing prerequisite) is lookup-failed, never not-installed" {
  override_with_stub_probes 'exit 0' 'print -u2 "jq not on PATH."; exit 1'
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 1 ]
  [ "$output" = $'override=off\nreason=approver-lookup-failed' ]
  [ "$stderr" = "jq not on PATH." ]
}

@test "ARCHITECTURE.md states the ENV exception and the no-App way to forbid AI approvals" {
  grep -q 'CLAUDE_PLUGIN_APPROVER=1' "$REPO_ROOT/ARCHITECTURE.md"
  grep -q 'development/scripts/approval/plugin-approver-override.zsh' "$REPO_ROOT/ARCHITECTURE.md"
  grep -q 'not installing the Approver App is the supported way to forbid AI approvals' "$REPO_ROOT/ARCHITECTURE.md"
}
