#!/usr/bin/env zsh
# gather-snyk.zsh — fetch Snyk findings via the REST API.
#
# Why a separate script: the existing CLI invocations in
# gather-python-findings.sh (`snyk code test`, `snyk test`) each consume
# one slot from the org's monthly private-test quota REGARDLESS of repo
# visibility. The GitHub-integration-imported project on app.snyk.io
# already has the latest scan results; this script fetches them via the
# REST API (which does NOT consume private-test budget) and outputs them
# in the same shape the legacy CLI invocations produced, so downstream
# agents (python-snyk-triage) don't need to change.
#
# Tracking: timo-jakob/timos-claude-code-plugins#82.
#
# Usage:
#   gather-snyk.zsh <repo_path>
#
# Output (stdout, JSON):
#   { "snyk_code": [ ...SARIF-flat array... ],
#     "snyk_oss":  [ ...vulnerability records... ] }
#
# Stderr: a single explanatory line summarizing what happened. The
#   caller surfaces this via the gather payload's `notes[]`.
#
# Exit codes:
#   0 → success; arrays may be empty if the project genuinely has no
#       findings, but the API path worked end-to-end.
#   1 → API path failed (no token, no project match, HTTP error, etc.).
#       The caller treats both arrays as empty and propagates the stderr
#       note. Per #82 design decision, the caller does NOT fall back to
#       CLI scans — that would defeat the purpose of avoiding quota burn.
#   2 → usage error (bad / missing repo_path argument).

set -euo pipefail

repo="${1:-}"
[[ -n "$repo" && -d "$repo" ]] || { print -u2 -- "usage: $0 <repo_path>"; exit 2; }
cd "$repo"

# --- read Snyk API token from local CLI config -------------------------------
# We still need a token to call the API — same one the user already
# configured via `snyk auth`. We just don't INVOKE the CLI for scans
# (which is what consumes quota); using the token to read the REST API
# is free.
command -v snyk >/dev/null 2>&1 \
  || { print -u2 -- "snyk CLI not on PATH; cannot read API token. Install with 'brew install snyk-cli'."; exit 1; }

SNYK_TOKEN=$(snyk config get api 2>/dev/null || true)
[[ -n "$SNYK_TOKEN" ]] \
  || { print -u2 -- "snyk has no API token configured; run 'snyk auth --auth-type=token'."; exit 1; }

# --- resolve current GitHub repo's full name ---------------------------------
# Snyk's integration-imported project name starts with the GitHub
# nameWithOwner (e.g. "owner/repo:Dockerfile"). We use this to filter
# the org's project list down to the ones for this repo.
command -v gh >/dev/null 2>&1 \
  || { print -u2 -- "gh CLI not on PATH; can't resolve current repo's GitHub name."; exit 1; }
gh auth status >/dev/null 2>&1 \
  || { print -u2 -- "gh not authenticated; run 'gh auth login'."; exit 1; }

REPO_FULL=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
[[ -n "$REPO_FULL" ]] \
  || { print -u2 -- "could not resolve current repo's GitHub nameWithOwner."; exit 1; }

# --- API helpers --------------------------------------------------------------
SNYK_API_V1='https://api.snyk.io/v1'
SNYK_API_REST='https://api.snyk.io/rest'
# Snyk REST API uses date-stamped versions. We pin to a known stable
# date; bump when Snyk's docs flag a breaking change. Stable versions
# are documented at https://apidocs.snyk.io/.
SNYK_REST_VERSION='2024-10-15'

snyk_v1() {
  local method="$1" path="$2"
  curl -sS -X "$method" \
    -H "Authorization: token $SNYK_TOKEN" \
    -H "Accept: application/json" \
    -w '\nHTTP_STATUS=%{http_code}\n' \
    "${SNYK_API_V1}${path}"
}

snyk_rest() {
  local path="$1" sep='?'
  [[ "$path" == *"?"* ]] && sep='&'
  curl -sS \
    -H "Authorization: token $SNYK_TOKEN" \
    -H "Accept: application/vnd.api+json" \
    -w '\nHTTP_STATUS=%{http_code}\n' \
    "${SNYK_API_REST}${path}${sep}version=${SNYK_REST_VERSION}"
}

# Extract body from a snyk_* response (strip trailing HTTP_STATUS line)
strip_status() { sed '/^HTTP_STATUS=/d'; }
# Read the HTTP status from a snyk_* response
read_status() { sed -n 's/^HTTP_STATUS=//p' | tail -1; }

# --- discover org ID ----------------------------------------------------------
# Reuse the same dance the bootstrap script uses. The user's token is
# tied to one or more orgs; we resolve a single org-ID to scope project
# / issue calls.
orgs_resp=$(snyk_v1 GET /orgs)
orgs_status=$(printf '%s' "$orgs_resp" | read_status)
[[ "$orgs_status" == 200 ]] \
  || { print -u2 -- "Snyk v1 /orgs returned HTTP $orgs_status; cannot resolve org."; exit 1; }

orgs_body=$(printf '%s' "$orgs_resp" | strip_status)

# Prefer the org the user has configured via `snyk config get org`; fall
# back to the first org returned.
preferred_org_slug=$(snyk config get org 2>/dev/null | tr -d '[:space:]' || true)
if [[ -n "$preferred_org_slug" ]]; then
  SNYK_ORG_ID=$(printf '%s' "$orgs_body" \
    | jq -r --arg s "$preferred_org_slug" \
        '.orgs[]? | select(.slug == $s) | .id // empty' | head -1)
else
  SNYK_ORG_ID=""
fi
[[ -n "$SNYK_ORG_ID" ]] \
  || SNYK_ORG_ID=$(printf '%s' "$orgs_body" | jq -r '.orgs[0].id // empty')

[[ -n "$SNYK_ORG_ID" ]] \
  || { print -u2 -- "no Snyk org found for this token."; exit 1; }

# --- list projects matching this repo ----------------------------------------
# REST API: /orgs/{org_id}/projects pages through every project. For a
# free-tier org this is small; for larger orgs we'd need to paginate via
# the `links.next` field. We follow `links.next` if present.
all_projects='[]'
next_path="/orgs/${SNYK_ORG_ID}/projects?limit=100"
while [[ -n "$next_path" ]]; do
  resp=$(snyk_rest "$next_path")
  status=$(printf '%s' "$resp" | read_status)
  [[ "$status" == 200 ]] \
    || { print -u2 -- "Snyk REST /orgs/.../projects returned HTTP $status."; exit 1; }
  body=$(printf '%s' "$resp" | strip_status)
  page=$(printf '%s' "$body" | jq '[.data[]?]')
  all_projects=$(jq -n --argjson a "$all_projects" --argjson b "$page" '$a + $b')

  # Pagination — `links.next` is a relative path like
  # "/rest/orgs/.../projects?starting_after=...&version=...". Strip the
  # leading "/rest" so it works with our snyk_rest helper, and strip
  # the version param (the helper re-adds it).
  next_raw=$(printf '%s' "$body" | jq -r '.links.next? // empty')
  if [[ -n "$next_raw" ]]; then
    next_path="${next_raw#/rest}"
    next_path="${next_path//&version=${SNYK_REST_VERSION}/}"
    next_path="${next_path//?version=${SNYK_REST_VERSION}&/?}"
  else
    next_path=""
  fi
done

# Filter to projects whose `attributes.name` matches this repo. Snyk
# integration-imported projects have names like:
#   "<owner>/<repo>:pyproject.toml"   (Python deps)
#   "<owner>/<repo>:Dockerfile"       (container)
#   "<owner>/<repo>"                  (Snyk Code root project)
matching_projects=$(printf '%s' "$all_projects" \
  | jq --arg repo "$REPO_FULL" \
      '[.[] | select(.attributes.name == $repo or (.attributes.name | startswith($repo + ":")))]')

n_matches=$(printf '%s' "$matching_projects" | jq 'length')
if [[ "$n_matches" == 0 ]]; then
  print -u2 -- "no Snyk projects match '$REPO_FULL' in this org; is the GitHub integration import in place?"
  exit 1
fi

# --- per-project: fetch issues, classify as code vs OSS ----------------------
# Project `attributes.type` values:
#   "sast"             → Snyk Code (SAST)
#   "pip"|"npm"|...    → Snyk Open Source (deps)
#   "dockerfile"       → container scan (we let the existing CI workflow
#                        handle this; not part of the maintenance gather)
code_arr='[]'
oss_arr='[]'
project_summary=()

while IFS= read -r row; do
  pid=$(printf '%s' "$row"   | jq -r '.id')
  pname=$(printf '%s' "$row" | jq -r '.attributes.name')
  ptype=$(printf '%s' "$row" | jq -r '.attributes.type')

  # Skip container projects — covered by the workflow's snyk-container job.
  case "$ptype" in
    dockerfile|container|"linux") continue ;;
  esac

  issues_path="/orgs/${SNYK_ORG_ID}/issues?scan_item.id=${pid}&scan_item.type=project&limit=100"
  issues_all='[]'
  while [[ -n "$issues_path" ]]; do
    iresp=$(snyk_rest "$issues_path")
    istatus=$(printf '%s' "$iresp" | read_status)
    [[ "$istatus" == 200 ]] \
      || { print -u2 -- "Snyk REST /orgs/.../issues returned HTTP $istatus for project $pid."; exit 1; }
    ibody=$(printf '%s' "$iresp" | strip_status)
    ipage=$(printf '%s' "$ibody" | jq '[.data[]?]')
    issues_all=$(jq -n --argjson a "$issues_all" --argjson b "$ipage" '$a + $b')

    next_raw=$(printf '%s' "$ibody" | jq -r '.links.next? // empty')
    if [[ -n "$next_raw" ]]; then
      issues_path="${next_raw#/rest}"
      issues_path="${issues_path//&version=${SNYK_REST_VERSION}/}"
      issues_path="${issues_path//?version=${SNYK_REST_VERSION}&/?}"
    else
      issues_path=""
    fi
  done

  n_issues=$(printf '%s' "$issues_all" | jq 'length')
  project_summary+=("$pname [$ptype, $n_issues issue(s)]")

  if [[ "$ptype" == "sast" ]]; then
    # Map Snyk Code issues to the SARIF-flat shape `snyk code test --json`
    # produces (after gather-python-findings.sh's `jq '.runs[]?.results[]?'`
    # extraction). Each SARIF result has: ruleId, level, message.text,
    # locations[].physicalLocation.{artifactLocation.uri, region.startLine}.
    page=$(printf '%s' "$issues_all" | jq '
      [ .[] | {
          ruleId: (.attributes.key // .attributes.title // .id),
          level: (
            (.attributes.effective_severity_level // .attributes.severity_level // "info")
            | ascii_downcase
            | if . == "critical" or . == "high" then "error"
              elif . == "medium" then "warning"
              else "note"
              end
          ),
          message: { text: (.attributes.title // "") },
          locations: [
            (.attributes.locations? // [])[]
            | {
                physicalLocation: {
                  artifactLocation: { uri: (.source_location?.file?.path // "") },
                  region: { startLine: (.source_location?.region?.start?.line // 1) }
                }
              }
          ],
          properties: {
            snyk_id: .id,
            cwe: [ (.attributes.classes? // [])[] | select(.source == "CWE") | .id ],
            severity_label: (.attributes.effective_severity_level // .attributes.severity_level // "")
          }
        }
      ]
    ')
    code_arr=$(jq -n --argjson a "$code_arr" --argjson b "$page" '$a + $b')
  else
    # Map Snyk Open Source issues to the `snyk test --json` shape
    # (after gather-python-findings.sh's vulnerabilities[] extraction).
    # Fields the downstream agent reads: id, title, severity, packageName,
    # version, fixedIn, identifiers.CVE, cvssScore, etc.
    page=$(printf '%s' "$issues_all" | jq '
      [ .[] | {
          id: (.attributes.key // .id),
          title: (.attributes.title // ""),
          severity: (.attributes.effective_severity_level // .attributes.severity_level // "info"),
          packageName: (
            (.attributes.coordinates? // [])[0]?.representations?[0]?.dependency?.package_name
            // (.attributes.coordinates? // [])[0]?.representations?[0]?.package_name
            // null
          ),
          version: (
            (.attributes.coordinates? // [])[0]?.representations?[0]?.dependency?.package_version
            // null
          ),
          fixedIn: [
            (.attributes.coordinates? // [])[]?.remedies? // [] | .[]
            | (.description // "")
          ] | map(select(length > 0)),
          identifiers: {
            CVE: [ (.attributes.problems? // [])[] | select(.source == "CVE") | .id ],
            CWE: [ (.attributes.classes? // [])[]  | select(.source == "CWE") | .id ],
            SNYK: [ .attributes.key ] | map(select(. != null))
          },
          cvssScore: (.attributes.risk?.score?.value // null)
        }
      ]
    ')
    oss_arr=$(jq -n --argjson a "$oss_arr" --argjson b "$page" '$a + $b')
  fi
done < <(printf '%s' "$matching_projects" | jq -c '.[]')

# --- summary note (single line to stderr) ------------------------------------
code_count=$(printf '%s' "$code_arr" | jq 'length')
oss_count=$(printf '%s' "$oss_arr" | jq 'length')
projects_joined="${(j:, :)project_summary}"
print -u2 -- "Snyk findings via REST API (no quota consumed): ${code_count} code, ${oss_count} OSS. Projects scanned: ${projects_joined}."

# --- emit final JSON ---------------------------------------------------------
jq -n --argjson code "$code_arr" --argjson oss "$oss_arr" \
  '{ snyk_code: $code, snyk_oss: $oss }'
