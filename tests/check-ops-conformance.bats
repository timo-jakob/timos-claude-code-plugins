#!/usr/bin/env bats
#
# Behavioural tests for the ops-conformance checker (#688) —
# templates/common/scripts/check-ops-conformance.zsh. The checker curls a live
# service's /info, /health, /metrics and validates them against the ops-api/v1
# fragment's shapes. curl is not in the test toolchain (and no server runs), so a
# STUB curl (via $OPS_CURL) serves canned per-endpoint responses from a fixture
# dir — this exercises the checker's DECISION logic (status codes, /info schema
# incl. the deprecated-needs-sunset rule, /metrics content type). The real curl +
# a real service are exercised by the Python canonical impl's acceptance run.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/check-ops-conformance.zsh"

  STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  export OPS_STUB_DIR="$STUB_DIR"

  # Stub curl: honours the checker's `-o <file>` and `-w '%{http_code}\t%{content_type}'`,
  # keying the response off the URL's final path segment (info|health|metrics)
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
  serve metrics 200 'text/plain; version=0.0.4' \
    'http_server_request_duration_seconds_bucket{le="0.1"} 1'
}

# serve <endpoint> <http-code> <content-type> <body>
serve() {
  printf '%s' "$2" > "$STUB_DIR/$1.code"
  printf '%s' "$3" > "$STUB_DIR/$1.ct"
  printf '%s' "$4" > "$STUB_DIR/$1.body"
}

run_check() { run zsh "$SCRIPT" "http://svc:8080"; }

@test "happy: fully conformant service -> exit 0, all three PASS" {
  run_check
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '/info    PASS'
  echo "$output" | grep -q '/health  PASS'
  echo "$output" | grep -q '/metrics PASS'
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
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '/metrics'
}

@test "error: /metrics 200 with wrong content-type -> non-zero, names content-type" {
  # guards the content-type contract itself: a 200 that isn't a Prometheus/
  # OpenMetrics exposition must fail (else the /metrics gate could silently
  # regress to a no-op — every other test would still pass green).
  serve metrics 200 'application/json' '{}'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '/metrics'
  echo "$output" | grep -qi 'content-type'
}

@test "error: deprecated major with no sunset -> non-zero, cites the major" {
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0","git_sha":"deadbee"},"api":[{"major":1,"lifecycle":"deprecated"}]}'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'major 1'
  echo "$output" | grep -qi 'sunset'
}

@test "error: /health not ok -> non-zero, names /health" {
  serve health 200 'application/json' '{"status":"degraded"}'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '/health'
}

@test "error: /info missing build.git_sha -> non-zero, names /info" {
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0"},"api":[{"major":1,"lifecycle":"active"}]}'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '/info'
}

@test "error: /info major as a JSON string -> non-zero (type not erased)" {
  # a string-typed major "1" satisfies a naive regex but violates the fragment's
  # `type: integer` — the jq type check must reject it.
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0","git_sha":"cafe123"},"api":[{"major":"1","lifecycle":"active"}]}'
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '/info'
}

@test "error: /info major 0 -> non-zero (minimum 1)" {
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0","git_sha":"cafe123"},"api":[{"major":0,"lifecycle":"active"}]}'
  run_check
  [ "$status" -ne 0 ]
}

@test "error: deprecated major with non-string sunset -> non-zero" {
  serve info 200 'application/json' \
    '{"build":{"version":"1.0.0","git_sha":"cafe123"},"api":[{"major":1,"lifecycle":"deprecated","sunset":true}]}'
  run_check
  [ "$status" -ne 0 ]
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
