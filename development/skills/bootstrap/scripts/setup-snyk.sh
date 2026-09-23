#!/usr/bin/env bash
# setup-snyk.sh — Step 4.5's Snyk setup, run iff the resolved vulnerabilities
# tool is snyk, whatever the visibility or Dockerfile (#1769):
#   1. snyk auth --auth-type=token (token mode — GitHub Actions can't refresh
#      OAuth), unless the CLI is already authenticated
#   2. Store SNYK_TOKEN as a GitHub secret (Actions + Dependabot scopes)
#   3. Import this repository through Snyk's GitHub integration
#   4. Print the two manual Snyk UI steps (auto-Fix-PRs, PR status checks)
#
# Usage:
#   setup-snyk.sh
#
# Run from the target repo's working dir: the repository is `gh repo view`'s.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $# -eq 0 ]] || die "Unknown argument: $1"

# Fail fast with a preflight pointer (preflight installs snyk-cli for snyk).
require_tools curl jq gh snyk

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
#      to set up the integration, then re-check. Up to 3 tries; exit
#      non-zero on the third failure (don't fall back to broken CLI
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
orgs_resp=$(snyk_api GET /orgs | sed '/^HTTP_STATUS=/d')
SNYK_ORG_SLUG=$(snyk config get org 2>/dev/null | tr -d '[:space:]' || true)
if [[ -z "$SNYK_ORG_SLUG" ]]; then
	SNYK_ORG_SLUG=$(printf '%s' "$orgs_resp" | jq -r '.orgs[0].slug // empty')
fi
[[ -n "$SNYK_ORG_SLUG" ]] || die "Could not discover Snyk org (check 'snyk config get org' or your token's org assignments)"

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
[[ -n "$GH_INT_ID" ]] || die "Snyk GitHub integration still missing after 3 attempts. Set it up manually at https://app.snyk.io/org/$SNYK_ORG_SLUG/manage/integrations, then re-run setup-snyk.sh (SETUP.md §2b.1 is the manual path)."
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
info "See SETUP.md section 2b.2 for the full recipe."

echo
info "═══ Manual step: configure Snyk PR status checks ═══"
info "Third-party CVEs change without our code changing, so they must not"
info "gate a build — handle them via daily monitoring + auto-Fix-PRs instead."
info "  1. Open: https://app.snyk.io/org/$SNYK_ORG_SLUG/manage/integrations"
info "  2. GitHub integration → 'Pull request status checks'."
info "  3. 'Open Source security and licenses' → DISABLE (drops security/snyk)."
info "  4. 'Code analysis' → DISABLE (drops code/snyk — the repo's SAST gate covers SAST; Snyk Code's free-tier cap breaks the Approver, #387)."
info "See SETUP.md section 2b.1 for the rationale."

echo
ok "Snyk setup complete"
cat <<EOF

  Snyk org      $SNYK_ORG_SLUG
  Secrets set   SNYK_TOKEN  (Actions + Dependabot scopes)
  Monitoring    GitHub-integration import of $gh_repo
EOF
