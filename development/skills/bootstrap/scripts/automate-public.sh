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
#                      [--has-ko true|false] \
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
HAS_KO="false"
HAS_CODEQL="false"
CODEQL_LANGUAGES=""
CLAUDE_APPROVER="false"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--project-key)
		PROJECT_KEY="$2"
		shift 2
		;;
	--org-key)
		ORG_KEY="$2"
		shift 2
		;;
	--project-name)
		PROJECT_NAME="$2"
		shift 2
		;;
	--default-branch)
		DEFAULT_BRANCH="$2"
		shift 2
		;;
	--has-dockerfile)
		HAS_DOCKERFILE="$2"
		shift 2
		;;
	--has-ko)
		HAS_KO="$2"
		shift 2
		;;
	--has-codeql)
		HAS_CODEQL="$2"
		shift 2
		;;
	--codeql-languages)
		CODEQL_LANGUAGES="$2"
		shift 2
		;;
	--claude-approver)
		CLAUDE_APPROVER="$2"
		shift 2
		;;
	*) die "Unknown argument: $1" ;;
	esac
done

[[ -n "$PROJECT_KEY" ]] || die "--project-key required"
[[ -n "$ORG_KEY" ]] || die "--org-key required"
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

# --- Register the project with Snyk via the GitHub integration ----------------
# Why not `snyk monitor --all-projects`? Because CLI-registered Snyk projects
# always count as PRIVATE tests against the org's monthly quota — Snyk has no
# way to discover the underlying GitHub repo from a local `pip install` graph,
# so it categorizes them as private regardless of GitHub repo visibility. For
# public repos with a GitHub integration, the GitHub-typed project gets
# UNLIMITED testing AND continuous re-scanning on every commit AND PR-level
# status checks AND auto-fix PRs — all things CLI monitoring can't do.
#
# Flow:
#   1. Discover the user's Snyk org from their CLI config.
#   2. Check whether the org has an active GitHub integration.
#   3. If yes → POST to the integration's import endpoint with this repo.
#   4. If no → open the Snyk integrations page in the browser, ask the user
#      to set up the integration, then re-check. Up to 3 tries; halt the
#      bootstrap on the third failure (don't fall back to broken CLI
#      registration — that's the trap we're trying to climb out of).

# Small helper: hit the Snyk REST API with the user's token.
SNYK_API='https://api.snyk.io/v1'
snyk_api() {
	local method="$1" path="$2"
	shift 2
	curl -sS -X "$method" \
		-H "Authorization: token $SNYK_TOKEN" \
		-H "Content-Type: application/json" \
		-w '\nHTTP_STATUS=%{http_code}\n' \
		"$SNYK_API$path" "$@"
}

# Discover the org (prefer the user's CLI default, else the first org listed).
SNYK_ORG_SLUG=$(snyk config get org 2>/dev/null | tr -d '[:space:]' || true)
if [[ -z "$SNYK_ORG_SLUG" ]]; then
	SNYK_ORG_SLUG=$(snyk_api GET /orgs | sed '/^HTTP_STATUS=/d' | jq -r '.orgs[0].slug // empty')
fi
[[ -n "$SNYK_ORG_SLUG" ]] || die "Could not discover Snyk org (check 'snyk config get org' or your token's org assignments)"

orgs_resp=$(snyk_api GET /orgs | sed '/^HTTP_STATUS=/d')
SNYK_ORG_ID=$(printf '%s' "$orgs_resp" | jq -r --arg s "$SNYK_ORG_SLUG" '.orgs[] | select(.slug == $s) | .id // empty' | head -1)
[[ -n "$SNYK_ORG_ID" ]] || die "Could not resolve Snyk org ID for slug '$SNYK_ORG_SLUG'"
ok "Snyk org: $SNYK_ORG_SLUG (id=$SNYK_ORG_ID)"

# Detect the GitHub integration on this org.
detect_github_integration() {
	local resp
	resp=$(snyk_api GET "/org/$SNYK_ORG_ID/integrations" | sed '/^HTTP_STATUS=/d')
	printf '%s' "$resp" | jq -r '.github // empty'
}

GH_INT_ID=$(detect_github_integration)
attempt=1
while [[ -z "$GH_INT_ID" && $attempt -le 3 ]]; do
	warn "Snyk's GitHub integration isn't connected for org '$SNYK_ORG_SLUG' (attempt $attempt of 3)."
	info "Opening Snyk's integrations page. In the browser:"
	info "  1. Find the GitHub integration."
	info "  2. Click 'Connect' (or 'Add integration → GitHub')."
	info "  3. Complete the OAuth flow."
	info "  4. Come back here and confirm."
	echo
	open "https://app.snyk.io/org/$SNYK_ORG_SLUG/manage/integrations" 2>/dev/null ||
		warn "Could not auto-open the browser. Visit: https://app.snyk.io/org/$SNYK_ORG_SLUG/manage/integrations"
	echo
	ask_yn "Done setting up the GitHub integration?" || true
	GH_INT_ID=$(detect_github_integration)
	attempt=$((attempt + 1))
done
[[ -n "$GH_INT_ID" ]] || die "Snyk GitHub integration still missing after 3 attempts. Set it up manually at https://app.snyk.io/org/$SNYK_ORG_SLUG/manage/integrations and re-run /development:bootstrap."
ok "Snyk GitHub integration: $GH_INT_ID"

# Import this repo via the integration. Snyk runs the actual scan
# asynchronously and creates Open Source + Code (and Dockerfile if detected)
# projects under the GitHub-typed target. Public repos: unlimited testing.
gh_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh_owner=${gh_repo%%/*}
gh_name=${gh_repo##*/}
gh_branch=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)

info "Importing $gh_repo into Snyk via the GitHub integration…"
import_body=$(jq -n \
	--arg owner "$gh_owner" \
	--arg name "$gh_name" \
	--arg branch "$gh_branch" \
	'{ target: { owner: $owner, name: $name, branch: $branch } }')

import_resp=$(snyk_api POST "/org/$SNYK_ORG_ID/integrations/$GH_INT_ID/import" --data "$import_body")
import_status=$(printf '%s' "$import_resp" | sed -n 's/^HTTP_STATUS=//p')
case "$import_status" in
201 | 202)
	ok "Import job accepted by Snyk (HTTP $import_status). The project appears at app.snyk.io within ~1 minute."
	;;
409)
	ok "Project was already imported (HTTP 409). Snyk will continue monitoring it."
	;;
*)
	warn "Unexpected response from Snyk import (HTTP $import_status). Response body:"
	printf '%s\n' "$import_resp" | sed '/^HTTP_STATUS=/d' | head -10
	warn "The integration is set up; you can import manually via 'Import GitHub Projects' on the Snyk integrations page."
	;;
esac

# --- Snyk auto-Fix-PRs (manual UI step on free plans) ------------------------
# We cannot enable autoFixPR via the v1/REST API on free plans — Snyk gates
# the v1 integrations endpoint behind paid-plan entitlement (returns 403
# "not entitled for API access"), and the REST API does not expose an
# equivalent settings endpoint at all (verified 2026-06-05 against
# api.snyk.io/rest/orgs/{id}/integrations → 404). UI is the only path on
# free. Surface this clearly to the user instead of failing silently.
echo
info "═══ Manual step: enable Snyk auto-Fix-PRs ═══"
info "Snyk's API doesn't expose the auto-Fix-PR toggle on free plans. To"
info "make Snyk open PRs when new vulnerabilities are detected:"
info "  1. Open: https://app.snyk.io/org/$SNYK_ORG_SLUG/manage/integrations"
info "  2. Click the GitHub integration → 'Edit Settings'."
info "  3. Toggle 'Automatic Fix PRs' ON; set max open PRs to 5."
info "  4. Leave 'Automatic Upgrade PRs' OFF (Dependabot handles upgrades)."
info "See SETUP.md section 2.6 for the full recipe."

echo
info "═══ Manual step: configure Snyk PR status checks ═══"
info "Third-party CVEs change without our code changing, so they must not"
info "gate a build — handle them via daily monitoring + auto-Fix-PRs instead."
info "  1. Open: https://app.snyk.io/org/$SNYK_ORG_SLUG/manage/integrations"
info "  2. GitHub integration → 'Pull request status checks'."
info "  3. 'Open Source security and licenses' → DISABLE (drops security/snyk)."
info "  4. 'Code analysis' → DISABLE (drops code/snyk — CodeQL covers SAST; Snyk Code's free-tier cap breaks the Approver, #387)."
info "See SETUP.md section 2.5 for the rationale."

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
		--has-ko "$HAS_KO" \
		--has-codeql "$HAS_CODEQL" \
		--codeql-languages "$CODEQL_LANGUAGES" \
		--default-branch "$DEFAULT_BRANCH"
fi

# --- Claude Apps install ------------------------------------------------------
# Phase 1 of #89. Installs the two GitHub Apps registered locally by
# register-claude-apps.zsh onto this repo and stores the per-repo secrets +
# variables the Approver workflow (Phase 2) and the Maintenance bot identity
# will need at runtime.
if [[ "$CLAUDE_APPROVER" == "true" ]]; then
	echo
	info "═══ Claude Apps install ═══"
	"$SCRIPT_DIR/install-claude-apps.zsh"
fi

# --- Summary ------------------------------------------------------------------
echo
ok "Public-path automation complete"

if [[ "${_gate_created:-false}" == "true" && "${_gate_assigned:-false}" == "true" ]]; then
	gate_summary="Zero Tolerance custom gate (created + assigned)"
elif [[ "${_gate_created:-false}" == "true" ]]; then
	gate_summary="Zero Tolerance gate exists but unassigned (Free-plan paywall) — Sonar way active; coverage-floor CI step enforces 90%"
else
	gate_summary="Sonar way (Free-plan fallback; see warning above) — coverage-floor CI step enforces 90%"
fi

cat <<EOF

  Project       $PROJECT_KEY
  Sonar gate    $gate_summary
  Coverage 90%  Enforced by the 'coverage-floor' CI step (diff-cover) + pre-push hook,
                regardless of which Sonar gate is active on the project.
  Secrets set   SONAR_TOKEN, SNYK_TOKEN  (Actions + Dependabot scopes)
  Monitoring    $(snyk config get api >/dev/null 2>&1 && echo "Snyk authenticated" || echo "Snyk auth pending")

  Next: push a branch and open a PR — CI will run on the new workflows.
EOF
