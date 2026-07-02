#!/usr/bin/env zsh
# install-claude-apps.zsh — install both Claude GitHub Apps on the current
# repo. Since epic #476 the Approver and Maintenance identities mint their
# installation tokens LOCALLY from the Keychain (mint-approver-token.zsh /
# mint-maintenance-token.zsh), so this script stores NO repo secrets or
# variables (#498) — the App *installation* on the repo is all that's needed
# for the identities to post reviews and author PRs.
#
# Prerequisites:
#   - register-claude-apps.zsh has been run (apps.json entries + Keychain
#     keys for both claude-approver and claude-maintenance exist)
#   - gh CLI authenticated against the repo's hosting account
#   - the script is run from inside the target repo's working tree
#
# What it does:
#   1. Opens https://github.com/apps/<slug>/installations/new in the
#      browser for each App so the user installs them on the target repo.
#   2. Flags leftover CI-era repo secrets/variables (pre-#476 installs
#      stored the App PEMs as repo secrets) for cleanup.
#
# Doctor mode (#234): `--verify [--fix]` detects wrong — not just
# missing — Keychain keys (local JWT validation against GET /app),
# guides the user through key regeneration when the local key is bad,
# and under --fix deletes the obsolete CI-era repo secrets/variables.
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

# CI-era repo config (pre-#476/#498). The Actions-based Approver stored the
# App PEMs, an Anthropic key, and gate variables per-repo; nothing consumes
# them since approval went local — the PEM secrets in particular are pure
# liability (a private key copied out of the Keychain). The doctor flags
# them and deletes them under --fix, unless a workflow file still
# references the name (a legacy claude-approver.yml not yet removed).
readonly -a LEGACY_SECRETS=(
  CLAUDE_APPROVER_PRIVATE_KEY CLAUDE_MAINTENANCE_PRIVATE_KEY ANTHROPIC_API_KEY
)
readonly -a LEGACY_VARIABLES=(
  CLAUDE_APPROVER_APP_ID CLAUDE_MAINTENANCE_APP_ID CLAUDE_APPROVER_AUTHOR_ALLOWLIST
)

readonly REGISTER_SCRIPT="${SCRIPT_DIR}/register-claude-apps.zsh"

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
  # Optional app subset (e.g. just claude-maintenance for --writer-only);
  # defaults to all KNOWN_APPS.
  local check_apps=("$@")
  (( ${#check_apps} )) || check_apps=("${KNOWN_APPS[@]}")
  if [[ ! -f "$CONFIG_FILE" ]]; then
    err "register-claude-apps.zsh has not been run yet on this machine."
    err "  Run: $REGISTER_SCRIPT"
    exit 1
  fi
  local app key
  for app in "${check_apps[@]}"; do
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

  # Backfill apps.json so future runs skip the lookup. GET /app also
  # returns the Client ID — record it alongside the slug (#223): nothing
  # consumes it yet (the numeric App ID stays a valid JWT issuer and
  # create-github-app-token client-id value), but capturing it here
  # spares a manual lookup if GitHub ever drops numeric-ID acceptance.
  local client_id
  client_id=$(print -r -- "$resp" | jq -r '.client_id // empty')
  key=$(config_key_for "$app")
  jq --arg key "$key" --arg slug "$slug" --arg cid "$client_id" \
    '.[$key].slug = $slug
     | if $cid != "" then .[$key].client_id = $cid else . end' \
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

# Is a legacy secret/variable name still referenced by a workflow file?
# A pre-#476 claude-approver.yml (or any user workflow) that still reads
# the name makes deletion unsafe — flag instead of delete, and point at
# the workflow that pins it.
legacy_name_in_workflows() {
  local name="$1"
  grep -rls -- "$name" .github/workflows 2>/dev/null
}

# Flag (and under --fix delete) the CI-era repo secrets/variables that
# pre-#476 installs stored (#498). Deletion is per-name conservative:
# skipped with a warning when any workflow file still references the
# name. ANTHROPIC_API_KEY additionally never auto-deletes — unlike the
# CLAUDE_* names it isn't unambiguously ours, so removal stays a
# suggested manual command.
check_legacy_repo_config() {
  local fix="${1:-}" name refs found=0
  local actions_secrets dependabot_secrets variables
  actions_secrets=$(gh secret list --json name --jq '.[].name' 2>/dev/null) || actions_secrets=""
  dependabot_secrets=$(gh secret list --app dependabot --json name --jq '.[].name' 2>/dev/null) || dependabot_secrets=""
  variables=$(gh variable list --json name --jq '.[].name' 2>/dev/null) || variables=""

  for name in "${LEGACY_SECRETS[@]}"; do
    local in_actions="" in_dependabot=""
    print -r -- "$actions_secrets"    | grep -qx "$name" && in_actions=1
    print -r -- "$dependabot_secrets" | grep -qx "$name" && in_dependabot=1
    [[ -z "$in_actions" && -z "$in_dependabot" ]] && continue
    found=1
    if refs=$(legacy_name_in_workflows "$name") && [[ -n "$refs" ]]; then
      warn "Legacy secret $name is still referenced by: ${refs//$'\n'/, }"
      warn "  Remove that workflow first (epic #476 retired the Actions Approver)."
      continue
    fi
    if [[ -n "$fix" && "$name" != ANTHROPIC_API_KEY ]]; then
      [[ -n "$in_actions"    ]] && gh secret delete "$name" >/dev/null \
        && ok "Deleted legacy Actions secret $name."
      [[ -n "$in_dependabot" ]] && gh secret delete "$name" --app dependabot >/dev/null \
        && ok "Deleted legacy Dependabot-scope secret $name."
    else
      warn "Legacy secret $name present — nothing consumes it since #476."
      if [[ "$name" == ANTHROPIC_API_KEY ]]; then
        warn "  Not auto-deleted (may serve other tooling). If unused:"
        warn "  gh secret delete $name; gh secret delete $name --app dependabot"
      fi
    fi
  done

  for name in "${LEGACY_VARIABLES[@]}"; do
    print -r -- "$variables" | grep -qx "$name" || continue
    found=1
    if refs=$(legacy_name_in_workflows "$name") && [[ -n "$refs" ]]; then
      warn "Legacy variable $name is still referenced by: ${refs//$'\n'/, }"
      warn "  Remove that workflow first (epic #476 retired the Actions Approver)."
      continue
    fi
    if [[ -n "$fix" ]]; then
      gh variable delete "$name" >/dev/null && ok "Deleted legacy variable $name."
    else
      warn "Legacy variable $name present — nothing consumes it since #476."
    fi
  done

  if (( found )); then
    [[ -z "$fix" ]] && warn "Clean up with: install-claude-apps.zsh --verify --fix"
  else
    ok "No legacy CI-era secrets/variables on this repo."
  fi
  return 0
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

  # NOTE: every loop-used variable must be declared here, NOT inside the
  # loop. zsh's `local name` (no assignment) on an already-declared local
  # PRINTS the variable and its value — that pattern leaked a private key
  # to stdout during #234 testing.
  local problems=0 app display key pem
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

    # 3. Approver push access (#418). GitHub tallies an APPROVE toward a
    #     branch's required_approving_review_count ONLY when the reviewer can
    #     push to the repo — and "push access" is the Contents permission, not
    #     Pull requests. A claude-approver still on the old Contents:read grant
    #     posts reviews that never satisfy the gate (authorCanPushToRepository=
    #     false), so green PRs stay reviewDecision=REVIEW_REQUIRED / BLOCKED.
    #     Probe GET /app (the JWT already authenticated above) and flag a stale
    #     grant — a permission INCREASE needs the user to re-accept the install,
    #     so re-registering alone doesn't fix an existing installation.
    if [[ "$app" == claude-approver ]]; then
      app_meta=$(app_probe_with_pem "$(app_id_for "$app")" "$pem" 2>/dev/null) || app_meta=""
      contents_perm=$(print -r -- "$app_meta" | jq -r '.permissions.contents // "none"' 2>/dev/null)
      if [[ "$contents_perm" == "write" ]]; then
        ok "$display: Contents:write present — its approvals count toward branch protection."
      else
        err "$display: Contents permission is '$contents_perm', must be 'write' (#418)."
        err "  Without it the App's approvals don't count toward branch protection,"
        err "  so green + Approver-approved PRs stay BLOCKED and never auto-merge."
        err "  Fix: App settings → Permissions → Contents: Read & write → Save, then"
        err "  github.com/settings/installations → $display → Configure → accept the"
        err "  permission update (re-registering only affects brand-new installs)."
        (( problems++ )) || true
      fi
    fi

  done
  print

  # 4. Legacy CI-era repo config (#498): flag leftover secrets/variables
  #    from pre-#476 installs; --fix deletes the unambiguous ones.
  check_legacy_repo_config "$fix"
  print

  if (( problems == 0 )); then
    ok "Doctor found no problems on $repo_nwo."
  elif [[ -n "$fix" ]]; then
    ok "Doctor finished — $problems problem(s) found and addressed above."
  else
    warn "$problems problem(s) found. Re-run with: install-claude-apps.zsh --verify --fix"
    return 1
  fi
}

# --- browser-based install ---------------------------------------------------

walk_browser_install() {
  local app="$1" repo_nwo="$2" slug
  # Resolve the slug (live GET /app + apps.json backfill) when the --import
  # registration path stored it empty — the same fallback the secret-storage
  # step uses. Only drop to the manual hunt when even the live lookup fails.
  slug=$(app_slug_resolve "$app") || slug=""
  if [[ -z "$slug" ]]; then
    warn "Could not resolve the slug for $(app_display_name "$app")."
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

# --- usage --------------------------------------------------------------------

print_usage() {
  cat <<EOF
install-claude-apps.zsh — install both Claude GitHub Apps on the current repo.
No repo secrets or variables are stored (#476/#498): both identities mint
their tokens locally from the Keychain, so installing the Apps is all a repo
needs.

Usage:
  install-claude-apps.zsh                  Walk the install for both Apps on
                                           the current repo (interactive).
  install-claude-apps.zsh --writer-only    Install ONLY the Maintenance App (the
                                           writer) — for Claude-plugin repos,
                                           where a human approves (no Approver)
                                           and PRs come from the writer bot via
                                           /development:open-pr.
  install-claude-apps.zsh --verify         Doctor: validate the local keys
                                           (parseable + cryptographically
                                           matching their App via GET /app),
                                           check the Approver's Contents:write
                                           grant (#418), and flag leftover
                                           CI-era repo secrets/variables from
                                           pre-#476 installs. Read-only.
  install-claude-apps.zsh --verify --fix   Doctor + converge: delete the
                                           obsolete CI-era secrets/variables
                                           (skipping any a workflow file still
                                           references, and never touching
                                           ANTHROPIC_API_KEY automatically).
                                           Guides you through key regeneration
                                           when the Keychain key itself is
                                           missing or invalid (the one step
                                           GitHub has no API for).
  install-claude-apps.zsh --help           Show this help.

Prerequisites:
  - register-claude-apps.zsh has been run on this machine.
  - gh CLI authenticated against the repo's hosting account.
  - Run from inside the target repo's working tree.

See development/skills/bootstrap/docs/CLAUDE-APPS.md for the design,
the manual fallback flow, and the permissions reference.
EOF
}

# --- main --------------------------------------------------------------------

main() {
  local writer_only=""
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
    --writer-only)
      writer_only=1
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

  # writer-only installs just the Maintenance App (the writer); full install
  # needs both Apps registered.
  if [[ -n "$writer_only" ]]; then
    verify_register_run claude-maintenance
  else
    verify_register_run
  fi

  local repo_info owner name repo_nwo
  repo_info=$(get_repo_info)
  owner=$(print -- "$repo_info" | jq -r .owner.login)
  name=$(print  -- "$repo_info" | jq -r .name)
  repo_nwo="${owner}/${name}"

  # --- writer-only path (plugin repos) ----------------------------------------
  # Install ONLY the Maintenance App as the writer. No Approver (plugin repos are
  # human-only approval), and no per-repo secrets/variables: /development:open-pr
  # mints the writer token LOCALLY from the Keychain key, so nothing in this repo
  # or its CI needs the private key.
  if [[ -n "$writer_only" ]]; then
    info "═══ Claude writer-App install (writer-only): $repo_nwo ═══"
    print
    walk_browser_install claude-maintenance "$repo_nwo"
    print
    ok "Claude writer App (Claude Maintenance) installed on $repo_nwo."
    print -- "  /development:open-pr now opens PRs authored by"
    print -- "  claude-maintenance-${owner}[bot] — you approve, squash auto-merge."
    print -- "  No Approver is installed (plugin repos are human-only approval)."
    print -- "  The writer token is minted locally from your Keychain; this repo"
    print -- "  needs no secrets."
    return 0
  fi

  info "═══ Claude Apps install: $repo_nwo ═══"
  print

  # 1. Walk the user through installing each App on the repo.
  local app
  for app in "${KNOWN_APPS[@]}"; do
    walk_browser_install "$app" "$repo_nwo"
    print
  done

  # 2. Nothing to store (#476/#498): both identities mint their tokens
  #    locally from the Keychain. Flag any CI-era leftovers from an
  #    earlier install so the user knows to clean up.
  check_legacy_repo_config ""

  print
  ok "Claude Apps installed on $repo_nwo."
  print -- "  No repo secrets or variables were stored — tokens are minted"
  print -- "  locally from your Keychain when needed."
  print -- "  Approve PRs with '/development-<lang>:approve <PR>' (posts as"
  print -- "  the Approver App); /development:maintenance opens PRs as the"
  print -- "  Maintenance App the same way."
}

# Run main only when executed directly — when the file is *sourced* (unit
# tests exercising its functions) ZSH_EVAL_CONTEXT carries a `:file`
# segment and we skip it, so sourcing has no side effects.
if [[ "${ZSH_EVAL_CONTEXT:-}" != *:file* ]]; then
  main "$@"
fi
