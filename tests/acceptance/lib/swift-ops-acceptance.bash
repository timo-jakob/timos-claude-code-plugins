# shellcheck shell=bash
# Shared helpers for the Swift resilience acceptance cases (#1146).
#
# Sourced by tests/acceptance/rest/swift-resilience.bats and
# tests/acceptance/cli/swift-resilience.bats. The directive above is mandatory: this
# is a shebang-less library bats `load`s (ARCHITECTURE.md, "Exception — the bats
# suite").
#
# The protocol-level readers — http_code, http_body, http_ctype, port_is_closed,
# checker_passed, checker_failed, require_port_free, ops_dump_log — are the Node
# harness's, reused rather than copied: they are about HTTP and the checker, not
# about Node, and two copies would be two things to keep honest. Everything that
# starts, stops or provisions a fixture is Swift-specific and lives here.

# shellcheck source=tests/acceptance/lib/ops-acceptance.bash
source "${BASH_SOURCE[0]%/*}/ops-acceptance.bash"

# The variables the fixture READS, cleared so a developer or CI shell cannot
# silently change a case's verdict — an inherited $OPS_DEPENDENCIES_FILE would swap
# the declaration under every case, and an inherited OTLP endpoint makes the ops
# surface dial out every export interval.
SWIFT_SCRUB=(
  -u GIT_SHA -u BUILD_VERSION -u OPS_PORT -u OPS_DEPENDENCIES_FILE
  -u OTEL_EXPORTER_OTLP_ENDPOINT -u OTEL_EXPORTER_OTLP_METRICS_ENDPOINT
  -u APP_PORT -u PRICING_PORT -u BREAKER_OPEN_MS -u SCENARIO
)

# swift_provision — build the sandbox ONCE per file, from setup_file. Allowed to fail
# the whole file: a missing toolchain must be loud, never skipped.
swift_provision() {
  local root
  root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)" || return 1
  # The provisioner's typed exit (1 our side, 2 bad inputs, 3 in use) is passed on,
  # not folded into 1 — it is what tells a toolchain gap from a busy sandbox.
  local rc=0
  SWIFT_SANDBOX_DIR="$(zsh "$root/tests/acceptance/lib/swift-ops-sandbox.zsh" \
    --suite "$BATS_TEST_FILENAME")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$SWIFT_SANDBOX_DIR" ] || {
    echo "swift-ops-sandbox.zsh printed no sandbox path" >&2
    return 1
  }
  export SWIFT_SANDBOX_DIR
}

# swift_port_band — a REGISTERED per-file band, never a hash of the path (see
# ops_port in ops-acceptance.bash for why a hash reintroduces the clash it exists
# to prevent). Bands 0-3 belong to ops_port (the Node suites); the Swift ones sit
# above them, and ops_port says so.
swift_port_band() {
  local key
  key="$(basename "$(dirname "$BATS_TEST_FILENAME")")/$(basename "$BATS_TEST_FILENAME")"
  case "$key" in
    rest/swift-resilience.bats) echo 4 ;;
    cli/swift-resilience.bats) echo 5 ;;
    *)
      echo "swift_port_band: no port band registered for '$key'" >&2
      return 1
      ;;
  esac
}

# swift_sandbox — per-test paths and ports, in the TEST's shell (never a subshell's).
swift_sandbox() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck disable=SC2034  # read by the .bats files that `load` this library
  CHECKER="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/check-ops-conformance.zsh"
  [ -f "$CHECKER" ] || { echo "checker not found: $CHECKER" >&2; return 1; }
  SANDBOX="${SWIFT_SANDBOX_DIR:-}"
  [ -n "$SANDBOX" ] || { echo "SWIFT_SANDBOX_DIR is unset — setup_file's swift_provision did not run" >&2; return 1; }
  FIXTURE="$SANDBOX/.build/debug/OpsFixture"
  [ -x "$FIXTURE" ] || { echo "fixture binary missing: $FIXTURE — provisioning failed" >&2; return 1; }
  [ "$BATS_TEST_NUMBER" -le 49 ] || { echo "more than 49 tests in this file — widen the stride" >&2; return 1; }
  local band; band="$(swift_port_band)" || return 1
  OPS_LOG="$BATS_TEST_TMPDIR/fixture.log"
  PORT=$(( 9500 + band * 100 + BATS_TEST_NUMBER ))
  APP_PORT=$(( PORT + 50 ))
  PRICING_PORT=$(( 20000 + band * 100 + BATS_TEST_NUMBER ))
  # shellcheck disable=SC2034  # read by the .bats files that `load` this library
  BASE="http://127.0.0.1:$PORT"
  # shellcheck disable=SC2034
  APP="http://127.0.0.1:$APP_PORT"
}

# swift_start <scenario> [VAR=value ...] — start the fixture and block until the
# management port answers, setting OPS_PID. `exec` so $! is the fixture itself, and
# `3>&-` so it does not hold bats' status pipe open.
swift_start() {
  local scenario="$1"; shift
  require_port_free "$PORT" "the fixture's management port" || return 1
  require_port_free "$APP_PORT" "the fixture's app port" || return 1
  require_port_free "$PRICING_PORT" "the fake pricing-api upstream's port" || return 1
  ( exec env "${SWIFT_SCRUB[@]}" GIT_SHA=9e11997 BUILD_VERSION=1.4.2 \
      SCENARIO="$scenario" OPS_PORT="$PORT" APP_PORT="$APP_PORT" PRICING_PORT="$PRICING_PORT" "$@" \
      "$FIXTURE" > "$OPS_LOG" 2>&1 3>&- ) &
  OPS_PID=$!
  local _
  for _ in $(seq 1 120); do
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/health/live" 2>/dev/null \
       && curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$APP_PORT/upstream-hits" 2>/dev/null; then
      kill -0 "$OPS_PID" 2>/dev/null && return 0
      echo "something else is serving port $PORT — our fixture is already gone" >&2
      ops_dump_log
      return 1
    fi
    kill -0 "$OPS_PID" 2>/dev/null || break
    sleep 0.25
  done
  echo "fixture did not come up (scenario=$scenario, port=$PORT):" >&2
  ops_dump_log
  return 1
}

# swift_stop — cleanup, not an assertion. Safe to call when nothing ran.
swift_stop() {
  [ -n "${OPS_PID:-}" ] || return 0
  kill "$OPS_PID" 2>/dev/null || true
  local _
  for _ in $(seq 1 20); do
    kill -0 "$OPS_PID" 2>/dev/null || break
    sleep 0.05
  done
  # Only while it is still ours: once reaped, the PID may belong to anything.
  if kill -0 "$OPS_PID" 2>/dev/null; then kill -9 "$OPS_PID" 2>/dev/null || true; fi
  wait "$OPS_PID" 2>/dev/null || true
  OPS_PID=""
}

# swift_run_expect_exit [VAR=value ...] — run the fixture to COMPLETION for the
# startup-failure cases, setting OPS_STATUS. BOUNDED: if the payload regresses in the
# direction under test it binds and serves forever, and an unbounded wait would hang
# the suite instead of going red. Call it DIRECTLY, never through `run` or `$(…)`.
swift_run_expect_exit() {
  require_port_free "$PORT" "the port the fixture must refuse to bind" || return 1
  require_port_free "$PRICING_PORT" "the fake pricing-api upstream's port" || return 1
  OPS_STATUS=0
  ( exec env "${SWIFT_SCRUB[@]}" GIT_SHA=9e11997 BUILD_VERSION=1.4.2 \
      SCENARIO=all-up OPS_PORT="$PORT" APP_PORT="$APP_PORT" PRICING_PORT="$PRICING_PORT" "$@" \
      "$FIXTURE" > "$OPS_LOG" 2>&1 3>&- ) &
  local pid=$! _
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "fixture did NOT exit — it was supposed to refuse to start:" >&2
    ops_dump_log
    return 1
  fi
  # shellcheck disable=SC2034  # asserted by the .bats files that `load` this library
  wait "$pid" 2>/dev/null || OPS_STATUS=$?
}

# declaration_file <name> <content> — write a declaration for $OPS_DEPENDENCIES_FILE
# into the test's own tmpdir and print its path.
declaration_file() {
  local path="$BATS_TEST_TMPDIR/$1"
  printf '%s' "$2" > "$path"
  printf '%s' "$path"
}

# health_when <jq-predicate> <seconds> — poll /health until the predicate holds.
# For the half-open cases, which wait on the breaker's own clock. Returns 1 with the
# last body on a timeout, so a breaker that never recovers is a red test, not a hang.
health_when() {
  local predicate="$1" budget="$2" body="" waited=0
  while [ "$waited" -lt $(( budget * 4 )) ]; do
    body="$(http_body "$BASE/health")"
    jq -e "$predicate" <<< "$body" >/dev/null 2>&1 && return 0
    sleep 0.25
    waited=$(( waited + 1 ))
  done
  echo "health never satisfied '$predicate' within ${budget}s; last body: $body" >&2
  return 1
}
