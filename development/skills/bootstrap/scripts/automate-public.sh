#!/usr/bin/env bash
# automate-public.sh — public-repo bootstrap automation:
#   1. Walk user through SonarCloud project import (browser, one-time human step)
#   2. Collect SONAR_TOKEN, create Zero Tolerance Quality Gate, assign to project
#   3. snyk auth (token mode) → read token from snyk config → store as GH secret
#   4. snyk monitor — onboard repo for continuous monitoring
#   5. Apply branch protection
#
# Usage:
#   automate-public.sh --project-key KEY --org-key ORG --project-name NAME \
#                      --default-branch main \
#                      --has-dockerfile true|false \
#                      --has-codeql true|false

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# The user invokes automate-public.sh from their target repo's working dir,
# so cwd is the repo root (where sonar-project.properties lives).
REPO_ROOT="$(pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PROJECT_KEY=""
ORG_KEY=""
PROJECT_NAME=""
DEFAULT_BRANCH="main"
HAS_DOCKERFILE="false"
HAS_CODEQL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-key)    PROJECT_KEY="$2"; shift 2 ;;
    --org-key)        ORG_KEY="$2"; shift 2 ;;
    --project-name)   PROJECT_NAME="$2"; shift 2 ;;
    --default-branch) DEFAULT_BRANCH="$2"; shift 2 ;;
    --has-dockerfile) HAS_DOCKERFILE="$2"; shift 2 ;;
    --has-codeql)     HAS_CODEQL="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$PROJECT_KEY"  ]] || die "--project-key required"
[[ -n "$ORG_KEY"      ]] || die "--org-key required"
[[ -n "$PROJECT_NAME" ]] || die "--project-name required"

# Tools the public-path automation directly invokes. Fail-fast with a
# preflight-pointer instead of a confusing later failure.
require_tools curl jq gh snyk

SONAR_HOST="https://sonarcloud.io"

# --- SonarCloud onboarding ----------------------------------------------------
echo
info "═══ SonarCloud setup ═══"
cat <<EOF

I'll open SonarCloud in your browser. Do the following one-time steps:

  1. Sign in with your GitHub account.
  2. Click "Analyze a new project" and import this repo.
  3. After import, click your avatar → "My Account" → "Security" tab.
  4. Generate a token (any name works) and copy it.

When you have the token, paste it here. The token stays on this machine —
I'll only use it to call the SonarCloud API directly.

EOF
ask_yn "Open SonarCloud in browser now?" && open "https://sonarcloud.io/projects/create"

echo
ask_secret "Paste SONAR_TOKEN:" SONAR_TOKEN
[[ -n "$SONAR_TOKEN" ]] || die "Empty token"
export SONAR_TOKEN

# Validate token by hitting an authenticated endpoint
info "Validating token…"
resp=$(sonar_curl GET "$SONAR_HOST/api/authentication/validate")
valid=$(printf '%s' "$resp" | jq -r '.valid // false')
[[ "$valid" == "true" ]] || die "Token validation failed: $resp"
ok "Token valid"

# --- Resolve the real SonarCloud org slug ------------------------------------
# The orchestrator passed `--org-key=<github-owner>` as a best guess, but
# SonarCloud's actual org key can be `<github-owner>` OR `<github-owner>-github`
# (and sometimes neither — auto-generated suffix on accounts with name
# collisions). Query the user's actual orgs and pick the matching one.
info "Resolving SonarCloud organization for '$ORG_KEY'…"
orgs_resp=$(sonar_curl GET "$SONAR_HOST/api/organizations/search?member=true")
_load_http_status
[[ "$_http_status" =~ ^20 ]] || die "Could not enumerate SonarCloud orgs (HTTP $_http_status): $orgs_resp"

resolved_org=$(printf '%s' "$orgs_resp" | jq -r --arg owner "$ORG_KEY" '
  # Prefer the exact match; fall back to the -github-suffixed variant.
  ([.organizations[] | select(.key == $owner)] + [.organizations[] | select(.key == ($owner + "-github"))])
  | first
  | .key // empty
')

if [[ -z "$resolved_org" ]]; then
  available=$(printf '%s' "$orgs_resp" | jq -r '.organizations[].key' | paste -sd, -)
  die "No SonarCloud org matches '$ORG_KEY' or '${ORG_KEY}-github'. Available orgs for this user: ${available:-<none>}. Re-run automate-public.sh with --org-key=<the correct slug>."
fi

if [[ "$resolved_org" != "$ORG_KEY" ]]; then
  warn "GitHub owner is '$ORG_KEY' but SonarCloud org slug is '$resolved_org' — using the resolved slug."
  # Patch sonar-project.properties in place so the workflow uses the right slug.
  if [[ -f "$REPO_ROOT/sonar-project.properties" ]]; then
    # Portable sed -i: use a backup extension then remove the backup.
    sed -i.bak "s|^sonar\.organization=.*|sonar.organization=$resolved_org|" \
      "$REPO_ROOT/sonar-project.properties"
    rm -f "$REPO_ROOT/sonar-project.properties.bak"
    ok "Patched sonar-project.properties: sonar.organization=$resolved_org"
  fi
  ORG_KEY="$resolved_org"
else
  ok "Org slug matches: $ORG_KEY"
fi

# Project may already exist (auto-created by the SonarCloud import flow).
# Skip create-if-exists; we just need to be able to assign the Quality Gate.

# --- Quality Gate -------------------------------------------------------------
create_zero_tolerance_gate "$SONAR_HOST" "$ORG_KEY"
if [[ "${_gate_created:-false}" == "true" ]]; then
  assign_gate_to_project "$SONAR_HOST" "$ORG_KEY" "$PROJECT_KEY" "Zero Tolerance"
else
  dim "  (Default 'Sonar way' gate is already assigned to new projects — no further action)"
fi

# --- Store SONAR_TOKEN as GitHub secret (both scopes) -------------------------
info "Storing SONAR_TOKEN as a GitHub secret (Actions + Dependabot scopes)…"
gh_secret_set_both SONAR_TOKEN "$SONAR_TOKEN"
ok "SONAR_TOKEN set (Actions + Dependabot)"

# --- Snyk ---------------------------------------------------------------------
echo
info "═══ Snyk setup ═══"

# Use token-based auth, not OAuth — GitHub Actions can't run OAuth refresh.
if snyk config get api >/dev/null 2>&1 && [[ -n "$(snyk config get api 2>/dev/null)" ]]; then
  ok "Snyk already authenticated"
else
  cat <<EOF

I'll run 'snyk auth --auth-type=token'. Your browser will open. Approve the
request. The CLI will then write a long-lived API token to:
    ~/.config/configstore/snyk.json

We need the token-mode (not OAuth) because GitHub Actions can't refresh OAuth
tokens — a static API token is what the workflow uses.

EOF
  ask_yn "Run 'snyk auth --auth-type=token' now?" || die "Snyk auth declined"
  snyk auth --auth-type=token
fi

SNYK_TOKEN=$(snyk config get api 2>/dev/null || true)
[[ -n "$SNYK_TOKEN" ]] || die "Could not read Snyk API token from local config"
ok "Read Snyk token from local config"

info "Storing SNYK_TOKEN as a GitHub secret (Actions + Dependabot scopes)…"
gh_secret_set_both SNYK_TOKEN "$SNYK_TOKEN"
ok "SNYK_TOKEN set (Actions + Dependabot)"

# Onboard for continuous monitoring
if ask_yn "Run 'snyk monitor' now to enable continuous monitoring on snyk.io?"; then
  # Best-effort — exit code != 0 if monitor finds issues but we still want to continue.
  snyk monitor --all-projects || warn "snyk monitor reported a non-zero status (often means findings were detected; check snyk.io)"
fi

# --- GitHub Security & Quality features --------------------------------------
# All four are free on public repos. Each `gh api` call is idempotent — running
# this against a repo where the feature is already on returns the same success.
# We do these unconditionally (no Y/N prompt): the script's contract is "set up
# the security toolchain for this public repo," and these toggles are part of
# that. Users who want them off can disable from the UI afterwards.
echo
info "═══ GitHub Security & Quality features ═══"

GH_REPO_FULL=$(gh repo view --json nameWithOwner -q .nameWithOwner)

info "Enabling Dependabot alerts…"
if gh api --silent -X PUT "repos/$GH_REPO_FULL/vulnerability-alerts" 2>/dev/null; then
  ok "Dependabot alerts enabled"
else
  warn "Dependabot alerts: enable call returned non-zero (likely already enabled)"
fi

info "Enabling Dependabot automated security fixes…"
if gh api --silent -X PUT "repos/$GH_REPO_FULL/automated-security-fixes" 2>/dev/null; then
  ok "Dependabot automated security fixes enabled"
else
  warn "Automated security fixes: enable call returned non-zero (likely already enabled)"
fi

info "Enabling secret scanning + push protection…"
if gh api -X PATCH "repos/$GH_REPO_FULL" \
    -F 'security_and_analysis[secret_scanning][status]=enabled' \
    -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
    --silent 2>/dev/null; then
  ok "Secret scanning + push protection enabled"
else
  warn "Secret scanning: enable call returned non-zero (private repos require GHAS — fine on public)"
fi

info "Enabling Private Vulnerability Reporting…"
if gh api --silent -X PUT "repos/$GH_REPO_FULL/private-vulnerability-reporting" 2>/dev/null; then
  ok "Private Vulnerability Reporting enabled"
else
  warn "PVR: enable call returned non-zero (likely already enabled)"
fi

# --- Branch protection --------------------------------------------------------
echo
info "═══ Branch protection ═══"
if ask_yn "Apply Zero-Tolerance branch protection on '$DEFAULT_BRANCH' now?"; then
  "$SCRIPT_DIR/branch-protection.sh" \
    --visibility public \
    --has-dockerfile "$HAS_DOCKERFILE" \
    --has-codeql "$HAS_CODEQL" \
    --default-branch "$DEFAULT_BRANCH"
fi

# --- Summary ------------------------------------------------------------------
echo
ok "Public-path automation complete"

if [[ "${_gate_created:-false}" == "true" ]]; then
  gate_summary="Zero Tolerance (assigned)"
else
  gate_summary="Sonar way (default — Free plan fallback; see warning above)"
fi

cat <<EOF

  Project       $PROJECT_KEY
  Quality Gate  $gate_summary
  Secrets set   SONAR_TOKEN, SNYK_TOKEN  (Actions + Dependabot scopes)
  Monitoring    $(snyk config get api >/dev/null 2>&1 && echo "Snyk authenticated" || echo "Snyk auth pending")

  Next: push a branch and open a PR — CI will run on the new workflows.
EOF
