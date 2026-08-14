#!/usr/bin/env bats
#
# Behavioural tests for the ops-conformance checker (#688) —
# templates/common/scripts/check-ops-conformance.zsh. The checker curls a live
# service's /info, /health, /metrics and validates them against the ops-api v2
# fragment's shapes. curl is not in the test toolchain (and no server runs), so a
# STUB curl (via $OPS_CURL) serves canned per-endpoint responses from a fixture
# dir — this exercises the checker's DECISION logic (status codes, /info schema
# incl. the deprecated-needs-sunset rule, /metrics content type). The real curl +
# a real service are exercised by the Python canonical impl's acceptance run.

bats_require_minimum_version 1.5.0
# The shared helpers are the sanctioned way to assert here (tests/README.md); this
# file predates them and its older cases still use `echo | grep -q`, which is fine
# as a command of its own. New cases use contains/lacks — `lacks` in particular,
# because a hand-rolled `! echo … | grep` is the inert-negation shape the suite
# lint bans.
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/check-ops-conformance.zsh"

  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  export OPS_STUB_DIR="$STUB_DIR"

  # Stub curl: honours the checker's `-o <file>` and `-w '%{http_code}\t%{content_type}'`,
  # keying the response off the URL's final path segment (info | health | live |
  # ready | metrics — /health/live and /health/ready reduce to live/ready)
  # against files <ep>.code / <ep>.ct / <ep>.body in $OPS_STUB_DIR.
  local stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
  cat > "$stub/curl" <<'EOS'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    -m) shift 2 ;;
    -sS) shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
ep="${url##*/}"
d="$OPS_STUB_DIR"
# A per-endpoint <ep>.rc makes the stub EXIT with that code, so the checker's
# "curl could not reach the host" branch is reachable from the suite.
rc="$(cat "$d/$ep.rc" 2>/dev/null || echo 0)"
if [ "$rc" != "0" ]; then exit "$rc"; fi
if [ -n "$out" ] && [ -f "$d/$ep.body" ]; then cp "$d/$ep.body" "$out"; fi
code="$(cat "$d/$ep.code" 2>/dev/null || echo 000)"
ct="$(cat "$d/$ep.ct" 2>/dev/null || echo application/json)"
printf '%s\t%s' "$code" "$ct"
EOS
  chmod +x "$stub/curl"
  export OPS_CURL="$stub/curl"

  # Conformant defaults for all three endpoints; individual tests override one.
  serve info 200 'application/json' \
    '{"build":{"version":"1.4.2","git_sha":"9f3c2ab"},"api":[{"major":2,"lifecycle":"active"}]}'
  serve health 200 'application/json' '{"status":"ok"}'
  serve live 200 'application/json' '{"status":"ok"}'
  serve ready 200 'application/json' '{"status":"ok"}'
  serve metrics 200 'text/plain; version=0.0.4' \
    'http_server_request_duration_seconds_bucket{le="0.1"} 1'
}

# serve <endpoint> <http-code> <content-type> <body>
serve() {
  printf '%s' "$2" > "$STUB_DIR/$1.code"
  printf '%s' "$3" > "$STUB_DIR/$1.ct"
  printf '%s' "$4" > "$STUB_DIR/$1.body"
}

# serve_rc <endpoint> <curl-exit-code> — make the stub curl FAIL for <endpoint>,
# so the checker sees an unreachable host rather than an HTTP response.
serve_rc() { printf '%s' "$2" > "$STUB_DIR/$1.rc"; }

run_check() { run zsh "$SCRIPT" "http://svc:8080"; }

@test "happy: fully conformant service -> exit 0, all five PASS" {
  run_check
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '/info +PASS'
  echo "$output" | grep -qE '/health +PASS'
  echo "$output" | grep -qE '/health/live +PASS'
  echo "$output" | grep -qE '/health/ready +PASS'
  echo "$output" | grep -qE '/metrics +PASS'
}

@test "error: /health/live 503 -> non-zero, names /health/live" {
  serve live 503 'application/json' '{"status":"down"}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '/health/live'
}

@test "error: /health/ready 503 -> non-zero, names /health/ready" {
  serve ready 503 'application/json' '{"status":"down"}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '/health/ready'
}

# ---- ops-api v2: the RFC 9457 probe 503 (#1330) -----------------------------

@test "error: a probe answering 404 or 500 takes the generic branch, naming the code" {
  # Round-2 finding. #1330 diverted every probe 503 into check_probe_problem, and
  # the only two tests that previously reached the generic "expected HTTP 200, got
  # N" fallthrough were 503s — so that branch became dead to this suite and could
  # have been deleted, or had its message rewritten to name the wrong endpoint,
  # with everything green. A probe answering 404 is the commonest symptom of a
  # payload mounted on the wrong path (the Go `go 1.22` directive trap).
  serve ready 404 'application/json' 'not found'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" '/health/ready: expected HTTP 200, got 404'
  # It must NOT be routed through the problem-document branch. Needled on that
  # branch's own vocabulary, not the bare word "problem" — the checker's summary
  # line reads "N problem(s)" on every failing run.
  lacks "$output" 'problem+json'
  lacks "$output" 'problem document'
  lacks "$output" 'ops-api v1 envelope'
}

@test "error: a probe answering 500 is reported against the endpoint that answered it" {
  serve live 500 'application/json' '{}'
  run_check
  [ "$status" -eq 1 ]
  # Endpoint-qualified, so a probe mislabelled as its sibling still reds.
  contains "$output" '/health/live: expected HTTP 200, got 500'
  lacks "$output" '/health/ready: expected HTTP 200, got 500'
}

@test "tc-error-legacy-v1-503-body: a v1 {\"status\":\"down\"} 503 is named as a MIGRATION, not a shape error" {
  # #1344. This is the single message that turns the v1 -> v2 cutover from a
  # mystery into a task: reported generically, an adopter debugs their own code.
  serve ready 503 'application/json' '{"status":"down"}'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" 'ops-api v1 envelope'
  contains "$output" 'contracts/ops/v2'
  # The PUBLISHED URL, not a repo-relative path: this script runs in the
  # bootstrapped repo, which has no docs/how-to/ tree, so a relative pointer
  # dead-ends exactly when the message needs to be actionable.
  contains "$output" 'https://timo-jakob.github.io/timos-claude-code-plugins/how-to/adopt-the-ops-surface/'
  lacks "$output" 'see docs/how-to/adopt-the-ops-surface.md'
}

@test "corner: a liveness 503 is labelled NOT ALIVE, not 'not ready'" {
  # Round-1 review finding: check_probe_problem serves both probes, and the Spring
  # payload really does emit a not-alive problem on /health/live. A fixed "not
  # ready" label would mislabel a liveness failure — and the two have opposite
  # remedies, restart versus shed traffic.
  serve live 503 'application/problem+json' \
    '{"type":"urn:problem-type:ops:not-alive","title":"Service Not Alive","status":503,"detail":"the process is not alive and should be restarted"}'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" '/health/live: not alive — the process is not alive and should be restarted (503)'
  lacks "$output" '/health/live: not ready'
}

@test "tc-error-readiness-503-fails-conformance: a valid v2 problem 503 still FAILS, and names the dependency" {
  # #1343. A 503 stays a conformance failure — conformance asserts a SERVING
  # service and there is deliberately no flag to tolerate one. What v2 buys is
  # that the failure says WHICH dependency shed the pod.
  serve ready 503 'application/problem+json' \
    '{"type":"urn:problem-type:ops:not-ready","title":"Service Not Ready","status":503,"detail":"hard dependency '"'"'orders-db'"'"' is down","components":{"orders-db":{"status":"down","kind":"hard","breaker":"open"}}}'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" '/health/ready'
  contains "$output" "not ready — hard dependency 'orders-db' is down (503)"
  # …and it must NOT be misreported as a legacy body.
  lacks "$output" 'ops-api v1 envelope'
}

@test "corner: a v2 problem 503 on application/json is rejected for the MEDIA TYPE" {
  # Bare problem+json is part of the contract: a correctly shaped body on the wrong
  # media type is still an org-problem-json-errors failure, so the checker must not
  # accept it just because the members are right.
  serve ready 503 'application/json' \
    '{"type":"urn:problem-type:ops:not-ready","title":"Service Not Ready","status":503,"detail":"hard dependency '"'"'orders-db'"'"' is down"}'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" 'must be served as application/problem+json'
}

@test "error: a problem 503 missing a required member names the member" {
  serve ready 503 'application/problem+json' \
    '{"type":"urn:problem-type:ops:not-ready","title":"Service Not Ready","status":503}'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" 'missing required member(s): detail'
}

@test "error: an EMPTY 503 body is diagnosed as such, not as a status-type error" {
  # Round-1 review finding. Without a parse guard, jq's failure on an empty body
  # left `missing` empty, the branch concluded all four members were present, and
  # the run reported "status must be the integer 503" — about a body with no status
  # at all. Right exit code, lying diagnosis.
  serve ready 503 'application/problem+json' ''
  run_check
  [ "$status" -eq 1 ]
  contains "$output" 'not a JSON object'
  lacks "$output" 'must be the integer 503'
}

@test "error: a non-object 503 body (array, scalar) is diagnosed as such" {
  serve ready 503 'application/problem+json' '["not","a","problem"]'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" 'not a JSON object'
  # An array would otherwise make `keys` yield indices, so the subtraction leaves
  # all four names and the message claims four missing members of a non-document.
  lacks "$output" 'missing required member(s): type, title, status, detail'
}

@test "corner: an UPPERCASE problem+json media type is accepted (RFC 9110 case-insensitivity)" {
  # Media types are case-insensitive, and the script's own /metrics check already
  # lowercases. A conformant server using Application/Problem+JSON must still get
  # the dependency detail, not a wrong-media-type complaint.
  serve ready 503 'Application/Problem+JSON; charset=utf-8' \
    '{"type":"urn:problem-type:ops:not-ready","title":"Service Not Ready","status":503,"detail":"hard dependency '"'"'orders-db'"'"' is down"}'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" "not ready — hard dependency 'orders-db' is down (503)"
  lacks "$output" 'must be served as application/problem+json'
}

@test "error: a NULL detail is diagnosed, not read out as \"not ready — null\"" {
  serve ready 503 'application/problem+json' \
    '{"type":"urn:problem-type:ops:not-ready","title":"Service Not Ready","status":503,"detail":null}'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" '"detail" must be a string'
  lacks "$output" 'not ready — null'
}

@test "error: a problem 503 whose status is the health STRING is rejected" {
  # The collision between RFC 9457's integer `status` and the health envelope's
  # "ok"/"down" string is the whole reason ops-api v2 exists, so a string here is
  # exactly the mistake worth catching.
  serve ready 503 'application/problem+json' \
    '{"type":"urn:problem-type:ops:not-ready","title":"Service Not Ready","status":"down","detail":"hard dependency '"'"'orders-db'"'"' is down"}'
  run_check
  [ "$status" -eq 1 ]
  contains "$output" 'must be the integer 503'
}

@test "corner: two majors, one deprecated with sunset -> exit 0" {
  serve info 200 'application/json' \
    '{"build":{"version":"3.0.0","git_sha":"abc1234"},"api":[{"major":1,"lifecycle":"deprecated","sunset":"2027-01-31"},{"major":2,"lifecycle":"active"}]}'
  run_check
  [ "$status" -eq 0 ]
}

@test "corner: /metrics as application/openmetrics-text -> exit 0" {
  serve metrics 200 'application/openmetrics-text; version=1.0.0' \
    '# EOF'
  run_check
  [ "$status" -eq 0 ]
}

@test "error: /metrics 404 -> non-zero, names /metrics" {
  serve metrics 404 'text/plain' 'not found'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '/metrics'
}

@test "error: /metrics 200 with wrong content-type -> non-zero, names content-type" {
  # guards the content-type contract itself: a 200 that isn't a Prometheus/
  # OpenMetrics exposition must fail (else the /metrics gate could silently
  # regress to a no-op — every other test would still pass green).
  serve metrics 200 'application/json' '{}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '/metrics'
  echo "$output" | grep -qi 'content-type'
}

@test "error: deprecated major with no sunset -> non-zero, cites the major" {
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0","git_sha":"deadbee"},"api":[{"major":1,"lifecycle":"deprecated"}]}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'major 1'
  echo "$output" | grep -qi 'sunset'
}

@test "error: /health status down -> exit 1, says the service is not serving" {
  # "down" is the one aggregate that is NOT serving. ("degraded" became a
  # conformant aggregate in ops-api v1.1 — see the components tests below.)
  # The needle is unique to THIS branch: '/health' alone would also match a
  # /health/live or /health/ready failure line.
  serve health 200 'application/json' '{"status":"down"}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'not serving'
}

@test "error: /health status not a contract value -> exit 1, names the enum" {
  serve health 200 'application/json' '{"status":"wobbly"}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'expected JSON status'
}

@test "error: /health status non-string -> exit 1 (type not erased)" {
  # jq -r would turn `true` into the string "true"; the checker's type guard
  # must reject it as it does for /info's major and sunset.
  serve health 200 'application/json' '{"status":true}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'expected JSON status'
}

@test "error: /health 503 -> exit 1, names the HTTP code (entry guard)" {
  serve health 503 'application/json' '{"status":"down"}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'expected HTTP 200'
}

@test "error: /health body not JSON -> exit 1 (entry guard)" {
  serve health 200 'application/json' '<html>gateway error</html>'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'not valid JSON'
}

@test "error: /health unreachable -> exit 1, names /health (entry guard)" {
  serve_rc health 7
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '/health: unreachable'
}

# ---- dependency components (ops-api v1.1, #965) ----------------------------

@test "components: degraded aggregate with a soft dep down -> exit 0 (still serving)" {
  serve health 200 'application/json' \
    '{"status":"degraded","components":{"orders-db":{"status":"up","kind":"hard"},"pricing-api":{"status":"down","kind":"soft","breaker":"open","since":"2026-07-23T09:12:04Z"}}}'
  run_check
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '/health +PASS'
}

@test "components: all up with an ok aggregate -> exit 0" {
  serve health 200 'application/json' \
    '{"status":"ok","components":{"orders-db":{"status":"up","kind":"hard","breaker":"closed"}}}'
  run_check
  [ "$status" -eq 0 ]
}

@test "components: absent entirely -> exit 0 (a service with no declared deps)" {
  serve health 200 'application/json' '{"status":"ok"}'
  run_check
  [ "$status" -eq 0 ]
}

@test "components: a bare degraded aggregate with NO components -> exit 0" {
  # The headline v1.1 behaviour change, on the components-free path: pre-v1.1
  # this exact body was rejected. Both other degraded-passes tests carry a
  # components map, so without this one a revert of the aggregate enum to
  # ok-only would go unnoticed here.
  serve health 200 'application/json' '{"status":"degraded"}'
  run_check
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '/health +PASS'
}

@test "components: hard dep down must make the aggregate down, not degraded" {
  serve health 200 'application/json' \
    '{"status":"degraded","components":{"orders-db":{"status":"down","kind":"hard","breaker":"open"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'orders-db'
  # 'hard dependency', not bare 'hard' — the latter also matches "(want hard|soft)"
  echo "$output" | grep -q 'hard dependency'
}

@test "components: soft dep down must make the aggregate at least degraded, not ok" {
  serve health 200 'application/json' \
    '{"status":"ok","components":{"pricing-api":{"status":"down","kind":"soft","breaker":"open"}}}'
  run_check
  [ "$status" -eq 1 ]
  # 'at least' is unique to the floor message; bare 'degraded' also appears in
  # the invalid-status enum text (want up|degraded|down).
  echo "$output" | grep -q 'at least'
}

@test "components: a hard dep down with a down aggregate still fails (not serving)" {
  # The derivation is satisfied, but the service is not serving — conformance
  # must not pass just because the aggregate is honest about being down.
  serve health 200 'application/json' \
    '{"status":"down","components":{"orders-db":{"status":"down","kind":"hard","breaker":"open"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'not serving'
  # ...and NOT because the floor rule tripped: the aggregate matches its floor.
  run ! grep -q 'want "down"' <<< "$output"
}

@test "components: a half-open (degraded) soft dep needs at least a degraded aggregate" {
  serve health 200 'application/json' \
    '{"status":"ok","components":{"pricing-api":{"status":"degraded","kind":"soft","breaker":"half_open"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'at least'
  echo "$output" | grep -q 'pricing-api\|dependency is down or degraded'
}

@test "components: a HARD dep that is only degraded floors at degraded, not down" {
  # The kind-agnostic middle branch: half-open is not down, so it must NOT
  # demand a "down" aggregate. If the elif were changed to force "down" for any
  # non-up hard dependency, this would fail.
  serve health 200 'application/json' \
    '{"status":"degraded","components":{"orders-db":{"status":"degraded","kind":"hard","breaker":"half_open"}}}'
  run_check
  [ "$status" -eq 0 ]
}

@test "components: a HARD dep that is only degraded still forbids an ok aggregate" {
  serve health 200 'application/json' \
    '{"status":"ok","components":{"orders-db":{"status":"degraded","kind":"hard","breaker":"half_open"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'at least'
}

@test "components: hard-down wins over a later soft-down (floor never downgrades)" {
  # Guards the `[[ "$floor" == "down" ]] || floor="degraded"` line: with a
  # hard-down dependency FOLLOWED by a soft-down one, dropping that guard would
  # downgrade the floor to degraded and let this under-reporting body pass.
  serve health 200 'application/json' \
    '{"status":"degraded","components":{"orders-db":{"status":"down","kind":"hard"},"pricing-api":{"status":"down","kind":"soft"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'hard dependency'
  echo "$output" | grep -q 'orders-db'
}

@test "components: soft-down FIRST then hard-down still demands a down aggregate" {
  # The mirror order — jq's to_entries preserves insertion order, so this is the
  # case where the floor is raised to degraded before the hard-down is seen.
  serve health 200 'application/json' \
    '{"status":"degraded","components":{"a-cache":{"status":"down","kind":"soft"},"orders-db":{"status":"down","kind":"hard"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'hard dependency'
  echo "$output" | grep -q 'orders-db'
}

@test "components: internal degradation with all deps up is allowed (floor, not equality)" {
  # A service may be degraded for a reason no dependency models; over-reporting
  # must never be a conformance failure.
  serve health 200 'application/json' \
    '{"status":"degraded","components":{"orders-db":{"status":"up","kind":"hard"}}}'
  run_check
  [ "$status" -eq 0 ]
}

@test "components: invalid kind -> exit 1, names the dependency and the kind rule" {
  serve health 200 'application/json' \
    '{"status":"ok","components":{"orders-db":{"status":"up","kind":"critical"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'orders-db'
  echo "$output" | grep -q 'invalid kind'
}

@test "components: missing kind -> exit 1 (readiness would be undefined)" {
  serve health 200 'application/json' \
    '{"status":"ok","components":{"orders-db":{"status":"up"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'orders-db'
  echo "$output" | grep -q 'invalid kind'
}

@test "components: invalid dependency status -> exit 1, names the status rule" {
  # "ok" is the AGGREGATE's healthy spelling, never a dependency's — a
  # dependency is up|degraded|down. This pins that asymmetry.
  serve health 200 'application/json' \
    '{"status":"ok","components":{"orders-db":{"status":"ok","kind":"hard"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'orders-db'
  echo "$output" | grep -q 'invalid status'
}

@test "components: invalid breaker state -> exit 1, names the breaker rule" {
  serve health 200 'application/json' \
    '{"status":"ok","components":{"orders-db":{"status":"up","kind":"hard","breaker":"tripped"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'orders-db'
  echo "$output" | grep -q 'invalid breaker'
}

@test "components: non-string breaker -> exit 1 (type not erased)" {
  # The dedicated present-but-not-a-string branch; the "tripped" test above
  # takes the invalid-enum branch instead, so without this one that elif is dead.
  serve health 200 'application/json' \
    '{"status":"ok","components":{"orders-db":{"status":"up","kind":"hard","breaker":123}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'non-string breaker'
}

@test "components: non-string since -> exit 1 (type not erased)" {
  serve health 200 'application/json' \
    '{"status":"ok","components":{"orders-db":{"status":"up","kind":"hard","since":true}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'non-string since'
}

@test "components: not an object -> exit 1, names the components rule" {
  serve health 200 'application/json' '{"status":"ok","components":[]}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'components must be an object'
}

@test "components: /health/live and /health/ready stay binary (no degraded)" {
  # The probes are deliberately NOT tri-state — the kubelet acts on one yes/no.
  # BOTH probes are overridden: asserting only /health/live would leave the
  # readiness half of the title unverified, and readiness is exactly what v1.1
  # re-specifies.
  serve live 200 'application/json' '{"status":"degraded"}'
  serve ready 200 'application/json' '{"status":"degraded"}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '/health/live: expected JSON status'
  echo "$output" | grep -q '/health/ready: expected JSON status'
}

@test "components: an invalid SECOND dependency is still caught" {
  # Guards against validation that stops after the first entry: the first
  # dependency here is well-formed, so only a loop that validates every entry
  # reports the second one.
  serve health 200 'application/json' \
    '{"status":"ok","components":{"a-ok":{"status":"up","kind":"hard"},"z-bad":{"status":"up","kind":"critical"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'z-bad'
  echo "$output" | grep -q 'invalid kind'
}

@test "components: TWO invalid dependencies are both reported" {
  # The third truncation direction: the previous test proves entry 2 is reached
  # when entry 1 is CLEAN, but not that validation continues past a dependency
  # that has already failed. A break/return after the first failing entry would
  # survive both of the others; the exact problem count is what pins it.
  serve health 200 'application/json' \
    '{"status":"ok","components":{"a-bad":{"status":"up","kind":"critical"},"z-bad":{"status":"ok","kind":"hard"}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'a-bad'
  echo "$output" | grep -q 'z-bad'
  echo "$output" | grep -q 'invalid kind'
  echo "$output" | grep -q 'invalid status'
  echo "$output" | grep -q 'FAILED: 2 problem(s)'
}

@test "components: every bad field of one dependency is reported independently" {
  # Guards against a `continue` after the first failure inside the loop body:
  # all four field checks must fire for the same dependency, and the failure
  # count pins the accumulator itself.
  serve health 200 'application/json' \
    '{"status":"ok","components":{"orders-db":{"status":"bogus","kind":"critical","breaker":"tripped","since":true}}}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'invalid status'
  echo "$output" | grep -q 'invalid kind'
  echo "$output" | grep -q 'invalid breaker'
  echo "$output" | grep -q 'non-string since'
  # Anchored: a bare '4 problem(s)' would also match '14 problem(s)'.
  echo "$output" | grep -q 'FAILED: 4 problem(s)'
}

@test "error: /info missing build.git_sha -> non-zero, names /info" {
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0"},"api":[{"major":1,"lifecycle":"active"}]}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '/info'
}

@test "error: /info major as a JSON string -> non-zero (type not erased)" {
  # a string-typed major "1" satisfies a naive regex but violates the fragment's
  # `type: integer` — the jq type check must reject it.
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0","git_sha":"cafe123"},"api":[{"major":"1","lifecycle":"active"}]}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '/info'
}

@test "error: /info major 0 -> non-zero (minimum 1)" {
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0","git_sha":"cafe123"},"api":[{"major":0,"lifecycle":"active"}]}'
  run_check
  [ "$status" -eq 1 ]
}

@test "error: deprecated major with non-string sunset -> non-zero" {
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0","git_sha":"cafe123"},"api":[{"major":1,"lifecycle":"deprecated","sunset":true}]}'
  run_check
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi 'sunset'
}

@test "usage: no base url -> exit 2" {
  run zsh "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "usage: non-numeric --timeout -> exit 2 (caller error, not unreachable)" {
  run zsh "$SCRIPT" "http://svc:8080" --timeout tenseconds
  [ "$status" -eq 2 ]
}
