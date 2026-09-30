#!/usr/bin/env bats
#
# Acceptance cases for the Node resilience payload (#1145) — the `curl`-tooled
# half of its story-spec `test_cases[]`, one test per `tc-*` id:
#
#   tc-happy-health-all-dependencies-up               #1200
#   tc-corner-seam-unset-is-conforming-v1-0           #1202
#   tc-corner-soft-dependency-open-stays-ready        #1203
#   tc-corner-hard-dependency-open-fails-readiness    #1204
#   tc-corner-half-open-visible-with-zero-traffic     #1205
#   tc-error-caller-4xx-does-not-open-the-breaker     #1207
#   tc-error-open-breaker-fast-fails-without-crashing #1209
#
# These run against a REAL service built from BOTH shipped templates — the
# ops-api payload and the resilience payload beside it — with real upstream
# processes the cases kill to take a dependency down (see
# ../lib/node-ops-sandbox.zsh --with-resilience and
# ../lib/resilience-fixture-service.ts). They are NOT part of the default gate —
# `bats tests` does not recurse — see ../README.md.

bats_require_minimum_version 1.5.0
load ../lib/ops-acceptance

setup_file() {
  load ../lib/ops-acceptance
  ops_provision --with-resilience
}

setup() {
  ops_sandbox
  # Three more ports per test, offset from the per-test ops port so they inherit
  # its per-file band and can never collide with a sibling test's.
  APP_PORT=$(( PORT + 1000 ))
  PRICING_PORT=$(( PORT + 2000 ))
  ORDERS_PORT=$(( PORT + 3000 ))
  APP="http://127.0.0.1:$APP_PORT"
  PRICING_PID=""
  ORDERS_PID=""
}

teardown() {
  ops_stop
  upstream_kill PRICING_PID
  upstream_kill ORDERS_PID
}

# upstream_start <pid-var> <port> — start a stand-in dependency and block until it
# answers. Called directly, never through `$(…)`, so the pid lands in THIS shell.
upstream_start() {
  local var="$1" port="$2" log="$BATS_TEST_TMPDIR/upstream-$2.log" pid
  require_port_free "$port" "a stand-in upstream" || return 1
  ( cd "$SANDBOX" && exec env ROLE=upstream UPSTREAM_PORT="$port" \
      node "$SANDBOX/dist/main.js" > "$log" 2>&1 3>&- ) &
  pid=$!
  printf -v "$var" '%s' "$pid"
  for _ in $(seq 1 80); do
    curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$port/healthz" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  echo "upstream on $port did not come up:" >&2
  cat "$log" >&2
  return 1
}

# upstream_kill <pid-var> — take a dependency DOWN: the real outage shape,
# connection refused, not a scripted error status.
upstream_kill() {
  local pid="${!1:-}"
  [ -n "$pid" ] || return 0
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  printf -v "$1" '%s' ""
}

# start_service [scenario] — both upstreams, then the service wired to them.
start_service() {
  upstream_start PRICING_PID "$PRICING_PORT"
  upstream_start ORDERS_PID "$ORDERS_PORT"
  ops_start "${1:-wired}" APP_PORT="$APP_PORT" \
    PRICING_API_BASE_URL="http://127.0.0.1:$PRICING_PORT" ORDERS_DB_URL="http://127.0.0.1:$ORDERS_PORT"
}

# component <name> <field> — one field of one /health components entry.
component() { jq -r --arg n "$1" --arg f "$2" '.components[$n][$f] // "absent"' <<< "$(http_body "$BASE/health")"; }

# trip <route> <dependency> — drive traffic until that dependency's breaker opens,
# BOUNDED: every call is up to three counted attempts, so ten calls is far past
# the ten counted failures the trip rule needs. Never loops forever on a breaker
# that will not trip.
trip() {
  for _ in $(seq 1 10); do
    curl -s -o /dev/null --max-time 15 "$APP/$1" || true
    [ "$(component "$2" breaker)" = "open" ] && return 0
  done
  echo "the $2 breaker did not open after 10 calls to /$1:" >&2
  http_body "$BASE/health" >&2
  return 1
}

@test "tc-happy-health-all-dependencies-up: both breakers closed report up, with their kinds" {
  start_service
  # Real traffic first, so the closed state is one the breakers have SEEN calls in.
  [ "$(jq -r .available <<< "$(http_body "$APP/price/sku-4711")")" = "true" ]
  [ "$(jq -r .available <<< "$(http_body "$APP/order/ord-20260930")")" = "true" ]
  [ "$(http_code "$BASE/health")" = "200" ]
  local body; body="$(http_body "$BASE/health")"
  [ "$(jq -r .status <<< "$body")" = "ok" ]
  [ "$(jq -c '.components["orders-db"] | {status, kind, breaker}' <<< "$body")" = '{"status":"up","kind":"hard","breaker":"closed"}' ]
  [ "$(jq -c '.components["pricing-api"] | {status, kind, breaker}' <<< "$body")" = '{"status":"up","kind":"soft","breaker":"closed"}' ]
  # since is RFC 3339, second precision.
  jq -e '.components["orders-db"].since | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' <<< "$body"
  # DIRECT dependencies only: exactly the two declared, nothing transitive.
  [ "$(jq -r '.components | keys | join(",")' <<< "$body")" = "orders-db,pricing-api" ]
  [ "$(http_code "$BASE/health/ready")" = "200" ]
}

@test "tc-corner-seam-unset-is-conforming-v1-0: the dependencies slot unset serves no components key" {
  start_service unwired
  local body; body="$(http_body "$BASE/health")"
  [ "$(jq -r .status <<< "$body")" = "ok" ]
  [ "$(jq -r 'has("components")' <<< "$body")" = "false" ]
  run zsh "$CHECKER" "$BASE"
  [ "$status" -eq 0 ]
}

@test "tc-corner-soft-dependency-open-stays-ready: a soft breaker open degrades, never sheds traffic" {
  start_service
  upstream_kill PRICING_PID
  trip price/sku-4711 pricing-api
  local body; body="$(http_body "$BASE/health")"
  [ "$(http_code "$BASE/health")" = "200" ]
  [ "$(jq -r .status <<< "$body")" = "degraded" ]
  [ "$(jq -c '.components["pricing-api"] | {status, kind, breaker}' <<< "$body")" = '{"status":"down","kind":"soft","breaker":"open"}' ]
  # The hard dependency is untouched, and readiness holds.
  [ "$(jq -r '.components["orders-db"].status' <<< "$body")" = "up" ]
  [ "$(http_code "$BASE/health/ready")" = "200" ]
  [ "$(jq -r .status <<< "$(http_body "$BASE/health/ready")")" = "ok" ]
}

@test "tc-corner-hard-dependency-open-fails-readiness: a hard breaker open is down and sheds traffic" {
  start_service
  upstream_kill ORDERS_PID
  trip order/ord-20260930 orders-db
  local body; body="$(http_body "$BASE/health")"
  # /health still answers 200 — the verdict is in the body.
  [ "$(http_code "$BASE/health")" = "200" ]
  [ "$(jq -r .status <<< "$body")" = "down" ]
  [ "$(jq -c '.components["orders-db"] | {status, kind}' <<< "$body")" = '{"status":"down","kind":"hard"}' ]
  # The readiness probe sheds traffic: 503, an RFC 9457 problem naming orders-db.
  [ "$(http_code "$BASE/health/ready")" = "503" ]
  local ready; ready="$(http_body "$BASE/health/ready")"
  [ "$(jq -r .status <<< "$ready")" = "503" ]
  [ "$(jq -r .detail <<< "$ready")" = "hard dependency 'orders-db' is down" ]
  # …and liveness never follows a dependency.
  [ "$(http_code "$BASE/health/live")" = "200" ]
}

@test "tc-corner-half-open-visible-with-zero-traffic: recovery shows on /health with no calls at all" {
  start_service
  upstream_kill ORDERS_PID
  trip order/ord-20260930 orders-db
  local opened_since; opened_since="$(component orders-db since)"
  # ZERO traffic from here: no app call of any kind, only /health reads — which
  # are passive and never call a dependency. The reset timeout is 10s.
  sleep 11
  local body; body="$(http_body "$BASE/health")"
  [ "$(jq -r '.components["orders-db"].breaker' <<< "$body")" = "half_open" ]
  [ "$(jq -r '.components["orders-db"].status' <<< "$body")" = "degraded" ]
  # A hard dependency merely half-open floors the aggregate at degraded, not down,
  # so readiness holds.
  [ "$(jq -r .status <<< "$body")" = "degraded" ]
  [ "$(http_code "$BASE/health/ready")" = "200" ]
  # since moved with the transition.
  [ "$(jq -r '.components["orders-db"].since' <<< "$body")" != "$opened_since" ]
}

@test "tc-error-caller-4xx-does-not-open-the-breaker: 30 caller 404s leave the dependency up" {
  start_service
  local i
  for i in $(seq 1 30); do
    [ "$(jq -r .available <<< "$(http_body "$APP/price/missing-sku-$i")")" = "false" ]
  done
  [ "$(component pricing-api breaker)" = "closed" ]
  [ "$(component pricing-api status)" = "up" ]
  [ "$(jq -r .status <<< "$(http_body "$BASE/health")")" = "ok" ]
  # Un-retried, too: a caller error reproduces exactly on retry, so thirty calls
  # are thirty upstream requests, not ninety.
  [ "$(jq -r .served <<< "$(http_body "http://127.0.0.1:$PRICING_PORT/stats")")" = "30" ]
}

@test "tc-error-open-breaker-fast-fails-without-crashing: an open breaker fast-fails through the fallback" {
  start_service
  upstream_kill PRICING_PID
  trip price/sku-4711 pricing-api
  # Twenty concurrent calls against the open breaker. Each must come back quickly,
  # un-retried, through the fallback — never parked on a dead dependency.
  local out="$BATS_TEST_TMPDIR/concurrent" i pids=()
  for i in $(seq 1 20); do
    curl -s --max-time 5 -o "$out.$i.body" -w '%{http_code} %{time_total}\n' "$APP/price/sku-$i" > "$out.$i.meta" &
    pids+=("$!")
  done
  # Wait on the CURLS only. A bare `wait` also waits on the fixture and the
  # upstream this test started, which never exit, and hangs the suite.
  wait "${pids[@]}"
  for i in $(seq 1 20); do
    [ "$(cut -d' ' -f1 < "$out.$i.meta")" = "200" ]
    [ "$(jq -r .available < "$out.$i.body")" = "false" ]
    # Well under one backoff step plus a connect: nothing was retried.
    awk '{ exit !($2 < 0.5) }' < "$out.$i.meta"
  done
  # The process kept serving: liveness answers, the fixture is alive, and no
  # unhandled rejection was ever logged (Node would have exited on one).
  [ "$(http_code "$BASE/health/live")" = "200" ]
  kill -0 "$OPS_PID"
  run ! grep -qi 'unhandled' "$OPS_LOG"
}
