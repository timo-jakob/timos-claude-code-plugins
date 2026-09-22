#!/usr/bin/env zsh
# mint-maintenance-token.zsh — mint a claude-maintenance App installation
# token for the current repo. Writes the token to a mode-600 temp file and
# prints the FILE PATH (default); `--stdout` prints the raw token instead.
#
# Used by /development:maintenance during Phase 8 PR creation so that
# maintenance-opened PRs attribute to claude-maintenance[bot] (a distinct
# identity from claude-approver[bot]). This is what makes the Claude
# Approver's anti-rubber-stamp gate fire correctly when the Approver
# evaluates maintenance-opened PRs.
#
# Why print a path by default (#640): so a naive `TOKEN=$(mint...)` captures
# a path, not a secret — a token value in a shell variable is one `echo` away
# from the session transcript that .tgz handoffs ship around. A caller that
# needs the value in-process reads it inline: `$(cat <path>)`, then `rm -f`.
#
# Prerequisites:
#   - register-claude-apps.zsh has registered claude-maintenance for the OWNER of the
#     current repository (#1683): an owners[<owner>] entry in
#     ~/.config/claude-plugins/apps.json + its key in the Keychain service
#     claude-plugins.<owner>.claude-maintenance. The owner is resolved from the repo
#     (claude-apps-owner.zsh), so an organisation repo mints the organisation's
#     App and a personal repo the personal one, with no flag.
#   - install-claude-apps.zsh has been run on the current repo (the App is
#     installed on this repo so the installation-discovery succeeds).
#   - Run from inside the target repo's working tree.
#
# Exit codes:
#   0 — success (path printed, or token printed with --stdout)
#   1 — prerequisite missing (owner unresolvable, App not registered for the
#       owner, apps.json still schema 1 — the message names the command)
#   2 — GitHub API failure (network, expired key, etc.)
#
# Stdout (default): the path to a mode-600 temp file holding the token
#   (one line, no trailing newline). The caller owns the file — read it with
#   `$(cat <path>)` at the point of use and `rm -f` it when done.
# Stdout (--stdout): the raw installation token (one line, no trailing
#   newline). Escape hatch for callers that cannot read from a file path.
# Stderr: human-readable diagnostics on failure.
#
# Token lifetime: 1 hour (GitHub's default for installation tokens).
# Re-mint if maintenance runs longer than that.

setopt err_exit nounset pipefail

# --- argument parsing --------------------------------------------------------
emit_stdout=false
if [[ "${1:-}" == "--stdout" ]]; then
  emit_stdout=true
fi

readonly APP="claude-maintenance"

# The one owner-resolution answer every Claude Apps consumer shares (#1683).
# shellcheck source=development/skills/bootstrap/scripts/claude-apps-owner.zsh
source "${0:A:h}/../../bootstrap/scripts/claude-apps-owner.zsh"

# --- preconditions -----------------------------------------------------------

command -v gh >/dev/null 2>&1 || { print -u2 -- "gh CLI not on PATH."; exit 1; }
command -v curl >/dev/null 2>&1 || { print -u2 -- "curl not on PATH."; exit 1; }
command -v openssl >/dev/null 2>&1 || { print -u2 -- "openssl not on PATH."; exit 1; }
command -v jq >/dev/null 2>&1 || { print -u2 -- "jq not on PATH."; exit 1; }

# The repo's owner picks the pair: owners[<owner>] and
# claude-plugins.<owner>.claude-maintenance only. A missing owner or App is
# an error naming the register command — never a fall-through to another owner's App or to a
# pre-#1682 top-level key / Keychain item.
claude_apps_load || exit 1
app_id=$(claude_apps_app_id "$APP") || exit 1
pem=$(claude_apps_read_pem "$APP") || exit 1
owner_repo="$CA_REPO"

# --- build JWT ---------------------------------------------------------------

# JWT format: <header_b64>.<payload_b64>.<sig_b64>, where each piece is
# URL-safe base64 with no padding.
b64url() {
  base64 | tr '/+' '_-' | tr -d '=' | tr -d '\n'
}

header_b64=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)

# iat = now - 60s (clock skew tolerance); exp = now + 5min (well under
# GitHub's 10-min cap for App JWTs).
iat=$(($(date +%s) - 60))
exp=$(($(date +%s) + 300))
payload_b64=$(printf '{"iat":%d,"exp":%d,"iss":%s}' "$iat" "$exp" "$app_id" | b64url)

signing_input="${header_b64}.${payload_b64}"

# Sign with openssl. Pipe the PEM via a temp file because openssl's -sign
# wants a file path. The temp file is removed via trap.
tmp_pem=$(mktemp -t claude-maintenance-pem.XXXXXX)
trap 'rm -f "$tmp_pem"' EXIT
print -r -- "$pem" > "$tmp_pem"

sig_b64=$(printf '%s' "$signing_input" \
  | openssl dgst -sha256 -sign "$tmp_pem" -binary \
  | b64url)

jwt="${signing_input}.${sig_b64}"

# --- discover installation for this repo ------------------------------------

install_resp=$(curl -sS \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${owner_repo}/installation" \
  || true)

install_id=$(printf '%s' "$install_resp" | jq -r '.id // empty' 2>/dev/null || true)
if [[ -z "$install_id" || "$install_id" == "null" ]]; then
  # Only GitHub's own 404 means "not installed" (#1683): callers such as
  # /development:open-pr key their fallback on that line, so an unreachable
  # GitHub or a key it rejects must never read as it.
  if [[ -z "$install_resp" ]]; then
    print -u2 -- "Could not reach GitHub to look up the claude-maintenance installation on ${owner_repo} (network?)."
    print -u2 -- "  Re-run once GitHub is reachable."
  elif [[ "$(printf '%s' "$install_resp" | jq -r '.message // empty' 2>/dev/null || true)" == "Not Found" ]]; then
    print -u2 -- "claude-maintenance App is not installed on ${owner_repo}."
    print -u2 -- "  Re-run /development:bootstrap --claude-approver true to install."
  else
    print -u2 -- "GitHub rejected the claude-maintenance installation lookup on ${owner_repo} — a key it no longer accepts?"
    print -u2 -- "  Check the key: install-claude-apps.zsh --verify --fix (inside this repo)."
  fi
  print -u2 -- "  API response: $install_resp"
  exit 2
fi

# --- mint the installation token --------------------------------------------

token_resp=$(curl -sS -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${install_id}/access_tokens" \
  || true)

token=$(printf '%s' "$token_resp" | jq -r '.token // empty')
if [[ -z "$token" || "$token" == "null" ]]; then
  print -u2 -- "Failed to mint installation token."
  print -u2 -- "  API response: $token_resp"
  exit 2
fi

if [[ "$emit_stdout" == true ]]; then
  # Escape hatch: raw token on stdout. Use only when the caller genuinely
  # cannot read from a file path. A token on stdout is easily captured into
  # a shell variable and echoed into a transcript — the leak #640 fixes.
  print -n -- "$token"
else
  # Default (#640): never expose the token value to the caller. Write it to a
  # mode-600 temp file and print only the PATH. mktemp already restricts the
  # file to the owner; chmod 600 makes the intent explicit and defends against
  # a permissive umask. The caller reads it with `$(cat <path>)` and removes
  # the file when done.
  token_file=$(mktemp -t claude-maintenance-token.XXXXXX)
  chmod 600 "$token_file"
  print -rn -- "$token" > "$token_file"
  print -rn -- "$token_file"
fi
