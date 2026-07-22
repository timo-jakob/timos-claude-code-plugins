#!/usr/bin/env zsh
# check-ops-conformance.zsh — verify a running service exposes the org-standard
# ops surface, in one command (epic #682, design §5; issue #688).
#
# Curls a live service's /info, /health, and /metrics and validates them against
# the ops-api/v1 fragment's shapes:
#
#   /info    — 200 + JSON: build.version, build.git_sha, and an api[] table where
#              every entry has an integer major and a lifecycle of active|deprecated;
#              a DEPRECATED major MUST carry a sunset date (RFC 8594), an active one
#              need not.
#   /health  — 200 + JSON with status "ok".
#   /metrics — 200 + a Prometheus/OpenMetrics exposition content type
#              (text/plain or application/openmetrics-text — both accepted).
#
# Exit 0 when all three conform; non-zero (1) otherwise, with each failure naming
# the offending path and reason on stderr. Usage/tooling errors exit 2.
#
# The HTTP client is `curl`; tests stub it on PATH (the repo's stub-on-PATH
# convention), so this script's decision logic is exercised without a live server.
#
# Bootstrap installs it at scripts/check-ops-conformance.zsh and wires it as the
# `ops-conformance` workflow job. Source template:
# development/skills/bootstrap/templates/common/scripts/check-ops-conformance.zsh
emulate -L zsh
setopt pipe_fail no_unset

CURL="${OPS_CURL:-curl}"
TIMEOUT="${OPS_TIMEOUT:-10}"

usage() {
  print -u2 -- "usage: check-ops-conformance.zsh <base-url> [--timeout <seconds>]"
  print -u2 -- "  e.g. check-ops-conformance.zsh http://localhost:8080"
  exit 2
}

BASE=""
while (( $# > 0 )); do
  case "$1" in
    --timeout) (( $# >= 2 )) || usage; TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) print -u2 -- "unknown flag: $1"; usage ;;
    *)  [[ -z "$BASE" ]] || { print -u2 -- "unexpected argument: $1"; usage; }
        BASE="$1"; shift ;;
  esac
done
[[ -n "$BASE" ]] || usage
BASE="${BASE%/}"   # tolerate a trailing slash
# A non-numeric --timeout is a caller mistake, not a service fault — catch it
# here so curl never turns it into a spurious "unreachable" verdict (exit 2, per
# the usage/tooling-error contract).
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || {
  print -u2 -- "invalid --timeout: '$TIMEOUT' (want a whole number of seconds)"
  usage
}

command -v "$CURL" >/dev/null 2>&1 || {
  print -u2 -- "::error:: '$CURL' not found on PATH"
  exit 2
}
command -v jq >/dev/null 2>&1 || {
  print -u2 -- "::error:: 'jq' not found on PATH"
  exit 2
}

typeset -a failures
BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

HTTP_CODE=""
CONTENT_TYPE=""

# fetch <url> — GET <url>, capturing HTTP_CODE + CONTENT_TYPE and writing the
# body to $BODY_FILE. Returns non-zero only when curl itself can't reach the host
# (a 404/500 is a successful fetch with that status code).
fetch() {
  local meta rc
  : > "$BODY_FILE"   # curl only opens -o lazily; never let a prior body linger
  meta="$("$CURL" -sS -m "$TIMEOUT" -o "$BODY_FILE" \
            -w '%{http_code}\t%{content_type}' "$1" 2>/dev/null)"
  rc=$?
  # curl rc 2 (bad usage) / 3 (malformed URL) are CALLER errors, not an
  # unreachable service — surface them as the exit-2 usage/tooling class rather
  # than a spurious "non-conformant" verdict.
  if (( rc == 2 || rc == 3 )); then
    print -u2 -- "::error:: curl could not use the request for '$1' (rc $rc) — check the base URL"
    exit 2
  fi
  (( rc == 0 )) || return 1
  HTTP_CODE="${meta%%$'\t'*}"
  CONTENT_TYPE="${meta#*$'\t'}"
  return 0
}

fail() { failures+=("$1"); print -u2 -- "::error:: $1"; }

# ---- /info -----------------------------------------------------------------
check_info() {
  local url="$BASE/info"
  if ! fetch "$url"; then
    fail "/info: unreachable at $url"; return
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    fail "/info: expected HTTP 200, got $HTTP_CODE"; return
  fi
  if ! jq -e . "$BODY_FILE" >/dev/null 2>&1; then
    fail "/info: body is not valid JSON"; return
  fi
  jq -e '.build.version | strings and (. != "")' "$BODY_FILE" >/dev/null 2>&1 \
    || fail "/info: missing build.version"
  jq -e '.build.git_sha | strings and (. != "")' "$BODY_FILE" >/dev/null 2>&1 \
    || fail "/info: missing build.git_sha"
  if ! jq -e '.api | arrays' "$BODY_FILE" >/dev/null 2>&1; then
    fail "/info: api must be an array of served majors"; return
  fi
  # Per-major shape + the deprecated-needs-sunset rule. Iterate one compact JSON
  # object per line (no base64 — portable across macOS/Debian jq).
  local m major life sunset
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    # major must be a JSON integer >= 1 — jq -r would erase a string "1" or a 0,
    # both of which the fragment's `type: integer, minimum: 1` forbids.
    if ! jq -e '(.major | type == "number" and . == floor and . >= 1)' \
         >/dev/null 2>&1 <<< "$m"; then
      fail "/info: an api entry has a missing or non-integer major (must be an integer >= 1)"
      continue
    fi
    major=$(jq -r '.major' <<< "$m")
    life=$(jq -r '.lifecycle // empty' <<< "$m")
    # sunset counts as present only as a (date) string — not true / 1 / null.
    sunset=$(jq -r 'if (.sunset | type) == "string" then .sunset else "" end' <<< "$m")
    if [[ "$life" != "active" && "$life" != "deprecated" ]]; then
      fail "/info: major $major has an invalid lifecycle '$life' (want active|deprecated)"
      continue
    fi
    if [[ "$life" == "deprecated" && -z "$sunset" ]]; then
      fail "/info: major $major is deprecated but has no sunset date (RFC 8594)"
    fi
  done < <(jq -c '.api[]?' "$BODY_FILE" 2>/dev/null)
}

# ---- /health ---------------------------------------------------------------
check_health() {
  local url="$BASE/health"
  if ! fetch "$url"; then
    fail "/health: unreachable at $url"; return
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    fail "/health: expected HTTP 200, got $HTTP_CODE"; return
  fi
  jq -e '.status == "ok"' "$BODY_FILE" >/dev/null 2>&1 \
    || fail "/health: expected JSON status \"ok\""
}

# ---- /metrics --------------------------------------------------------------
check_metrics() {
  local url="$BASE/metrics"
  if ! fetch "$url"; then
    fail "/metrics: unreachable at $url"; return
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    fail "/metrics: expected HTTP 200, got $HTTP_CODE"; return
  fi
  # Both Prometheus and OpenMetrics exposition content types are accepted; the
  # match is a prefix because curl reports e.g. "text/plain; version=0.0.4".
  case "${CONTENT_TYPE:l}" in
    text/plain*|application/openmetrics-text*) : ;;
    *) fail "/metrics: unexpected content-type '$CONTENT_TYPE' (want text/plain or application/openmetrics-text)" ;;
  esac
}

check_info
check_health
check_metrics

if (( ${#failures} > 0 )); then
  print -u2 -- "ops conformance FAILED: ${#failures} problem(s) at $BASE"
  exit 1
fi

print -- "ops conformance PASSED at $BASE"
print -- "  /info    PASS"
print -- "  /health  PASS"
print -- "  /metrics PASS"
exit 0
