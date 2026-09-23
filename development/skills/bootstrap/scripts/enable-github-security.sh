#!/usr/bin/env bash
# enable-github-security.sh — Step 4.5's GitHub-side security toggles, run on
# every non-IaC repo:
#   always         Dependabot alerts + Dependabot automated security fixes
#   iff public     secret scanning + push protection, Private Vulnerability
#                  Reporting
#   iff private    a note that those three need GitHub Advanced Security
#
# Usage:
#   enable-github-security.sh --visibility public|private
#
# It takes visibility, not the toolchain, because GitHub prices these features
# per visibility, not per tool (#1769). Each `gh api` call is idempotent, and
# none is prompted for: turning them on is what this script is for, and each
# can be turned off in the repo's Settings afterwards.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

VISIBILITY=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--visibility)
		[[ $# -ge 2 ]] || die "--visibility must be public or private"
		VISIBILITY="$2"
		shift 2
		;;
	*) die "Unknown argument: $1" ;;
	esac
done

[[ "$VISIBILITY" =~ ^(public|private)$ ]] || die "--visibility must be public or private"

require_tools gh

echo
info "═══ GitHub security features ($VISIBILITY) ═══"

GH_REPO_FULL=$(gh repo view --json nameWithOwner -q .nameWithOwner)
[[ -n "$GH_REPO_FULL" ]] || die "Could not resolve this repository (gh repo view)"

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

if [[ "$VISIBILITY" == "public" ]]; then
	info "Enabling secret scanning + push protection…"
	if gh api -X PATCH "repos/$GH_REPO_FULL" \
		-F 'security_and_analysis[secret_scanning][status]=enabled' \
		-F 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
		--silent 2>/dev/null; then
		ok "Secret scanning + push protection enabled"
	else
		warn "Secret scanning: enable call failed — check repo admin rights and that the repo really is public"
	fi

	info "Enabling Private Vulnerability Reporting…"
	if gh api --silent -X PUT "repos/$GH_REPO_FULL/private-vulnerability-reporting" 2>/dev/null; then
		ok "Private Vulnerability Reporting enabled"
	else
		warn "PVR: enable call returned non-zero (likely already enabled)"
	fi
else
	dim "  Secret scanning, push protection, and Private Vulnerability Reporting"
	dim "  require GitHub Advanced Security on private repos. If your org has GHAS,"
	dim "  enable them manually: repo Settings → Code security and analysis."
fi
