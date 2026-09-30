#!/usr/bin/env bats
#
# Acceptance cases for the Swift resilience payload (#1146) — the `curl`-tooled half
# of its story-spec `test_cases[]`, one test per `tc-*` id:
#
#   tc-happy-health-all-up                        #1211
#   tc-corner-soft-down-stays-ready               #1213
#   tc-corner-hard-half-open-floors-at-degraded   #1214
#   tc-corner-no-dependencies-is-v1-0             #1215
#   tc-corner-breaker-recovers-without-traffic    #1216
#   tc-error-hard-down-fails-readiness            #1217
#   tc-error-open-breaker-fast-fails              #1218
#
# These run against a REAL Swift service compiled from the shipped ops-api and
# resilience templates in the bootstrapped one-target layout (see
# ../lib/swift-ops-sandbox.zsh). Every breaker state here is reached by REAL failing
# calls through the payload's catalog — nothing forces a state. They are NOT part of
# the default gate — `bats tests` does not recurse — see ../README.md.

bats_require_minimum_version 1.5.0
load ../lib/swift-ops-acceptance
load ../../assertions

setup_file() {
  load ../lib/swift-ops-acceptance
  swift_provision
}

setup() { swift_sandbox; }
teardown() { swift_stop; }

# The RFC 3339 shape every sibling payload serves for `since`.
RFC3339='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

@test "tc-happy-health-all-up: both breakers closed report up, with kind, breaker and since" {
  swift_start all-up
  [ "$(http_code "$BASE/health")" = "200" ]
  local body; body="$(http_body "$BASE/health")"
  [ "$(jq -r .status <<< "$body")" = "ok" ]
  [ "$(jq -r '.components["orders-db"].status' <<< "$body")" = "up" ]
  [ "$(jq -r '.components["orders-db"].kind' <<< "$body")" = "hard" ]
  [ "$(jq -r '.components["orders-db"].breaker' <<< "$body")" = "closed" ]
  matches "$(jq -r '.components["orders-db"].since' <<< "$body")" "$RFC3339"
  matches "$(jq -r '.components["pricing-api"].since' <<< "$body")" "$RFC3339"
  [ "$(jq -r '.components["pricing-api"].status' <<< "$body")" = "up" ]
  [ "$(jq -r '.components["pricing-api"].kind' <<< "$body")" = "soft" ]
  [ "$(jq -r '.components["pricing-api"].breaker' <<< "$body")" = "closed" ]
  # Exactly the two declared DIRECT dependencies — nothing transitive, nothing extra.
  [ "$(jq -r '.components | keys | join(",")' <<< "$body")" = "orders-db,pricing-api" ]
  # And the upstream really serves: a price comes back through the worked client.
  [ "$(http_code "$APP/prices/sku-1234")" = "200" ]
}

@test "tc-corner-soft-down-stays-ready: a soft dependency down degrades but never sheds traffic" {
  swift_start soft-down BREAKER_OPEN_MS=600000
  local body; body="$(http_body "$BASE/health")"
  [ "$(http_code "$BASE/health")" = "200" ]
  [ "$(jq -r .status <<< "$body")" = "degraded" ]
  [ "$(jq -r '.components["pricing-api"].status' <<< "$body")" = "down" ]
  [ "$(jq -r '.components["pricing-api"].breaker' <<< "$body")" = "open" ]
  [ "$(jq -r '.components["pricing-api"].kind' <<< "$body")" = "soft" ]
  [ "$(jq -r '.components["orders-db"].status' <<< "$body")" = "up" ]
  # The readiness hinge: a SOFT dependency never sheds traffic.
  [ "$(http_code "$BASE/health/ready")" = "200" ]
  [ "$(jq -r .status <<< "$(http_body "$BASE/health/ready")")" = "ok" ]
  # …and a degraded service is still a CONFORMING one.
  run zsh "$CHECKER" "$BASE"
  [ "$status" -eq 0 ]
}

@test "tc-corner-hard-half-open-floors-at-degraded: a hard dependency half-open is degraded, not down" {
  # A short open duration, so the half-open probe window arrives inside the test.
  swift_start hard-down BREAKER_OPEN_MS=5000
  [ "$(jq -r '.components["orders-db"].breaker' <<< "$(http_body "$BASE/health")")" = "open" ]
  health_when '.components["orders-db"].breaker == "half_open"' 12
  local body; body="$(http_body "$BASE/health")"
  [ "$(jq -r .status <<< "$body")" = "degraded" ]
  [ "$(jq -r '.components["orders-db"].status' <<< "$body")" = "degraded" ]
  # The wire spelling is half_open, never halfOpen.
  [ "$(jq -r '.components["orders-db"].breaker' <<< "$body")" = "half_open" ]
  [ "$(http_code "$BASE/health/ready")" = "200" ]
}

@test "tc-corner-no-dependencies-is-v1-0: an empty declaration serves a body with NO components key" {
  local decl; decl="$(declaration_file empty.properties $'# no direct dependencies\n')"
  swift_start all-up OPS_DEPENDENCIES_FILE="$decl"
  local body; body="$(http_body "$BASE/health")"
  [ "$(jq -r .status <<< "$body")" = "ok" ]
  # ABSENT — not `{}`, which would announce a v1.1 body that reports nothing.
  [ "$(jq -r 'has("components")' <<< "$body")" = "false" ]
  [ "$body" = '{"status":"ok"}' ]
  [ "$(http_code "$BASE/health/ready")" = "200" ]
}

@test "tc-corner-breaker-recovers-without-traffic: open -> half_open on a passive read alone" {
  swift_start hard-down BREAKER_OPEN_MS=5000
  [ "$(jq -r '.components["orders-db"].breaker' <<< "$(http_body "$BASE/health")")" = "open" ]
  local before; before="$(jq -r .calls <<< "$(http_body "$APP/orders-db-calls")")"
  # Positive control: tripping it really did call the dependency, so an equality below
  # cannot pass on two empty or null reads.
  matches "$before" '^[0-9]+$'
  [ "$before" -gt 0 ]
  # No request traffic at all — only /health reads, which must not generate any.
  health_when '.components["orders-db"].breaker == "half_open"' 12
  # Nothing reached the dependency: no probe scheduler, no downstream /health call.
  [ "$(jq -r .calls <<< "$(http_body "$APP/orders-db-calls")")" = "$before" ]
}

@test "tc-error-hard-down-fails-readiness: a hard dependency down sheds traffic but stays alive" {
  swift_start hard-down BREAKER_OPEN_MS=600000
  [ "$(http_code "$BASE/health")" = "200" ]
  local body; body="$(http_body "$BASE/health")"
  [ "$(jq -r .status <<< "$body")" = "down" ]
  [ "$(jq -r '.components["orders-db"].status' <<< "$body")" = "down" ]
  [ "$(jq -r '.components["orders-db"].breaker' <<< "$body")" = "open" ]
  [ "$(http_code "$BASE/health/ready")" = "503" ]
  local ready; ready="$(http_body "$BASE/health/ready")"
  [ "$(jq -r .detail <<< "$ready")" = "hard dependency 'orders-db' is down" ]
  # Liveness is never a function of a dependency.
  [ "$(http_code "$BASE/health/live")" = "200" ]
}

@test "tc-error-open-breaker-fast-fails: an open breaker answers from the fallback, with no connection and no retry" {
  swift_start soft-down BREAKER_OPEN_MS=600000
  local before; before="$(jq -r .hits <<< "$(http_body "$APP/upstream-hits")")"
  [ "$before" -gt 0 ]   # positive control: tripping it really did reach the upstream
  local headers="$BATS_TEST_TMPDIR/headers" code
  code="$(curl -s -D "$headers" -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' --max-time 5 "$APP/prices/sku-1234")"
  # The registered fallback's honest absence — never a fabricated price.
  [ "$code" = "503" ]
  grep -qF 'no cached price' "$BATS_TEST_TMPDIR/body"
  grep -qF 'is open' "$BATS_TEST_TMPDIR/body"
  # Single-digit milliseconds, measured INSIDE the service around the client call, so
  # connection setup and curl's own overhead cannot blur the verdict.
  local ms; ms="$(tr -d '\r' < "$headers" | awk -F': ' 'tolower($1) == "x-elapsed-ms" { print $2 }')"
  [ -n "$ms" ]
  [ "$ms" -lt 10 ]
  # Not one request reached the dependency — not the call, and not a retry.
  [ "$(jq -r .hits <<< "$(http_body "$APP/upstream-hits")")" = "$before" ]
}
