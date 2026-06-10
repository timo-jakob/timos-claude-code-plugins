#!/usr/bin/env zsh
# install-claude-apps.sh — install both Claude GitHub Apps on the current
# repo and store the per-repo secrets + variables the Approver workflow
# (Phase 2) and the Maintenance bot identity will need at runtime.
#
# Prerequisites:
#   - register-claude-apps.sh has been run (apps.json entries + Keychain
#     keys for both claude-approver and claude-maintenance exist)
#   - gh CLI authenticated against the repo's hosting account
#   - the script is run from inside the target repo's working tree
#
# What it does:
#   1. Opens https://github.com/apps/<slug>/installations/new in the
#      browser for each App so the user installs them on the target repo.
#   2. Captures ANTHROPIC_API_KEY (env var or prompt).
#   3. Stores per-repo variables (CLAUDE_APPROVER_APP_ID,
#      CLAUDE_MAINTENANCE_APP_ID, CLAUDE_APPROVER_AUTHOR_ALLOWLIST)
#      and secrets (CLAUDE_APPROVER_PRIVATE_KEY,
#      CLAUDE_MAINTENANCE_PRIVATE_KEY, ANTHROPIC_API_KEY) — secrets in
#      both Actions and Dependabot scopes via gh_secret_set_both.
#
# Not in scope for this script:
#   - Rendering the Approver workflow / policy / PR template (Phase 2).
#   - The python-approver agent (Phase 3).
#
# See development/skills/bootstrap/docs/CLAUDE-APPS.md for the design
# and the manual fallback.

setopt err_exit nounset pipefail

SCRIPT_DIR="${0:A:h}"
# shellcheck source=development/skills/bootstrap/scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# --- constants ----------------------------------------------------------------

readonly CONFIG_DIR="${HOME}/.config/claude-plugins"
readonly CONFIG_FILE="${CONFIG_DIR}/apps.json"
readonly KNOWN_APPS=(claude-approver claude-maintenance)

# Approver only evaluates PRs from authors on this list. Bootstrap stores it
# as a per-repo variable so the user can widen it later via the GitHub UI
# (e.g., to ["*"] for human PRs) without editing this script.
#
# The maintenance bot's entry is appended at runtime from the App's REAL
# slug (#229): GitHub App slugs are globally unique, so registered apps get
# owner-suffixed slugs like `claude-maintenance-<owner>` — the generic
# `claude-maintenance[bot]` login never matches an actual PR author.
readonly BASE_AUTHOR_ALLOWLIST='["dependabot[bot]","github-actions[bot]"]'

readonly REGISTER_SCRIPT="${SCRIPT_DIR}/register-claude-apps.sh"

# --- helpers ------------------------------------------------------------------

app_display_name() {
  case "$1" in
    claude-approver)    print -- "Claude Approver" ;;
    claude-maintenance) print -- "Claude Maintenance" ;;
    *) die "Unknown app: $1" ;;
  esac
}

config_key_for() { print -- "${1//-/_}" }

# --- preflight ---------------------------------------------------------------

verify_register_run() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    err "register-claude-apps.sh has not been run yet on this machine."
    err "  Run: $REGISTER_SCRIPT"
    exit 1
  fi
  local app key
  for app in "${KNOWN_APPS[@]}"; do
    key=$(config_key_for "$app")
    if ! jq -e --arg key "$key" '.[$key].app_id' "$CONFIG_FILE" >/dev/null 2>&1; then
      err "$(app_display_name "$app") not registered locally."
      err "  Run: $REGISTER_SCRIPT"
      exit 1
    fi
    if ! security find-generic-password \
            -s "claude-plugins.${app}" \
            -a "private-key" \
            -w >/dev/null 2>&1; then
      err "Private key missing in Keychain for $(app_display_name "$app")."
      err "  Run: $REGISTER_SCRIPT --reset $app"
      err "  Then re-run: $REGISTER_SCRIPT"
      exit 1
    fi
  done
}

get_repo_info() {
  command -v gh >/dev/null 2>&1 || die "gh CLI not on PATH"
  gh repo view --json owner,name 2>/dev/null \
    || die "Not in a GitHub-tracked repo, or gh not authenticated."
}

# --- per-app fetch -----------------------------------------------------------

app_id_for() {
  local key
  key=$(config_key_for "$1")
  jq -r --arg key "$key" '.[$key].app_id' "$CONFIG_FILE"
}

app_slug_for() {
  local key
  key=$(config_key_for "$1")
  jq -r --arg key "$key" '.[$key].slug // empty' "$CONFIG_FILE"
}

# Resolve an app's slug, falling back to a live GET /app lookup when
# apps.json has an empty slug (the register --import path doesn't capture
# it — #229). A successful lookup is backfilled into apps.json so the
# fallback runs at most once per app per machine.
app_slug_resolve() {
  local app="$1" slug key
  slug=$(app_slug_for "$app")
  if [[ -n "$slug" ]]; then
    print -- "$slug"
    return 0
  fi

  info "apps.json has no slug for $app — resolving via GET /app…" >&2

  # Mint a short-lived App JWT (same recipe as mint-maintenance-token.zsh)
  # and ask GitHub which app this key belongs to.
  local app_id pem header_b64 payload_b64 iat exp signing_input sig_b64 jwt tmp_pem
  app_id=$(app_id_for "$app")
  pem=$(app_pem_for "$app")
  b64url() { base64 | tr '/+' '_-' | tr -d '=' | tr -d '\n' }
  header_b64=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  iat=$(($(date +%s) - 60))
  exp=$(($(date +%s) + 300))
  payload_b64=$(printf '{"iat":%d,"exp":%d,"iss":%s}' "$iat" "$exp" "$app_id" | b64url)
  signing_input="${header_b64}.${payload_b64}"
  tmp_pem=$(mktemp -t claude-apps-pem.XXXXXX)
  trap 'rm -f "$tmp_pem"' EXIT
  print -r -- "$pem" > "$tmp_pem"
  sig_b64=$(printf '%s' "$signing_input" \
    | openssl dgst -sha256 -sign "$tmp_pem" -binary | b64url)
  rm -f "$tmp_pem"
  jwt="${signing_input}.${sig_b64}"

  slug=$(curl -sS \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app" | jq -r '.slug // empty')

  if [[ -z "$slug" ]]; then
    return 1
  fi

  # Backfill apps.json so future runs skip the lookup.
  key=$(config_key_for "$app")
  jq --arg key "$key" --arg slug "$slug" '.[$key].slug = $slug' \
    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  ok "Resolved + backfilled slug for $app: $slug" >&2

  print -- "$slug"
}

app_pem_for() {
  local raw
  raw=$(security find-generic-password \
    -s "claude-plugins.$1" \
    -a "private-key" \
    -w)
  # macOS `security find-generic-password -w` returns the stored value
  # hex-encoded when it contains newlines. PEM private keys are
  # multi-line, so we get hex back instead of the original PEM. Decode
  # if the retrieval looks like pure hex; otherwise pass through. The
  # check is conservative — PEMs contain `-` `=` newlines, none of
  # which appear in hex output. See #208.
  if [[ "$raw" =~ ^[0-9a-fA-F]+$ ]]; then
    printf '%s' "$raw" | xxd -r -p
  else
    printf '%s' "$raw"
  fi
}

# --- browser-based install ---------------------------------------------------

walk_browser_install() {
  local app="$1" repo_nwo="$2" slug
  slug=$(app_slug_for "$app")
  if [[ -z "$slug" ]]; then
    # --import path stores empty slug. Fall back to the App management page.
    warn "Slug missing in apps.json for $(app_display_name "$app")."
    warn "  Find the App at https://github.com/settings/apps and click Install."
    print
    # `read -p` is bash-only; in zsh `-p` means "read from coprocess". Use
    # /dev/tty so it works in both shells. See #196.
    printf 'Press Enter once the install is complete… ' > /dev/tty
    read -r _ < /dev/tty
    return
  fi

  local install_url="https://github.com/apps/${slug}/installations/new"
  info "Installing $(app_display_name "$app") on $repo_nwo"
  print -- "  When the install page loads:"
  print -- "    1. Choose your account (not an org)."
  print -- "    2. Select 'Only select repositories' and pick $repo_nwo."
  print -- "    3. Click Install (or Update access if the App is already installed)."
  print
  if ! ask_yn "Open install page in browser now?"; then
    die "Aborted by user."
  fi
  # `open_browser` (from lib.sh) tries named browsers in order, falling back
  # to the default — robust against Launch Services having no .html handler.
  # See #197.
  open_browser "$install_url"
  print
  printf 'Press Enter once the install is complete… ' > /dev/tty
  read -r _ < /dev/tty
}

# --- Anthropic API key -------------------------------------------------------

resolve_anthropic_key() {
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    ok "Using ANTHROPIC_API_KEY from environment."
    print -- "$ANTHROPIC_API_KEY"
    return
  fi

  local key
  while true; do
    ask_secret "Paste ANTHROPIC_API_KEY (sk-ant-...):" key
    [[ -z "$key" ]] && { err "Empty key."; continue; }
    [[ "$key" == sk-ant-* ]] && break
    warn "Doesn't look like an Anthropic API key (expected sk-ant-... prefix)."
  done
  print -- "$key"
}

# --- usage --------------------------------------------------------------------

print_usage() {
  cat <<EOF
install-claude-apps.sh — install both Claude GitHub Apps on the current repo
and store the per-repo secrets + variables the Approver and Maintenance
identities need.

Usage:
  install-claude-apps.sh         Walk the install for both Apps on the
                                  current repo (interactive).
  install-claude-apps.sh --help  Show this help.

Prerequisites:
  - register-claude-apps.sh has been run on this machine.
  - gh CLI authenticated against the repo's hosting account.
  - Run from inside the target repo's working tree.

What it stores per-repo:
  Variables:
    CLAUDE_APPROVER_APP_ID
    CLAUDE_MAINTENANCE_APP_ID
    CLAUDE_APPROVER_AUTHOR_ALLOWLIST  (default machine-only)
  Secrets (set in Actions and Dependabot scopes):
    CLAUDE_APPROVER_PRIVATE_KEY
    CLAUDE_MAINTENANCE_PRIVATE_KEY
    ANTHROPIC_API_KEY                 (env or prompt)

Environment overrides:
  ANTHROPIC_API_KEY                   skip the prompt; use this value.

See development/skills/bootstrap/docs/CLAUDE-APPS.md for the design,
the manual fallback flow, and the permissions reference.
EOF
}

# --- main --------------------------------------------------------------------

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_usage
    return 0
  fi
  if [[ -n "${1:-}" ]]; then
    err "Unknown argument: $1"
    print
    print_usage
    exit 2
  fi

  require_macos
  require_tools gh jq

  verify_register_run

  local repo_info owner name repo_nwo
  repo_info=$(get_repo_info)
  owner=$(print -- "$repo_info" | jq -r .owner.login)
  name=$(print  -- "$repo_info" | jq -r .name)
  repo_nwo="${owner}/${name}"

  info "═══ Claude Apps install: $repo_nwo ═══"
  print

  # 1. Walk the user through installing each App on the repo.
  local app
  for app in "${KNOWN_APPS[@]}"; do
    walk_browser_install "$app" "$repo_nwo"
    print
  done

  # 2. Capture the Anthropic API key (env var, else prompt).
  info "Anthropic API key"
  local anthropic_key
  anthropic_key=$(resolve_anthropic_key)
  print

  # 3. Store per-repo secrets + variables.
  info "Storing per-repo secrets and variables…"

  local approver_id maintenance_id approver_pem maintenance_pem
  approver_id=$(app_id_for claude-approver)
  maintenance_id=$(app_id_for claude-maintenance)
  approver_pem=$(app_pem_for claude-approver)
  maintenance_pem=$(app_pem_for claude-maintenance)

  # Variables — non-secret, plain text.
  gh variable set CLAUDE_APPROVER_APP_ID    --body "$approver_id"
  ok "Variable set: CLAUDE_APPROVER_APP_ID = $approver_id"
  gh variable set CLAUDE_MAINTENANCE_APP_ID --body "$maintenance_id"
  ok "Variable set: CLAUDE_MAINTENANCE_APP_ID = $maintenance_id"

  # Allowlist: base entries + the maintenance bot's REAL login (#229).
  # The bot login is "<slug>[bot]" with the owner-suffixed slug, e.g.
  # "claude-maintenance-timo-jakob[bot]" — never the generic name.
  local maintenance_slug author_allowlist
  if maintenance_slug=$(app_slug_resolve claude-maintenance); then
    author_allowlist=$(jq -nc --argjson base "$BASE_AUTHOR_ALLOWLIST" \
      --arg m "${maintenance_slug}[bot]" '$base + [$m]')
  else
    warn "Could not resolve the claude-maintenance App slug; allowlist will"
    warn "not include the maintenance bot. Add \"<slug>[bot]\" to the"
    warn "CLAUDE_APPROVER_AUTHOR_ALLOWLIST repo variable manually (the slug"
    warn "is shown on https://github.com/settings/apps)."
    author_allowlist="$BASE_AUTHOR_ALLOWLIST"
  fi
  gh variable set CLAUDE_APPROVER_AUTHOR_ALLOWLIST --body "$author_allowlist"
  ok "Variable set: CLAUDE_APPROVER_AUTHOR_ALLOWLIST = $author_allowlist"

  # Secrets — stored in both Actions and Dependabot scopes via lib.sh helper.
  gh_secret_set_both CLAUDE_APPROVER_PRIVATE_KEY    "$approver_pem"
  ok "Secret set:   CLAUDE_APPROVER_PRIVATE_KEY"
  gh_secret_set_both CLAUDE_MAINTENANCE_PRIVATE_KEY "$maintenance_pem"
  ok "Secret set:   CLAUDE_MAINTENANCE_PRIVATE_KEY"
  gh_secret_set_both ANTHROPIC_API_KEY              "$anthropic_key"
  ok "Secret set:   ANTHROPIC_API_KEY"

  print
  ok "Claude Apps installed and configured on $repo_nwo."
  print -- "  Next: open a PR — the Approver evaluates once CI lands green."
  print -- "  See development-python/docs/python-approver.md for runtime behaviour."
  print -- "  Run '/development-python:approve' locally to dry-run before pushing."
}

main "$@"
