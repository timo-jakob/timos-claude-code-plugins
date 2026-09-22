#!/usr/bin/env zsh
# register-claude-apps.zsh — register the Claude GitHub Apps
# (claude-approver + claude-maintenance, or any subset of them) under an
# owner — the current user's personal account, or an organisation with
# --org — via the GitHub App Manifest flow, and persist the resulting
# credentials locally so /development:bootstrap can install them per-repo.
#
# The registry holds one entry per owner (#1682), so a personal pair and an
# organisation pair live side by side on one machine.
#
# See development/skills/bootstrap/docs/CLAUDE-APPS.md for the why and the
# manual fallback.

setopt err_exit nounset pipefail

SCRIPT_DIR="${0:A:h}"
# shellcheck source=development/skills/bootstrap/scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# --- constants ----------------------------------------------------------------

readonly CONFIG_DIR="${HOME}/.config/claude-plugins"
readonly CONFIG_FILE="${CONFIG_DIR}/apps.json"
# 2 = the per-owner registry (#1682). A schema-1 file (one top-level pair) is
# migrated in place on first use; its original is kept at LEGACY_BACKUP.
readonly SCHEMA_VERSION=2
readonly LEGACY_BACKUP="${CONFIG_FILE}.v1.bak"

readonly REDIRECT_HOST="127.0.0.1"
readonly REDIRECT_PORT=18923
readonly REDIRECT_PATH="/callback"
readonly REDIRECT_URL="http://${REDIRECT_HOST}:${REDIRECT_PORT}${REDIRECT_PATH}"

# How long the user has to click "Create GitHub App" in the browser.
readonly MANIFEST_TIMEOUT=300

# Homepage URL embedded in each App's manifest. Not functionally used by the
# Apps; GitHub just needs *some* URL. Point at this repo.
readonly REPO_HOMEPAGE="https://github.com/timo-jakob/timos-claude-code-plugins"

readonly KNOWN_APPS=(claude-approver claude-maintenance)

# --- app definitions ----------------------------------------------------------

app_display_name() {
  case "$1" in
    claude-approver)    print -- "Claude Approver" ;;
    claude-maintenance) print -- "Claude Maintenance" ;;
    *) die "Unknown app: $1 (known: ${KNOWN_APPS[*]})" ;;
  esac
}

# Permissions are minimal-by-default. See CLAUDE-APPS.md for the rationale
# behind each scope.
app_permissions_json() {
  case "$1" in
    claude-approver)
      # contents:write is NOT for pushing — the Approver never commits. GitHub
      # only tallies an APPROVE toward a branch's required_approving_review_count
      # when the reviewer *can push to the repo*, and "push access" is the
      # Contents permission (NOT Pull requests). With contents:read the App's
      # reviews post but `authorCanPushToRepository=false`, so the PR stays
      # reviewDecision=REVIEW_REQUIRED / mergeStateStatus=BLOCKED and never
      # auto-merges. See CLAUDE-APPS.md and #418 (root-caused on
      # tick-client-snapper#226). `main` stays PR-protected, so the bot still
      # cannot push directly to a protected branch — exposure is bounded.
      # security_events:read lets the Approver verify Code Scanning alert
      # states (e.g. "is CodeQL alert #N fixed at this head?") under its own
      # identity — a read squarely inside its read-only review design. Without
      # it those API reads 403 and the agent falls back to the user's gh auth
      # (#654). Existing installations must re-accept the updated permissions.
      print -- '{
        "pull_requests":   "write",
        "contents":        "write",
        "issues":          "read",
        "actions":         "read",
        "checks":          "read",
        "security_events": "read",
        "metadata":        "read"
      }'
      ;;
    claude-maintenance)
      # workflows:write lets bot-authored PRs include .github/workflows/*
      # changes (#750). Workflow edits go through the same review path as
      # every other change — the Approver's ci:/build: risk-register lens on
      # app repos, human approval on plugin repos — so a separate
      # user-authored detour buys no extra safety. A permission increase on
      # an already-installed App requires a per-installation re-accept
      # (same dance as #418); install-claude-apps.zsh --verify flags
      # installations still on the old grant.
      print -- '{
        "contents":      "write",
        "pull_requests": "write",
        "issues":        "write",
        "workflows":     "write",
        "actions":       "read",
        "checks":        "read",
        "metadata":      "read"
      }'
      ;;
    *) die "Unknown app: $1" ;;
  esac
}

# Subscribed events. The webhook itself is deactivated (hook_attributes.active
# = false in the manifest) — these are what the App would receive if the
# webhook ever got turned on. Maintenance has no events because it's
# driven by the local maintenance pipeline, not by GitHub events.
app_events_json() {
  case "$1" in
    claude-approver)
      print -- '[
        "check_suite",
        "check_run",
        "pull_request",
        "pull_request_review",
        "pull_request_review_comment",
        "issue_comment"
      ]'
      ;;
    claude-maintenance)
      print -- '[]'
      ;;
    *) die "Unknown app: $1" ;;
  esac
}

# --- config file --------------------------------------------------------------
#
# apps.json (schema 2) is keyed by owner — a personal login or an organisation:
#
#   {"schema_version": 2,
#    "owners": {"<owner>": {"owner_scope": "user|organization",
#                           "claude_approver": {…}, "claude_maintenance": {…}}},
#    "claude_approver": {…}, "claude_maintenance": {…}}
#
# An owner's entry holds only the Apps that exist for it (a writer-only owner
# has just claude_maintenance). The two top-level keys are COMPATIBILITY
# ALIASES of owner entries (who maintains which: claim_aliases, mirror_aliases),
# kept because the consumers (mint scripts, install-claude-apps.zsh, the
# bootstrap probes) still read them until #1683 moves them onto the per-owner
# registry and removes the aliases.

ensure_config_dir() {
  if [[ ! -d "$CONFIG_DIR" ]]; then
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    print -- "{\"schema_version\": $SCHEMA_VERSION, \"owners\": {}}" > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
  fi
}

# Config keys are JSON-friendly snake_case (claude-approver → claude_approver).
config_key_for() { print -- "${1//-/_}" }

# Apply a jq program to apps.json and replace it atomically. Arguments are
# passed to jq verbatim (the program last).
config_update() {
  local tmp
  tmp=$(mktemp -t claude-plugins.apps.XXXXXX)
  if ! jq "$@" "$CONFIG_FILE" > "$tmp"; then
    rm -f "$tmp"
    die "Could not update $CONFIG_FILE."
  fi
  mv "$tmp" "$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"
}

config_has_app() {
  local owner="$1" app="$2"
  ensure_config_dir
  jq -e --arg owner "$owner" --arg key "$(config_key_for "$app")" \
    '.owners[$owner][$key] // empty' "$CONFIG_FILE" >/dev/null 2>&1
}

config_save_app() {
  # client_id is optional (the --import flow has nothing to supply; the
  # manifest-conversion flow returns it). Stored for #223 — the
  # create-github-app-token v3 action prefers Client IDs, though the
  # numeric App ID remains a valid JWT issuer, so nothing consumes this
  # field yet; capturing it at registration costs nothing and spares a
  # manual lookup if GitHub ever drops numeric-ID acceptance.
  local owner="$1" scope="$2" app="$3" app_id="$4" slug="$5" client_id="${6:-}"
  ensure_config_dir
  config_update \
    --arg owner      "$owner" \
    --arg scope      "$scope" \
    --arg key        "$(config_key_for "$app")" \
    --argjson app_id "$app_id" \
    --arg client_id  "$client_id" \
    --arg slug       "$slug" \
    --arg now        "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.owners[$owner].owner_scope = $scope
     | .owners[$owner][$key] = {
         app_id:        $app_id,
         client_id:     $client_id,
         slug:          $slug,
         owner_login:   $owner,
         owner_scope:   $scope,
         registered_at: $now
       }'
}

config_remove_app() {
  local owner="$1" app="$2"
  ensure_config_dir
  # An owner left with no App at all is dropped rather than kept as an empty
  # shell, so --list never shows an owner with nothing registered.
  config_update --arg owner "$owner" --arg key "$(config_key_for "$app")" \
    'del(.owners[$owner][$key])
     | if (.owners[$owner] // {} | del(.owner_scope) | length) == 0
       then del(.owners[$owner]) else . end'
}

# An ABSENT alias is taken only by ONE personal owner, recorded as
# `alias_owner` — set by the migration (the legacy pair's owner) or by the
# first personal login whose operation SUCCEEDS (mirror_aliases writes it).
# Returns 0 when <owner> is or may become that owner; writes nothing. A second
# personal login — after a `gh auth` switch — takes no alias.
claim_aliases() {
  local owner="$1" current
  current=$(jq -r '.alias_owner // ""' "$CONFIG_FILE" 2>/dev/null || true)
  [[ -z "$current" || "$current" == "$owner" ]] && return 0
  warn "The compatibility aliases belong to '$current', not '$owner' — it takes none (until #1683 moves the consumers onto the per-owner registry)." >&2
  return 1
}

# Keep the legacy top-level keys and Keychain items in step with <owner>'s
# entry, once its operation has succeeded: set (and the key copied) where the
# owner has the App, removed where it does not. Each existing alias is kept by
# the owner it records (its owner_login), so the other owner of a mixed
# schema-1 pair still rotates its own; an absent alias is taken only when
# <claim> is 1 (claim_aliases). The claiming owner, left with no App, releases
# `alias_owner`.
mirror_aliases() {
  local owner="$1" claim="$2" app key service pem
  for app in "${KNOWN_APPS[@]}"; do
    key=$(config_key_for "$app")
    jq -e --arg owner "$owner" --arg key "$key" --argjson claim "$claim" \
      'if .[$key] == null then $claim == 1 else .[$key].owner_login == $owner end' \
      "$CONFIG_FILE" >/dev/null || continue
    service=$(legacy_keychain_service_for "$app")
    if config_has_app "$owner" "$app"; then
      config_update --arg owner "$owner" --arg key "$key" '.[$key] = .owners[$owner][$key]'
      pem=$(keychain_read_pem "$(keychain_service_for "$owner" "$app")") \
        && keychain_store_pem "$service" "$pem"
    else
      config_update --arg key "$key" 'del(.[$key])'
      keychain_delete_pem "$service"
    fi
  done
  (( claim )) && config_update --arg owner "$owner" \
    'if .owners[$owner] then .alias_owner = $owner else del(.alias_owner) end'
  return 0
}

# --- keychain -----------------------------------------------------------------
#
# Service names carry the owner: claude-plugins.<owner>.<app>. The legacy
# claude-plugins.<app> item is kept as an alias of the alias owner's key
# (see the aliases note above), copied there by mirror_aliases.

keychain_service_for()        { print -- "claude-plugins.$1.$2" }
legacy_keychain_service_for() { print -- "claude-plugins.$1" }

keychain_store_pem() {
  local service="$1" pem="$2"
  security add-generic-password \
    -U \
    -s "$service" \
    -a "private-key" \
    -w "$pem" \
    >/dev/null
}

# Print the stored key. Exit 44 is `security`'s "item not found"; any other
# non-zero exit is a read that failed (a locked Keychain, a denied prompt).
# `security -w` returns a value containing newlines — every PEM — hex-encoded,
# so decode a pure-hex retrieval back to the PEM, as the mint scripts do (#208).
keychain_read_pem() {
  local raw rc=0
  raw=$(security find-generic-password -s "$1" -a "private-key" -w 2>/dev/null) || rc=$?
  (( rc == 0 )) || return $rc
  if [[ "$raw" =~ ^[0-9a-fA-F]+$ ]]; then
    printf '%s' "$raw" | xxd -r -p
  else
    print -r -- "$raw"
  fi
}

keychain_has_pem() {
  security find-generic-password -s "$1" -a "private-key" -w >/dev/null 2>&1
}

keychain_delete_pem() {
  security delete-generic-password \
    -s "$1" \
    -a "private-key" \
    >/dev/null 2>&1 || true
}

# --- migration ----------------------------------------------------------------
#
# A schema-1 apps.json holds one top-level pair. Migrate it in place on first
# use of any subcommand: back it up beside itself, copy each Keychain key to
# its owner-qualified service, then file each entry under its recorded
# owner_login (lower-cased; the current gh login when none was recorded). The
# top-level keys and the legacy Keychain items are left where they are — they
# become aliases, each stamped with the owner it was filed under (see
# mirror_aliases); the first personal entry's owner becomes `alias_owner`.
#
# Idempotent: a file that already has `owners` is left alone. The config is
# written LAST, so a run that dies copying a key leaves the file un-migrated
# and the next run retries; the backup is never overwritten, so it always
# holds the original. Progress goes to stderr, so a mode that prints JSON
# (--print-manifest) stays parseable on the run that migrates.

migrate_legacy_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1 \
    || die "$CONFIG_FILE is not a JSON object — refusing to migrate it. Move it aside and re-run."
  jq -e 'has("owners")' "$CONFIG_FILE" >/dev/null && return 0

  info "Migrating $CONFIG_FILE to the per-owner registry (original kept at $LEGACY_BACKUP)…" >&2
  [[ -e "$LEGACY_BACKUP" ]] || cp -p "$CONFIG_FILE" "$LEGACY_BACKUP"

  # An entry with no recorded owner_login (none is expected — every writer of
  # schema 1 recorded it) is filed under the current gh login.
  local fallback=""
  if jq -e '[.claude_approver, .claude_maintenance]
            | any(type == "object" and ((.owner_login // "") == ""))' \
       "$CONFIG_FILE" >/dev/null; then
    fallback=$(resolve_github_login)
  fi

  local app key owner service legacy pem rc
  for app in "${KNOWN_APPS[@]}"; do
    key=$(config_key_for "$app")
    jq -e --arg key "$key" '.[$key] | type == "object"' "$CONFIG_FILE" >/dev/null || continue
    owner=$(jq -r --arg key "$key" '.[$key].owner_login // ""' "$CONFIG_FILE")
    owner="${${owner:-$fallback}:l}"
    service=$(keychain_service_for "$owner" "$app")
    keychain_has_pem "$service" && continue
    legacy=$(legacy_keychain_service_for "$app")
    rc=0
    pem=$(keychain_read_pem "$legacy") || rc=$?
    if (( rc == 0 )); then
      keychain_store_pem "$service" "$pem"
    elif (( rc == 44 )); then
      warn "No Keychain key for $(app_display_name "$app") under $legacy — filed without one; add it with --import." >&2
    else
      die "Could not read the Keychain key $legacy (security exit $rc). Unlock the Keychain and re-run — nothing was migrated."
    fi
  done

  config_update --arg fallback "$fallback" --argjson version "$SCHEMA_VERSION" \
    '. as $c
     | [("claude_approver", "claude_maintenance")
        | select(($c[.] | type) == "object")] as $keys
     | def owner_of($k):
         ($c[$k].owner_login // "") | (if . == "" then $fallback else . end) | ascii_downcase;
     .schema_version = $version
     | .owners = (reduce $keys[] as $k ({};
         owner_of($k) as $o
         | ($c[$k].owner_scope // "user") as $s
         | .[$o].owner_scope = $s
         | .[$o][$k] = ($c[$k] + {owner_login: $o, owner_scope: $s})))
     | reduce $keys[] as $k (.; .[$k].owner_login = owner_of($k))
     | [$keys[] | select(($c[.].owner_scope // "user") == "user")] as $personal
     | if ($personal | length) > 0 then .alias_owner = owner_of($personal[0]) else . end'
  ok "Migrated to the per-owner registry." >&2
}

# --- GitHub login -------------------------------------------------------------

# Registry owner keys are lower-cased: GitHub logins and organisation slugs are
# case-insensitive, so `--org Acme-Corp` and `--org acme-corp` are one owner.
resolve_github_login() {
  command -v gh >/dev/null 2>&1 \
    || die "gh CLI not on PATH. Install with: brew install gh"
  local login
  login=$(gh api user --jq .login 2>/dev/null) \
    || die "gh CLI not authenticated. Run: gh auth login"
  print -- "${login:l}"
}

# Registering an App under an organisation needs organisation-owner rights.
# Say so before the browser opens, and check the membership when the API lets
# us — a definite "not an owner" stops here instead of failing in the browser.
require_org_owner() {
  local org="$1" login="$2" resp role state
  info "Registering under organisation '$org' needs organisation-owner rights (an active 'admin' membership)."
  if resp=$(gh api "orgs/${org}/memberships/${login}" 2>&1); then
    role=$(print -r -- "$resp" | jq -r '.role // ""' 2>/dev/null || true)
    state=$(print -r -- "$resp" | jq -r '.state // ""' 2>/dev/null || true)
    [[ "$role" == "admin" && "$state" == "active" ]] \
      || die "$login is not an owner of organisation '$org' (role: ${role:-unknown}, state: ${state:-unknown}). Registering Apps under it needs organisation-owner rights — ask an owner to run this, or to make you one."
  elif [[ "$resp" == *"HTTP 404"* ]]; then
    die "$login is not a member of organisation '$org' (or it does not exist). Registering Apps under it needs organisation-owner rights."
  else
    warn "Could not verify your membership of '$org' (gh api orgs/${org}/memberships/${login} failed). Continuing — GitHub refuses the App-creation page if you are not an owner."
  fi
}

# --- manifest -----------------------------------------------------------------

# The App is named <app>-<owner>: the personal login, or the organisation slug.
build_manifest_json() {
  local app="$1" owner="$2"
  local perms events
  perms=$(app_permissions_json "$app")
  events=$(app_events_json "$app")
  jq -n \
    --arg     name     "${app}-${owner}" \
    --arg     url      "$REPO_HOMEPAGE" \
    --arg     redirect "$REDIRECT_URL" \
    --argjson perms    "$perms" \
    --argjson events   "$events" \
    '{
       name:         $name,
       url:          $url,
       hook_attributes: { url: "https://example.invalid/never-called", active: false },
       redirect_url: $redirect,
       public:       false,
       default_permissions: $perms,
       default_events:      $events
     }'
}

# --- manifest flow ------------------------------------------------------------

# Writes an HTML page that auto-POSTs the manifest to GitHub. Echoes the path.
# JSON.stringify on the JS side dodges every HTML-escape edge case for the
# manifest payload.
write_submit_html() {
  local manifest_json="$1" state="$2" new_app_url="$3"
  local html
  # macOS `mktemp -t <template>` appends its random suffix AFTER the entire
  # template, so `claude-plugins.submit.XXXXXX.html` becomes
  # `claude-plugins.submit.XXXXXX.html.<random>` — the `.html` ends up in
  # the middle and the OS sees it as text/plain. Browsers then show the
  # raw HTML source instead of running the auto-submit JS. Rename to
  # ensure the file ends in `.html`. See #194.
  html=$(mktemp -t claude-plugins.submit)
  mv "$html" "${html}.html"
  html="${html}.html"
  # Single-quoted heredoc with controlled interpolation.
  cat > "$html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Creating Claude App…</title>
  <style>body{font:14px/1.5 system-ui;margin:3em auto;max-width:32em;color:#444}</style>
</head>
<body>
  <p>Redirecting to GitHub to create the App…</p>
  <form id="f" method="POST" action="${new_app_url}?state=${state}">
    <input type="hidden" id="m" name="manifest" value="">
    <noscript><button type="submit">Continue</button></noscript>
  </form>
  <script>
    const manifest = ${manifest_json};
    document.getElementById('m').value = JSON.stringify(manifest);
    document.getElementById('f').submit();
  </script>
</body>
</html>
HTML
  print -- "$html"
}

# One-shot HTTP listener for the GitHub redirect. Prints "STATE\tCODE" on
# stdout when the request arrives, then exits. Exits non-zero on timeout.
run_redirect_listener() {
  python3 - <<PYTHON
import http.server, signal, sys, urllib.parse

PORT    = ${REDIRECT_PORT}
TIMEOUT = ${MANIFEST_TIMEOUT}

def on_timeout(signum, frame):
    sys.stderr.write("Manifest-flow callback timed out after %ds.\n" % TIMEOUT)
    sys.exit(2)

signal.signal(signal.SIGALRM, on_timeout)
signal.alarm(TIMEOUT)

received = {"state": "", "code": ""}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a, **k): pass
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(url.query)
        received["code"]  = qs.get("code",  [""])[0]
        received["state"] = qs.get("state", [""])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(
            b"<!doctype html><html><body>"
            b"<h1>App created.</h1>"
            b"<p>You can close this tab and return to your terminal.</p>"
            b"</body></html>"
        )

srv = http.server.HTTPServer(("${REDIRECT_HOST}", PORT), H)
srv.handle_request()
state = received["state"]
code  = received["code"]
print(f"{state}\t{code}", flush=True)
PYTHON
}

# Where the manifest is POSTed: the personal settings page, or the
# organisation's.
new_app_url_for() {
  local owner="$1" scope="$2"
  if [[ "$scope" == "organization" ]]; then
    print -- "https://github.com/organizations/${owner}/settings/apps/new"
  else
    print -- "https://github.com/settings/apps/new"
  fi
}

# Walks the manifest flow for one App under one owner. On success, persists
# credentials.
manifest_flow() {
  local app="$1" owner="$2" scope="$3"
  info "Registering: $(app_display_name "$app") (owner: $owner, $scope)"

  local manifest_json state
  manifest_json=$(build_manifest_json "$app" "$owner")
  state=$(openssl rand -hex 16)

  local html
  html=$(write_submit_html "$manifest_json" "$state" "$(new_app_url_for "$owner" "$scope")")

  info "  Opening the App-creation page in your browser…"
  info "  After clicking 'Create GitHub App', return here. Timeout: ${MANIFEST_TIMEOUT}s."
  open_browser "$html"

  local result
  if ! result=$(run_redirect_listener); then
    rm -f "$html"
    die "Did not receive the manifest-flow callback. Re-run when ready, or use --import."
  fi
  rm -f "$html"

  local got_state got_code
  got_state="${result%%$'\t'*}"
  got_code="${result##*$'\t'}"
  [[ "$got_state" == "$state" ]] \
    || die "State mismatch on manifest-flow callback. Refusing to proceed."
  [[ -n "$got_code" ]] \
    || die "Empty code on manifest-flow callback. Refusing to proceed."

  info "  Exchanging the temporary code for App credentials…"
  local resp
  resp=$(gh api -X POST "/app-manifests/${got_code}/conversions") \
    || die "Code exchange failed. The code is single-use; re-run register-claude-apps.zsh to retry."

  local app_id client_id slug pem
  # `print -r --` (raw) prevents zsh from interpreting `\n` escape sequences
  # inside the JSON response — without `-r`, the embedded PEM's `\n` becomes
  # a real newline before reaching jq, and jq rejects the resulting raw
  # newlines inside the string with "control characters … must be escaped".
  # See #195.
  app_id=$(print -r -- "$resp" | jq -r '.id')
  client_id=$(print -r -- "$resp" | jq -r '.client_id // empty')
  slug=$(print -r -- "$resp" | jq -r '.slug')
  pem=$(print -r -- "$resp" | jq -r '.pem')
  [[ -n "$app_id" && "$app_id" != "null" ]] \
    || die "Conversion response missing 'id'."
  [[ -n "$pem" && "$pem" != "null" ]] \
    || die "Conversion response missing 'pem'."

  keychain_store_pem "$(keychain_service_for "$owner" "$app")" "$pem"
  config_save_app  "$owner" "$scope" "$app" "$app_id" "$slug" "$client_id"

  ok "Registered: $(app_display_name "$app") (owner=$owner, id=$app_id, slug=$slug)"
}

# --- import flow --------------------------------------------------------------

import_flow() {
  local app="$1" app_id="$2" pem_path="$3" owner="$4" scope="$5"
  [[ "$app_id" =~ ^[0-9]+$ ]] \
    || die "--app-id must be a positive integer. Got: $app_id"
  [[ -r "$pem_path" ]] \
    || die "--pem path is not readable: $pem_path"

  local pem
  pem=$(<"$pem_path")
  [[ "$pem" == *"BEGIN RSA PRIVATE KEY"* || "$pem" == *"BEGIN PRIVATE KEY"* ]] \
    || die "--pem does not look like a PEM-encoded private key: $pem_path"

  keychain_store_pem "$(keychain_service_for "$owner" "$app")" "$pem"
  # Slug is not strictly required; leaving it empty in the JSON keeps the
  # import path simple. install-claude-apps.zsh resolves a missing slug from
  # GET /app (#229).
  config_save_app "$owner" "$scope" "$app" "$app_id" ""

  ok "Imported: $(app_display_name "$app") (owner=$owner, id=$app_id)"
}

# --- reset --------------------------------------------------------------------

reset_flow() {
  local app="$1" owner="$2"
  config_has_app "$owner" "$app" \
    || die "$(app_display_name "$app") is not registered for $owner — nothing to reset (see --list)."
  config_remove_app "$owner" "$app"
  keychain_delete_pem "$(keychain_service_for "$owner" "$app")"
  ok "Reset: $(app_display_name "$app") for $owner (config entry + Keychain key removed)"
}

# --- list ---------------------------------------------------------------------

# Every owner, with its scope and the Apps registered for it. An App an owner
# does not have is not listed: a writer-only owner shows one App.
list_apps() {
  ensure_config_dir
  local -a owners
  owners=(${(f)"$(jq -r '.owners // {} | keys[]' "$CONFIG_FILE")"})
  if (( ${#owners} == 0 )); then
    print -- "  No Claude Apps registered."
    return 0
  fi
  local owner scope app key id slug pem_state
  for owner in "${owners[@]}"; do
    scope=$(jq -r --arg owner "$owner" '.owners[$owner].owner_scope // "user"' "$CONFIG_FILE")
    printf '  %s (%s)\n' "$owner" "$scope"
    for app in "${KNOWN_APPS[@]}"; do
      config_has_app "$owner" "$app" || continue
      key=$(config_key_for "$app")
      id=$(jq -r   --arg owner "$owner" --arg key "$key" '.owners[$owner][$key].app_id' "$CONFIG_FILE")
      slug=$(jq -r --arg owner "$owner" --arg key "$key" '.owners[$owner][$key].slug // ""' "$CONFIG_FILE")
      pem_state="missing"
      keychain_has_pem "$(keychain_service_for "$owner" "$app")" && pem_state="present"
      printf '    %-22s id=%s slug=%s key=%s\n' \
        "$(app_display_name "$app")" "$id" "${slug:--}" "$pem_state"
    done
  done
}

# --- usage --------------------------------------------------------------------

print_usage() {
  cat <<EOF
register-claude-apps.zsh — register the Claude GitHub Apps locally, per owner

Usage:
  register-claude-apps.zsh [--org <slug>] [--apps <app>[,<app>]]
      Register any missing Apps via the manifest flow — under your personal
      account, or under organisation <slug> with --org (needs
      organisation-owner rights). --apps registers only the named Apps
      (default: all); --apps claude-maintenance is the writer-only
      registration.

  register-claude-apps.zsh --list
      Print every owner with its registered Apps.

  register-claude-apps.zsh --print-manifest <app> [--org <slug>]
      Emit the manifest JSON for inspection. No browser, no registration.

  register-claude-apps.zsh --import <app> --app-id <id> --pem <path> [--org <slug>]
      Import credentials obtained via the manual fallback flow
      (see CLAUDE-APPS.md).

  register-claude-apps.zsh --reset <app> [--org <slug>]
      Remove the config entry + Keychain key for <app> under one owner.

  register-claude-apps.zsh --help
      Show this help.

<app> is one of: ${KNOWN_APPS[*]}
Without --org, the owner is your personal gh login.

Storage:
  App IDs + metadata  → ~/.config/claude-plugins/apps.json (keyed by owner)
  Private keys        → macOS Keychain (service: claude-plugins.<owner>.<app>,
                                          account: private-key)

A schema-1 apps.json (one pair, no owners) is migrated in place on first use;
the original is kept at apps.json.v1.bak.

See development/skills/bootstrap/docs/CLAUDE-APPS.md for the manual
fallback flow, the rationale behind the two App identities, and the
permissions reference.
EOF
}

# --- arguments ----------------------------------------------------------------

# Die unless $1 names a known App.
require_known_app() {
  local flag="$1" app="$2"
  (( ${KNOWN_APPS[(Ie)$app]} )) \
    || die "$flag requires an app name (one of: ${KNOWN_APPS[*]}). Got: ${app:-nothing}"
}

# Parse a comma-separated --apps value into the global SELECTED_APPS, in
# KNOWN_APPS order and without duplicates.
parse_apps_list() {
  local csv="$1" app
  local -a wanted
  wanted=(${(s:,:)csv})
  (( ${#wanted} > 0 )) || die "--apps requires at least one app (one of: ${KNOWN_APPS[*]})"
  for app in "${wanted[@]}"; do
    (( ${KNOWN_APPS[(Ie)$app]} )) \
      || die "--apps: unknown app '$app' (known: ${KNOWN_APPS[*]})"
  done
  SELECTED_APPS=()
  for app in "${KNOWN_APPS[@]}"; do
    (( ${wanted[(Ie)$app]} )) && SELECTED_APPS+=("$app")
  done
  return 0
}

# --- main ---------------------------------------------------------------------

main() {
  local mode="" app="" app_id="" pem_path="" org="" apps_csv=""
  local have_apps=0

  # A value flag must be followed by a value — never swallow the next flag.
  _value() {
    [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 requires a value (see --help)"
  }
  _mode() {
    [[ -z "$mode" ]] || die "Only one of --list, --print-manifest, --import, --reset may be given."
    mode="$1"
  }

  while (( $# > 0 )); do
    case "$1" in
      --help|-h)        print_usage; return 0 ;;
      --list)           _mode list; shift ;;
      --print-manifest) _mode print-manifest; _value "$@"; app="$2"; shift 2 ;;
      --import)         _mode import;         _value "$@"; app="$2"; shift 2 ;;
      --reset)          _mode reset;          _value "$@"; app="$2"; shift 2 ;;
      --app-id)         _value "$@"; app_id="$2";   shift 2 ;;
      --pem)            _value "$@"; pem_path="$2"; shift 2 ;;
      --org)            _value "$@"; org="$2";      shift 2 ;;
      --apps)           _value "$@"; apps_csv="$2"; have_apps=1; shift 2 ;;
      *)
        err "Unknown argument: $1"
        print
        print_usage
        exit 2
        ;;
    esac
  done
  mode="${mode:-register}"

  [[ -z "$org" || "$org" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] \
    || die "--org must be a GitHub organisation slug (letters, digits, hyphens). Got: $org"
  [[ "$mode" != list || -z "$org" ]] \
    || die "--list shows every owner; --org does not apply to it."
  (( have_apps == 0 )) || [[ "$mode" == register ]] \
    || die "--apps applies only to registration (no --list/--print-manifest/--import/--reset)."
  [[ "$mode" == import ]] || [[ -z "$app_id" && -z "$pem_path" ]] \
    || die "--app-id / --pem apply only to --import."

  require_macos
  require_tools curl jq gh python3 openssl

  migrate_legacy_config

  if [[ "$mode" == list ]]; then
    list_apps
    return 0
  fi

  # Everything else acts on one owner: the organisation, or the personal login.
  local owner scope recorded
  if [[ -n "$org" ]]; then
    owner="${org:l}"; scope="organization"
  else
    owner=$(resolve_github_login); scope="user"
  fi
  recorded=$(jq -r --arg owner "$owner" '.owners[$owner].owner_scope // ""' "$CONFIG_FILE" 2>/dev/null || true)
  [[ -z "$recorded" || "$recorded" == "$scope" ]] \
    || die "$owner is registered with owner_scope '$recorded', not '$scope' — refusing to mix the two (check --org)."

  # Only a personal owner can take an absent compatibility alias (claim_aliases).
  local claim=0
  if [[ "$scope" == "user" && "$mode" != print-manifest ]] && claim_aliases "$owner"; then
    claim=1
  fi

  case "$mode" in
    register)
      SELECTED_APPS=("${KNOWN_APPS[@]}")
      (( have_apps == 0 )) || parse_apps_list "$apps_csv"

      local -a pending=()
      local a
      for a in "${SELECTED_APPS[@]}"; do
        if config_has_app "$owner" "$a" \
           && keychain_has_pem "$(keychain_service_for "$owner" "$a")"; then
          dim "  $(app_display_name "$a") for $owner: already registered, skipping."
        else
          pending+=("$a")
        fi
      done

      if (( ${#pending} > 0 )); then
        if [[ "$scope" == "organization" ]]; then
          # Assigned first: a failed lookup inside an argument would not stop
          # the run under err_exit, and the browser would open anyway.
          local login
          login=$(resolve_github_login)
          require_org_owner "$owner" "$login"
        fi
        info "Registering missing Claude Apps for $owner via the manifest flow…"
        for a in "${pending[@]}"; do
          manifest_flow "$a" "$owner" "$scope"
        done
      fi
      print
      info "Current state:"
      list_apps
      ;;

    print-manifest)
      require_known_app --print-manifest "$app"
      build_manifest_json "$app" "$owner" | jq .
      ;;

    import)
      require_known_app --import "$app"
      [[ -n "$app_id"   ]] || die "--import requires --app-id"
      [[ -n "$pem_path" ]] || die "--import requires --pem"
      import_flow "$app" "$app_id" "$pem_path" "$owner" "$scope"
      ;;

    reset)
      require_known_app --reset "$app"
      reset_flow "$app" "$owner"
      ;;
  esac

  # Only once the operation succeeded — a run that died above claimed nothing.
  [[ "$mode" == print-manifest ]] || mirror_aliases "$owner" "$claim"
  return 0
}

# Run main only when executed directly — when the file is *sourced* (unit tests
# exercising app_permissions_json etc.) ZSH_EVAL_CONTEXT carries a `:file`
# segment and we skip it, so sourcing has no side effects.
if [[ "${ZSH_EVAL_CONTEXT:-}" != *:file* ]]; then
  main "$@"
fi
