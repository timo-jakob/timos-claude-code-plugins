#!/usr/bin/env zsh
# mint-approver-token.zsh — mint a claude-approver App installation token
# for the current repo. Writes the token to a mode-600 temp file and prints
# the FILE PATH (default); `--stdout` prints the raw token instead;
# `--check-installed` only probes whether the App is installed on the repo.
#
# Used by /development-python:approve (and other language approve skills)
# to post code review verdicts. The App is invoked locally by the user,
# not by GitHub Actions. This is what enables approval without platform
# lock-in: user stays in control, no GitHub Actions, works with any AI
# coding assistant.
#
# Why print a path by default (#640): the orchestrator hands the token to a
# subagent through its *prompt*, and a raw token pasted into a prompt (or
# echoed to read it) lands verbatim in the session transcript that .tgz
# handoffs ship around. Printing only the path means the orchestrator never
# sees the token value — it passes the path along, and the consumer runs
# `export GH_TOKEN=$(cat <path>)` itself, then removes the file.
#
# Prerequisites:
#   - register-claude-apps.zsh has registered claude-approver for the OWNER of the
#     current repository (#1683): an owners[<owner>] entry in
#     ~/.config/claude-plugins/apps.json + its key in the Keychain service
#     claude-plugins.<owner>.claude-approver. The owner is resolved from the repo
#     (claude-apps-owner.zsh), so an organisation repo mints the organisation's
#     App and a personal repo the personal one, with no flag.
#   - install-claude-apps.zsh has been run on the current repo (the App is
#     installed on this repo so the installation-discovery succeeds).
#   - Run from inside the target repo's working tree.
#
# Exit codes:
#   0 — success (path printed, or token printed with --stdout; with
#       --check-installed: the App is installed, nothing printed)
#   1 — prerequisite missing (owner unresolvable, App not registered for the
#       owner, apps.json still schema 1 — the message names the command);
#       also bad usage (an unknown, empty or second argument), with a one-line
#       usage message on stderr and no GitHub request
#   2 — GitHub API failure (network, expired key, etc.)
#   3 — --check-installed only: the App is not installed on this repo
#       (GitHub answered the lookup Not Found). Silent: no stdout, no stderr.
#
# --check-installed (#2130): probe only. Signs the JWT and looks up
#   /repos/<owner>/<repo>/installation, but mints NO token and makes no
#   access_tokens request. Exit 0 = installed (prints nothing); 3 = not
#   installed, silently, because "not installed" is the supported way to forbid
#   AI approvals and must not read as an error; 2 = any other lookup failure
#   (unreachable GitHub, a rejected key) with the diagnostics below, so neither
#   ever reads as "not installed". Exit 1 is unchanged. Without the flag a
#   Not Found stays exit 2 with its message, which /development:open-pr's
#   fallback keys on.
#
# Stdout (default): the path to a mode-600 temp file holding the token
#   (one line, no trailing newline). The caller owns the file — read it with
#   `$(cat <path>)` at the point of use and `rm -f` it when done.
# Stdout (--stdout): the raw installation token (one line, no trailing
#   newline). Escape hatch for callers that cannot read from a file path.
# Stderr: human-readable diagnostics on failure.
#
# Token lifetime: 1 hour (GitHub's default for installation tokens).
# Re-mint if approve job runs longer than that.

setopt err_exit nounset pipefail

# --- argument parsing --------------------------------------------------------
emit_stdout=false
check_installed=false
# Strict: at most one argument, and only a known one. A typo or a second flag
# must never fall through to the mint path (a live token for a mere probe).
readonly SCRIPT_NAME="${0:t}"   # $0 inside a function is the function's name
usage() { print -u2 -- "usage: ${SCRIPT_NAME} [--stdout|--check-installed]"; exit 1; }
(( $# <= 1 )) || usage
if (( $# == 1 )); then
  case "$1" in
    --stdout)          emit_stdout=true ;;
    # Probe only: is the Approver App installed on this repo? No token is minted.
    --check-installed) check_installed=true ;;
    "")                usage ;;
    *)                 usage ;;
  esac
fi

readonly APP="claude-approver"

# The one owner-resolution answer every Claude Apps consumer shares (#1683).
# shellcheck source=development/skills/bootstrap/scripts/claude-apps-owner.zsh
source "${0:A:h}/../../bootstrap/scripts/claude-apps-owner.zsh"

# --- preconditions -----------------------------------------------------------

command -v gh >/dev/null 2>&1 || { print -u2 -- "gh CLI not on PATH."; exit 1; }
command -v curl >/dev/null 2>&1 || { print -u2 -- "curl not on PATH."; exit 1; }
command -v openssl >/dev/null 2>&1 || { print -u2 -- "openssl not on PATH."; exit 1; }
command -v jq >/dev/null 2>&1 || { print -u2 -- "jq not on PATH."; exit 1; }

# The repo's owner picks the pair: owners[<owner>] and
# claude-plugins.<owner>.claude-approver only. A missing owner or App is an
# error naming the register command — never a fall-through to another owner's App or to a
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

install_id=$(printf '%s' "$install_resp" | jq -r '.id // empty' 2>/dev/null || true)
if [[ "$check_installed" == true ]]; then
  [[ -n "$install_id" && "$install_id" != "null" ]] && exit 0
  # Only GitHub's own Not Found is "not installed" — and it is silent.
  if [[ -n "$install_resp" \
        && "$(printf '%s' "$install_resp" | jq -r '.message // empty' 2>/dev/null || true)" == "Not Found" ]]; then
    exit 3
  fi
  # Anything else falls through to the diagnostics below (exit 2).
fi
if [[ -z "$install_id" || "$install_id" == "null" ]]; then
  # Only GitHub's own 404 means "not installed" (#1683): callers such as
  # /development:open-pr key their fallback on that line, so an unreachable
  # GitHub or a key it rejects must never read as it.
  if [[ -z "$install_resp" ]]; then
    print -u2 -- "Could not reach GitHub to look up the claude-approver installation on ${owner_repo} (network?)."
    print -u2 -- "  Re-run once GitHub is reachable."
  elif [[ "$(printf '%s' "$install_resp" | jq -r '.message // empty' 2>/dev/null || true)" == "Not Found" ]]; then
    print -u2 -- "claude-approver App is not installed on ${owner_repo}."
    print -u2 -- "  Run /development:bootstrap to install."
  else
    print -u2 -- "GitHub rejected the claude-approver installation lookup on ${owner_repo} — a key it no longer accepts?"
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
  token_file=$(mktemp -t claude-approver-token.XXXXXX)
  chmod 600 "$token_file"
  print -rn -- "$token" > "$token_file"
  print -rn -- "$token_file"
fi
