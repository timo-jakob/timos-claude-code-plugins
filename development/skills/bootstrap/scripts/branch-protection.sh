#!/usr/bin/env bash
# branch-protection.sh — apply Zero-Tolerance branch protection on the default
# branch via the GitHub API. Idempotent (PUT replaces the rule each time).
#
# Usage:
#   branch-protection.sh --visibility public|private \
#                        --has-dockerfile true|false \
#                        --has-codeql true|false \
#                        --default-branch main
#
# Requires: gh CLI authenticated, repository admin permission. On 403 the
# script falls back to printing manual instructions.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

VISIBILITY=""
HAS_DOCKERFILE="false"
HAS_CODEQL="false"
DEFAULT_BRANCH="main"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --visibility)     VISIBILITY="$2"; shift 2 ;;
    --has-dockerfile) HAS_DOCKERFILE="$2"; shift 2 ;;
    --has-codeql)     HAS_CODEQL="$2"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    *)                die "Unknown argument: $1" ;;
  esac
done

[[ "$VISIBILITY" =~ ^(public|private)$ ]] || die "--visibility must be public or private"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
[[ -n "$REPO" ]] || die "Could not determine current repo from gh"

# --- build required-status-checks list ---------------------------------------
# These names must match the `jobs.<id>` keys in the generated workflow files.
checks=("test-and-coverage" "semgrep")

case "$VISIBILITY" in
  public)
    checks+=("sonarcloud" "snyk-code" "snyk-open-source" "license-fs")
    [[ "$HAS_DOCKERFILE" == "true" ]] && checks+=("image")
    [[ "$HAS_CODEQL"     == "true" ]] && checks+=("analyze")  # codeql job id
    ;;
  private)
    checks+=("sonarqube" "trivy-fs" "license-fs")
    [[ "$HAS_DOCKERFILE" == "true" ]] && checks+=("image")
    ;;
esac

# --- assemble JSON payload ----------------------------------------------------
contexts_json=$(printf '%s\n' "${checks[@]}" | jq -R . | jq -s .)
payload=$(jq -n \
  --argjson contexts "$contexts_json" \
  '{
    required_status_checks: {
      strict: true,
      contexts: $contexts
    },
    enforce_admins: false,
    required_pull_request_reviews: {
      required_approving_review_count: 1,
      dismiss_stale_reviews: true,
      require_code_owner_reviews: false
    },
    restrictions: null,
    required_linear_history: true,
    allow_force_pushes: false,
    allow_deletions: false,
    required_conversation_resolution: true
  }')

info "Applying branch protection on $REPO@$DEFAULT_BRANCH"
dim  "Required checks:"
printf '  • %s\n' "${checks[@]}"

# --- PUT --------------------------------------------------------------------
http_body=$(mktemp)
http_status=$(curl -sS -o "$http_body" -w '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: token $(gh auth token)" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -X PUT \
  "https://api.github.com/repos/$REPO/branches/$DEFAULT_BRANCH/protection" \
  --data "$payload")

case "$http_status" in
  200)
    ok "Branch protection applied"
    ;;
  403)
    warn "403 — your account does not have admin permission on $REPO"
    cat <<EOF

You'll need to apply branch protection manually. In GitHub:
  Settings → Branches → Add rule → Branch name pattern: $DEFAULT_BRANCH

Required status checks:
$(printf '  • %s\n' "${checks[@]}")

Plus: require PR before merging, require linear history, block force pushes,
block deletions. See SETUP.md for the full list.
EOF
    exit 0   # not a hard failure — user can do it by hand
    ;;
  *)
    err "Branch protection failed (HTTP $http_status):"
    cat "$http_body" >&2
    rm -f "$http_body"
    exit 1
    ;;
esac

rm -f "$http_body"
