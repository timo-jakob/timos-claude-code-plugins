# Shared stubs for the Claude Apps consumers (#1683): the mint scripts,
# install-claude-apps.zsh, claude-apps-owner.zsh, preflight.sh's Claude Apps
# check and register-claude-apps.zsh --list, driven for real against a stubbed
# `gh`, `security`, `curl`, `openssl` and `uname` on PATH.
#
# Loaded by tests/claude-apps-owner.bats and
# tests/acceptance/cli/claude-apps-owner.bats. Call claude_apps_stubs in setup.
#
# The repository the scripts run "inside" is chosen per test:
#   REPO_OWNER   — owner.login gh repo view reports (mixed case allowed)
#   REPO_IN_ORG  — true for an organisation-owned repo (default false)
#   GH_REPO_FAIL — set: gh repo view fails (not a GitHub repo / unauthenticated)
#   GH_LOGIN     — the login `gh api user` reports (default timo-jakob);
#   GH_USER_FAIL — set: that lookup fails
# and the stubs' failure switches:
#   KC_READ_FAIL / KC_DELETE_FAIL / KC_ADD_FAIL=<service> — that Keychain
#     item cannot be read / deleted / stored, as a locked Keychain (exit 51)
#   CURL_NO_INSTALL / CURL_NO_TOKEN / CURL_NO_APP — GitHub answers that call
#     with an error object instead (the installation lookup: a 404 Not Found)
#   CURL_INSTALL_REJECTED — the installation lookup is refused (401 body)
#   CURL_OFFLINE — every call fails as with no network (no output, exit 6)
# Every stub call is logged under $STUB_DIR (gh.log, security.log, curl.log,
# openssl.log) so a test can prove what was — and was not — read.

claude_apps_stubs() {
  # tests/ or tests/acceptance/cli/ — walk up to the repository root.
  REPO_ROOT="$BATS_TEST_DIRNAME"
  while [ ! -f "$REPO_ROOT/ARCHITECTURE.md" ] && [ "$REPO_ROOT" != / ]; do
    REPO_ROOT="$(dirname "$REPO_ROOT")"
  done
  export SCRIPTS="$REPO_ROOT/development/skills/bootstrap/scripts"
  export HELPER="$SCRIPTS/claude-apps-owner.zsh"
  export REGISTER="$SCRIPTS/register-claude-apps.zsh"
  export INSTALL="$SCRIPTS/install-claude-apps.zsh"
  export PREFLIGHT="$SCRIPTS/preflight.sh"
  export MINT_APPROVER="$REPO_ROOT/development/skills/maintenance/scripts/mint-approver-token.zsh"
  export MINT_WRITER="$REPO_ROOT/development/skills/maintenance/scripts/mint-maintenance-token.zsh"

  export HOME="$BATS_TEST_TMPDIR/home"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  export KC_DIR="$BATS_TEST_TMPDIR/keychain"
  mkdir -p "$HOME" "$STUB_DIR" "$KC_DIR" "$BATS_TEST_TMPDIR/bin"
  export CONFIG="$HOME/.config/claude-plugins/apps.json"
  export REPO_OWNER="timo-jakob" REPO_IN_ORG="false"
  export GH_LOGIN="timo-jakob"
  unset GH_REPO_FAIL GH_USER_FAIL KC_READ_FAIL KC_DELETE_FAIL KC_ADD_FAIL CURL_INSTALL_REJECTED CURL_OFFLINE CURL_NO_INSTALL CURL_NO_TOKEN CURL_NO_APP
  # Minted token files land in the test's own temp dir, not the host's.
  export TMPDIR="$BATS_TEST_TMPDIR"

  local bin="$BATS_TEST_TMPDIR/bin"

  cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/gh.log"
case "$*" in
  "repo view --json owner,name,isInOrganization")
    [ -n "${GH_REPO_FAIL:-}" ] && { echo "gh: not a git repository" >&2; exit 1; }
    printf '{"owner":{"login":"%s"},"name":"widget","isInOrganization":%s}\n' "$REPO_OWNER" "$REPO_IN_ORG"
    ;;
  "api user --jq .login")
    [ -n "${GH_USER_FAIL:-}" ] && { echo "gh: HTTP 401" >&2; exit 1; }
    echo "$GH_LOGIN"
    ;;
  "auth status"*) : ;;
  "secret list"*|"variable list"*) : ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF

  # A file-per-service Keychain, as in register-claude-apps-owners.bats: like
  # the real `security -w`, a value containing a newline is read back as hex.
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
echo "$cmd $svc" >> "$STUB_DIR/security.log"
f="$KC_DIR/$svc"
case "$cmd" in
  add-generic-password)
    [ "${KC_ADD_FAIL:-}" = "$svc" ] && exit 51
    printf '%s' "$pw" > "$f" ;;
  find-generic-password)
    [ "${KC_READ_FAIL:-}" = "$svc" ] && exit 51
    [ -f "$f" ] || exit 44
    if grep -q . <(tail -n +2 "$f"); then od -An -tx1 "$f" | tr -d ' \n'; echo; else cat "$f"; echo; fi
    ;;
  delete-generic-password)
    [ "${KC_DELETE_FAIL:-}" = "$svc" ] && exit 51
    [ -f "$f" ] || exit 44; rm -f "$f" ;;
esac
EOF

  # GitHub's API. The JWT's issuer (the App ID the script signed as) is decoded
  # from the Authorization header and logged, and it names the minted token.
  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
url="" auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in "Authorization: Bearer "*) auth="${2#Authorization: Bearer }" ;; esac; shift 2 ;;
    -X) shift 2 ;;
    -*) shift ;;
    *)  url="$1"; shift ;;
  esac
done
payload=$(printf '%s' "$auth" | cut -d. -f2 | tr '_-' '/+')
while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="$payload="; done
iss=$(printf '%s' "$payload" | base64 --decode 2>/dev/null | jq -r '.iss // empty')
echo "$url iss=$iss" >> "$STUB_DIR/curl.log"
[ -n "${CURL_OFFLINE:-}" ] && { echo "curl: (6) Could not resolve host: api.github.com" >&2; exit 6; }
case "$url" in
  */installation)
    if [ -n "${CURL_NO_INSTALL:-}" ]; then echo '{"message": "Not Found"}'
    elif [ -n "${CURL_INSTALL_REJECTED:-}" ]; then echo '{"message": "Bad credentials"}'
    else echo '{"id": 77}'; fi ;;
  */app/installations/77/access_tokens)
    if [ -n "${CURL_NO_TOKEN:-}" ]; then echo '{"message": "Bad credentials"}'
    else printf '{"token": "ghs_minted_by_%s"}\n' "$iss"; fi ;;
  https://api.github.com/app)
    if [ -n "${CURL_NO_APP:-}" ]; then echo '{"message": "Bad credentials"}'
    else printf '{"id": %s, "slug": "slug-from-api-%s", "client_id": "Iv1.api%s", "permissions": {"contents": "write", "security_events": "read", "workflows": "write"}}\n' "$iss" "$iss" "$iss"; fi ;;
esac
EOF

  # Signing: log which key signed, return a fixed signature.
  cat > "$bin/openssl" <<'EOF'
#!/usr/bin/env bash
key=""
while [ $# -gt 0 ]; do
  case "$1" in -sign) key="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$key" ] && echo "signed-with $(tr -d '\n' < "$key")" >> "$STUB_DIR/openssl.log"
printf 'SIG'
EOF

  printf '#!/usr/bin/env bash\necho Darwin\n' > "$bin/uname"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/python3"
  # preflight.sh: Homebrew present and every formula it asks about installed,
  # and the mikefarah yq its IaC mode checks for — so no host tool decides it.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/brew"
  printf '#!/usr/bin/env bash\necho "yq (https://github.com/mikefarah/yq/) version v4.44.3"\n' > "$bin/yq"
  chmod +x "$bin"/*
  export PATH="$bin:$PATH"

  # install-claude-apps.zsh, with its interactive steps answered: yes to every
  # prompt, the browser recorded instead of opened, no wait for Enter.
  export INSTALL_DRIVE="$BATS_TEST_TMPDIR/install-drive.zsh"
  cat > "$INSTALL_DRIVE" <<'EOF'
source "$INSTALL"
ask_yn() { return 0 }
open_browser() { print -r -- "$1" >> "$STUB_DIR/browser.log" }
wait_for_enter() { : }
main "$@"
EOF

  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cd "$WORK" || return
}

# The use case's machine: a personal pair for timo-jakob and a writer-only
# organisation acme-corp, each with its own Keychain key.
write_registry() {
  mkdir -p "$HOME/.config/claude-plugins"
  cat > "$CONFIG" <<'EOF'
{
  "schema_version": 2,
  "owners": {
    "timo-jakob": {"owner_scope": "user",
      "claude_approver":    {"app_id": 111, "client_id": "", "slug": "claude-approver-timo-jakob",    "owner_login": "timo-jakob", "owner_scope": "user"},
      "claude_maintenance": {"app_id": 222, "client_id": "", "slug": "claude-maintenance-timo-jakob", "owner_login": "timo-jakob", "owner_scope": "user"}},
    "acme-corp": {"owner_scope": "organization",
      "claude_maintenance": {"app_id": 333, "client_id": "", "slug": "claude-maintenance-acme-corp", "owner_login": "acme-corp", "owner_scope": "organization"}}
  }
}
EOF
  chmod 0600 "$CONFIG"
  printf 'PEM-timo-jakob-approver'    > "$KC_DIR/claude-plugins.timo-jakob.claude-approver"
  printf 'PEM-timo-jakob-maintenance' > "$KC_DIR/claude-plugins.timo-jakob.claude-maintenance"
  printf 'PEM-acme-corp-maintenance'  > "$KC_DIR/claude-plugins.acme-corp.claude-maintenance"
}

# The same machine as #1682 left it: timo-jakob is alias_owner, but its entry
# LACKS the Approver, while a top-level alias and the legacy Keychain item for
# it are still present.
write_aliased_registry_without_owner_approver() {
  write_registry
  jq 'del(.owners["timo-jakob"].claude_approver)
      | .alias_owner = "timo-jakob"
      | .claude_approver = {"app_id": 999, "slug": "claude-approver-timo-jakob", "owner_login": "timo-jakob"}' \
    "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  rm -f "$KC_DIR/claude-plugins.timo-jakob.claude-approver"
  printf 'PEM-LEGACY-ALIAS' > "$KC_DIR/claude-plugins.claude-approver"
}

write_schema1_registry() {
  mkdir -p "$HOME/.config/claude-plugins"
  cat > "$CONFIG" <<'EOF'
{"schema_version": 1,
 "claude_approver":    {"app_id": 111, "slug": "claude-approver-timo-jakob",    "owner_login": "timo-jakob", "owner_scope": "user"},
 "claude_maintenance": {"app_id": 222, "slug": "claude-maintenance-timo-jakob", "owner_login": "timo-jakob", "owner_scope": "user"}}
EOF
  printf 'PEM-LEGACY-APPROVER' > "$KC_DIR/claude-plugins.claude-approver"
  printf 'PEM-LEGACY-WRITER'   > "$KC_DIR/claude-plugins.claude-maintenance"
}

in_org_repo()      { export REPO_OWNER="$1" REPO_IN_ORG="true"; }
in_personal_repo() { export REPO_OWNER="$1" REPO_IN_ORG="false"; }

# Checksum every file the registry lives in — path and content per file.
registry_sum() {
  (cd "$BATS_TEST_TMPDIR" && find home keychain -type f -exec cksum {} + | LC_ALL=C sort)
}

# Registered Apps for <owner> per `register-claude-apps.zsh --list`: the names
# of the Apps listed under that owner with key=present, comma-joined.
list_registered() {
  local owner="$1"
  zsh "$REGISTER" --list 2>/dev/null | awk -v o="$owner" '
    /^  [^ ]/ { on = ($1 == o); next }
    on && /key=present/ { sub(/^ +/, ""); split($0, w, " "); print tolower(w[2]) }
  ' | LC_ALL=C sort | paste -sd, -
}

# Registered Apps per claude-apps-owner.zsh status, same shape.
status_registered() {
  zsh "$HELPER" status 2>/dev/null | awk -F': ' '$2 == "registered" { print $1 }' \
    | LC_ALL=C sort | paste -sd, -
}

# preflight.sh run from a copy of its directory, with a stub
# register-claude-apps.zsh beside it: it logs its arguments and, when
# REGISTER_WORKS is set, registers the organisation's Approver the way the real
# one would. Sets bats' status/output/stderr.
preflight_with_stub_register() {
  local dir="$BATS_TEST_TMPDIR/pf"
  mkdir -p "$dir"
  cp "$PREFLIGHT" "$SCRIPTS/lib.sh" "$HELPER" "$dir/"
  cat > "$dir/register-claude-apps.zsh" <<'EOF'
#!/usr/bin/env zsh
print -r -- "$*" >> "$STUB_DIR/register.log"
if [[ -n "${REGISTER_WORKS:-}" ]]; then
  jq '.owners["acme-corp"].claude_approver = {"app_id": 444, "slug": "claude-approver-acme-corp"}' \
    "$CONFIG" > "$CONFIG.tmp"
  mv "$CONFIG.tmp" "$CONFIG"
  printf 'PEM-acme-corp-approver' > "$KC_DIR/claude-plugins.acme-corp.claude-approver"
fi
EOF
  chmod +x "$dir"/*
  run --separate-stderr bash "$dir/preflight.sh" --languages "" \
    --has-dockerfile false --iac-only true --claude-approver true --assume-yes </dev/null
}
