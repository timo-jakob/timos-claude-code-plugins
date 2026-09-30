#!/usr/bin/env bats
#
# Acceptance cases for the Node resilience payload (#1145) — the `cli`-tooled half
# of its story-spec `test_cases[]`, one test per `tc-*` id:
#
#   tc-happy-conformance-passes                  #1201
#   tc-error-declaration-mismatch-fails-startup  #1210
#
# Same sandbox shape as ../rest/javascript-resilience.bats (both shipped payloads,
# real upstream processes), provisioned separately — see ../README.md for why each
# suite owns its sandbox. NOT part of the default gate.

bats_require_minimum_version 1.5.0
load ../lib/ops-acceptance

setup_file() {
  load ../lib/ops-acceptance
  ops_provision --with-resilience
}

setup() {
  ops_sandbox
  APP_PORT=$(( PORT + 1000 ))
  UPSTREAM_PORT=$(( PORT + 2000 ))
  UPSTREAM_PID=""
}

teardown() {
  ops_stop
  if [ -n "$UPSTREAM_PID" ]; then
    kill -9 "$UPSTREAM_PID" 2>/dev/null || true
    wait "$UPSTREAM_PID" 2>/dev/null || true
  fi
}

# One stand-in serves both dependencies here: these cases are about startup and
# conformance, never about taking one dependency down on its own.
upstream_start() {
  local log="$BATS_TEST_TMPDIR/upstream.log"
  require_port_free "$UPSTREAM_PORT" "the stand-in upstream" || return 1
  ( cd "$SANDBOX" && exec env ROLE=upstream UPSTREAM_PORT="$UPSTREAM_PORT" \
      node "$SANDBOX/dist/main.js" > "$log" 2>&1 3>&- ) &
  UPSTREAM_PID=$!
  for _ in $(seq 1 80); do
    curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$UPSTREAM_PORT/healthz" 2>/dev/null && return 0
    kill -0 "$UPSTREAM_PID" 2>/dev/null || break
    sleep 0.25
  done
  cat "$log" >&2
  return 1
}

# The service's env, minus the declaration: each case chooses its own.
service_env() {
  SERVICE_ENV=(APP_PORT="$APP_PORT"
    PRICING_API_BASE_URL="http://127.0.0.1:$UPSTREAM_PORT" ORDERS_DB_URL="http://127.0.0.1:$UPSTREAM_PORT")
}

@test "tc-happy-conformance-passes: the checker passes the wired service, components included" {
  upstream_start
  service_env
  ops_start wired "${SERVICE_ENV[@]}"
  # Positive control: the surface under test really carries the v1.1 components
  # map, so the PASS below is about a v1.1 body, not a v1.0 one.
  [ "$(jq -r '.components | keys | join(",")' <<< "$(http_body "$BASE/health")")" = "orders-db,pricing-api" ]
  run zsh "$CHECKER" "$BASE"
  [ "$status" -eq 0 ]
  checker_passed "$output" /info
  checker_passed "$output" /health
  checker_passed "$output" /health/live
  checker_passed "$output" /health/ready
  checker_passed "$output" /metrics
}

@test "tc-error-declaration-mismatch-fails-startup: under-reporting is refused from BOTH sides at startup" {
  upstream_start
  service_env

  # (a) GUARDED BUT UNDECLARED: the pricing client claims pricing-api, which this
  # declaration never names. Startup must refuse, naming it.
  local undeclared="$BATS_TEST_TMPDIR/undeclared.properties"
  printf '%s\n' '# orders-db only — pricing-api is missing' 'orders-db=hard' > "$undeclared"
  ops_run_expect_exit wired "${SERVICE_ENV[@]}" OPS_DEPENDENCIES_FILE="$undeclared"
  [ "$OPS_STATUS" -ne 0 ]
  grep -qF 'dependency "pricing-api" is guarded in code but not declared in' "$OPS_LOG"
  # It refused BEFORE binding anything: no /health ever reported the dependency.
  port_is_closed "$PORT"

  # (b) DECLARED BUT UNGUARDED: inventory-cache is declared, and no client claims
  # it — its breaker could never leave closed, so /health would swear it was up
  # through an outage. Startup must refuse, naming it.
  local unguarded="$BATS_TEST_TMPDIR/unguarded.properties"
  printf '%s\n' 'orders-db=hard' 'pricing-api=soft' 'inventory-cache=soft' > "$unguarded"
  ops_run_expect_exit wired "${SERVICE_ENV[@]}" OPS_DEPENDENCIES_FILE="$unguarded"
  [ "$OPS_STATUS" -ne 0 ]
  grep -qF 'declares inventory-cache, but no client claimed them' "$OPS_LOG"
  port_is_closed "$PORT"

  # Control: the SHIPPED declaration, which both clients claim, boots — so the two
  # refusals above are about the mismatches, not a service that never starts.
  ops_start wired "${SERVICE_ENV[@]}"
  [ "$(http_code "$BASE/health")" = "200" ]
}
