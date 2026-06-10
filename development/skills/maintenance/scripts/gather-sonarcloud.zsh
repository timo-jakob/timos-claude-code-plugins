#!/usr/bin/env zsh
# gather-sonarcloud.zsh — fetch open SonarCloud findings (issues + hotspots)
# plus the main branch's Quality Gate verdict for a given org+project.
#
# Normalized per-finding shape (matches python-sonar-triage agent expectations):
#   { type, severity, rule, component, line, message, key, security_category? }
#
# Issues come from /api/issues/search?resolved=false.
# Hotspots come from /api/hotspots/search?status=TO_REVIEW (separate endpoint
# in the Sonar API). vulnerabilityProbability → severity mapping:
#   HIGH→CRITICAL  MEDIUM→MAJOR  LOW→MINOR.
# Quality Gate comes from /api/qualitygates/project_status (no branch param =
# the project's main branch). QG fetch failure is non-fatal: findings are
# still emitted with quality_gate: null.
#
# The API host defaults to SonarCloud but supports self-hosted SonarQube:
# SONAR_HOST_URL env var → sonar.host.url in ./sonar-project.properties →
# https://sonarcloud.io. (The caller runs this script with the target repo
# as cwd, so the properties lookup is relative.)
#
# Token is resolved via sibling sonar-auth.zsh (env var → keychain → prompt).
#
# Usage:   gather-sonarcloud.zsh <org-key> <project-key>
# stdout:  JSON object:
#            { "findings":     [ ...normalized findings... ],
#              "quality_gate": { "status": "OK|ERROR|WARN|NONE",
#                                "conditions": [ ... ] } | null }
#          (findings [] and quality_gate null on failure)
# stderr:  progress + errors; final line is a one-liner suitable for surfacing
#          as a user-facing note in the maintenance orchestrator's summary
# Exit:    0 success | 1 unavailable (token / network / API) | 2 usage error

setopt err_exit nounset pipefail

# --- resolve API host (SonarCloud or self-hosted SonarQube) ------------------
sonar_host="${SONAR_HOST_URL:-}"
if [[ -z "$sonar_host" && -f sonar-project.properties ]]; then
  sonar_host=$(grep -E '^[[:space:]]*sonar\.host\.url' sonar-project.properties \
    | head -1 | cut -d= -f2- | tr -d ' \r' || true)
fi
[[ -z "$sonar_host" ]] && sonar_host='https://sonarcloud.io'
readonly API_BASE="${sonar_host%/}/api"
readonly PAGE_SIZE=500
readonly MAX_PAGES=20  # safety cap (10,000 findings per endpoint)

SCRIPT_DIR="${0:A:h}"
readonly SCRIPT_DIR

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

err_block() {
  print -ru2 -- "${c_red}✗${c_reset} $1"
  print -ru2 -- "  Why:    $2"
  print -ru2 -- "  Where:  $3"
  print -ru2 -- "  Action: $4"
}

# Final stderr line that the gather-python-findings.sh caller picks up as
# the note for the maintenance summary. Should be a one-liner.
final_note() { print -ru2 -- "$*" }

# --- args ------------------------------------------------------------------
if (( $# != 2 )); then
  err_block \
    "Missing arguments" \
    "gather-sonarcloud.zsh expects <org-key> <project-key>" \
    "command line: $0" \
    "Pass both, e.g.: $0 timo-jakob-github timo-jakob_ai-doc-organizer"
  print -- '{"findings": [], "quality_gate": null}'
  final_note "SonarCloud gather: usage error (missing org or project key)."
  exit 2
fi
org="$1"
project="$2"

# --- step 1: resolve token --------------------------------------------------
info "Resolving SonarCloud token for org '$org'..."
auth_stderr=$(mktemp); _tmpfiles+=("$auth_stderr")
if ! token=$("$SCRIPT_DIR/sonar-auth.zsh" "$org" 2>"$auth_stderr"); then
  # sonar-auth's stderr already explains the situation
  cat "$auth_stderr" >&2
  print -- '{"findings": [], "quality_gate": null}'
  final_note "SonarCloud token unavailable for org '$org'. Run $SCRIPT_DIR/sonar-auth.zsh $org from a terminal to set it up."
  exit 1
fi

if [[ -z "$token" ]]; then
  err_block \
    "Empty token from sonar-auth.zsh" \
    "sonar-auth.zsh exited 0 but produced no token on stdout" \
    "$SCRIPT_DIR/sonar-auth.zsh $org" \
    "Re-run sonar-auth.zsh interactively to refresh the token"
  print -- '{"findings": [], "quality_gate": null}'
  final_note "SonarCloud token resolution returned empty; see errors above."
  exit 1
fi
ok "Token resolved"

# --- step 2: pageable fetch helper -----------------------------------------
# fetch_all <endpoint_path> <jq_array_filter> <extra_query_string>
# Echoes the merged JSON array of all pages of the given array.
fetch_all() {
  local endpoint="$1" array_filter="$2" extra_qs="$3"
  local acc body http page=1 total page_size page_index fetched
  acc=$(mktemp); _tmpfiles+=("$acc")
  print '[]' > "$acc"

  while (( page <= MAX_PAGES )); do
    body=$(mktemp); _tmpfiles+=("$body")
    if ! http=$(command curl -sS -o "$body" -w '%{http_code}' \
         -H "Authorization: Bearer $token" \
         "${API_BASE}${endpoint}?${extra_qs}&ps=${PAGE_SIZE}&p=${page}" 2>/dev/null); then
      err_block \
        "Couldn't reach SonarCloud" \
        "curl failed before HTTP response (likely network)" \
        "GET ${API_BASE}${endpoint}" \
        "Check your network connection, then re-run maintenance"
      return 1
    fi

    if [[ "$http" != "200" ]]; then
      local api_msg
      api_msg=$(jq -r '.errors[0].msg // "no error message"' "$body" 2>/dev/null || cat "$body")
      err_block \
        "SonarCloud API returned HTTP $http" \
        "$api_msg" \
        "GET ${API_BASE}${endpoint}" \
        "If 401: refresh token via sonar-auth.zsh $org. If 403/404: verify projectKey and that the token's user has read access."
      return 1
    fi

    if ! jq -s '.[0] + .[1]' "$acc" <(jq "$array_filter" "$body") > "$acc.new" 2>/dev/null; then
      err_block \
        "Failed to parse SonarCloud response" \
        "jq could not extract '$array_filter' from response body" \
        "GET ${API_BASE}${endpoint}" \
        "Check SonarCloud status; capture the response body for debugging"
      return 1
    fi
    mv "$acc.new" "$acc"

    total=$(jq -r '.paging.total // 0' "$body")
    page_size=$(jq -r '.paging.pageSize // 0' "$body")
    page_index=$(jq -r '.paging.pageIndex // 0' "$body")
    fetched=$(( page_index * page_size ))
    (( fetched >= total )) && break
    page=$(( page + 1 ))
  done

  if (( page > MAX_PAGES )); then
    warn "Hit MAX_PAGES=$MAX_PAGES on $endpoint; some findings may be missing"
  fi

  cat "$acc"
}

# --- step 3: fetch issues + hotspots ---------------------------------------
info "Fetching open issues..."
if ! issues_raw=$(fetch_all '/issues/search' '.issues' \
       "componentKeys=${project}&organization=${org}&resolved=false"); then
  print -- '{"findings": [], "quality_gate": null}'
  final_note "SonarCloud issues fetch failed; see errors above."
  exit 1
fi
issues_count=$(jq 'length' <<<"$issues_raw")
ok "Issues fetched: $issues_count"

info "Fetching open hotspots..."
if ! hotspots_raw=$(fetch_all '/hotspots/search' '.hotspots' \
       "projectKey=${project}&organization=${org}&status=TO_REVIEW"); then
  print -- '{"findings": [], "quality_gate": null}'
  final_note "SonarCloud hotspots fetch failed; see errors above."
  exit 1
fi
hotspots_count=$(jq 'length' <<<"$hotspots_raw")
ok "Hotspots fetched: $hotspots_count"

# --- step 4: quality gate verdict (main branch) ------------------------------
# Single REST call, no paging. Non-fatal: a failure here still emits the
# findings gathered above, with quality_gate: null and a stderr warning.
info "Fetching Quality Gate status..."
quality_gate='null'
qg_label="unavailable"
qg_body=$(mktemp); _tmpfiles+=("$qg_body")
if qg_http=$(command curl -sS -o "$qg_body" -w '%{http_code}' \
     -H "Authorization: Bearer $token" \
     "${API_BASE}/qualitygates/project_status?projectKey=${project}" 2>/dev/null) \
   && [[ "$qg_http" == "200" ]]; then
  if quality_gate=$(jq -c '.projectStatus | {status, conditions: (.conditions // [])}' "$qg_body" 2>/dev/null); then
    qg_status=$(jq -r '.status' <<<"$quality_gate")
    case "$qg_status" in
      OK)    qg_label="PASS" ;;
      ERROR) qg_label="FAIL" ;;
      WARN)  qg_label="WARN" ;;
      *)     qg_label="not computed" ;;
    esac
    ok "Quality Gate: $qg_label"
  else
    quality_gate='null'
    warn "Quality Gate response unparseable; continuing without verdict"
  fi
else
  warn "Quality Gate fetch failed (HTTP ${qg_http:-network error}); continuing without verdict"
fi

# --- step 5: normalize ------------------------------------------------------
info "Normalizing findings..."

# Strip "<projectKey>:" prefix from component → bare file path.
# Hotspot severity from vulnerabilityProbability per the SonarCloud convention.
normalized=$(jq -n \
  --argjson issues "$issues_raw" \
  --argjson hotspots "$hotspots_raw" \
  '
  ($issues | map({
    type:      .type,
    severity:  .severity,
    rule:      .rule,
    component: (.component | sub("^[^:]+:"; "")),
    line:      .line,
    message:   .message,
    key:       .key
  }))
  +
  ($hotspots | map({
    type:              "SECURITY_HOTSPOT",
    severity:          ({HIGH: "CRITICAL", MEDIUM: "MAJOR", LOW: "MINOR"}[.vulnerabilityProbability] // "MAJOR"),
    rule:              .ruleKey,
    component:         (.component | sub("^[^:]+:"; "")),
    line:              .line,
    message:           .message,
    key:               .key,
    security_category: .securityCategory
  }))
  ')

total=$(jq 'length' <<<"$normalized")
ok "Normalized $total findings ($issues_count issues + $hotspots_count hotspots)"

jq -n --argjson findings "$normalized" --argjson qg "$quality_gate" \
  '{findings: $findings, quality_gate: $qg}'
final_note "SonarCloud: gathered $total findings ($issues_count issues + $hotspots_count hotspots). Quality Gate (main): $qg_label."
exit 0
