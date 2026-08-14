#!/usr/bin/env zsh
# check-ops-conformance.zsh — verify a running service exposes the org-standard
# ops surface, in one command (epic #682, design §5; issue #688).
#
# The BASE URL is the service's internal MANAGEMENT base (e.g.
# http://localhost:9090) — the ops surface is served on a separate management
# port, never the public app port. Curls the ops endpoints and validates them
# against the ops-api/v2 fragment's shapes (v2 per #1330 — the probe 503s are RFC
# 9457 problem documents; see the /health/live and /health/ready entries below):
#
#   /info         — 200 + JSON: build.version, build.git_sha, and an api[] table
#                   where every entry has an integer major and a lifecycle of
#                   active|deprecated; a DEPRECATED major MUST carry a sunset date
#                   (RFC 8594), an active one need not.
#   /health       — 200 + JSON status "ok" or "degraded" (aggregate, human-facing;
#                   a degraded service is still serving, so it still conforms —
#                   an aggregate of "down" is a legitimate runtime state but NOT
#                   a conforming one, because conformance asserts a service that
#                   is serving). When the OPTIONAL `components` map is present
#                   (ops-api v1.1, #965) its shape is validated and the aggregate
#                   is checked against it: a HARD dependency DOWN means the
#                   aggregate must be "down"; ANY other dependency down or
#                   degraded (hard or soft — a hard dependency that is merely
#                   half-open counts here, not above) means at least "degraded".
#   /health/live  — 200 + JSON status "ok" (K8s liveness — process only).
#   /health/ready — 200 + JSON status "ok" (K8s readiness — dependencies).
#                   EITHER probe answering 503 is a conformance FAILURE (this
#                   command asserts a SERVING service, and there is no flag to
#                   tolerate one) — but the 503 is still VALIDATED, because its
#                   body is where the reason lives: it must be a bare
#                   application/problem+json RFC 9457 document with type, title,
#                   an INTEGER status and a string detail, and the failure then
#                   names the dependency out of `detail`. A v1
#                   `{"status":"down"}` 503 is reported as an UNMIGRATED payload,
#                   pointing at the ops how-to — that message is a migration
#                   instruction, not a shape complaint.
#                   NOTE the limit: a HEALTHY service never answers 503, so a
#                   green run does not prove the 503 bodies are v2-shaped. Only a
#                   run that actually observes a 503 does.
#   /metrics      — 200 + a Prometheus/OpenMetrics exposition content type
#                   (text/plain or application/openmetrics-text — both accepted).
#
# Exit 0 when all conform; non-zero (1) otherwise, with each failure naming the
# offending path and reason on stderr. Usage/tooling errors exit 2.
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

# ---- /health/live, /health/ready -------------------------------------------
# check_status_endpoint <ep> — a BINARY Kubernetes probe: 200 + JSON status "ok".
# The probes stay binary by contract (the kubelet acts on one yes/no answer), so
# "degraded" is not a probe value — the tri-state aggregate lives on /health
# (check_health). A soft dependency being down must NOT fail readiness; that rule
# is the service's to implement, and is asserted end-to-end, not from here.
# NB: the parameter must NOT be named `path` — in zsh `path` is the special array
# tied to $PATH, and clobbering it breaks command lookup (env can't find bash).
check_status_endpoint() {
  local ep="$1" url="$BASE$1"
  if ! fetch "$url"; then
    fail "${ep}: unreachable at $url"; return
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    # A 503 stays a conformance FAILURE — conformance asserts a SERVING service,
    # and there is deliberately no flag to tolerate one. But since ops-api v2
    # (#1330) that 503 carries an RFC 9457 problem document, so the failure can
    # say WHICH dependency shed the pod instead of just naming a status code.
    if [[ "$HTTP_CODE" == "503" ]]; then
      check_probe_problem "$ep"
      return
    fi
    fail "${ep}: expected HTTP 200, got $HTTP_CODE"; return
  fi
  jq -e '.status == "ok"' "$BODY_FILE" >/dev/null 2>&1 \
    || fail "${ep}: expected JSON status \"ok\""
}

# check_probe_problem <ep> — validate a probe's 503 body as RFC 9457 problem
# details, and fail with the most useful message the body supports.
#
# THE LEGACY BRANCH IS THE POINT. A service still running an ops-api v1 payload
# answers {"status":"down"} here. Reported as a generic shape error, that reads as
# a broken service and sends an adopter debugging their own code; reported as what
# it is, it is a one-line migration instruction. This is the single message that
# turns the v1 -> v2 cutover from a mystery into a task.
check_probe_problem() {
  local ep="$1" detail missing
  if jq -e '.status == "down" and (has("type") | not)' "$BODY_FILE" >/dev/null 2>&1; then
    # The URL, not a repo-relative path: this script runs in the BOOTSTRAPPED
    # repo, which has no docs/how-to/ tree of its own, so a relative pointer
    # dead-ends exactly when the message is meant to be actionable.
    fail "${ep}: 503 body is the ops-api v1 envelope {\"status\":\"down\"}, not RFC 9457 problem details — this service is still on an ops-api v1 payload; migrate to contracts/ops/v2: https://timo-jakob.github.io/timos-claude-code-plugins/how-to/adopt-the-ops-surface/"
    return
  fi
  # Lowercased, like check_metrics: media types are case-insensitive (RFC 9110), so
  # `Application/Problem+JSON` is conformant and must not be reported as the wrong
  # type — that would hide the dependency detail this branch exists to surface.
  case "${CONTENT_TYPE:l}" in
    application/problem+json*) ;;
    *) fail "${ep}: 503 must be served as application/problem+json (RFC 9457), got '${CONTENT_TYPE}'"; return ;;
  esac
  # PARSE BEFORE SHAPE-CHECKING, as check_info and check_health already do. Without
  # this, an empty body (curl truncates $BODY_FILE on a bodyless 503), truncated
  # JSON, or a scalar/array makes the `keys` subtraction below FAIL rather than
  # return members — `missing` comes back empty, the branch concludes all four are
  # present, and the run reports "status must be the integer 503" about a body that
  # has no status at all. The exit code would be right and the diagnosis a lie,
  # which defeats the whole point of this branch.
  if ! jq -e 'type == "object"' "$BODY_FILE" >/dev/null 2>&1; then
    fail "${ep}: 503 body is not a JSON object (RFC 9457 problem details required)"; return
  fi
  # All four members are REQUIRED by the contract, and `status` is the HTTP code as
  # an INTEGER — the collision with the health envelope's "ok"/"down" string is the
  # whole reason ops-api v2 exists, so a string here is exactly the mistake to catch.
  missing="$(jq -r '["type","title","status","detail"] - (. | keys) | join(", ")' "$BODY_FILE" 2>/dev/null)"
  if [[ -n "$missing" ]]; then
    fail "${ep}: 503 problem document is missing required member(s): ${missing}"; return
  fi
  if ! jq -e '.status == 503' "$BODY_FILE" >/dev/null 2>&1; then
    fail "${ep}: 503 problem document's \"status\" must be the integer 503 (RFC 9457), not the health envelope's string"; return
  fi
  # Presence is not enough: a null or non-string detail passes the `keys` check and
  # would be read out verbatim, so the failure line would read "not ready — null".
  if ! jq -e '.detail | type == "string"' "$BODY_FILE" >/dev/null 2>&1; then
    fail "${ep}: 503 problem document's \"detail\" must be a string (RFC 9457)"; return
  fi
  detail="$(jq -r '.detail' "$BODY_FILE" 2>/dev/null)"
  # The label follows the ENDPOINT, not the branch: this function serves both
  # probes, and the Spring payload really does emit a not-alive problem on
  # /health/live (its LivenessState can be BROKEN). A fixed "not ready" would
  # mislabel a liveness failure as a readiness one — the two have opposite
  # remedies, restart versus shed traffic.
  local label="not ready"
  if [[ "$ep" == "/health/live" ]]; then
    label="not alive"
  fi
  fail "${ep}: ${label} — ${detail} (503)"
}

# ---- /health (aggregate + optional dependency components, #965) ------------
# The components set a FLOOR on the aggregate: "down" if any HARD dependency is
# DOWN, else "degraded" if ANY dependency (hard or soft) is down or degraded,
# else "ok". Note the middle branch is deliberately kind-agnostic — a HARD
# dependency that is merely `degraded` (breaker half-open, re-probing) floors the
# aggregate at "degraded", not "down"; only a hard dependency that is fully down
# forces "down".
#
# It is a FLOOR, not an equality: a service may report itself degraded for an
# internal reason no dependency models (a backed-up queue), and failing that
# would be a false alarm. What can never be legitimate is UNDER-reporting — a
# hard dependency down while the aggregate still claims to be serving — so that
# is what this rejects.
#
# "degraded" is a CONFORMANT aggregate: a soft dependency is down, the breaker is
# open, and the service is deliberately still serving (that is the whole point of
# the hard/soft split). Only "down" fails.
check_health() {
  local ep="/health" url="$BASE/health" agg floor="ok" hard_down="" c name cstatus kind breaker since
  if ! fetch "$url"; then
    fail "${ep}: unreachable at $url"; return
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    fail "${ep}: expected HTTP 200, got $HTTP_CODE"; return
  fi
  if ! jq -e . "$BODY_FILE" >/dev/null 2>&1; then
    fail "${ep}: body is not valid JSON"; return
  fi
  # A non-string status (true / 1 / null) is not the contract's enum member.
  agg=$(jq -r 'if (.status | type) == "string" then .status else "" end' "$BODY_FILE")
  case "$agg" in
    ok|degraded|down) : ;;
    *) fail "${ep}: expected JSON status \"ok\", \"degraded\" or \"down\", got '${agg}'"; return ;;
  esac

  # `components` is OPTIONAL — a service with no declared dependencies omits it.
  if jq -e 'has("components")' "$BODY_FILE" >/dev/null 2>&1; then
    if ! jq -e '.components | objects' "$BODY_FILE" >/dev/null 2>&1; then
      fail "${ep}: components must be an object keyed by dependency name"
      return
    fi
    # One compact JSON object per dependency, carrying its key — the same
    # no-base64 iteration /info uses, portable across macOS/Debian jq.
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      # to_entries yields {key, value} — the dependency name is the KEY.
      name=$(jq -r '.key' <<< "$c")
      cstatus=$(jq -r 'if (.value.status | type) == "string" then .value.status else "" end' <<< "$c")
      kind=$(jq -r 'if (.value.kind | type) == "string" then .value.kind else "" end' <<< "$c")
      breaker=$(jq -r 'if (.value.breaker | type) == "string" then .value.breaker else "" end' <<< "$c")
      since=$(jq -r 'if (.value | has("since")) then ((.value.since | type)) else "absent" end' <<< "$c")
      case "$cstatus" in
        up|degraded|down) : ;;
        *) fail "${ep}: dependency '${name}' has an invalid status '${cstatus}' (want up|degraded|down)" ;;
      esac
      # kind is the readiness hinge — an undeclared one leaves readiness undefined.
      case "$kind" in
        hard|soft) : ;;
        *) fail "${ep}: dependency '${name}' has an invalid kind '${kind}' (want hard|soft)" ;;
      esac
      # breaker + since are optional, but a present one must be well-formed.
      if [[ -n "$breaker" ]]; then
        case "$breaker" in
          closed|open|half_open) : ;;
          *) fail "${ep}: dependency '${name}' has an invalid breaker '${breaker}' (want closed|open|half_open)" ;;
        esac
      elif jq -e '.value | has("breaker")' >/dev/null 2>&1 <<< "$c"; then
        fail "${ep}: dependency '${name}' has a non-string breaker"
      fi
      [[ "$since" == "string" || "$since" == "absent" ]] \
        || fail "${ep}: dependency '${name}' has a non-string since (want an RFC 3339 timestamp)"
      # Raise the floor the aggregate must meet.
      if [[ "$cstatus" == "down" && "$kind" == "hard" ]]; then
        floor="down"; hard_down="$name"
      elif [[ "$cstatus" == "down" || "$cstatus" == "degraded" ]]; then
        [[ "$floor" == "down" ]] || floor="degraded"
      fi
    done < <(jq -c '.components | to_entries[]?' "$BODY_FILE" 2>/dev/null)

    if [[ "$floor" == "down" && "$agg" != "down" ]]; then
      fail "${ep}: hard dependency '${hard_down}' is down but the aggregate status is '${agg}' (want \"down\")"
    elif [[ "$floor" == "degraded" && "$agg" == "ok" ]]; then
      fail "${ep}: a dependency is down or degraded but the aggregate status is \"ok\" (want at least \"degraded\")"
    fi
  fi

  # Reported after the component checks, so the output names the dependency that
  # caused it rather than only the aggregate.
  [[ "$agg" == "down" ]] \
    && fail "${ep}: aggregate status is \"down\" — the service is not serving"
  return 0
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
check_status_endpoint /health/live
check_status_endpoint /health/ready
check_metrics

if (( ${#failures} > 0 )); then
  print -u2 -- "ops conformance FAILED: ${#failures} problem(s) at $BASE"
  exit 1
fi

print -- "ops conformance PASSED at $BASE"
print -- "  /info         PASS"
print -- "  /health       PASS"
print -- "  /health/live  PASS"
print -- "  /health/ready PASS"
print -- "  /metrics      PASS"
exit 0
