#!/usr/bin/env bats
#
# #1682: register-claude-apps.zsh keeps one registry entry per owner — a
# personal login or an organisation — so both pairs coexist on one machine,
# registers any subset of the two Apps (--apps), registers under an
# organisation (--org) only for its owners, and migrates a schema-1 apps.json
# in place. Since #1683 the compatibility aliases #1682 kept are gone (the top-level
# keys, alias_owner and the legacy Keychain items claude-plugins.<app>):
# registration creates none, and the next run removes any a machine carries.
#
# The script's `main` is driven for real against stubbed `gh`, `security`,
# `uname` and `openssl` on PATH; the two interactive steps — opening the
# browser and waiting for GitHub's redirect — are replaced by functions after
# sourcing, which record the submitted page instead of opening it.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export S="$REPO_ROOT/development/skills/bootstrap/scripts/register-claude-apps.zsh"

  export HOME="$BATS_TEST_TMPDIR/home"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  export KC_DIR="$BATS_TEST_TMPDIR/keychain"
  mkdir -p "$HOME" "$STUB_DIR" "$KC_DIR" "$BATS_TEST_TMPDIR/bin"
  CONFIG="$HOME/.config/claude-plugins/apps.json"

  export GH_LOGIN="octo-dev"
  export GH_ORG_ROLE="admin"
  # The redirect the stubbed listener answers with, and the conversion reply.
  export LISTEN_STATE="teststate"
  export LISTEN_CODE="CODE"
  export CONVERSION="ok"

  local bin="$BATS_TEST_TMPDIR/bin"

  # Only the exact membership URL for acme-corp + octo-dev is answered; any
  # other gh call is a failure the test sees.
  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/gh.log"
case "$*" in
  "api user --jq .login") echo "$GH_LOGIN" ;;
  "api -X POST /app-manifests/CODE/conversions")
    [ "$CONVERSION" = fail ] && { echo 'gh: Unprocessable (HTTP 422)' >&2; exit 1; }
    n=$(( $(cat "$STUB_DIR/gh.count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$STUB_DIR/gh.count"
    if [ "$CONVERSION" = no-pem ]; then
      printf '{"id": %d, "slug": "stub-app-%d"}\n' "$((1000 + n))" "$n"
    else
      printf '{"id": %d, "client_id": "Iv1.c%d", "slug": "stub-app-%d", "pem": "-----BEGIN RSA PRIVATE KEY-----\\nKEY%d\\n-----END RSA PRIVATE KEY-----\\n"}\n' \
        "$((1000 + n))" "$n" "$n" "$n"
    fi
    ;;
  "api orgs/acme-corp/memberships/octo-dev")
    case "$GH_ORG_ROLE" in
      admin)         echo '{"role":"admin","state":"active"}' ;;
      pending-admin) echo '{"role":"admin","state":"pending"}' ;;
      member)        echo '{"role":"member","state":"active"}' ;;
      404)           echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      500)           echo 'gh: Server Error (HTTP 500)' >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF

  # A file-per-service Keychain: $KC_DIR/<service> holds the password. Like
  # the real `security -w`, a value containing a newline is read back as hex.
  # KC_READ_FAIL=<service> makes reading that one item fail as a locked
  # Keychain would (exit 51, not 44's "not found"); KC_DELETE_FAIL and
  # KC_ADD_FAIL=<service> do the same to deleting / storing it, and
  # KC_READ_FAIL_AFTER=<n> fails every item's reads after its first n — as a
  # Keychain that locks mid-run. Every call is logged to security.log.
  cat > "$bin/security" <<'EOF'
#!/usr/bin/env bash
cmd="$1"; shift
svc=""; pw=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift 2 ;;
    -a) shift 2 ;;
    -w) if [ "$cmd" = add-generic-password ]; then pw="$2"; shift 2; else shift; fi ;;
    *)  shift ;;
  esac
done
f="$KC_DIR/$svc"
echo "$cmd $svc" >> "$STUB_DIR/security.log"
case "$cmd" in
  add-generic-password)
    [ "${KC_ADD_FAIL:-}" = "$svc" ] && exit 51
    printf '%s' "$pw" > "$f" ;;
  find-generic-password)
    [ "${KC_READ_FAIL:-}" = "$svc" ] && exit 51
    if [ -n "${KC_READ_FAIL_AFTER:-}" ]; then
      c="$STUB_DIR/reads.$svc"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
      [ "$n" -gt "$KC_READ_FAIL_AFTER" ] && exit 51
    fi
    [ -f "$f" ] || exit 44
    if grep -q . <(tail -n +2 "$f"); then od -An -tx1 "$f" | tr -d ' \n'; echo; else cat "$f"; echo; fi
    ;;
  delete-generic-password)
    [ "${KC_DELETE_FAIL:-}" = "$svc" ] && exit 51
    [ -f "$f" ] || exit 44; rm -f "$f" ;;
esac
EOF

  printf '#!/usr/bin/env bash\necho Darwin\n' > "$bin/uname"
  printf '#!/usr/bin/env bash\necho teststate\n' > "$bin/openssl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/python3"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/curl"
  chmod +x "$bin"/*
  export PATH="$bin:$PATH"

  DRIVE="$BATS_TEST_TMPDIR/drive.zsh"
  cat > "$DRIVE" <<'EOF'
source "$S"
# Record the page instead of opening it; answer the redirect with the state
# and code the test chose (openssl's stub mints "teststate").
open_browser() {
  n=$(( $(cat "$STUB_DIR/browser.count" 2>/dev/null || echo 0) + 1 ))
  print -- "$n" > "$STUB_DIR/browser.count"
  cp "$1" "$STUB_DIR/page-$n.html"
}
run_redirect_listener() { print -r -- "${LISTEN_STATE}"$'\t'"${LISTEN_CODE}" }
main "$@"
EOF
}

reg() { run zsh "$DRIVE" "$@"; }

browser_opens() { cat "$STUB_DIR/browser.count" 2>/dev/null || echo 0; }

# Checksum every file the registry lives in — path and content per file.
state_sum() {
  (cd "$BATS_TEST_TMPDIR" && find home keychain -type f -exec cksum {} + | LC_ALL=C sort)
}

write_legacy_config() {
  mkdir -p "$HOME/.config/claude-plugins"
  cat > "$CONFIG" <<'EOF'
{
  "schema_version": 1,
  "claude_approver": {"app_id": 111, "client_id": "", "slug": "claude-approver-octo-dev",
                      "owner_login": "octo-dev", "owner_scope": "user", "registered_at": "2026-06-06T12:34:56Z"},
  "claude_maintenance": {"app_id": 222, "client_id": "", "slug": "claude-maintenance-octo-dev",
                         "owner_login": "octo-dev", "owner_scope": "user", "registered_at": "2026-06-06T12:35:42Z"}
}
EOF
  printf 'LEGACY-APPROVER-PEM' > "$KC_DIR/claude-plugins.claude-approver"
  printf 'LEGACY-WRITER-PEM'   > "$KC_DIR/claude-plugins.claude-maintenance"
}

# --- AC1: a personal pair and an organisation pair coexist ---------------------

@test "owners: --org registers a second pair beside the personal one; neither overwrites the other" {
  reg
  [ "$status" -eq 0 ]
  reg --org acme-corp
  [ "$status" -eq 0 ]

  # apps.json: two owners, each with both Apps, distinct IDs.
  [ "$(jq -r .schema_version "$CONFIG")" = "2" ]
  [ "$(jq -r '.owners | keys | join(",")' "$CONFIG")" = "acme-corp,octo-dev" ]
  [ "$(jq -r '.owners["octo-dev"].owner_scope' "$CONFIG")" = "user" ]
  [ "$(jq -r '.owners["acme-corp"].owner_scope' "$CONFIG")" = "organization" ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.app_id' "$CONFIG")" = "1001" ]
  [ "$(jq -r '.owners["octo-dev"].claude_maintenance.app_id' "$CONFIG")" = "1002" ]
  [ "$(jq -r '.owners["acme-corp"].claude_approver.app_id' "$CONFIG")" = "1003" ]
  [ "$(jq -r '.owners["acme-corp"].claude_maintenance.app_id' "$CONFIG")" = "1004" ]
  [ "$(jq -r '.owners["acme-corp"].claude_approver.slug' "$CONFIG")" = "stub-app-3" ]
  [ "$(jq -r '.owners["acme-corp"].claude_approver.client_id' "$CONFIG")" = "Iv1.c3" ]

  # Keychain: owner-qualified services, each holding its own key.
  grep -q KEY1 "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  grep -q KEY2 "$KC_DIR/claude-plugins.octo-dev.claude-maintenance"
  grep -q KEY3 "$KC_DIR/claude-plugins.acme-corp.claude-approver"
  grep -q KEY4 "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"

  # No compatibility alias is created (#1683): no top-level key, no legacy item.
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
  [ ! -e "$KC_DIR/claude-plugins.claude-approver" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-maintenance" ]

  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "octo-dev (user)"
  contains "$output" "acme-corp (organization)"
  contains "$output" "slug=stub-app-3"
  [ "$(grep -c 'key=present' <<<"$output")" -eq 4 ]
}

@test "owners: --org posts the manifest to the organisation's settings page, named <app>-<slug>" {
  reg --org acme-corp --apps claude-approver
  [ "$status" -eq 0 ]
  grep -q 'action="https://github.com/organizations/acme-corp/settings/apps/new?state=teststate"' \
    "$STUB_DIR/page-1.html"
  grep -q '"name": *"claude-approver-acme-corp"' "$STUB_DIR/page-1.html"
  grep -qx 'api orgs/acme-corp/memberships/octo-dev' "$STUB_DIR/gh.log"
  [ "$(jq -r '.owners["acme-corp"].claude_approver.owner_login' "$CONFIG")" = "acme-corp" ]
  [ "$(jq -r '.owners["acme-corp"].claude_approver.owner_scope' "$CONFIG")" = "organization" ]
  # No registration creates a compatibility alias.
  [ "$(jq -r 'has("alias_owner") or has("claude_approver")' "$CONFIG")" = "false" ]
}

@test "owners: a personal registration posts to the personal page and never checks an org membership" {
  export GH_ORG_ROLE="404"
  reg --apps claude-approver
  [ "$status" -eq 0 ]
  grep -q 'action="https://github.com/settings/apps/new?state=teststate"' "$STUB_DIR/page-1.html"
  grep -q '"name": *"claude-approver-octo-dev"' "$STUB_DIR/page-1.html"
  lacks "$(cat "$STUB_DIR/gh.log")" "memberships"
}

@test "owners: --org is case-insensitive — Acme-Corp and acme-corp are one owner" {
  reg --org acme-corp --apps claude-approver
  [ "$status" -eq 0 ]
  reg --org Acme-Corp --apps claude-approver
  [ "$status" -eq 0 ]
  [ "$(browser_opens)" -eq 1 ]
  [ "$(jq -r '.owners | keys | join(",")' "$CONFIG")" = "acme-corp" ]
}

@test "owners: a personal login is case-insensitive too" {
  export GH_LOGIN="Octo-Dev"
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners | keys | join(",")' "$CONFIG")" = "octo-dev" ]
}

@test "owners: registration walks only the Apps the owner is missing" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  reg
  [ "$status" -eq 0 ]
  [ "$(browser_opens)" -eq 2 ]
  [ "$(jq -r '.owners["octo-dev"].claude_maintenance.app_id' "$CONFIG")" = "1001" ]
}

@test "owners: --apps names an App once, however often it is listed" {
  reg --apps claude-maintenance,claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(browser_opens)" -eq 1 ]
}

@test "owners: a new registry is created 0700/0600" {
  reg --list
  [ "$status" -eq 0 ]
  [ -n "$(find "$HOME/.config/claude-plugins" -maxdepth 0 -perm 0700)" ]
  [ -n "$(find "$CONFIG" -perm 0600)" ]
}

@test "owners: --print-manifest --org names the App after the organisation" {
  reg --print-manifest claude-maintenance --org acme-corp
  [ "$status" -eq 0 ]
  [ "$(jq -r .name <<<"$output")" = "claude-maintenance-acme-corp" ]
}

@test "owners: re-running registration for an owner whose Apps exist opens no browser" {
  reg --org acme-corp
  [ "$status" -eq 0 ]
  [ "$(browser_opens)" -eq 2 ]
  reg --org acme-corp
  [ "$status" -eq 0 ]
  [ "$(browser_opens)" -eq 2 ]
  contains "$output" "already registered"
}

@test "owners: an owner whose Keychain key is gone lists key=missing and is sent to key regeneration, not re-registered" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  rm "$KC_DIR/claude-plugins.octo-dev.claude-maintenance"

  reg --list
  contains "$output" "key=missing"
  # The App still exists on GitHub: a second manifest flow would collide with
  # its own name (#1683), so the run stops and names the key fix.
  reg --apps claude-maintenance
  [ "$status" -ne 0 ]
  contains "$output" "install-claude-apps.zsh --verify --fix"
  [ "$(browser_opens)" -eq 1 ]
  [ "$(jq -r '.owners["octo-dev"].claude_maintenance.app_id' "$CONFIG")" = "1001" ]
}

# --- AC2: register a subset ----------------------------------------------------

@test "owners: --apps claude-maintenance registers the writer only; --list shows one App" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(browser_opens)" -eq 1 ]
  [ "$(jq -r '.owners["octo-dev"] | del(.owner_scope) | keys | join(",")' "$CONFIG")" = "claude_maintenance" ]
  [ ! -e "$KC_DIR/claude-plugins.octo-dev.claude-approver" ]
  # No top-level key is invented for a writer-only owner.
  [ "$(jq -r 'has("claude_approver")' "$CONFIG")" = "false" ]

  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "octo-dev (user)"
  contains "$output" "Claude Maintenance"
  lacks "$output" "Claude Approver"
  [ "$(grep -c 'id=' <<<"$output")" -eq 1 ]
}

@test "owners: --apps rejects an unknown App, and an empty list, before anything is registered" {
  reg --apps claude-maintenance,claude-reviewer
  [ "$status" -ne 0 ]
  contains "$output" "unknown app 'claude-reviewer'"
  reg --apps ,
  [ "$status" -ne 0 ]
  contains "$output" "requires at least one app"
  [ ! -e "$STUB_DIR/browser.count" ]
}

@test "owners: flags outside their mode are refused" {
  reg --list --apps claude-approver
  [ "$status" -ne 0 ]
  contains "$output" "applies only to registration"
  reg --reset claude-approver --app-id 1
  [ "$status" -ne 0 ]
  contains "$output" "apply only to --import"
  reg --list --reset claude-approver
  [ "$status" -ne 0 ]
  contains "$output" "Only one of --list"
  reg --list --org acme-corp
  [ "$status" -ne 0 ]
  contains "$output" "--list shows every owner"
}

# --- AC3: migration of a schema-1 apps.json ------------------------------------

@test "owners: a schema-1 apps.json is migrated in place under its owner_login, backup kept" {
  write_legacy_config
  cp "$CONFIG" "$BATS_TEST_TMPDIR/original.json"

  reg --list
  [ "$status" -eq 0 ]

  cmp -s "$CONFIG.v1.bak" "$BATS_TEST_TMPDIR/original.json"
  [ "$(jq -r .schema_version "$CONFIG")" = "2" ]
  [ "$(jq -r '.owners | keys | join(",")' "$CONFIG")" = "octo-dev" ]
  [ "$(jq -r '.owners["octo-dev"].owner_scope' "$CONFIG")" = "user" ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.app_id' "$CONFIG")" = "111" ]
  [ "$(jq -r '.owners["octo-dev"].claude_maintenance.app_id' "$CONFIG")" = "222" ]
  # Keys copied to the owner-qualified services; the legacy items, the
  # top-level keys and alias_owner are gone — the migration creates no alias.
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "LEGACY-APPROVER-PEM" ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-maintenance")" = "LEGACY-WRITER-PEM" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-approver" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-maintenance" ]
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
  contains "$output" "octo-dev (user)"
  [ "$(grep -c 'key=present' <<<"$output")" -eq 2 ]
}

@test "owners: a second invocation after migration changes nothing" {
  write_legacy_config
  reg --list
  [ "$status" -eq 0 ]
  local before
  before="$(state_sum)"

  reg --list
  [ "$status" -eq 0 ]
  [ "$(state_sum)" = "$before" ]
  lacks "$output" "Migrating"
}

@test "owners: migration copies a multi-line PEM as the PEM, not the hex security -w returns" {
  write_legacy_config
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nLEGACY\n-----END RSA PRIVATE KEY-----' \
    > "$KC_DIR/claude-plugins.claude-approver"
  cp "$KC_DIR/claude-plugins.claude-approver" "$BATS_TEST_TMPDIR/legacy.pem"
  reg --list
  [ "$status" -eq 0 ]
  # The legacy item itself is removed on the same run (#1683), so compare the
  # copy with what it held.
  cmp -s "$BATS_TEST_TMPDIR/legacy.pem" "$KC_DIR/claude-plugins.octo-dev.claude-approver"
}

@test "owners: migration files a legacy pair under its RECORDED owner, not the current login" {
  write_legacy_config
  export GH_LOGIN="someone-else"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners | keys | join(",")' "$CONFIG")" = "octo-dev" ]
}

@test "owners: migration files an entry with no owner_login under the current gh login" {
  write_legacy_config
  jq 'del(.claude_approver.owner_login)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners | keys | join(",")' "$CONFIG")" = "octo-dev" ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.owner_login' "$CONFIG")" = "octo-dev" ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "LEGACY-APPROVER-PEM" ]
}

@test "owners: migration lower-cases a recorded owner_login" {
  write_legacy_config
  jq '.claude_approver.owner_login = "Octo-Dev"' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  # `ls`, not `-e`: a case-insensitive filesystem would match either spelling.
  [ "$(ls "$KC_DIR" | grep -c '^claude-plugins\.octo-dev\.claude-approver$')" -eq 1 ]
  [ "$(jq -c '(.owners | keys)' "$CONFIG")" = '["octo-dev"]' ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.owner_login' "$CONFIG")" = "octo-dev" ]
}

@test "owners: migration of a writer-only legacy file files just that App" {
  write_legacy_config
  jq 'del(.claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -c '[(.owners | keys), (.owners["octo-dev"] | del(.owner_scope) | keys)]' "$CONFIG")" = '[["octo-dev"],["claude_maintenance"]]' ]
}

@test "owners: migration keeps a recorded organisation scope" {
  write_legacy_config
  jq '.claude_approver.owner_login = "acme-corp" | .claude_approver.owner_scope = "organization"' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.owners["acme-corp"].owner_scope, .owners["octo-dev"].owner_scope]' "$CONFIG")" = '["organization","user"]' ]
  [ "$(cat "$KC_DIR/claude-plugins.acme-corp.claude-approver")" = "LEGACY-APPROVER-PEM" ]
}

@test "owners: migration keeps an existing owner-qualified key and an existing backup" {
  write_legacy_config
  printf 'NEWER' > "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  printf 'EARLIER-BACKUP' > "$CONFIG.v1.bak"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "NEWER" ]
  [ "$(cat "$CONFIG.v1.bak")" = "EARLIER-BACKUP" ]
}

@test "owners: a legacy key that cannot be READ stops the migration, leaving schema 1 for a retry" {
  write_legacy_config
  export KC_READ_FAIL="claude-plugins.claude-maintenance"
  reg --list
  [ "$status" -ne 0 ]
  contains "$output" "Could not read the Keychain key claude-plugins.claude-maintenance"
  [ "$(jq -r 'has("owners")' "$CONFIG")" = "false" ]

  unset KC_READ_FAIL
  reg --list
  [ "$status" -eq 0 ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-maintenance")" = "LEGACY-WRITER-PEM" ]
}

@test "owners: a legacy key that is simply absent is reported and the entry filed without it" {
  write_legacy_config
  rm "$KC_DIR/claude-plugins.claude-maintenance"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "No Keychain key for Claude Maintenance"
  contains "$output" "key=missing"
}

@test "owners: an apps.json that is not a JSON object is refused, not migrated" {
  mkdir -p "$HOME/.config/claude-plugins"
  echo '[]' > "$CONFIG"
  reg --list
  [ "$status" -ne 0 ]
  contains "$output" "not a JSON object"
  [ ! -e "$CONFIG.v1.bak" ]
}

@test "owners: --print-manifest stays valid JSON on the run that migrates" {
  write_legacy_config
  run bash -c 'zsh "$1" --print-manifest claude-approver 2>/dev/null' _ "$DRIVE"
  [ "$status" -eq 0 ]
  [ "$(jq -r .name <<<"$output")" = "claude-approver-octo-dev" ]
}

@test "owners: --print-manifest stays valid JSON when the migration reports an absent key" {
  write_legacy_config
  rm "$KC_DIR/claude-plugins.claude-maintenance"
  run bash -c 'zsh "$1" --print-manifest claude-approver 2>/dev/null' _ "$DRIVE"
  [ "$status" -eq 0 ]
  [ "$(jq -r .name <<<"$output")" = "claude-approver-octo-dev" ]
}

@test "owners: migration runs on registration too, and the registration then skips the migrated pair" {
  write_legacy_config
  reg
  [ "$status" -eq 0 ]
  [ -e "$CONFIG.v1.bak" ]
  [ ! -e "$STUB_DIR/browser.count" ]
  contains "$output" "already registered"
}

# --- AC4: --org without owner rights stops before the browser ------------------

@test "owners: --org as a non-owner member stops with the requirement, before the browser" {
  export GH_ORG_ROLE="member"
  reg --org acme-corp
  [ "$status" -ne 0 ]
  contains "$output" "Registering Apps under it needs organisation-owner rights"
  contains "$output" "role: member"
  [ ! -e "$STUB_DIR/browser.count" ]
  lacks "$(cat "$STUB_DIR/gh.log")" "app-manifests"
  [ "$(jq -r '.owners | length' "$CONFIG")" = "0" ]
}

@test "owners: --org as a pending admin stops before the browser" {
  export GH_ORG_ROLE="pending-admin"
  reg --org acme-corp
  [ "$status" -ne 0 ]
  contains "$output" "state: pending"
  [ ! -e "$STUB_DIR/browser.count" ]
}

@test "owners: --org as a non-member stops with the requirement, before the browser" {
  export GH_ORG_ROLE="404"
  reg --org acme-corp
  [ "$status" -ne 0 ]
  contains "$output" "not a member of organisation 'acme-corp'"
  contains "$output" "Registering Apps under it needs organisation-owner rights"
  [ ! -e "$STUB_DIR/browser.count" ]
}

@test "owners: --org whose membership cannot be checked warns and continues" {
  export GH_ORG_ROLE="500"
  reg --org acme-corp --apps claude-maintenance
  [ "$status" -eq 0 ]
  contains "$output" "Could not verify your membership of 'acme-corp'"
  [ "$(browser_opens)" -eq 1 ]
}

@test "owners: --org with gh unauthenticated stops before the browser" {
  export GH_LOGIN=""
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/gh.log"
exit 1
EOF
  reg --org acme-corp
  [ "$status" -ne 0 ]
  contains "$output" "gh CLI not authenticated"
  [ ! -e "$STUB_DIR/browser.count" ]
}

@test "owners: --org rejects a value that is not an organisation slug" {
  reg --org 'acme/../x'
  [ "$status" -ne 0 ]
  contains "$output" "organisation slug"
  [ ! -e "$STUB_DIR/browser.count" ]
}

# --- the manifest flow's failure paths ------------------------------------------

@test "owners: a redirect whose state does not match is refused and nothing is stored" {
  export LISTEN_STATE="forged"
  reg --apps claude-maintenance
  [ "$status" -ne 0 ]
  contains "$output" "State mismatch"
  lacks "$(cat "$STUB_DIR/gh.log")" "app-manifests"
  [ "$(jq -r '.owners | length' "$CONFIG")" = "0" ]
}

@test "owners: a failed or pem-less conversion stores nothing" {
  export CONVERSION="fail"
  reg --apps claude-maintenance
  [ "$status" -ne 0 ]
  contains "$output" "Code exchange failed"
  export CONVERSION="no-pem"
  reg --apps claude-maintenance
  [ "$status" -ne 0 ]
  contains "$output" "missing 'pem'"
  [ "$(jq -r '.owners | length' "$CONFIG")" = "0" ]
  [ -z "$(ls "$KC_DIR")" ]
}

# --- per-owner --import / --reset ----------------------------------------------

@test "owners: --import --org files the key under the organisation, leaving the personal owner alone" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nORGKEY\n-----END RSA PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/k.pem"

  reg --import claude-maintenance --app-id 4242 --pem "$BATS_TEST_TMPDIR/k.pem" --org acme-corp
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners["acme-corp"].claude_maintenance.app_id' "$CONFIG")" = "4242" ]
  [ "$(jq -r '.owners["acme-corp"].owner_scope' "$CONFIG")" = "organization" ]
  grep -q ORGKEY "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
  [ "$(jq -r '.owners["octo-dev"].claude_maintenance.app_id' "$CONFIG")" = "1001" ]
  grep -q KEY1 "$KC_DIR/claude-plugins.octo-dev.claude-maintenance"
}

@test "owners: --import validates its inputs before storing anything" {
  printf 'not a key\n' > "$BATS_TEST_TMPDIR/notakey.txt"
  reg --import claude-maintenance --app-id abc --pem "$BATS_TEST_TMPDIR/notakey.txt"
  [ "$status" -ne 0 ]
  contains "$output" "--app-id must be a positive integer"
  reg --import claude-maintenance --app-id 7 --pem "$BATS_TEST_TMPDIR/missing.pem"
  [ "$status" -ne 0 ]
  contains "$output" "--pem path is not readable"
  reg --import claude-maintenance --app-id 7 --pem "$BATS_TEST_TMPDIR/notakey.txt"
  [ "$status" -ne 0 ]
  contains "$output" "does not look like a PEM-encoded private key"
  [ -z "$(ls "$KC_DIR")" ]
}

@test "owners: --org naming your own personal login is refused, not re-scoped" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nX\n-----END RSA PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/k.pem"
  reg --import claude-maintenance --app-id 9 --pem "$BATS_TEST_TMPDIR/k.pem" --org octo-dev
  [ "$status" -ne 0 ]
  contains "$output" "owner_scope 'user', not 'organization'"
  [ "$(jq -r '.owners["octo-dev"].owner_scope' "$CONFIG")" = "user" ]
}

@test "owners: --reset --org removes only that owner's App" {
  reg
  reg --org acme-corp
  [ "$status" -eq 0 ]

  reg --reset claude-approver --org acme-corp
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners["acme-corp"] | has("claude_approver")' "$CONFIG")" = "false" ]
  [ "$(jq -r '.owners["acme-corp"] | has("claude_maintenance")' "$CONFIG")" = "true" ]
  [ ! -e "$KC_DIR/claude-plugins.acme-corp.claude-approver" ]
  [ -e "$KC_DIR/claude-plugins.octo-dev.claude-approver" ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.app_id' "$CONFIG")" = "1001" ]
}

@test "owners: --reset of an App the owner does not have is refused" {
  reg --reset claude-approver --org typo-corp
  [ "$status" -ne 0 ]
  contains "$output" "is not registered for typo-corp"
}

@test "owners: --reset of the personal owner's last App drops the owner" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  reg --reset claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners | has("octo-dev")' "$CONFIG")" = "false" ]
  [ "$(jq -r 'has("claude_maintenance")' "$CONFIG")" = "false" ]
  [ "$(jq -r 'has("alias_owner")' "$CONFIG")" = "false" ]
  [ ! -e "$KC_DIR/claude-plugins.octo-dev.claude-maintenance" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-maintenance" ]

  reg --list
  contains "$output" "No Claude Apps registered."
}

# --- #1683: the #1682 compatibility aliases are removed ------------------------

# A machine #1682 migrated: owner entries plus the aliases it kept.
write_aliased_config() {
  mkdir -p "$HOME/.config/claude-plugins"
  cat > "$CONFIG" <<'EOF'
{
  "schema_version": 2,
  "owners": {
    "octo-dev": {"owner_scope": "user",
      "claude_approver": {"app_id": 111, "slug": "claude-approver-octo-dev", "owner_login": "octo-dev", "owner_scope": "user"},
      "claude_maintenance": {"app_id": 222, "slug": "claude-maintenance-octo-dev", "owner_login": "octo-dev", "owner_scope": "user"}},
    "acme-corp": {"owner_scope": "organization",
      "claude_maintenance": {"app_id": 333, "slug": "claude-maintenance-acme-corp", "owner_login": "acme-corp", "owner_scope": "organization"}}
  },
  "alias_owner": "octo-dev",
  "claude_approver": {"app_id": 111, "slug": "claude-approver-octo-dev", "owner_login": "octo-dev", "owner_scope": "user"},
  "claude_maintenance": {"app_id": 222, "slug": "claude-maintenance-octo-dev", "owner_login": "octo-dev", "owner_scope": "user"}
}
EOF
  chmod 0600 "$CONFIG"
  printf 'OWNER-APPROVER'  > "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  printf 'OWNER-WRITER'    > "$KC_DIR/claude-plugins.octo-dev.claude-maintenance"
  printf 'ORG-WRITER'      > "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
  printf 'LEGACY-APPROVER' > "$KC_DIR/claude-plugins.claude-approver"
  printf 'LEGACY-WRITER'   > "$KC_DIR/claude-plugins.claude-maintenance"
}

owner_state() {
  jq -S '.owners' "$CONFIG"
  (cd "$KC_DIR" && for f in claude-plugins.*.*; do printf '%s=%s\n' "$f" "$(cat "$f")"; done)
}

@test "aliases: one run removes the top-level keys, alias_owner and both legacy Keychain items" {
  write_aliased_config
  local before
  before="$(owner_state)"

  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
  [ ! -e "$KC_DIR/claude-plugins.claude-approver" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-maintenance" ]
  # Owner entries and owner-qualified keys are untouched.
  [ "$(owner_state)" = "$before" ]
  contains "$output" "Removed the pre-#1682 compatibility aliases"
  [ -n "$(find "$CONFIG" -perm 0600)" ]
}

# The order (Keychain first, apps.json last) is what this proves: a delete that
# fails leaves apps.json exactly as it was.
@test "aliases: a failed Keychain delete warns, keeps the apps.json aliases, and a re-run completes" {
  write_aliased_config
  local before_config
  before_config="$(cat "$CONFIG")"
  export KC_DELETE_FAIL="claude-plugins.claude-approver"

  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "Could not delete the legacy Keychain item claude-plugins.claude-approver"
  [ "$(cat "$CONFIG")" = "$before_config" ]
  [ -e "$KC_DIR/claude-plugins.claude-approver" ]

  unset KC_DELETE_FAIL
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
  [ ! -e "$KC_DIR/claude-plugins.claude-approver" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-maintenance" ]
}

@test "aliases: an already-absent legacy item is not an error" {
  write_aliased_config
  rm "$KC_DIR/claude-plugins.claude-approver" "$KC_DIR/claude-plugins.claude-maintenance"
  reg --list
  [ "$status" -eq 0 ]
  lacks "$output" "Could not delete"
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
}

@test "aliases: the cleanup is idempotent — a second run changes nothing and says nothing" {
  write_aliased_config
  reg --list
  [ "$status" -eq 0 ]
  local before
  before="$(state_sum)"
  : > "$STUB_DIR/security.log"

  reg --list
  [ "$status" -eq 0 ]
  [ "$(state_sum)" = "$before" ]
  lacks "$output" "Removed the pre-#1682"
  lacks "$output" "Could not delete"
  run grep -c 'delete-generic-password' "$STUB_DIR/security.log"
  [ "$output" = "0" ]
}

@test "aliases: --help removes nothing; --print-manifest removes them and stays valid JSON" {
  write_aliased_config
  local before
  before="$(state_sum)"
  reg --help
  [ "$status" -eq 0 ]
  [ "$(state_sum)" = "$before" ]

  run bash -c 'zsh "$1" --print-manifest claude-approver 2>/dev/null' _ "$DRIVE"
  [ "$status" -eq 0 ]
  [ "$(jq -r .name <<<"$output")" = "claude-approver-octo-dev" ]
  [ "$(jq -r 'has("alias_owner")' "$CONFIG")" = "false" ]
}

@test "aliases: the alias functions are gone from the script" {
  run grep -nE 'claim_aliases|mirror_aliases|legacy_keychain_service_for|\.alias_owner = ' "$S"
  [ "$status" -eq 1 ]
}

@test "aliases: an alias whose owner has no copy of the key is copied there before the legacy item goes" {
  write_aliased_config
  rm "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "LEGACY-APPROVER" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-approver" ]
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
}

@test "aliases: an alias whose owner has no entry for that App is filed under the owner, not dropped" {
  write_aliased_config
  jq 'del(.owners["octo-dev"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  rm "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.app_id' "$CONFIG")" = "111" ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.owner_login' "$CONFIG")" = "octo-dev" ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "LEGACY-APPROVER" ]
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
  contains "$output" "Claude Approver"
}

@test "aliases: a legacy key that cannot be READ is neither copied nor deleted, and apps.json keeps its aliases" {
  write_aliased_config
  rm "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  local before_config
  before_config="$(cat "$CONFIG")"
  export KC_READ_FAIL="claude-plugins.claude-approver"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "Could not read the legacy Keychain item claude-plugins.claude-approver — unlock the Keychain"
  [ "$(cat "$CONFIG")" = "$before_config" ]
  [ "$(cat "$KC_DIR/claude-plugins.claude-approver")" = "LEGACY-APPROVER" ]
  [ ! -e "$KC_DIR/claude-plugins.octo-dev.claude-approver" ]

  unset KC_READ_FAIL
  reg --list
  [ "$status" -eq 0 ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "LEGACY-APPROVER" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-approver" ]
}

@test "aliases: an alias with no (or an empty) owner_login belongs to alias_owner" {
  write_aliased_config
  jq 'del(.claude_approver.owner_login) | .claude_maintenance.owner_login = ""
      | del(.owners["octo-dev"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  rm "$KC_DIR/claude-plugins.octo-dev.claude-approver" "$KC_DIR/claude-plugins.octo-dev.claude-maintenance"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.app_id' "$CONFIG")" = "111" ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "LEGACY-APPROVER" ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-maintenance")" = "LEGACY-WRITER" ]
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
}

@test "aliases: an alias's mixed-case owner is its lower-cased registry key" {
  write_aliased_config
  jq '.claude_approver.owner_login = "Octo-Dev" | del(.owners["octo-dev"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  rm "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  reg --list
  [ "$status" -eq 0 ]
  # `ls`, not `-e`: a case-insensitive filesystem would match either spelling.
  [ "$(ls "$KC_DIR" | grep -c '^claude-plugins\.octo-dev\.claude-approver$')" -eq 1 ]
  [ "$(jq -c '.owners | keys' "$CONFIG")" = '["acme-corp","octo-dev"]' ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.owner_login' "$CONFIG")" = "octo-dev" ]
}

@test "aliases: an alias whose owner has no entry at all is filed with scope user" {
  write_aliased_config
  jq '.claude_approver.owner_login = "new-owner" | del(.claude_approver.owner_scope)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners["new-owner"].owner_scope' "$CONFIG")" = "user" ]
  [ "$(jq -r '.owners["new-owner"].claude_approver.app_id' "$CONFIG")" = "111" ]
  [ "$(cat "$KC_DIR/claude-plugins.new-owner.claude-approver")" = "LEGACY-APPROVER" ]
}

@test "aliases: owner key and legacy item both absent is not an error — the aliases go" {
  write_aliased_config
  rm "$KC_DIR/claude-plugins.octo-dev.claude-approver" "$KC_DIR/claude-plugins.claude-approver"
  reg --list
  [ "$status" -eq 0 ]
  lacks "$output" "Could not"
  [ "$(jq -c 'keys' "$CONFIG")" = '["owners","schema_version"]' ]
}

@test "aliases: a legacy key with no recorded owner at all is kept, with the aliases" {
  write_aliased_config
  jq 'del(.alias_owner) | del(.claude_approver.owner_login)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "belongs to no recorded owner — kept"
  [ "$(cat "$KC_DIR/claude-plugins.claude-approver")" = "LEGACY-APPROVER" ]
  [ "$(jq -r 'has("claude_approver")' "$CONFIG")" = "true" ]
}

@test "aliases: a legacy key of another App than the owner's entry is never copied under it" {
  write_aliased_config
  jq '.claude_approver.app_id = 999' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  rm "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  local before_config
  before_config="$(cat "$CONFIG")"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "is App 999's key, but octo-dev's entry names App 111 — kept"
  [ ! -e "$KC_DIR/claude-plugins.octo-dev.claude-approver" ]
  [ "$(cat "$KC_DIR/claude-plugins.claude-approver")" = "LEGACY-APPROVER" ]
  # Kept WITH the aliases: apps.json still names App 999.
  [ "$(cat "$CONFIG")" = "$before_config" ]
}

@test "aliases: an owner key that cannot be READ is never overwritten by the legacy key" {
  write_aliased_config
  export KC_READ_FAIL="claude-plugins.octo-dev.claude-approver"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "Could not read the Keychain item claude-plugins.octo-dev.claude-approver"
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "OWNER-APPROVER" ]
  [ -e "$KC_DIR/claude-plugins.claude-approver" ]
  [ "$(jq -r 'has("alias_owner")' "$CONFIG")" = "true" ]
}

@test "owners: a key that cannot be READ is key=unreadable in --list, and stops a registration" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  export KC_READ_FAIL="claude-plugins.octo-dev.claude-maintenance"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "key=unreadable"
  reg --apps claude-maintenance
  [ "$status" -ne 0 ]
  contains "$output" "Could not read the Keychain item claude-plugins.octo-dev.claude-maintenance"
  [ "$(browser_opens)" -eq 1 ]
}

@test "aliases: a failed store of the copied key keeps the legacy item and apps.json untouched" {
  write_aliased_config
  rm "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  local before_config
  before_config="$(cat "$CONFIG")"
  export KC_ADD_FAIL="claude-plugins.octo-dev.claude-approver"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "Could not store claude-plugins.octo-dev.claude-approver"
  [ "$(cat "$KC_DIR/claude-plugins.claude-approver")" = "LEGACY-APPROVER" ]
  [ "$(cat "$CONFIG")" = "$before_config" ]
}

@test "aliases: a legacy key with no apps.json record naming its App is kept" {
  write_aliased_config
  jq 'del(.claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  rm "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "has no apps.json record naming its App — kept"
  [ "$(cat "$KC_DIR/claude-plugins.claude-approver")" = "LEGACY-APPROVER" ]
  [ ! -e "$KC_DIR/claude-plugins.octo-dev.claude-approver" ]
  [ "$(jq -r 'has("alias_owner")' "$CONFIG")" = "true" ]
}

@test "aliases: another App's legacy key is kept even when the owner's own key is present" {
  write_aliased_config
  jq '.claude_approver.app_id = 999' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  local before_config
  before_config="$(cat "$CONFIG")"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "is App 999's key, but octo-dev's entry names App 111 — kept"
  [ "$(cat "$KC_DIR/claude-plugins.claude-approver")" = "LEGACY-APPROVER" ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "OWNER-APPROVER" ]
  [ "$(jq -r '.claude_approver.app_id' "$CONFIG")" = "999" ]
  [ "$(cat "$CONFIG")" = "$before_config" ]
}

@test "aliases: an alias whose owner has no entry but a DIFFERENT key under its service is kept" {
  write_aliased_config
  jq 'del(.owners["octo-dev"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "already holds a key, but octo-dev has no apps.json entry for Claude Approver"
  [ "$(cat "$KC_DIR/claude-plugins.claude-approver")" = "LEGACY-APPROVER" ]
  [ "$(jq -r '.owners["octo-dev"] | has("claude_approver")' "$CONFIG")" = "false" ]

  # The same key under both services is safe: filed, then the alias goes.
  printf 'LEGACY-APPROVER' > "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.app_id' "$CONFIG")" = "111" ]
  [ ! -e "$KC_DIR/claude-plugins.claude-approver" ]
}

@test "owners: migration stops when the owner-qualified Keychain item cannot be read, leaving schema 1" {
  write_legacy_config
  export KC_READ_FAIL="claude-plugins.octo-dev.claude-approver"
  reg --list
  [ "$status" -ne 0 ]
  contains "$output" "nothing was migrated"
  [ "$(jq -r 'has("owners")' "$CONFIG")" = "false" ]
  [ ! -e "$KC_DIR/claude-plugins.octo-dev.claude-approver" ]
}

@test "aliases: two keys that cannot be READ are never taken for the same key" {
  write_aliased_config
  jq 'del(.owners["octo-dev"].claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  # The same key under both services — but the Keychain locks after each
  # item's first read (the state probe), so the comparison cannot read either.
  printf 'LEGACY-APPROVER' > "$KC_DIR/claude-plugins.octo-dev.claude-approver"
  local before_config
  before_config="$(cat "$CONFIG")"
  export KC_READ_FAIL_AFTER=1
  reg --list
  [ "$status" -eq 0 ]
  contains "$output" "Could not read claude-plugins.claude-approver or claude-plugins.octo-dev.claude-approver"
  [ "$(cat "$KC_DIR/claude-plugins.claude-approver")" = "LEGACY-APPROVER" ]
  [ "$(cat "$CONFIG")" = "$before_config" ]
}
