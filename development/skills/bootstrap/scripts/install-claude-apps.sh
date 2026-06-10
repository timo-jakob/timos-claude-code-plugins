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
#      Private keys are validated against their App (JWT → GET /app)
#      and normalized to PKCS#8 before being set (#234).
#
# Doctor mode (#234): `--verify [--fix]` detects wrong — not just
# missing — keys (local validation + failed mint steps in recent
# Approver runs as runtime evidence), converges repo secrets from the
# validated Keychain keys, and guides the user through key
# regeneration when the local key itself is bad.
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

# Mint a short-lived App JWT from a PEM (same recipe as
# mint-maintenance-token.zsh) and ask GitHub which App the key belongs
# to. Prints the GET /app response JSON; returns non-zero when the key
# cannot sign or GitHub rejects the JWT — callers decide whether that
# is fatal. Shared by slug resolution (#229) and key validation (#234).
app_probe_with_pem() {
  local app_id="$1" pem="$2"
  local header_b64 payload_b64 iat exp signing_input sig_b64 jwt tmp_pem resp
  b64url() { base64 | tr '/+' '_-' | tr -d '=' | tr -d '\n' }
  header_b64=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  iat=$(($(date +%s) - 60))
  exp=$(($(date +%s) + 300))
  payload_b64=$(printf '{"iat":%d,"exp":%d,"iss":%s}' "$iat" "$exp" "$app_id" | b64url)
  signing_input="${header_b64}.${payload_b64}"
  tmp_pem=$(mktemp -t claude-apps-pem.XXXXXX)
  print -r -- "$pem" > "$tmp_pem"
  sig_b64=$(printf '%s' "$signing_input" \
    | openssl dgst -sha256 -sign "$tmp_pem" -binary 2>/dev/null | b64url) \
    || sig_b64=""
  rm -f "$tmp_pem"
  [[ -n "$sig_b64" ]] || return 1
  jwt="${signing_input}.${sig_b64}"

  resp=$(curl -sS \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app") || return 1
  # GitHub answers a bad JWT with a JSON error object that has no .id.
  print -r -- "$resp" | jq -e '.id' >/dev/null 2>&1 || return 1
  print -r -- "$resp"
}

# Prove that a PEM is parseable and cryptographically belongs to the
# registered App (#234): mint a JWT with it and require GET /app to
# return the expected app_id. Catches truncated keys, format corruption,
# and keys from a different App — failures that otherwise only surface
# as cryptic runtime errors in the workflow's mint step.
pem_validate_for_app() {
  local app="$1" pem="$2"
  local app_id resp got_id
  app_id=$(app_id_for "$app")
  resp=$(app_probe_with_pem "$app_id" "$pem") || return 1
  got_id=$(print -r -- "$resp" | jq -r '.id // empty')
  [[ "$got_id" == "$app_id" ]]
}

# Normalize a private key to PKCS#8 (#234). GitHub generates App keys in
# PKCS#1 ('BEGIN RSA PRIVATE KEY'); actions/create-github-app-token@v1
# accepted that, but v3+ (WebCrypto-based) only reads PKCS#8 ('BEGIN
# PRIVATE KEY') and fails with 'DataError: Invalid keyData'. The
# conversion is lossless and v1 accepts PKCS#8 too, so only the
# normalized form may enter a repo secret.
pem_to_pkcs8() {
  local pem="$1" out
  out=$(print -r -- "$pem" | openssl pkcs8 -topk8 -nocrypt 2>/dev/null) || out=""
  [[ -n "$out" ]] || return 1
  print -r -- "$out"
}

# Fetch an app's key from the Keychain, prove it belongs to the App, and
# normalize it to PKCS#8 (#234). This is the only path by which a key
# may reach gh_secret_set_both.
prepare_pem() {
  local app="$1" pem
  pem=$(app_pem_for "$app")
  if ! pem_validate_for_app "$app" "$pem"; then
    err "The Keychain key for $(app_display_name "$app") does not authenticate as App ID $(app_id_for "$app")."
    err "It is unparseable, truncated, or belongs to a different App."
    err "Run: install-claude-apps.sh --verify --fix   (guided key regeneration)"
    return 1
  fi
  pem_to_pkcs8 "$pem" \
    || { err "PKCS#8 conversion failed for $(app_display_name "$app")."; return 1 }
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

  local resp
  resp=$(app_probe_with_pem "$(app_id_for "$app")" "$(app_pem_for "$app")") \
    || return 1
  slug=$(print -r -- "$resp" | jq -r '.slug // empty')

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

# --- doctor (--verify / --fix) — #234 -----------------------------------------

# Guided key regeneration — the one step GitHub has no API for. Leads the
# user to the App settings page, picks the downloaded key up from
# ~/Downloads automatically, validates it against the App, and stores it
# in the Keychain. Returns non-zero if the user aborts or the new key
# fails validation.
regenerate_key_flow() {
  local app="$1" display slug url pem
  display=$(app_display_name "$app")
  slug=$(app_slug_resolve "$app") || slug=""
  if [[ -n "$slug" ]]; then
    url="https://github.com/settings/apps/${slug}"
  else
    url="https://github.com/settings/apps"
  fi

  info "Manual step required for $display — GitHub has no API to mint App keys:"
  print -- "  1. The App settings page opens: $url"
  print -- "     (Org-owned App? Use https://github.com/organizations/<org>/settings/apps/<slug>)"
  print -- "  2. Scroll to 'Private keys' and click 'Generate a private key'."
  print -- "     Your browser downloads '<slug>.<date>.private-key.pem'."
  print -- "  3. Come back here — the download is picked up automatically."
  if ! ask_yn "Open the App settings page now?"; then
    return 1
  fi
  open_browser "$url"
  printf 'Press Enter once the key has downloaded… ' > /dev/tty
  read -r _ < /dev/tty

  # Newest matching download. (Nom) = null glob, sorted by mtime desc.
  local -a candidates
  if [[ -n "$slug" ]]; then
    candidates=( "${HOME}"/Downloads/${slug}.*.private-key.pem(Nom) )
  else
    candidates=( "${HOME}"/Downloads/*.private-key.pem(Nom) )
  fi
  local pem_path="${candidates[1]:-}"
  if [[ -z "$pem_path" ]]; then
    printf 'Not found in ~/Downloads. Path to the downloaded .pem: ' > /dev/tty
    read -r pem_path < /dev/tty
  fi
  [[ -r "$pem_path" ]] || { err "Not readable: $pem_path"; return 1 }
  ok "Using key file: $pem_path"

  pem=$(<"$pem_path")
  if ! pem_validate_for_app "$app" "$pem"; then
    err "That key does not authenticate as App ID $(app_id_for "$app") — wrong file?"
    return 1
  fi

  security add-generic-password -U \
    -s "claude-plugins.${app}" \
    -a "private-key" \
    -w "$pem" >/dev/null
  ok "$display: new key validated and stored in the Keychain."
  warn "Old keys stay valid until deleted — remove the previous one on $url."
  warn "The downloaded file is no longer needed: rm '$pem_path'"
}

# Runtime evidence that the key in the repo secret is WRONG rather than
# missing (#234): secrets cannot be read back, but a failed
# 'Mint Approver App token' step in the Approver's own runs proves the
# stored key is bad (unparseable, PKCS#1 under a v3 action, or from a
# different App). Prints the newest such run id, if any.
latest_mint_failure_run() {
  local ids run_id
  ids=$(gh run list --workflow "Claude Approver" --limit 5 \
          --json databaseId,conclusion \
          --jq '.[] | select(.conclusion == "failure") | .databaseId' \
          2>/dev/null) || ids=""
  for run_id in ${(f)ids}; do
    if gh run view "$run_id" --json jobs \
         --jq '.jobs[].steps[]? | select(.name == "Mint Approver App token" and .conclusion == "failure") | .name' \
         2>/dev/null | grep -q .; then
      print -- "$run_id"
      return 0
    fi
  done
  return 1
}

cmd_verify() {
  local fix="${1:-}"
  require_macos
  require_tools gh jq openssl

  local repo_info owner name repo_nwo
  repo_info=$(get_repo_info)
  owner=$(print -- "$repo_info" | jq -r .owner.login)
  name=$(print  -- "$repo_info" | jq -r .name)
  repo_nwo="${owner}/${name}"

  info "═══ Claude Apps doctor: $repo_nwo ═══"
  print

  [[ -f "$CONFIG_FILE" ]] \
    || die "No apps.json — run $REGISTER_SCRIPT first."

  local secret_names
  secret_names=$(gh secret list --json name --jq '.[].name' 2>/dev/null) \
    || secret_names=""

  local problems=0 app display key pem fmt secret_name
  for app in "${KNOWN_APPS[@]}"; do
    display=$(app_display_name "$app")
    key=$(config_key_for "$app")

    # 1. Registered locally?
    if ! jq -e --arg key "$key" '.[$key].app_id' "$CONFIG_FILE" >/dev/null 2>&1; then
      err "$display: not registered locally — run $REGISTER_SCRIPT."
      (( problems++ )) || true
      continue
    fi

    # 2. Keychain key present + cryptographically valid for this App?
    pem=$(app_pem_for "$app" 2>/dev/null) || pem=""
    if [[ -z "$pem" ]] || ! pem_validate_for_app "$app" "$pem"; then
      if [[ -z "$pem" ]]; then
        err "$display: no private key in the Keychain."
      else
        err "$display: Keychain key does NOT authenticate as App ID $(app_id_for "$app")."
        err "  (unparseable, truncated, or belongs to a different App)"
      fi
      (( problems++ )) || true
      if [[ -n "$fix" ]]; then
        regenerate_key_flow "$app" || { err "$display: key regeneration failed."; continue }
        pem=$(app_pem_for "$app")
      else
        warn "  Re-run with --fix for guided key regeneration."
        continue
      fi
    else
      ok "$display: Keychain key authenticates as App ID $(app_id_for "$app")."
    fi

    # 3. Format note — PKCS#1 keys break create-github-app-token@v3.
    fmt=$(print -r -- "$pem" | head -1)
    if [[ "$fmt" == *"BEGIN RSA PRIVATE KEY"* ]]; then
      warn "$display: Keychain key is PKCS#1 — fine locally, but the repo secret"
      warn "  must be PKCS#8 for create-github-app-token@v3 ('Invalid keyData')."
    fi

    # 4. Repo secret present?
    secret_name="CLAUDE_$(print -- "${app#claude-}" | tr '[:lower:]-' '[:upper:]_')_PRIVATE_KEY"
    if ! print -r -- "$secret_names" | grep -qx "$secret_name"; then
      err "$display: repo secret $secret_name is missing."
      (( problems++ )) || true
    fi

    # 5. Fix: converge the repo secret onto the validated Keychain key,
    #    normalized to PKCS#8. Secrets can't be read back, so re-setting
    #    is also the only safe answer to "is the stored one correct?".
    if [[ -n "$fix" ]]; then
      local converted
      converted=$(pem_to_pkcs8 "$pem") \
        || { err "$display: PKCS#8 conversion failed."; (( problems++ )) || true; continue }
      gh_secret_set_both "$secret_name" "$converted"
      ok "$display: $secret_name re-set from the validated Keychain key (PKCS#8)."
    fi
  done
  print

  # 6. App-ID variable drift.
  local var_val expected
  expected=$(app_id_for claude-approver)
  var_val=$(gh variable get CLAUDE_APPROVER_APP_ID 2>/dev/null) || var_val=""
  if [[ "$var_val" != "$expected" ]]; then
    err "CLAUDE_APPROVER_APP_ID is '$var_val', expected '$expected'."
    (( problems++ )) || true
    if [[ -n "$fix" ]]; then
      gh variable set CLAUDE_APPROVER_APP_ID --body "$expected"
      ok "CLAUDE_APPROVER_APP_ID fixed."
    fi
  else
    ok "CLAUDE_APPROVER_APP_ID matches apps.json ($expected)."
  fi

  # 7. Runtime evidence: did the Approver's mint step fail recently?
  local mint_fail_run
  if mint_fail_run=$(latest_mint_failure_run); then
    warn "Run $mint_fail_run failed at 'Mint Approver App token' — the secret"
    warn "stored in the repo was bad at the time of that run."
    if [[ -n "$fix" ]]; then
      if ask_yn "Secrets are converged now. Re-run the failed Approver run?"; then
        gh run rerun "$mint_fail_run" --failed
        ok "Re-run dispatched: gh run watch $mint_fail_run"
      fi
    else
      warn "  Re-run with --fix to converge the secret, then re-run it:"
      warn "  gh run rerun $mint_fail_run --failed"
    fi
  else
    ok "No recent Approver run failed at the token mint step."
  fi
  print

  if (( problems == 0 )); then
    ok "Doctor found no problems on $repo_nwo."
  elif [[ -n "$fix" ]]; then
    ok "Doctor finished — $problems problem(s) found and addressed above."
  else
    warn "$problems problem(s) found. Re-run with: install-claude-apps.sh --verify --fix"
    return 1
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
  install-claude-apps.sh                  Walk the install for both Apps on
                                           the current repo (interactive).
  install-claude-apps.sh --verify         Doctor: validate the local keys
                                           (parseable + cryptographically
                                           matching their App via GET /app),
                                           check repo secrets/variables, and
                                           scan recent Approver runs for
                                           failed token-mint steps (= the
                                           stored secret is wrong, not just
                                           missing). Read-only.
  install-claude-apps.sh --verify --fix   Doctor + converge: re-set secrets
                                           from the validated Keychain keys
                                           (normalized to PKCS#8), fix
                                           variable drift, offer to re-run a
                                           failed Approver run. Guides you
                                           through key regeneration when the
                                           Keychain key itself is missing or
                                           invalid (the one step GitHub has
                                           no API for).
  install-claude-apps.sh --help           Show this help.

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
  case "${1:-}" in
    --help|-h)
      print_usage
      return 0
      ;;
    --verify)
      local fix=""
      if [[ "${2:-}" == "--fix" ]]; then
        fix=1
      elif [[ -n "${2:-}" ]]; then
        err "Unknown argument: $2"
        print
        print_usage
        exit 2
      fi
      cmd_verify "$fix"
      return
      ;;
    "")
      ;;
    *)
      err "Unknown argument: $1"
      print
      print_usage
      exit 2
      ;;
  esac

  require_macos
  require_tools gh jq openssl

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
  # Validated against the App + normalized to PKCS#8 before they may
  # enter a repo secret (#234).
  approver_pem=$(prepare_pem claude-approver)       || exit 1
  maintenance_pem=$(prepare_pem claude-maintenance) || exit 1

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
