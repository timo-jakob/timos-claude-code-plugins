#!/usr/bin/env bash
# setup-sonarcloud.sh — Step 4.5's SonarCloud onboarding, run iff the resolved
# static_analysis is sonarcloud (public or private):
#   1. Walk the user through the SonarCloud project import (browser, one-time
#      human step) and collect a user token
#   2. Resolve the real SonarCloud org slug (patching sonar-project.properties)
#   3. Create the Zero Tolerance Quality Gate and assign it, falling back to
#      'Sonar way' where the plan paywalls custom gates
#   4. Store SONAR_TOKEN as a GitHub secret (Actions + Dependabot scopes)
#
# Usage:
#   setup-sonarcloud.sh --project-key KEY --org-key ORG --project-name NAME
#
# Branch protection is not this script's business: bootstrap's Step 4b applies
# it once, with the resolved toolchain (#1769).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# The user invokes this from their target repo's working dir, so cwd is the
# repo root (where sonar-project.properties lives).
REPO_ROOT="$(pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PROJECT_KEY=""
ORG_KEY=""
PROJECT_NAME=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--project-key | --org-key | --project-name)
		[[ $# -ge 2 ]] || die "$1 requires a value"
		case "$1" in
		--project-key) PROJECT_KEY="$2" ;;
		--org-key) ORG_KEY="$2" ;;
		--project-name) PROJECT_NAME="$2" ;;
		esac
		shift 2
		;;
	*) die "Unknown argument: $1" ;;
	esac
done

[[ -n "$PROJECT_KEY" ]] || die "--project-key required"
[[ -n "$ORG_KEY" ]] || die "--org-key required"
[[ -n "$PROJECT_NAME" ]] || die "--project-name required"

# Fail fast with a preflight pointer instead of a later failure.
require_tools curl jq gh

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
	die "No SonarCloud org matches '$ORG_KEY' or '${ORG_KEY}-github'. Available orgs for this user: ${available:-<none>}. Re-run setup-sonarcloud.sh with --org-key=<the correct slug>."
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

# --- Summary ------------------------------------------------------------------
if [[ "${_gate_created:-false}" == "true" && "${_gate_assigned:-false}" == "true" ]]; then
	gate_summary="Zero Tolerance custom gate (created + assigned)"
elif [[ "${_gate_created:-false}" == "true" ]]; then
	gate_summary="Zero Tolerance gate exists but unassigned (Free-plan paywall) — Sonar way active; coverage-floor CI step enforces 90%"
else
	gate_summary="Sonar way (Free-plan fallback; see warning above) — coverage-floor CI step enforces 90%"
fi

echo
ok "SonarCloud setup complete"
cat <<EOF

  Project       $PROJECT_KEY  (org $ORG_KEY)
  Sonar gate    $gate_summary
  Coverage 90%  Enforced by the 'coverage-floor' CI step (diff-cover) + pre-push hook,
                regardless of which Sonar gate is active on the project.
  Secrets set   SONAR_TOKEN  (Actions + Dependabot scopes)
EOF
