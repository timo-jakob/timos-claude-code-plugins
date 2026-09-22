#!/usr/bin/env bats
#
# #1683: every Claude Apps consumer picks the App pair by the OWNER of the
# repository it runs in — the mint scripts, install-claude-apps.zsh, and
# bootstrap's probes (claude-apps-owner.zsh status, which the --claude-approver
# auto-detection runs, and preflight.sh's Step 4.5 check). One machine holds a
# personal pair (timo-jakob) and a writer-only organisation (acme-corp); the
# scripts run for real against stubbed gh / security / curl / openssl.

bats_require_minimum_version 1.5.0
load assertions
load claude-apps-stubs

setup() {
  claude_apps_stubs
}

# --- AC1: the owner picks the pair, on one machine, with no flag ---------------

@test "mint: an organisation repo mints the organisation's App, a personal repo the personal one" {
  write_registry

  in_org_repo "Acme-Corp"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "ghs_minted_by_333" ]
  grep -q 'signed-with PEM-acme-corp-maintenance' "$STUB_DIR/openssl.log"
  grep -q '^https://api.github.com/repos/Acme-Corp/widget/installation iss=333$' "$STUB_DIR/curl.log"

  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "ghs_minted_by_111" ]
  grep -q 'signed-with PEM-timo-jakob-approver' "$STUB_DIR/openssl.log"

  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 0 ]
  [ "$(cat "$output")" = "ghs_minted_by_222" ]

  # Only owner-qualified services were read; never a pre-#1682 item.
  grep -qx 'find-generic-password claude-plugins.acme-corp.claude-maintenance' "$STUB_DIR/security.log"
  grep -qx 'find-generic-password claude-plugins.timo-jakob.claude-approver' "$STUB_DIR/security.log"
  run grep -E ' claude-plugins\.claude-(approver|maintenance)$' "$STUB_DIR/security.log"
  [ "$status" -eq 1 ]
}

@test "mint: --stdout still prints the raw token of the owner's App" {
  write_registry
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$MINT_WRITER" --stdout
  [ "$status" -eq 0 ]
  [ "$output" = "ghs_minted_by_333" ]
}

# --- AC2: an owner with no pair fails with the exact register command ----------

@test "mint: an unregistered organisation fails naming register --org <slug> --apps <app>" {
  write_registry
  in_org_repo "Globex-Inc"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 1 ]
  contains "$stderr" "Claude Maintenance is not registered for globex-inc (organization)"
  contains "$stderr" "register-claude-apps.zsh --org globex-inc --apps claude-maintenance"
  [ ! -e "$STUB_DIR/curl.log" ]
  # Nothing of another owner's was read.
  [ ! -e "$STUB_DIR/security.log" ]
}

@test "mint: your own personal owner lacking an App fails naming register --apps <app>, without --org" {
  write_registry
  jq 'del(.owners["timo-jakob"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 1 ]
  contains "$stderr" "Run: $SCRIPTS/register-claude-apps.zsh --apps claude-approver"
  lacks "$stderr" "--org"
}

@test "mint: a personal repo owned by another account says only that account can register, never a command" {
  write_registry
  in_personal_repo "someone-else"
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 1 ]
  contains "$stderr" "someone-else is a personal account other than yours; only someone-else can register its Apps"
  lacks "$stderr" "register-claude-apps.zsh"
}

@test "mint: a writer-only organisation has no Approver to mint" {
  write_registry
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 1 ]
  contains "$stderr" "register-claude-apps.zsh --org acme-corp --apps claude-approver"
  [ ! -e "$STUB_DIR/curl.log" ]
}

@test "mint: a registered App whose Keychain key is gone names key regeneration, never a re-registration" {
  write_registry
  rm "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 1 ]
  contains "$stderr" "service claude-plugins.acme-corp.claude-maintenance"
  contains "$stderr" "$SCRIPTS/install-claude-apps.zsh --verify --fix"
  lacks "$stderr" "--reset"
  lacks "$stderr" "register-claude-apps.zsh"

  # The same for a personal owner — and still no --org anywhere.
  rm "$KC_DIR/claude-plugins.timo-jakob.claude-approver"
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 1 ]
  contains "$stderr" "install-claude-apps.zsh --verify --fix"
  lacks "$stderr" "--org"
}

@test "mint: a Keychain that cannot be read says unlock it — not missing, no reset, no re-register" {
  write_registry
  export KC_READ_FAIL="claude-plugins.acme-corp.claude-maintenance"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 1 ]
  contains "$stderr" "Could not read the Keychain item claude-plugins.acme-corp.claude-maintenance (security exit 51)"
  lacks "$stderr" "not in the Keychain"
  lacks "$stderr" "--verify --fix"
  [ ! -e "$STUB_DIR/curl.log" ]
}

@test "mint: a multi-line PEM, which security -w returns hex-encoded, is signed as the PEM" {
  write_registry
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nACME\n-----END RSA PRIVATE KEY-----' \
    > "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 0 ]
  grep -qx 'signed-with -----BEGIN RSA PRIVATE KEY-----ACME-----END RSA PRIVATE KEY-----' "$STUB_DIR/openssl.log"
}

@test "mint: a non-numeric App ID is refused before anything is signed" {
  write_registry
  jq '.owners["acme-corp"].claude_maintenance.app_id = "abc"' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 1 ]
  contains "$stderr" "is not numeric: abc"
  [ ! -e "$STUB_DIR/curl.log" ]
}

@test "mint: an App not installed on the repo, or a refused token, exits 2 naming the repo" {
  write_registry
  in_org_repo "Acme-Corp"
  export CURL_NO_INSTALL=1
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 2 ]
  contains "$stderr" "claude-maintenance App is not installed on Acme-Corp/widget"

  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 2 ]
  contains "$stderr" "claude-approver App is not installed on timo-jakob/widget"

  unset CURL_NO_INSTALL
  export CURL_NO_TOKEN=1
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 2 ]
  contains "$stderr" "Failed to mint installation token"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 2 ]
  contains "$stderr" "Failed to mint installation token"
}

# Both mint scripts, both failure switches: open-pr and bootstrap key their
# "not installed" fallback on the mint's text, so neither script may print it
# for an outage or a rejected key.
mint_lookup_failure() {  # <mint script> <app> <switch>
  export "$3"=1
  run --separate-stderr zsh "$1"
  unset "$3"
  [ "$status" -eq 2 ]
  lacks "$stderr" "is not installed"
  case "$3" in
    CURL_OFFLINE)
      contains "$stderr" "Could not reach GitHub to look up the $2 installation on timo-jakob/widget" ;;
    CURL_INSTALL_REJECTED)
      contains "$stderr" "GitHub rejected the $2 installation lookup on timo-jakob/widget"
      contains "$stderr" "install-claude-apps.zsh --verify --fix" ;;
  esac
}

@test "mint: only GitHub's 404 reads as 'not installed' — an outage or a rejected key says so instead" {
  write_registry
  in_personal_repo "timo-jakob"
  mint_lookup_failure "$MINT_WRITER"   claude-maintenance CURL_OFFLINE
  mint_lookup_failure "$MINT_WRITER"   claude-maintenance CURL_INSTALL_REJECTED
  mint_lookup_failure "$MINT_APPROVER" claude-approver    CURL_OFFLINE
  mint_lookup_failure "$MINT_APPROVER" claude-approver    CURL_INSTALL_REJECTED
}

@test "mint: the default output is a mode-600 token file" {
  write_registry
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 0 ]
  [ -n "$(find "$output" -perm 0600)" ]
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$MINT_APPROVER" --stdout
  [ "$status" -eq 0 ]
  [ "$output" = "ghs_minted_by_111" ]
}

@test "open-pr: a failed mint is its documented 'writer App not installed' branch, relaying the register command" {
  local skill="$REPO_ROOT/development/skills/open-pr/SKILL.md"
  contains "$(cat "$skill")" 'this is the **"writer App not installed"** branch'
  contains "$(cat "$skill")" 'register-claude-apps.zsh [--org <slug>] --apps claude-maintenance'
  contains "$(cat "$skill")" '`/tmp/mint.err` verbatim'
  # The mint the skill runs is the owner-resolving script.
  contains "$(cat "$skill")" 'maintenance/scripts/mint-maintenance-token.zsh" 2>/tmp/mint.err'
}

# --- AC3: an alias is never read, even for alias_owner -------------------------

@test "mint: alias_owner's entry lacking an App fails with the register command; the alias is never read" {
  write_aliased_registry_without_owner_approver
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 1 ]
  contains "$stderr" "register-claude-apps.zsh --apps claude-approver"
  [ ! -e "$STUB_DIR/curl.log" ]
  # The top-level alias's App ID (999) was never signed with, and the legacy
  # Keychain item was never read.
  [ ! -e "$STUB_DIR/openssl.log" ]
  touch "$STUB_DIR/security.log"
  run grep -c 'claude-plugins\.claude-approver$' "$STUB_DIR/security.log"
  [ "$output" = "0" ]
  [ -e "$KC_DIR/claude-plugins.claude-approver" ]
}

# --- owner resolution -----------------------------------------------------------

@test "mint: an owner that cannot be resolved stops with that reason and gh's own, reading nothing" {
  write_registry
  export GH_REPO_FAIL=1
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 1 ]
  contains "$stderr" "Cannot resolve the repository owner"
  contains "$stderr" "gh said: gh: not a git repository"
  [ ! -e "$STUB_DIR/security.log" ]
  [ ! -e "$STUB_DIR/curl.log" ]

  # The probe reports it as its own exit code, 4 — not 1 (unreadable registry).
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 4 ]
}

# A PATH holding only the named tools — never the host's /usr/bin, where an
# ubuntu runner ships a real gh (and jq).
only_tools_path() {
  local dir="$BATS_TEST_TMPDIR/only-$1" t
  mkdir -p "$dir"
  shift
  for t in zsh mktemp rm "$@"; do ln -sf "$(command -v "$t")" "$dir/$t"; done
  echo "$dir"
}

@test "helper: gh missing from PATH is named, as an unresolvable owner" {
  write_registry
  run --separate-stderr env PATH="$(only_tools_path nogh jq)" zsh "$HELPER" status
  [ "$status" -eq 4 ]
  contains "$stderr" "gh CLI not on PATH"
}

@test "helper: jq missing from PATH is exit 1, naming jq" {
  write_registry
  run --separate-stderr env PATH="$(only_tools_path nojq gh)" zsh "$HELPER" status
  [ "$status" -eq 1 ]
  contains "$stderr" "jq not on PATH (brew install jq)"
}

@test "helper: a mixed-case owner resolves to its lower-cased registry key" {
  write_registry
  in_org_repo "ACME-Corp"
  run --separate-stderr zsh "$HELPER" status claude-maintenance
  [ "$status" -eq 0 ]
  [ "$output" = $'owner: acme-corp (organization)\nmaintenance: registered' ]
}

@test "helper: a registered owner's recorded scope wins over the live lookup" {
  write_registry
  # An org-owned repo whose owner the registry records as an organisation is
  # an organisation even if gh reported otherwise.
  in_personal_repo "acme-corp"
  run --separate-stderr zsh "$HELPER" status claude-approver
  [ "$status" -eq 3 ]
  contains "$output" "owner: acme-corp (organization)"
  contains "$output" "register-args: --org acme-corp --apps claude-approver"
}

@test "helper: an apps.json that is not a JSON object is refused as such, not as schema 1" {
  mkdir -p "$HOME/.config/claude-plugins"
  echo '[]' > "$CONFIG"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 1 ]
  contains "$stderr" "is not a JSON object"
  lacks "$stderr" "schema 1"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 1 ]
  contains "$stderr" "is not a JSON object"
}

@test "helper: a registered App whose key is gone is 'key missing' with a fix line, not a register-args entry" {
  write_registry
  rm "$KC_DIR/claude-plugins.timo-jakob.claude-maintenance"
  jq 'del(.owners["timo-jakob"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 3 ]
  [ "$output" = "owner: timo-jakob (user)
approver: not registered
maintenance: key missing
register-args: --apps claude-approver
fix: $SCRIPTS/install-claude-apps.zsh --verify --fix" ]
}

@test "helper: a Keychain that cannot be read exits 1, never 'not registered'" {
  write_registry
  export KC_READ_FAIL="claude-plugins.acme-corp.claude-maintenance"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$HELPER" status claude-maintenance
  [ "$status" -eq 1 ]
  contains "$stderr" "Could not read the Keychain item claude-plugins.acme-corp.claude-maintenance"
  lacks "$output" "register-args"
}

@test "helper: your own personal repo gets register-args even when gh spells your login in capitals" {
  write_registry
  jq 'del(.owners["timo-jakob"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  export GH_LOGIN="Timo-Jakob"
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 3 ]
  contains "$output" "register-args: --apps claude-approver"
  lacks "$output" "note:"
}

@test "helper: a gh login that cannot be looked up still gets register-args (register then reports gh)" {
  write_registry
  jq 'del(.owners["timo-jakob"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  export GH_USER_FAIL=1
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 3 ]
  contains "$output" "register-args: --apps claude-approver"
  lacks "$output" "note:"
}

@test "helper: an empty gh login still gets register-args" {
  write_registry
  jq 'del(.owners["timo-jakob"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  export GH_LOGIN=""
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 3 ]
  contains "$output" "register-args: --apps claude-approver"
  lacks "$output" "note:"
}

@test "helper: an empty Keychain item is 'key missing', never 'registered'" {
  write_registry
  : > "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$HELPER" status claude-maintenance
  [ "$status" -eq 3 ]
  contains "$output" "maintenance: key missing"
}

@test "helper: an entry with a non-numeric App ID is not 'registered' — status exits 1 as the mint would" {
  write_registry
  jq '.owners["acme-corp"].claude_maintenance.app_id = "abc"' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$HELPER" status claude-maintenance
  [ "$status" -eq 1 ]
  contains "$stderr" "is not numeric: abc"
}

@test "helper: a personal repo owned by another account gets a note, no register-args" {
  write_registry
  in_personal_repo "someone-else"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 3 ]
  contains "$output" "note: someone-else is a personal account other than yours"
  lacks "$output" "register-args"
}

@test "helper: --help prints usage and exits 0" {
  run --separate-stderr zsh "$HELPER" --help
  [ "$status" -eq 0 ]
  contains "$output" "claude-apps-owner.zsh status"
}

@test "helper: usage errors exit 2" {
  run --separate-stderr zsh "$HELPER"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$HELPER" status claude-reviewer
  [ "$status" -eq 2 ]
  contains "$stderr" "Unknown app: claude-reviewer"
}

@test "helper: sourcing it defines the functions and runs nothing" {
  run zsh -c 'source "$HELPER"; whence -w claude_apps_load'
  [ "$status" -eq 0 ]
  [ "$output" = "claude_apps_load: function" ]
  [ ! -e "$STUB_DIR/gh.log" ]
}

# --- AC4: install-claude-apps.zsh targets the owner's pair ---------------------

@test "install: --writer-only in an organisation repo gives organisation instructions and its App" {
  write_registry
  in_org_repo "Acme-Corp"
  run --separate-stderr zsh "$INSTALL_DRIVE" --writer-only
  [ "$status" -eq 0 ]
  contains "$output" "Choose the organisation Acme-Corp (the owner of Acme-Corp/widget)."
  lacks "$output" "not an org"
  [ "$(cat "$STUB_DIR/browser.log")" = "https://github.com/apps/claude-maintenance-acme-corp/installations/new" ]
}

@test "install: a personal repo gives personal-account instructions and installs the personal pair" {
  write_registry
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$INSTALL_DRIVE"
  [ "$status" -eq 0 ]
  contains "$output" "Choose your personal account timo-jakob (the owner of timo-jakob/widget)."
  lacks "$output" "not an org"
  [ "$(cat "$STUB_DIR/browser.log")" = $'https://github.com/apps/claude-approver-timo-jakob/installations/new\nhttps://github.com/apps/claude-maintenance-timo-jakob/installations/new' ]
}

@test "install: a full install for a writer-only organisation stops naming the Approver's register command" {
  write_registry
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$INSTALL_DRIVE"
  [ "$status" -eq 1 ]
  contains "$stderr" "register-claude-apps.zsh --org acme-corp --apps claude-approver"
  [ ! -e "$STUB_DIR/browser.log" ]
}

@test "install: the slug / client_id backfill writes the owner's entry, never a top-level key" {
  write_registry
  jq '.owners["acme-corp"].claude_maintenance.slug = ""' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$INSTALL_DRIVE" --writer-only
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners["acme-corp"].claude_maintenance.slug' "$CONFIG")" = "slug-from-api-333" ]
  [ "$(jq -r '.owners["acme-corp"].claude_maintenance.client_id' "$CONFIG")" = "Iv1.api333" ]
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
  [ -n "$(find "$CONFIG" -perm 0600)" ]
  # The lookup signed with the organisation's key.
  grep -q 'signed-with PEM-acme-corp-maintenance' "$STUB_DIR/openssl.log"
  [ "$(cat "$STUB_DIR/browser.log")" = "https://github.com/apps/slug-from-api-333/installations/new" ]
}

@test "install: an organisation App whose slug cannot be resolved points at the organisation's settings" {
  write_registry
  jq '.owners["acme-corp"].claude_maintenance.slug = ""' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  export CURL_NO_APP=1
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$INSTALL_DRIVE" --writer-only
  [ "$status" -eq 0 ]
  contains "$output" "Find the App at https://github.com/organizations/acme-corp/settings/apps and click Install."
}

@test "install: a personal App whose slug cannot be resolved points at your own settings" {
  write_registry
  jq '.owners["timo-jakob"].claude_maintenance.slug = ""' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  export CURL_NO_APP=1
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$INSTALL_DRIVE" --writer-only
  [ "$status" -eq 0 ]
  contains "$output" "Find the App at https://github.com/settings/apps and click Install."
  lacks "$output" "organizations/"
}

@test "install: a registered App whose key is gone stops before any browser install, naming the key fix" {
  write_registry
  rm "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$INSTALL_DRIVE" --writer-only
  [ "$status" -eq 1 ]
  contains "$stderr" "install-claude-apps.zsh --verify --fix"
  [ ! -e "$STUB_DIR/browser.log" ]
}

@test "install: --verify counts a locked Keychain as a problem and exits 1" {
  write_registry
  export KC_READ_FAIL="claude-plugins.timo-jakob.claude-maintenance"
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$INSTALL_DRIVE" --verify
  [ "$status" -eq 1 ]
  contains "$output" "1 problem(s) found"
}

@test "install: --verify with a locked Keychain says unlock it and never regenerates the key" {
  write_registry
  export KC_READ_FAIL="claude-plugins.acme-corp.claude-maintenance"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$INSTALL_DRIVE" --verify --fix
  [ "$status" -eq 0 ]
  contains "$stderr" "could not read the Keychain item claude-plugins.acme-corp.claude-maintenance (security exit 51) — unlock the Keychain"
  lacks "$stderr" "no private key in the Keychain"
  touch "$STUB_DIR/browser.log"
  run grep -c 'settings/apps' "$STUB_DIR/browser.log"
  [ "$output" = "0" ]
}

@test "install: --verify checks the owner's pair and names the owner's register command" {
  write_registry
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$INSTALL_DRIVE" --verify
  [ "$status" -eq 1 ]
  contains "$output" "owner acme-corp, organization"
  contains "$stderr" "Claude Approver: not registered for acme-corp — Run: $SCRIPTS/register-claude-apps.zsh --org acme-corp --apps claude-approver"
  contains "$output" "Claude Maintenance: Keychain key authenticates as App ID 333."
  contains "$output" "Claude Maintenance: workflows:write present"
}

@test "install: --verify --fix regenerates an organisation key from the organisation's settings page" {
  write_registry
  rm "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
  mkdir -p "$HOME/Downloads"
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nNEWORG\n-----END RSA PRIVATE KEY-----\n' \
    > "$HOME/Downloads/claude-maintenance-acme-corp.2026-09-22.private-key.pem"
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$INSTALL_DRIVE" --verify --fix
  # Exit 0: the Approver is missing for acme-corp, but --fix reports every
  # problem it found and addressed without failing the run.
  [ "$status" -eq 0 ]
  contains "$output" "new key validated and stored in the Keychain"
  [ "$(head -1 "$STUB_DIR/browser.log")" = "https://github.com/organizations/acme-corp/settings/apps/claude-maintenance-acme-corp" ]
  grep -q NEWORG "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
  [ ! -e "$KC_DIR/claude-plugins.claude-maintenance" ]
}

@test "install: --verify --fix regenerates a personal key from your own settings page" {
  write_registry
  rm "$KC_DIR/claude-plugins.timo-jakob.claude-maintenance"
  mkdir -p "$HOME/Downloads"
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nNEWME\n-----END RSA PRIVATE KEY-----\n' \
    > "$HOME/Downloads/claude-maintenance-timo-jakob.2026-09-22.private-key.pem"
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$INSTALL_DRIVE" --verify --fix
  [ "$status" -eq 0 ]
  [ "$(head -1 "$STUB_DIR/browser.log")" = "https://github.com/settings/apps/claude-maintenance-timo-jakob" ]
  grep -q NEWME "$KC_DIR/claude-plugins.timo-jakob.claude-maintenance"
}

@test "install: the old personal-only instruction is gone from the script" {
  run grep -n "not an org" "$INSTALL"
  [ "$status" -eq 1 ]
}

# --- AC5: the probes agree with --list -----------------------------------------

@test "probe: status agrees with --list for an organisation, a personal owner and a missing key" {
  write_registry

  in_org_repo "acme-corp"
  [ "$(status_registered)" = "maintenance" ]
  [ "$(list_registered acme-corp)" = "maintenance" ]

  in_personal_repo "timo-jakob"
  [ "$(status_registered)" = "approver,maintenance" ]
  [ "$(list_registered timo-jakob)" = "approver,maintenance" ]

  # A key --list reports missing is not `registered` to the probe either (it
  # reports `key missing`).
  rm "$KC_DIR/claude-plugins.timo-jakob.claude-approver"
  [ "$(status_registered)" = "maintenance" ]
  [ "$(list_registered timo-jakob)" = "maintenance" ]
}

@test "probe: a writer-only owner reports 'approver: not registered' and the args to register it" {
  write_registry
  in_org_repo "acme-corp"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 3 ]
  [ "$output" = $'owner: acme-corp (organization)\napprover: not registered\nmaintenance: registered\nregister-args: --org acme-corp --apps claude-approver' ]
}

@test "probe: a fresh machine (no apps.json) is simply not registered" {
  in_personal_repo "timo-jakob"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 3 ]
  contains "$output" "register-args: --apps claude-approver,claude-maintenance"
  [ ! -e "$CONFIG" ]
}

@test "preflight: Step 4.5 reports the owner's pair and offers exactly the missing registration" {
  write_registry

  in_personal_repo "timo-jakob"
  run --separate-stderr bash "$PREFLIGHT" --visibility public --languages "" \
    --has-dockerfile false --iac-only true --claude-approver true </dev/null
  [ "$status" -eq 0 ]
  contains "$output" "Both Claude Apps registered locally for timo-jakob (user)"

  in_org_repo "acme-corp"
  run --separate-stderr bash "$PREFLIGHT" --visibility public --languages "" \
    --has-dockerfile false --iac-only true --claude-approver true </dev/null
  [ "$status" -ne 0 ]
  contains "$output" "approver: not registered"
  contains "$output" "maintenance: registered"
  contains "$stderr" "register-claude-apps.zsh --org acme-corp --apps claude-approver"
}

@test "preflight: an accepted registration runs register with exactly the owner's missing Apps, then re-probes" {
  write_registry
  in_org_repo "acme-corp"
  export REGISTER_WORKS=1
  preflight_with_stub_register
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/register.log")" = "--org acme-corp --apps claude-approver" ]
  contains "$output" "Both Claude Apps registered locally for this repo's owner"
}

@test "preflight: a register run that leaves the owner unregistered is not reported ready" {
  write_registry
  in_org_repo "acme-corp"
  preflight_with_stub_register
  [ "$status" -ne 0 ]
  [ "$(cat "$STUB_DIR/register.log")" = "--org acme-corp --apps claude-approver" ]
  contains "$stderr" "still not registered for this repo's owner"
  lacks "$output" "Preflight complete"
}

@test "preflight: a lost key stops it even when another App could be registered" {
  write_registry
  jq 'del(.owners["timo-jakob"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  rm "$KC_DIR/claude-plugins.timo-jakob.claude-maintenance"
  in_personal_repo "timo-jakob"
  preflight_with_stub_register
  [ "$status" -eq 1 ]
  contains "$output" "approver: not registered"
  contains "$output" "maintenance: key missing"
  contains "$stderr" "the fix:/note: line says how"
  [ ! -e "$STUB_DIR/register.log" ]
}

@test "preflight: a lost key, someone else's personal repo and an unresolvable owner stop without registering" {
  write_registry
  rm "$KC_DIR/claude-plugins.timo-jakob.claude-approver"
  in_personal_repo "timo-jakob"
  preflight_with_stub_register
  [ "$status" -ne 0 ]
  # (the helper names itself by its resolved path, so match the tail)
  contains "$output" "/pf/install-claude-apps.zsh --verify --fix"
  contains "$output" "fix: "

  in_personal_repo "someone-else"
  preflight_with_stub_register
  [ "$status" -ne 0 ]
  contains "$output" "note: someone-else is a personal account other than yours"

  export GH_REPO_FAIL=1
  preflight_with_stub_register
  [ "$status" -ne 0 ]
  contains "$stderr" "needs the repo's GitHub owner"
  [ ! -e "$STUB_DIR/register.log" ]
}

@test "probe: bootstrap's auto-detection and the maintenance probes run the shared helper" {
  local boot="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  local maint="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  contains "$(cat "$boot")" '"<skill-base-dir>/scripts/claude-apps-owner.zsh" status claude-approver claude-maintenance'
  contains "$(cat "$maint")" '"<skill-base-dir>/../bootstrap/scripts/claude-apps-owner.zsh" \'
  # An owner with no GitHub remote yet resolves the default, it does not stop.
  contains "$(cat "$boot")" '#   4 → false  (the repo has no GitHub owner yet'
  # No shipped skill still reads a top-level key of apps.json.
  run grep -rnE "jq -e '\.claude_(approver|maintenance)'" "$REPO_ROOT/development" "$REPO_ROOT"/development-*
  [ "$status" -eq 1 ]
}

# --- AC6: a schema-1 apps.json is refused, never migrated ----------------------

@test "schema 1: mint, install and the probes refuse naming register --list, changing nothing" {
  write_schema1_registry
  local before
  before="$(registry_sum)"
  in_personal_repo "timo-jakob"

  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 1 ]
  contains "$stderr" "register-claude-apps.zsh --list"
  run --separate-stderr zsh "$MINT_WRITER"
  [ "$status" -eq 1 ]
  contains "$stderr" "register-claude-apps.zsh --list"
  run --separate-stderr zsh "$INSTALL_DRIVE" --writer-only
  [ "$status" -ne 0 ]
  contains "$stderr" "register-claude-apps.zsh --list"
  run --separate-stderr zsh "$HELPER" status
  [ "$status" -eq 1 ]
  contains "$stderr" "register-claude-apps.zsh --list"
  run --separate-stderr bash "$PREFLIGHT" --visibility public --languages "" \
    --has-dockerfile false --iac-only true --claude-approver true </dev/null
  [ "$status" -ne 0 ]
  contains "$stderr" "register-claude-apps.zsh --list"

  [ "$(registry_sum)" = "$before" ]
  [ ! -e "$CONFIG.v1.bak" ]
  # The refusal comes before any Keychain call at all — not one add or delete.
  [ ! -e "$STUB_DIR/security.log" ]
}

# --- AC8: no shipped file still promises #1683 -----------------------------------

@test "docs: no shipped file outside docs/superpowers/ and tests/fixtures/ says #1683 will do something" {
  # Needles are split so this file does not match itself.
  local n1="until #""1683" n2="#""1683 removes" n3="until #""1683 moves"
  run bash -c 'cd "$1" && git ls-files -z | grep -zvE "^(docs/superpowers|tests/fixtures)/" \
    | xargs -0 grep -il -e "$2" -e "$3" -e "$4" --' _ "$REPO_ROOT" "$n1" "$n2" "$n3"
  # Judged on the listing alone: xargs' exit on "no match" is 1 on BSD, 123 on GNU.
  [ -z "$output" ]
}

@test "docs: no shipped file still names a pre-#1682 Keychain item except the page that says it is removed" {
  run bash -c 'cd "$1" && git ls-files -z | grep -zvE "^(docs/superpowers|tests)/" \
    | xargs -0 grep -lE "claude-plugins\.claude-(approver|maintenance)\b" --' _ "$REPO_ROOT"
  [ "$output" = "development/skills/bootstrap/docs/CLAUDE-APPS.md" ]
}
