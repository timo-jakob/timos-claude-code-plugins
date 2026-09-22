#!/usr/bin/env bats
#
# Acceptance cases for "mint, install and probe the Claude Apps by repository
# owner" (#1683) — the `cli`-tooled test_cases[] of its story-spec, one test per
# `tc-*` id:
#
#   tc-happy-mint-org-owner               #1693
#   tc-happy-mint-personal-owner          #1694
#   tc-happy-install-org-instructions     #1695
#   tc-happy-probe-agrees-with-list       #1696
#   tc-happy-register-removes-aliases     #1697
#   tc-corner-mixed-case-owner            #1698
#   tc-corner-writer-only-owner           #1699
#   tc-corner-private-org-repo            #1700
#   tc-corner-cleanup-idempotent          #1701
#   tc-error-owner-unregistered           #1702
#   tc-error-alias-owner-no-fallthrough   #1703
#   tc-error-schema1-refused              #1704
#   tc-error-owner-unresolvable           #1705
#   tc-error-keychain-delete-fails        #1706
#
# The use case: timo-platform-builder opens PRs in an organisation-owned
# private repo (acme-corp) and in a personal repo (timo-jakob) on the same Mac,
# each minting its own owner's App with no flag. The scripts run for real
# against a stubbed gh / security / curl / openssl (tests/claude-apps-stubs.bash);
# nothing reaches GitHub or the real Keychain, so these run offline. The
# default gate's tests/claude-apps-owner.bats covers the same criteria.

bats_require_minimum_version 1.5.0
load ../../assertions
load ../../claude-apps-stubs

setup() {
  claude_apps_stubs
  write_registry
}

# A #1682-migrated registry that still carries the compatibility aliases.
add_1682_aliases() {
  jq '.alias_owner = "timo-jakob"
      | .claude_approver = .owners["timo-jakob"].claude_approver
      | .claude_maintenance = .owners["timo-jakob"].claude_maintenance' \
    "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  printf 'PEM-LEGACY-APPROVER' > "$KC_DIR/claude-plugins.claude-approver"
  printf 'PEM-LEGACY-WRITER'   > "$KC_DIR/claude-plugins.claude-maintenance"
}

@test "tc-happy-mint-org-owner: an acme-corp repo mints from owners[acme-corp] and its Keychain key" {
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "ghs_minted_by_333" ]
  grep -qx 'find-generic-password claude-plugins.acme-corp.claude-maintenance' "$STUB_DIR/security.log"
  run grep -q 'claude-plugins.claude-maintenance$' "$STUB_DIR/security.log"
  [ "$status" -eq 1 ]
}

@test "tc-happy-mint-personal-owner: a timo-jakob repo on the same machine mints the personal Approver" {
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "ghs_minted_by_111" ]
  grep -q 'signed-with PEM-timo-jakob-approver' "$STUB_DIR/openssl.log"
}

@test "tc-happy-install-org-instructions: --writer-only in an acme-corp repo speaks of the organisation" {
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$INSTALL_DRIVE" --writer-only
  [ "$status" -eq 0 ]
  contains "$output" "Choose the organisation acme-corp"
  lacks "$output" "not an org"
}

@test "tc-happy-probe-agrees-with-list: the probe and --list give acme-corp the same answer" {
  in_org_repo "acme-corp"
  [ "$(status_registered)" = "$(list_registered acme-corp)" ]
  [ "$(status_registered)" = "maintenance" ]
  run --separate-stderr bash "$PREFLIGHT" --visibility private --languages "" \
    --has-dockerfile false --iac-only true --claude-approver true </dev/null
  [ "$status" -ne 0 ]
  contains "$output" "approver: not registered"
  contains "$output" "maintenance: registered"
}

@test "tc-happy-register-removes-aliases: one register run removes the #1682 aliases, owners untouched" {
  add_1682_aliases
  local owners
  owners="$(jq -S .owners "$CONFIG")"
  run --separate-stderr zsh "$REGISTER" --list
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
  [ "$(jq -S .owners "$CONFIG")" = "$owners" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-approver" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-maintenance" ]
  [ "$(cat "$KC_DIR/claude-plugins.timo-jakob.claude-approver")" = "PEM-timo-jakob-approver" ]
}

@test "tc-corner-mixed-case-owner: owner Acme-Corp resolves owners[acme-corp] and mints its token" {
  in_org_repo "Acme-Corp"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "ghs_minted_by_333" ]
}

@test "tc-corner-writer-only-owner: acme-corp reports approver: not registered, and its writer mints" {
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 3 ]
  contains "$output" "approver: not registered"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "ghs_minted_by_333" ]
}

@test "tc-corner-private-org-repo: open-pr's mint in a private acme-corp repo is acme-corp's writer, never the personal one" {
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "ghs_minted_by_333" ]
  run grep -c 'timo-jakob' "$STUB_DIR/security.log"
  [ "$output" = "0" ]
}

@test "tc-corner-cleanup-idempotent: a second register run after the removal changes nothing" {
  add_1682_aliases
  run --separate-stderr zsh "$REGISTER" --list
  [ "$status" -eq 0 ]
  local before
  before="$(registry_sum)"
  run --separate-stderr zsh "$REGISTER" --list
  [ "$status" -eq 0 ]
  lacks "$stderr" "Could not delete"
  lacks "$stderr" "Removed the pre-#1682"
  [ "$(registry_sum)" = "$before" ]
}

@test "tc-error-owner-unregistered: globex-inc fails with its register command; open-pr falls back" {
  in_org_repo "globex-inc"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 1 ]
  contains "$stderr" "Run: $SCRIPTS/register-claude-apps.zsh --org globex-inc --apps claude-maintenance"
  contains "$(cat "$REPO_ROOT/development/skills/open-pr/SKILL.md")" '"writer App not installed"'
}

@test "tc-error-alias-owner-no-fallthrough: alias_owner lacking an Approver never reads the alias" {
  write_aliased_registry_without_owner_approver
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 1 ]
  contains "$stderr" "register-claude-apps.zsh --apps claude-approver"
  [ ! -e "$STUB_DIR/openssl.log" ]
  touch "$STUB_DIR/security.log"
  run grep -c 'claude-plugins\.claude-approver$' "$STUB_DIR/security.log"
  [ "$output" = "0" ]
}

@test "tc-error-schema1-refused: mint, install and probe refuse a schema-1 apps.json, changing nothing" {
  write_schema1_registry
  local before
  before="$(registry_sum)"
  in_personal_repo "timo-jakob"
  local script
  for script in "$MINT_APPROVER" "$MINT_WRITER"; do
    run --separate-stderr zsh "$script"
    [ "$status" -eq 1 ]
    contains "$stderr" "register-claude-apps.zsh --list"
  done
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 1 ]
  contains "$stderr" "register-claude-apps.zsh --list"
  run --separate-stderr zsh "$INSTALL_DRIVE" --writer-only
  [ "$status" -eq 1 ]
  contains "$stderr" "register-claude-apps.zsh --list"
  [ "$(registry_sum)" = "$before" ]
  [ ! -e "$STUB_DIR/security.log" ]
}

@test "tc-error-owner-unresolvable: gh repo view failing stops the mint, with no fallback owner" {
  export GH_REPO_FAIL=1
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 1 ]
  contains "$stderr" "Cannot resolve the repository owner"
  [ ! -e "$STUB_DIR/security.log" ]
}

@test "tc-error-keychain-delete-fails: a failed legacy delete warns, keeps the aliases, and a re-run completes" {
  add_1682_aliases
  local aliased
  aliased="$(cat "$CONFIG")"
  # The legacy Approver item cannot be deleted, as with a locked Keychain.
  export KC_DELETE_FAIL="claude-plugins.claude-approver"

  run --separate-stderr zsh "$REGISTER" --list
  [ "$status" -eq 0 ]
  contains "$stderr" "Could not delete the legacy Keychain item claude-plugins.claude-approver"
  [ "$(cat "$CONFIG")" = "$aliased" ]

  unset KC_DELETE_FAIL
  run --separate-stderr zsh "$REGISTER" --list
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
  [ ! -e "$KC_DIR/claude-plugins.claude-approver" ]
}
