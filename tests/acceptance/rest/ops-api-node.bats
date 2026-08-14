#!/usr/bin/env bats
#
# Acceptance cases for the Node ops-api payload (#936) — the `curl`-tooled half
# of its story-spec `test_cases[]`, one test per `tc-*` id:
#
#   tc-happy-info-lifecycle-table              #1234
#   tc-happy-metrics-single-listener           #1235
#   tc-happy-version-falls-back-to-package-json #1236
#   tc-corner-health-200-while-down            #1237
#   tc-corner-soft-down-readiness-stays-200    #1238
#   tc-corner-hard-down-readiness-503          #1239
#   tc-corner-seam-unwired-is-v2.0             #1240
#   tc-error-ops-surface-not-on-app-port       #1244
#   tc-error-readiness-503-is-bare-problem-json #1347
#
# Plus two cases with no tc-* id, each a claim only a RUNNING service can prove:
# the SIGTERM graceful drain (which the teardown deliberately cannot make), and
# the provisioner's refusal to re-provision a sandbox in use (which has already
# shipped once in a form that could not fire, so it is observed rather than
# asserted).
#
# These run against a REAL service built from the shipped template (see
# ../lib/node-ops-sandbox.zsh). They are NOT part of the default gate — `bats
# tests` does not recurse — see ../README.md for why, and #243 for the tier that
# will run them.

bats_require_minimum_version 1.5.0
load ../lib/ops-acceptance

setup_file() {
  # Provision ONCE per file: the npm install is incremental but the tsc build is
  # not, and paying it per test would multiply the suite's runtime by the test
  # count. Unguarded and allowed to fail the file — a missing toolchain must be loud.
  load ../lib/ops-acceptance
  ops_provision
  # 9464 is the OTel Prometheus exporter's default and cannot be salted per test,
  # so tc-happy-metrics-single-listener's absence check is only meaningful on a
  # host where nothing else holds it. Diagnose that here, once, in words that
  # cannot be mistaken for a payload regression.
  require_port_free 9464 "the exporter must not start its own server"
}

setup() { ops_sandbox; }
teardown() { ops_stop; }

@test "tc-happy-info-lifecycle-table: /info serves the build block and the majors" {
  ops_start lifecycle GIT_SHA=9e11997 BUILD_VERSION=1.4.2
  [ "$(http_code "$BASE/info")" = "200" ]
  local body; body="$(http_body "$BASE/info")"
  [ "$(jq -r .build.version <<< "$body")" = "1.4.2" ]
  [ "$(jq -r .build.git_sha <<< "$body")" = "9e11997" ]
  [ "$(jq -r '.api[0].major' <<< "$body")" = "1" ]
  [ "$(jq -r '.api[0].lifecycle' <<< "$body")" = "deprecated" ]
  [ "$(jq -r '.api[0].sunset' <<< "$body")" = "2027-01-31" ]
  [ "$(jq -r '.api[1].major' <<< "$body")" = "2" ]
  [ "$(jq -r '.api[1].lifecycle' <<< "$body")" = "active" ]
  # An ACTIVE major must carry no sunset — the half of the RFC 8594 invariant
  # nothing downstream checks, so this is the only place it is observed.
  [ "$(jq -r '.api[1] | has("sunset")' <<< "$body")" = "false" ]
}

@test "tc-happy-metrics-single-listener: /metrics is served on the management port, and nothing else binds" {
  ops_start lifecycle GIT_SHA=9e11997
  [ "$(http_code "$BASE/metrics")" = "200" ]
  # The checker accepts text/plain or application/openmetrics-text, both possibly
  # with parameters (`; version=0.0.4`), so match a prefix.
  local ctype; ctype="$(http_ctype "$BASE/metrics")"
  case "$ctype" in
    text/plain*|application/openmetrics-text*) ;;
    *) echo "unexpected /metrics content-type: $ctype" >&2; return 1 ;;
  esac
  # THE point of the case: the OTel Prometheus exporter's own default port must
  # NOT be bound. Without `preventServerStart` it starts a second server on 9464
  # — a silent extra listener on a management surface — while every assertion
  # above still passes.
  port_is_closed 9464
}

@test "tc-happy-version-falls-back-to-package-json: BUILD_VERSION unset reports the package version" {
  # No BUILD_VERSION. The sandbox's package.json declares 1.4.2, and that is a
  # TRUTHFUL fallback — it is the service's own version, not a placeholder.
  ops_start unwired GIT_SHA=9e11997
  [ "$(jq -r .build.version <<< "$(http_body "$BASE/info")")" = "1.4.2" ]
}

@test "tc-corner-health-200-while-down: /health answers 200 with the verdict in the body" {
  # #1139, the defect the Java and Python payloads shipped: an operator reading
  # /health during an outage needs the diagnosis, so the verdict rides in the
  # BODY and the status stays 200. Only the two probes speak in status codes.
  ops_start hard-down GIT_SHA=9e11997
  [ "$(http_code "$BASE/health")" = "200" ]
  [ "$(jq -r .status <<< "$(http_body "$BASE/health")")" = "down" ]
}

@test "tc-corner-soft-down-readiness-stays-200: a soft dependency down degrades but keeps serving" {
  ops_start soft-down GIT_SHA=9e11997
  local body; body="$(http_body "$BASE/health")"
  [ "$(http_code "$BASE/health")" = "200" ]
  [ "$(jq -r .status <<< "$body")" = "degraded" ]
  [ "$(jq -r '.components["pricing-api"].status' <<< "$body")" = "down" ]
  [ "$(jq -r '.components["pricing-api"].kind' <<< "$body")" = "soft" ]
  [ "$(jq -r '.components["pricing-api"].breaker' <<< "$body")" = "open" ]
  [ "$(jq -r '.components["pricing-api"].since' <<< "$body")" = "2026-08-10T09:12:44Z" ]
  # The readiness hinge: a SOFT dependency never sheds traffic.
  [ "$(http_code "$BASE/health/ready")" = "200" ]
  [ "$(http_code "$BASE/health/live")" = "200" ]
  # …and a degraded service is still a CONFORMING one.
  run zsh "$CHECKER" "$BASE"
  [ "$status" -eq 0 ]
}

@test "tc-corner-hard-down-readiness-503: a hard dependency down sheds traffic but stays alive" {
  # ops-api v2 (#1330): the 503 is an RFC 9457 problem document, so the health
  # "down" string is GONE from this body — `status` is the integer 503, and the
  # diagnosis rides in `components`.
  ops_start hard-down GIT_SHA=9e11997
  [ "$(http_code "$BASE/health/ready")" = "503" ]
  local body; body="$(http_body "$BASE/health/ready")"
  [ "$(jq -r .type <<< "$body")" = "urn:problem-type:ops:not-ready" ]
  [ "$(jq -r .title <<< "$body")" = "Service Not Ready" ]
  # -e so a STRING "503" fails: the integer/string collision is why v2 exists.
  jq -e '.status == 503' <<< "$body" >/dev/null
  [ "$(jq -r .detail <<< "$body")" = "hard dependency 'orders-db' is down" ]
  # The map carries ALL declared dependencies, not only the failing one, and is
  # byte-identical to what /health serves for the same call.
  [ "$(jq -r '.components["orders-db"].status' <<< "$body")" = "down" ]
  [ "$(jq -r '.components["orders-db"].kind' <<< "$body")" = "hard" ]
  [ "$(jq -r '.components["orders-db"].breaker' <<< "$body")" = "open" ]
  jq -e --argjson h "$(jq -c .components <<< "$(http_body "$BASE/health")")" \
    '.components == $h' <<< "$body" >/dev/null
  # Liveness must be independent of every dependency: a failing liveness restarts
  # the pod, which turns a transient outage into a restart storm.
  [ "$(http_code "$BASE/health/live")" = "200" ]
  [ "$(jq -r .status <<< "$(http_body "$BASE/health/live")")" = "ok" ]
}

@test "tc-error-readiness-503-is-bare-problem-json: the 503 media type is problem+json, whatever the client asks for" {
  # #1347. Bare-ness is a RUNTIME property, not only a spec one: a correctly shaped
  # body on application/json is still an org-problem-json-errors failure. Nothing
  # asserted this end-to-end before v2.
  ops_start hard-down GIT_SHA=9e11997
  local ct; ct="$(http_ctype "$BASE/health/ready")"
  case "$ct" in
    application/problem+json*) ;;
    *) printf 'expected application/problem+json, got %s\n' "$ct" >&2; return 1 ;;
  esac
  # …even when the client explicitly asks for plain JSON.
  ct="$(curl -s -o /dev/null -w '%{content_type}' --max-time 5 \
        -H 'Accept: application/json' "$BASE/health/ready")"
  case "$ct" in
    application/problem+json*) ;;
    *) printf 'Accept: application/json changed the type to %s\n' "$ct" >&2; return 1 ;;
  esac
  # The 200 paths keep the ordinary type — v2 changed the 503 and nothing else.
  case "$(http_ctype "$BASE/health/live")" in
    application/json*) ;;
    *) printf 'liveness 200 lost application/json\n' >&2; return 1 ;;
  esac
  case "$(http_ctype "$BASE/health")" in
    application/json*) ;;
    *) printf '/health 200 lost application/json\n' >&2; return 1 ;;
  esac
}

@test "tc-corner-seam-unwired-is-v2.0: an unwired seam serves a byte-valid v2.0 body" {
  # The state of every repo that has not adopted the resilience payload (#1145).
  # `components` must be ABSENT — not `{}`, which would announce a v1.1 body that
  # then reports nothing. Renamed from -is-v1.0 with #1330: the id names the
  # version it asserts, and leaving it would make the test title a lie.
  ops_start unwired GIT_SHA=9e11997
  local body; body="$(http_body "$BASE/health")"
  [ "$(jq -r .status <<< "$body")" = "ok" ]
  [ "$(jq -r 'has("components")' <<< "$body")" = "false" ]
  [ "$(http_code "$BASE/health/ready")" = "200" ]
  # An unconfigured servedMajors defaults to a single ACTIVE major 1.
  [ "$(jq -r '.api | length' <<< "$(http_body "$BASE/info")")" = "1" ]
  [ "$(jq -r '.api[0].lifecycle' <<< "$(http_body "$BASE/info")")" = "active" ]
  run zsh "$CHECKER" "$BASE"
  [ "$status" -eq 0 ]
}

@test "tc-error-ops-surface-not-on-app-port: the surface binds the management port only" {
  # /info carries build data, so it must be unreachable from the public app port.
  # The service binds exactly one port — the management one — and the app port is
  # a different process's concern entirely.
  ops_start lifecycle GIT_SHA=9e11997
  [ "$(http_code "$BASE/info")" = "200" ]
  # NOT `port_is_closed 8080`: that asserts nothing on the HOST listens there,
  # which any local dev server or container publish falsifies while saying nothing
  # about the payload.
  #
  # Be honest about what remains: the fixture binds exactly one port, so NO edit to
  # opsApi.ts can make 8080 answer — this documents the claim, it is not falsifiable
  # at this tier. The falsifiable half of the case is below (404 naming the path,
  # 405 on a non-GET) and in tc-happy-metrics-single-listener's 9464 check, where
  # the exporter really would bind a second port.
  not_our_ops_surface 8080 9e11997
  # An unknown path on the management port names itself rather than serving a
  # blank 404 — and a non-GET is a 405, not a misleading "wrong path" 404.
  [ "$(http_code "$BASE/nope")" = "404" ]
  [ "$(jq -r .path <<< "$(http_body "$BASE/nope")")" = "/nope" ]
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$BASE/health")" = "405" ]
}

@test "the provisioner REFUSES to re-provision a sandbox a fixture is running out of" {
  # Not a payload claim — a harness one, and the only way to observe it. The
  # in-use guard has already been shipped once in a form that could never fire
  # (it grepped for an absolute path while the fixture was launched with a
  # relative one), and nothing noticed, because "the guard did not fire" and "the
  # guard cannot fire" look identical from outside.
  #
  # Safe to run: the guard sits BEFORE the prune, so a refusal leaves this
  # suite's sandbox exactly as it was.
  ops_start lifecycle GIT_SHA=9e11997
  local before; before="$(cksum < "$SANDBOX/dist/main.js")"
  run zsh "$REPO_ROOT/tests/acceptance/lib/node-ops-sandbox.zsh" \
    --suite "$BATS_TEST_FILENAME"
  # 3 is the provisioner's typed code for THIS refusal — 1 is a provisioning
  # failure and 2 a usage/toolchain fault, either of which would satisfy a bare
  # non-zero check while the guard stayed dead. The message is asserted too, so a
  # renumbering cannot quietly repoint the case at a different refusal.
  [ "$status" -eq 3 ]
  printf '%s\n' "$output" | grep -qF 'is in use by a running fixture'
  # …and it refused without touching anything. Compared by CONTENT, not by
  # existence: a provisioner that DID run would prune and recompile, restoring a
  # dist/main.js that an `-f` test could not tell from the untouched one.
  [ "$(cksum < "$SANDBOX/dist/main.js")" = "$before" ]
}

@test "SIGTERM drains and exits promptly, even with an idle keep-alive connection" {
  # Not one of the story-spec tc-* ids: it is the claim only a RUNNING service can
  # prove, and the teardown deliberately cannot make it (it SIGKILLs after a second
  # and ignores the result, so every outcome reports ok).
  #
  # What it proves: with an idle keep-alive connection open, SIGTERM still leads
  # to a CLEAN exit (status 0, via ops_terminate_within) inside 5s, and the port
  # is released. A close() that rejects, a provider.shutdown() that throws, or a
  # handler that never resolves each fail it — none of which the teardown could
  # see, since that SIGKILLs after a second and discards the result.
  #
  # What it deliberately does NOT claim: that it catches a dropped
  # `server.closeIdleConnections()`. That was measured (Node 26) and it does not —
  # `server.close()` releases idle keep-alive sockets on its own there, so the
  # drain finishes in 0s either way. The payload keeps the explicit call for
  # runtimes where close() waits instead; this case cannot discriminate it, and
  # saying otherwise would be false confidence.
  #
  # The socket is still held by THIS shell's fd rather than a curl subprocess:
  # curl exits after its last response and sends FIN, so there would be no idle
  # connection left at SIGTERM time and the case would not test what it says.
  ops_start lifecycle GIT_SHA=9e11997
  exec 9<>"/dev/tcp/127.0.0.1/$PORT"
  printf 'GET /health/live HTTP/1.1\r\nHost: ops\r\nConnection: keep-alive\r\n\r\n' >&9
  # Read one byte so the exchange has completed and the socket is genuinely IDLE
  # (not mid-request, which `server.close()` waits for on its own account).
  #
  # A bounded `read`, not `head -c 1`: head is unbounded and cannot tell a byte
  # from an EOF. A payload that accepts the connection but never answers would
  # hang the whole suite with every earlier test already reported ok — the failure
  # mode every other blocking call in this tier is budgeted against — and one that
  # DESTROYS the socket instead of answering would give head zero bytes and exit
  # 0, leaving the case to "prove" a drain with no connection open at all.
  # `-n 1` rather than `-N 1`: macOS ships bash 3.2, where `-N` does not exist.
  read -r -t 5 -n 1 -u 9 _ || {
    echo "no response byte on the keep-alive socket within 5s — the fixture did not answer, or it closed the connection" >&2
    return 1
  }
  ops_terminate_within 5
  exec 9<&-
  exec 9>&-
  port_is_closed "$PORT"
}
