#!/usr/bin/env zsh
# sonar-auth.zsh — resolve a SonarCloud user token for a given org.
#
# Lookup order:
#   1. $SONARQUBE_TOKEN env var → echo, exit 0
#   2. macOS Keychain (service=sonarcloud-token, account=<org>) → echo, exit 0
#   3. Interactive prompt: open browser, hidden paste, validate via REST,
#      store in keychain, then echo. Skipped (with a note) when stdin or
#      stderr isn't a TTY.
#
# Usage:   ./sonar-auth.zsh <organization-key>
# stdout:  the token on success (only)
# stderr:  progress, prompts, errors
# Exit:    0 success | 1 token unavailable | 2 usage error

setopt err_exit nounset pipefail

readonly SERVICE='sonarcloud-token'
readonly TOKEN_PAGE='https://sonarcloud.io/account/security'
readonly VALIDATE_URL='https://sonarcloud.io/api/authentication/validate'

typeset -a _tmpfiles=()
cleanup() { (( ${#_tmpfiles[@]} )) && rm -f "${_tmpfiles[@]}" }
trap cleanup EXIT INT TERM

if [[ -t 2 ]]; then
  c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'
  c_yellow=$'\033[33m'; c_blue=$'\033[34m'; c_dim=$'\033[2m'
else
  c_reset='' c_red='' c_green='' c_yellow='' c_blue='' c_dim=''
fi

info() { print -ru2 -- "${c_blue}==>${c_reset} $*" }
ok()   { print -ru2 -- "${c_green}✓${c_reset} $*" }
warn() { print -ru2 -- "${c_yellow}!${c_reset} $*" }
note() { print -ru2 -- "${c_dim}$*${c_reset}" }

err_block() {
  print -ru2 -- "${c_red}✗${c_reset} $1"
  print -ru2 -- "  Why:    $2"
  print -ru2 -- "  Where:  $3"
  print -ru2 -- "  Action: $4"
}

if (( $# != 1 )); then
  err_block \
    "Missing organization key" \
    "sonar-auth.zsh expects the SonarCloud organization key as its only argument" \
    "command line: $0" \
    "Pass the org key, e.g.: $0 timo-jakob-github"
  exit 2
fi
org="$1"

# --- step 1: env var --------------------------------------------------------
if [[ -n "${SONARQUBE_TOKEN:-}" ]]; then
  print -r -- "$SONARQUBE_TOKEN"
  exit 0
fi

# --- step 2: keychain lookup ------------------------------------------------
if token=$(security find-generic-password -s "$SERVICE" -a "$org" -w 2>/dev/null); then
  print -r -- "$token"
  exit 0
fi

# --- step 3: interactive onboarding -----------------------------------------
if [[ ! -t 0 || ! -t 2 ]]; then
  note "No SonarCloud token found for org '$org'."
  note "Create one at $TOKEN_PAGE and store it with:"
  note "  security add-generic-password -s $SERVICE -a $org -w '<token>' -U"
  note "or export SONARQUBE_TOKEN in your environment."
  exit 1
fi

info "No SonarCloud token found for org '$org'."
print -u2 ""
note "A SonarCloud user token is required to fetch live findings."
note "Opening your browser to: $TOKEN_PAGE"
note "(If the browser doesn't open, visit the URL manually.)"
print -u2 ""

if ! open "$TOKEN_PAGE" 2>/dev/null; then
  warn "Couldn't auto-open the browser. Open $TOKEN_PAGE manually."
fi

print -ru2 -- "Steps in the browser:"
print -ru2 -- "  1. Log in to SonarCloud if not already"
print -ru2 -- "  2. Find 'Tokens' → click 'Generate'"
print -ru2 -- "  3. Name it (e.g. 'claude-maintenance')"
print -ru2 -- "  4. Type: 'User Token'"
print -ru2 -- "  5. Copy the token"
print -u2 ""

read -rs "token?Paste token here (input hidden): "
print -u2 ""

if [[ -z "$token" ]]; then
  err_block \
    "No token entered" \
    "Input was empty" \
    "stdin prompt" \
    "Re-run '$0 $org' and paste a SonarCloud user token"
  exit 1
fi

# --- validate ---------------------------------------------------------------
info "Validating token..."
validate_body=$(mktemp); _tmpfiles+=("$validate_body")

if ! http_code=$(command curl -sS -o "$validate_body" -w '%{http_code}' \
       -H "Authorization: Bearer $token" \
       "$VALIDATE_URL" 2>/dev/null); then
  err_block \
    "Couldn't reach SonarCloud" \
    "curl failed before getting an HTTP response" \
    "GET $VALIDATE_URL" \
    "Check your network connection, then re-run '$0 $org'"
  exit 1
fi

if [[ "$http_code" != "200" ]]; then
  err_block \
    "Token rejected by SonarCloud (HTTP $http_code)" \
    "Token is invalid, revoked, or lacks the required permissions" \
    "GET $VALIDATE_URL" \
    "Generate a new user token at $TOKEN_PAGE and re-run '$0 $org'"
  exit 1
fi

valid=$(jq -r '.valid // false' "$validate_body" 2>/dev/null || print -n -- 'false')
if [[ "$valid" != "true" ]]; then
  err_block \
    "Token rejected by SonarCloud" \
    'SonarCloud responded with {"valid": false} — token does not authenticate' \
    "GET $VALIDATE_URL" \
    "Generate a new user token at $TOKEN_PAGE and re-run '$0 $org'"
  exit 1
fi

ok "Token valid"

# --- store in keychain ------------------------------------------------------
info "Storing in macOS Keychain..."
sec_err=$(mktemp); _tmpfiles+=("$sec_err")

if ! security add-generic-password -s "$SERVICE" -a "$org" -w "$token" -U 2>"$sec_err"; then
  sec_msg=$(<"$sec_err")
  [[ -z "$sec_msg" ]] && sec_msg="security command exited non-zero"
  err_block \
    "Failed to store token in keychain" \
    "$sec_msg" \
    "security add-generic-password -s $SERVICE -a $org" \
    "Run that command manually with -w '<your token>' appended"
  exit 1
fi

# --- success ---------------------------------------------------------------
print -u2 ""
ok "Token stored in macOS Keychain"
print -ru2 -- "    Service:  $SERVICE"
print -ru2 -- "    Account:  $org"
print -ru2 -- "    Retrieve: security find-generic-password -s $SERVICE -a $org -w"
print -u2 ""

print -r -- "$token"
exit 0
