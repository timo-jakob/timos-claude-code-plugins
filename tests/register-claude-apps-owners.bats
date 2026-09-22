#!/usr/bin/env bats
#
# #1682: register-claude-apps.zsh keeps one registry entry per owner — a
# personal login or an organisation — so both pairs coexist on one machine,
# registers any subset of the two Apps (--apps), registers under an
# organisation (--org) only for its owners, and migrates a schema-1 apps.json
# in place.
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
  # Keychain would (exit 51, not 44's "not found").
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
case "$cmd" in
  add-generic-password)    printf '%s' "$pw" > "$f" ;;
  find-generic-password)
    [ "${KC_READ_FAIL:-}" = "$svc" ] && exit 51
    [ -f "$f" ] || exit 44
    if grep -q . <(tail -n +2 "$f"); then od -An -tx1 "$f" | tr -d ' \n'; echo; else cat "$f"; echo; fi
    ;;
  delete-generic-password) [ -f "$f" ] || exit 44; rm -f "$f" ;;
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

  # The compatibility aliases still mirror the PERSONAL owner, not the org.
  [ "$(jq -r '.alias_owner' "$CONFIG")" = "octo-dev" ]
  [ "$(jq -r '.claude_approver.app_id' "$CONFIG")" = "1001" ]
  [ "$(jq -r '.claude_maintenance.app_id' "$CONFIG")" = "1002" ]
  grep -q KEY1 "$KC_DIR/claude-plugins.claude-approver"
  grep -q KEY2 "$KC_DIR/claude-plugins.claude-maintenance"

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
  # An organisation never takes the compatibility aliases.
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

@test "owners: an owner whose Keychain key is gone lists key=missing and is registered again" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  rm "$KC_DIR/claude-plugins.octo-dev.claude-maintenance"

  reg --list
  contains "$output" "key=missing"
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(browser_opens)" -eq 2 ]
}

# --- AC2: register a subset ----------------------------------------------------

@test "owners: --apps claude-maintenance registers the writer only; --list shows one App" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(browser_opens)" -eq 1 ]
  [ "$(jq -r '.owners["octo-dev"] | del(.owner_scope) | keys | join(",")' "$CONFIG")" = "claude_maintenance" ]
  [ ! -e "$KC_DIR/claude-plugins.octo-dev.claude-approver" ]
  # No Approver alias is invented for a writer-only owner.
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
  [ "$(jq -r '.alias_owner' "$CONFIG")" = "octo-dev" ]
  [ "$(jq -r '.owners["octo-dev"].owner_scope' "$CONFIG")" = "user" ]
  [ "$(jq -r '.owners["octo-dev"].claude_approver.app_id' "$CONFIG")" = "111" ]
  [ "$(jq -r '.owners["octo-dev"].claude_maintenance.app_id' "$CONFIG")" = "222" ]
  # Keys copied to the owner-qualified services; legacy items kept as aliases.
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-approver")" = "LEGACY-APPROVER-PEM" ]
  [ "$(cat "$KC_DIR/claude-plugins.octo-dev.claude-maintenance")" = "LEGACY-WRITER-PEM" ]
  [ -e "$KC_DIR/claude-plugins.claude-approver" ]
  [ -e "$KC_DIR/claude-plugins.claude-maintenance" ]
  # Legacy top-level keys kept as aliases, unchanged.
  [ "$(jq -r '.claude_approver.app_id' "$CONFIG")" = "111" ]
  [ "$(jq -r '.claude_maintenance.app_id' "$CONFIG")" = "222" ]
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
  reg --list
  [ "$status" -eq 0 ]
  cmp -s "$KC_DIR/claude-plugins.claude-approver" "$KC_DIR/claude-plugins.octo-dev.claude-approver"
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

  # The alias it was filed under is its owner's to keep in step.
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nROTATED\n-----END RSA PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/k.pem"
  reg --import claude-approver --app-id 111 --pem "$BATS_TEST_TMPDIR/k.pem"
  [ "$status" -eq 0 ]
  grep -q ROTATED "$KC_DIR/claude-plugins.claude-approver"
}

@test "owners: migration lower-cases a recorded owner_login" {
  write_legacy_config
  jq '.claude_approver.owner_login = "Octo-Dev"' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  # `ls`, not `-e`: a case-insensitive filesystem would match either spelling.
  [ "$(ls "$KC_DIR" | grep -c '^claude-plugins\.octo-dev\.claude-approver$')" -eq 1 ]
  [ "$(jq -c '[(.owners | keys), .alias_owner]' "$CONFIG")" = '[["octo-dev"],"octo-dev"]' ]

  # The alias it recorded as Octo-Dev is octo-dev's to rotate.
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nROTATED\n-----END RSA PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/k.pem"
  reg --import claude-approver --app-id 111 --pem "$BATS_TEST_TMPDIR/k.pem"
  [ "$status" -eq 0 ]
  grep -q ROTATED "$KC_DIR/claude-plugins.claude-approver"
}

@test "owners: migration of a writer-only legacy file files just that App" {
  write_legacy_config
  jq 'del(.claude_approver)' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -c '[(.owners | keys), (.owners["octo-dev"] | del(.owner_scope) | keys), .alias_owner]' "$CONFIG")" = '[["octo-dev"],["claude_maintenance"],"octo-dev"]' ]
}

@test "owners: migration keeps a recorded organisation scope, which takes no alias" {
  write_legacy_config
  jq '.claude_approver.owner_login = "acme-corp" | .claude_approver.owner_scope = "organization"' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  reg --list
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.owners["acme-corp"].owner_scope, .alias_owner]' "$CONFIG")" = '["organization","octo-dev"]' ]

  # The organisation's own --org run keeps the alias recorded for it in step.
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nROTATED\n-----END RSA PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/k.pem"
  reg --import claude-approver --app-id 333 --pem "$BATS_TEST_TMPDIR/k.pem" --org acme-corp
  [ "$status" -eq 0 ]
  grep -q ROTATED "$KC_DIR/claude-plugins.claude-approver"
}

@test "owners: a legacy pair with two owners keeps the other owner's alias through a rotation" {
  write_legacy_config
  jq '.claude_maintenance.owner_login = "other-login"' "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nROTATED\n-----END RSA PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/k.pem"
  reg --import claude-approver --app-id 111 --pem "$BATS_TEST_TMPDIR/k.pem"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.claude_maintenance.owner_login' "$CONFIG")" = "other-login" ]
  [ "$(cat "$KC_DIR/claude-plugins.claude-maintenance")" = "LEGACY-WRITER-PEM" ]

  # The alias owner registering that App itself leaves the other owner's alias.
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(jq -r '.claude_maintenance.owner_login' "$CONFIG")" = "other-login" ]
  [ "$(cat "$KC_DIR/claude-plugins.claude-maintenance")" = "LEGACY-WRITER-PEM" ]

  # ...while the other owner still rotates its own alias key.
  export GH_LOGIN="other-login"
  reg --import claude-maintenance --app-id 333 --pem "$BATS_TEST_TMPDIR/k.pem"
  [ "$status" -eq 0 ]
  grep -q ROTATED "$KC_DIR/claude-plugins.claude-maintenance"
  [ "$(jq -r '.claude_maintenance.app_id' "$CONFIG")" = "333" ]

  # ...and removes it with its own --reset.
  reg --reset claude-maintenance
  [ "$status" -eq 0 ]
  [ ! -e "$KC_DIR/claude-plugins.claude-maintenance" ]
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

@test "owners: --import --org files the key under the organisation, leaving the personal aliases alone" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nORGKEY\n-----END RSA PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/k.pem"

  reg --import claude-maintenance --app-id 4242 --pem "$BATS_TEST_TMPDIR/k.pem" --org acme-corp
  [ "$status" -eq 0 ]
  [ "$(jq -r '.owners["acme-corp"].claude_maintenance.app_id' "$CONFIG")" = "4242" ]
  [ "$(jq -r '.owners["acme-corp"].owner_scope' "$CONFIG")" = "organization" ]
  grep -q ORGKEY "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
  [ "$(jq -r '.claude_maintenance.app_id' "$CONFIG")" = "1001" ]
  grep -q KEY1 "$KC_DIR/claude-plugins.claude-maintenance"
}

@test "owners: a personal --import (key rotation) updates the legacy alias key too" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  printf -- '-----BEGIN RSA PRIVATE KEY-----\nROTATED\n-----END RSA PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/k.pem"
  reg --import claude-maintenance --app-id 4242 --pem "$BATS_TEST_TMPDIR/k.pem"
  [ "$status" -eq 0 ]
  grep -q ROTATED "$KC_DIR/claude-plugins.claude-maintenance"
}

@test "owners: a failed first run claims no aliases, so the next login that registers gets them" {
  export CONVERSION="fail"
  reg --apps claude-maintenance
  [ "$status" -ne 0 ]
  export CONVERSION="ok" GH_LOGIN="new-login"
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(jq -r '.alias_owner' "$CONFIG")" = "new-login" ]
}

@test "owners: a login that takes over released aliases has its existing Apps mirrored" {
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  export GH_LOGIN="new-login"
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  export GH_LOGIN="octo-dev"
  reg --reset claude-maintenance
  [ "$status" -eq 0 ]

  export GH_LOGIN="new-login"
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(jq -r '.claude_maintenance.owner_login' "$CONFIG")" = "new-login" ]
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
  grep -q KEY1 "$KC_DIR/claude-plugins.claude-approver"
  [ "$(jq -r '.claude_approver.app_id' "$CONFIG")" = "1001" ]
}

@test "owners: --reset of an App the owner does not have is refused" {
  reg --reset claude-approver --org typo-corp
  [ "$status" -ne 0 ]
  contains "$output" "is not registered for typo-corp"
}

@test "owners: --reset of the personal owner's last App drops the owner and its aliases" {
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

@test "owners: a second personal login never rewrites the alias owner's aliases" {
  write_legacy_config
  reg --list
  [ "$status" -eq 0 ]

  export GH_LOGIN="new-login"
  reg --apps claude-maintenance
  [ "$status" -eq 0 ]
  contains "$output" "belong to 'octo-dev'"
  [ "$(jq -r '.alias_owner' "$CONFIG")" = "octo-dev" ]
  [ "$(jq -r '.claude_approver.app_id' "$CONFIG")" = "111" ]
  [ "$(jq -r '.claude_maintenance.app_id' "$CONFIG")" = "222" ]
  [ "$(cat "$KC_DIR/claude-plugins.claude-maintenance")" = "LEGACY-WRITER-PEM" ]

  reg --reset claude-maintenance
  [ "$status" -eq 0 ]
  [ "$(jq -r '.claude_maintenance.app_id' "$CONFIG")" = "222" ]
  [ -e "$KC_DIR/claude-plugins.claude-maintenance" ]
}
