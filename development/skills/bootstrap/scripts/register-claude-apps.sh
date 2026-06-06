#!/usr/bin/env zsh
# register-claude-apps.sh — register the two Claude GitHub Apps
# (claude-approver + claude-maintenance) under the current user's account
# via the GitHub App Manifest flow, and persist the resulting credentials
# locally so /development:bootstrap can install them per-repo later.
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
readonly SCHEMA_VERSION=1

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
# behind each scope. workflows:write is deliberately NOT granted to
# Maintenance — workflow edits go through human review.
app_permissions_json() {
  case "$1" in
    claude-approver)
      print -- '{
        "pull_requests": "write",
        "contents":      "read",
        "issues":        "read",
        "actions":       "read",
        "checks":        "read",
        "metadata":      "read"
      }'
      ;;
    claude-maintenance)
      print -- '{
        "contents":      "write",
        "pull_requests": "write",
        "issues":        "write",
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

ensure_config_dir() {
  if [[ ! -d "$CONFIG_DIR" ]]; then
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    print -- "{\"schema_version\": $SCHEMA_VERSION}" > "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
  fi
}

# Config keys are JSON-friendly snake_case (claude-approver → claude_approver).
config_key_for() { print -- "${1//-/_}" }

config_has_app() {
  ensure_config_dir
  local key
  key=$(config_key_for "$1")
  jq -e --arg key "$key" '.[$key] // empty' "$CONFIG_FILE" >/dev/null 2>&1
}

config_save_app() {
  local app="$1" app_id="$2" slug="$3" owner_login="$4"
  ensure_config_dir
  local key
  key=$(config_key_for "$app")
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local tmp
  tmp=$(mktemp -t claude-plugins.apps.XXXXXX)
  jq \
    --arg key         "$key" \
    --argjson app_id  "$app_id" \
    --arg slug        "$slug" \
    --arg owner_login "$owner_login" \
    --arg now         "$now" \
    '.[$key] = {
       app_id:        $app_id,
       slug:          $slug,
       owner_login:   $owner_login,
       owner_scope:   "user",
       registered_at: $now
     }' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"
}

config_remove_app() {
  ensure_config_dir
  local key
  key=$(config_key_for "$1")
  local tmp
  tmp=$(mktemp -t claude-plugins.apps.XXXXXX)
  jq --arg key "$key" 'del(.[$key])' "$CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 0600 "$CONFIG_FILE"
}

# --- keychain -----------------------------------------------------------------

keychain_service_for() { print -- "claude-plugins.$1" }

keychain_store_pem() {
  local app="$1" pem="$2"
  security add-generic-password \
    -U \
    -s "$(keychain_service_for "$app")" \
    -a "private-key" \
    -w "$pem" \
    >/dev/null
}

keychain_has_pem() {
  security find-generic-password \
    -s "$(keychain_service_for "$1")" \
    -a "private-key" \
    -w >/dev/null 2>&1
}

keychain_delete_pem() {
  security delete-generic-password \
    -s "$(keychain_service_for "$1")" \
    -a "private-key" \
    >/dev/null 2>&1 || true
}

# --- GitHub login -------------------------------------------------------------

resolve_github_login() {
  command -v gh >/dev/null 2>&1 \
    || die "gh CLI not on PATH. Install with: brew install gh"
  gh api user --jq .login 2>/dev/null \
    || die "gh CLI not authenticated. Run: gh auth login"
}

# --- manifest -----------------------------------------------------------------

build_manifest_json() {
  local app="$1" github_login="$2"
  local perms events
  perms=$(app_permissions_json "$app")
  events=$(app_events_json "$app")
  jq -n \
    --arg     name     "${app}-${github_login}" \
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
  local manifest_json="$1" state="$2"
  local html
  html=$(mktemp -t claude-plugins.submit.XXXXXX.html)
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
  <form id="f" method="POST" action="https://github.com/settings/apps/new?state=${state}">
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

# Walks the manifest flow for one App. On success, persists credentials.
manifest_flow() {
  local app="$1" github_login
  github_login=$(resolve_github_login)
  info "Registering: $(app_display_name "$app") (account: $github_login)"

  local manifest_json state
  manifest_json=$(build_manifest_json "$app" "$github_login")
  state=$(openssl rand -hex 16)

  local html
  html=$(write_submit_html "$manifest_json" "$state")

  info "  Opening the App-creation page in your browser…"
  info "  After clicking 'Create GitHub App', return here. Timeout: ${MANIFEST_TIMEOUT}s."
  open "$html"

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
    || die "Code exchange failed. The code is single-use; re-run register-claude-apps.sh to retry."

  local app_id slug pem
  app_id=$(print -- "$resp" | jq -r '.id')
  slug=$(print   -- "$resp" | jq -r '.slug')
  pem=$(print    -- "$resp" | jq -r '.pem')
  [[ -n "$app_id" && "$app_id" != "null" ]] \
    || die "Conversion response missing 'id'."
  [[ -n "$pem" && "$pem" != "null" ]] \
    || die "Conversion response missing 'pem'."

  keychain_store_pem "$app" "$pem"
  config_save_app    "$app" "$app_id" "$slug" "$github_login"

  ok "Registered: $(app_display_name "$app") (id=$app_id, slug=$slug)"
}

# --- import flow --------------------------------------------------------------

import_flow() {
  local app="$1" app_id="$2" pem_path="$3"
  [[ "$app_id" =~ ^[0-9]+$ ]] \
    || die "--app-id must be a positive integer. Got: $app_id"
  [[ -r "$pem_path" ]] \
    || die "--pem path is not readable: $pem_path"

  local pem github_login
  pem=$(<"$pem_path")
  [[ "$pem" == *"BEGIN RSA PRIVATE KEY"* || "$pem" == *"BEGIN PRIVATE KEY"* ]] \
    || die "--pem does not look like a PEM-encoded private key: $pem_path"

  github_login=$(resolve_github_login)

  keychain_store_pem "$app" "$pem"
  # Slug is not strictly required; leaving it empty in the JSON keeps the
  # import path simple. Bootstrap (Phase 1) and the Approver workflow look up
  # the App by ID, not by slug.
  config_save_app "$app" "$app_id" "" "$github_login"

  ok "Imported: $(app_display_name "$app") (id=$app_id)"
}

# --- reset --------------------------------------------------------------------

reset_flow() {
  local app="$1"
  config_remove_app  "$app"
  keychain_delete_pem "$app"
  ok "Reset: $(app_display_name "$app") (config entry + Keychain key removed)"
}

# --- list ---------------------------------------------------------------------

list_apps() {
  ensure_config_dir
  local app key id slug pem_state
  for app in "${KNOWN_APPS[@]}"; do
    if config_has_app "$app"; then
      key=$(config_key_for "$app")
      id=$(jq -r   --arg key "$key" '.[$key].app_id' "$CONFIG_FILE")
      slug=$(jq -r --arg key "$key" '.[$key].slug // ""' "$CONFIG_FILE")
      pem_state="missing"
      keychain_has_pem "$app" && pem_state="present"
      printf '  %-22s id=%s slug=%s key=%s\n' \
        "$(app_display_name "$app")" "$id" "${slug:--}" "$pem_state"
    else
      printf '  %-22s not registered\n' "$(app_display_name "$app")"
    fi
  done
}

# --- usage --------------------------------------------------------------------

print_usage() {
  cat <<EOF
register-claude-apps.sh — register the two Claude GitHub Apps locally

Usage:
  register-claude-apps.sh
      Register any missing Apps via the manifest flow.

  register-claude-apps.sh --list
      Print current registration status.

  register-claude-apps.sh --print-manifest <app>
      Emit the manifest JSON for inspection. No network calls.

  register-claude-apps.sh --import <app> --app-id <id> --pem <path>
      Import credentials obtained via the manual fallback flow
      (see CLAUDE-APPS.md).

  register-claude-apps.sh --reset <app>
      Remove the config entry + Keychain key for <app>.

  register-claude-apps.sh --help
      Show this help.

<app> is one of: ${KNOWN_APPS[*]}

Storage:
  App IDs + metadata  → ~/.config/claude-plugins/apps.json
  Private keys        → macOS Keychain (service: claude-plugins.<app>,
                                          account: private-key)

See development/skills/bootstrap/docs/CLAUDE-APPS.md for the manual
fallback flow, the rationale behind the two App identities, and the
permissions reference.
EOF
}

# --- main ---------------------------------------------------------------------

main() {
  require_macos
  require_tools curl jq gh python3 openssl

  local cmd="${1:-}"
  case "$cmd" in
    "" )
      info "Registering any missing Claude Apps via the manifest flow…"
      local app
      for app in "${KNOWN_APPS[@]}"; do
        if config_has_app "$app" && keychain_has_pem "$app"; then
          dim "  $(app_display_name "$app"): already registered, skipping."
        else
          manifest_flow "$app"
        fi
      done
      print
      info "Current state:"
      list_apps
      ;;

    --list)
      list_apps
      ;;

    --print-manifest)
      local app="${2:-}"
      [[ -n "$app" ]] || die "--print-manifest requires an app name (one of: ${KNOWN_APPS[*]})"
      local github_login
      github_login=$(resolve_github_login)
      build_manifest_json "$app" "$github_login" | jq .
      ;;

    --import)
      local app="${2:-}" app_id="" pem_path=""
      [[ -n "$app" ]] || die "--import requires an app name (one of: ${KNOWN_APPS[*]})"
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --app-id) app_id="$2";   shift 2 ;;
          --pem)    pem_path="$2"; shift 2 ;;
          *) die "Unknown flag: $1 (see --help)" ;;
        esac
      done
      [[ -n "$app_id"   ]] || die "--import requires --app-id"
      [[ -n "$pem_path" ]] || die "--import requires --pem"
      import_flow "$app" "$app_id" "$pem_path"
      ;;

    --reset)
      local app="${2:-}"
      [[ -n "$app" ]] || die "--reset requires an app name (one of: ${KNOWN_APPS[*]})"
      reset_flow "$app"
      ;;

    --help|-h)
      print_usage
      ;;

    *)
      err "Unknown argument: $cmd"
      print
      print_usage
      exit 2
      ;;
  esac
}

main "$@"
