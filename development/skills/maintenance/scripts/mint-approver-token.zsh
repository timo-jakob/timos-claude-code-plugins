#!/usr/bin/env zsh
# mint-approver-token.zsh — mint a claude-approver App installation token
# for the current repo, print to stdout.
#
# Used by /development-python:approve (and other language approve skills)
# to post code review verdicts. The App is invoked locally by the user,
# not by GitHub Actions. This is what enables approval without platform
# lock-in: user stays in control, no GitHub Actions, works with any AI
# coding assistant.
#
# Prerequisites:
#   - register-claude-apps.zsh has been run on this machine (claude-approver
#     entry in ~/.config/claude-plugins/apps.json + PEM in Keychain).
#   - install-claude-apps.zsh has been run on the current repo (the App is
#     installed on this repo so the installation-discovery succeeds).
#   - Run from inside the target repo's working tree.
#
# Exit codes:
#   0 — token printed to stdout
#   1 — prerequisite missing (Apps not registered / not installed locally)
#   2 — GitHub API failure (network, expired key, etc.)
#
# Stdout: the installation token (one line, no trailing newline).
# Stderr: human-readable diagnostics on failure.
#
# Token lifetime: 1 hour (GitHub's default for installation tokens).
# Re-mint if approve job runs longer than that.

setopt err_exit nounset pipefail

readonly CONFIG_FILE="${HOME}/.config/claude-plugins/apps.json"
readonly KEYCHAIN_SERVICE="claude-plugins.claude-approver"

# --- preconditions -----------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
  print -u2 -- "claude-plugins not registered: $CONFIG_FILE missing."
  print -u2 -- "  Run: development/skills/bootstrap/scripts/register-claude-apps.zsh"
  exit 1
fi

app_id=$(jq -r '.claude_approver.app_id // empty' "$CONFIG_FILE")
if [[ -z "$app_id" ]]; then
  print -u2 -- "claude-approver not registered (no entry in $CONFIG_FILE)."
  print -u2 -- "  Run: development/skills/bootstrap/scripts/register-claude-apps.zsh"
  exit 1
fi
if ! [[ "$app_id" =~ ^[0-9]+$ ]]; then
  print -u2 -- "claude_approver.app_id is not numeric: $app_id"
  exit 1
fi

if ! raw=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "private-key" -w 2>/dev/null); then
  print -u2 -- "Private key for claude-approver not in Keychain."
  print -u2 -- "  Run: development/skills/bootstrap/scripts/register-claude-apps.zsh --reset claude-approver"
  print -u2 -- "  Then re-run register-claude-apps.zsh to re-mint the key."
  exit 1
fi
# macOS `security find-generic-password -w` returns the stored value
# hex-encoded when it contains newlines. PEM private keys are multi-line
# by definition, so retrievals come back as a long hex string instead of
# the original bytes. Detect pure-hex retrievals and decode. The check is
# conservative — PEMs contain `-` `=` and newlines, none of which appear
# in hex output, so a stored PEM can never look like the hex form. See
# #208.
if [[ "$raw" =~ ^[0-9a-fA-F]+$ ]]; then
  pem=$(printf '%s' "$raw" | xxd -r -p)
else
  pem="$raw"
fi

command -v gh >/dev/null 2>&1 || { print -u2 -- "gh CLI not on PATH."; exit 1; }
command -v curl >/dev/null 2>&1 || { print -u2 -- "curl not on PATH."; exit 1; }
command -v openssl >/dev/null 2>&1 || { print -u2 -- "openssl not on PATH."; exit 1; }
command -v jq >/dev/null 2>&1 || { print -u2 -- "jq not on PATH."; exit 1; }

# --- discover repo ----------------------------------------------------------

if ! owner_repo=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null); then
  print -u2 -- "Not in a GitHub-tracked repo, or gh not authenticated."
  exit 1
fi

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
tmp_pem=$(mktemp -t claude-approver-pem.XXXXXX)
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

install_id=$(printf '%s' "$install_resp" | jq -r '.id // empty')
if [[ -z "$install_id" || "$install_id" == "null" ]]; then
  print -u2 -- "claude-approver App is not installed on ${owner_repo}."
  print -u2 -- "  Run /development:bootstrap to install."
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

print -n -- "$token"
