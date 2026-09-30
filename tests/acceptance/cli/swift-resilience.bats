#!/usr/bin/env bats
#
# Acceptance cases for the Swift resilience payload (#1146) — the `cli`-tooled half
# of its story-spec `test_cases[]`, one test per `tc-*` id:
#
#   tc-happy-conformance-script              #1212
#   tc-error-bad-declaration-fails-startup   #1219
#   tc-corner-linux-container-parity         #1220
#
# These run against a REAL Swift service compiled from the shipped templates (see
# ../lib/swift-ops-sandbox.zsh), and drive the SHIPPED check-ops-conformance.zsh.
# The parity case also builds the same package inside the official Swift image and
# re-runs the probe set against the container, so it needs Docker — and, like every
# case here, it FAILS rather than skips when its toolchain is missing. They are NOT
# part of the default gate — `bats tests` does not recurse — see ../README.md.

bats_require_minimum_version 1.5.0
load ../lib/swift-ops-acceptance
load ../../assertions

setup_file() {
  load ../lib/swift-ops-acceptance
  swift_provision
}

setup() { swift_sandbox; }
teardown() {
  swift_stop
  [ -z "${CONTAINER:-}" ] || docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [ -z "${IMAGE:-}" ] || docker rmi "$IMAGE" >/dev/null 2>&1 || true
}

@test "tc-happy-conformance-script: the shipped checker passes all five endpoints" {
  swift_start all-up
  run zsh "$CHECKER" "$BASE"
  [ "$status" -eq 0 ]
  checker_passed "$output" "/info"
  checker_passed "$output" "/health"
  checker_passed "$output" "/health/live"
  checker_passed "$output" "/health/ready"
  checker_passed "$output" "/metrics"
}

@test "tc-happy-conformance-script: the aggregate floor — hard down fails conformance as down" {
  # The other half of the floor: soft-down conforming as degraded is asserted in
  # rest/swift-resilience.bats. A hard dependency down must force the aggregate to
  # `down`, which the checker rejects (status 1, its conformance-failure code).
  swift_start hard-down BREAKER_OPEN_MS=600000
  [ "$(jq -r .status <<< "$(http_body "$BASE/health")")" = "down" ]
  run zsh "$CHECKER" "$BASE"
  [ "$status" -eq 1 ]
  checker_failed "$output" "hard dependency 'orders-db' is down"
}

@test "tc-error-bad-declaration-fails-startup: a duplicate name refuses to boot, naming the line" {
  local decl; decl="$(declaration_file dup.properties $'orders-db=hard\norders-db=soft\npricing-api=soft\n')"
  swift_run_expect_exit OPS_DEPENDENCIES_FILE="$decl"
  [ "$OPS_STATUS" -eq 1 ]
  grep -qF "$decl:2: dependency \"orders-db\" is declared twice (hard, then \"soft\")" "$OPS_LOG"
}

@test "tc-error-bad-declaration-fails-startup: a trailing comment refuses to boot rather than guessing" {
  local decl; decl="$(declaration_file trailing.properties $'orders-db=hard # primary\npricing-api=soft\n')"
  swift_run_expect_exit OPS_DEPENDENCIES_FILE="$decl"
  [ "$OPS_STATUS" -eq 1 ]
  grep -qF "$decl:1: dependency \"orders-db\" has kind \"hard # primary\"" "$OPS_LOG"
}

@test "tc-error-bad-declaration-fails-startup: a declared name no client guards refuses to boot" {
  local decl; decl="$(declaration_file unguarded.properties $'orders-db=hard\npricing-api=soft\ninventory-api=soft\n')"
  swift_run_expect_exit OPS_DEPENDENCIES_FILE="$decl"
  [ "$OPS_STATUS" -eq 1 ]
  grep -qF '["inventory-api"], but no client claimed them' "$OPS_LOG"
}

@test "tc-error-bad-declaration-fails-startup: an unreadable override refuses to boot instead of falling back" {
  local missing="$BATS_TEST_TMPDIR/does-not-exist.properties"
  swift_run_expect_exit OPS_DEPENDENCIES_FILE="$missing"
  [ "$OPS_STATUS" -eq 1 ]
  grep -qF "\$OPS_DEPENDENCIES_FILE is set to \"$missing\" but it cannot be read" "$OPS_LOG"
}

@test "tc-error-bad-declaration-fails-startup: a CRLF declaration still declares — the hinge is not silently disarmed" {
  # The shape a ConfigMap built from a Windows-edited file takes. Swift reads "\r\n" as
  # ONE Character, so a parser splitting on "\n" sees one line; this one starts with a
  # comment, so it would declare NOTHING: /health would drop its components and a hard
  # dependency could never fail readiness. Declared correctly, hard-down sheds traffic.
  local decl; decl="$(declaration_file crlf.properties $'# written on Windows\r\norders-db=hard\r\npricing-api=soft\r\n')"
  swift_start hard-down BREAKER_OPEN_MS=600000 OPS_DEPENDENCIES_FILE="$decl"
  local body; body="$(http_body "$BASE/health")"
  [ "$(jq -r '.components | keys | join(",")' <<< "$body")" = "orders-db,pricing-api" ]
  [ "$(jq -r .status <<< "$body")" = "down" ]
  [ "$(http_code "$BASE/health/ready")" = "503" ]
}

# probe_set <ops-base> <app-base> — the observations the parity case compares, one
# per line, with the only legitimately platform-varying field (`since`) removed.
probe_set() {
  local health
  health="$(http_body "$1/health")"
  # A dead fixture on BOTH sides would otherwise print identical empty/000 lines and
  # compare equal: refuse an unanswered probe before it can reach the comparison.
  [ -n "$health" ] || { echo "probe_set: $1/health answered nothing" >&2; return 1; }
  printf 'health=%s\n' "$(jq -cS 'if has("components") then .components |= map_values(del(.since)) else . end' <<< "$health")"
  printf 'ready=%s\n' "$(http_code "$1/health/ready")"
  printf 'ready-detail=%s\n' "$(jq -r '.detail // "-"' <<< "$(http_body "$1/health/ready")")"
  printf 'price=%s\n' "$(http_code "$2/prices/sku-1234")"
  printf 'checker=%s\n' "$(zsh "$CHECKER" "$1" >/dev/null 2>&1; echo $?)"
}

@test "tc-corner-linux-container-parity: the container answers the probe set exactly as the native build" {
  command -v docker >/dev/null 2>&1 || { echo "docker is required for the Linux parity case" >&2; return 1; }
  docker info >/dev/null 2>&1 || { echo "docker is installed but not usable" >&2; return 1; }
  # The build context is the provisioned package WITHOUT its .build — the image
  # compiles from source, exactly as an adopter's Dockerfile would. The runtime stage
  # is the SLIM image with the binary alone: no source tree, no .properties file, so
  # the declaration it reports can only have come from the compiled-in literal.
  local ctx="$BATS_TEST_TMPDIR/ctx"
  mkdir -p "$ctx"
  cp "$SANDBOX/Package.swift" "$ctx/"
  cp -R "$SANDBOX/Sources" "$ctx/"
  # The native build's resolved versions, so a parity red names the PLATFORM, never a
  # dependency release that landed between the two builds.
  [ ! -f "$SANDBOX/Package.resolved" ] || cp "$SANDBOX/Package.resolved" "$ctx/"
  cat > "$ctx/Dockerfile" <<'EOF'
FROM swift:6.2 AS build
WORKDIR /src
COPY . .
RUN swift build -c release --static-swift-stdlib
FROM swift:6.2-slim
COPY --from=build /src/.build/release/OpsFixture /usr/local/bin/OpsFixture
ENTRYPOINT ["/usr/local/bin/OpsFixture"]
EOF
  # The image ID this build produced — never a shared tag, which a concurrent run in
  # another worktree could re-point at its own payload between our build and our run.
  IMAGE="$(docker build -q "$ctx")" || { echo "docker build failed" >&2; return 1; }
  [ -n "$IMAGE" ] || { echo "docker build printed no image ID" >&2; return 1; }

  local empty; empty="$(declaration_file empty.properties $'# none\n')"
  local scenario native linux
  for scenario in all-up soft-down hard-down empty; do
    # A long open window on both sides, so no breaker reaches half-open between the
    # native probe and the container's.
    local run_scenario="$scenario" extra=(BREAKER_OPEN_MS=600000)
    if [ "$scenario" = empty ]; then run_scenario=all-up; extra+=(OPS_DEPENDENCIES_FILE="$empty"); fi

    swift_start "$run_scenario" "${extra[@]}"
    native="$(probe_set "$BASE" "$APP")" || return 1
    swift_stop

    local mounts=() envs=()
    if [ "$scenario" = empty ]; then
      mounts=(-v "$empty:/etc/ops/deps.properties:ro")
      envs=(-e OPS_DEPENDENCIES_FILE=/etc/ops/deps.properties)
    fi
    CONTAINER="$(docker run -d "${mounts[@]}" "${envs[@]}" \
      -e GIT_SHA=9e11997 -e BUILD_VERSION=1.4.2 -e SCENARIO="$run_scenario" \
      -e OPS_PORT=9090 -e APP_PORT=8080 -e PRICING_PORT=18080 -e BREAKER_OPEN_MS=600000 \
      -p "127.0.0.1:$PORT:9090" -p "127.0.0.1:$APP_PORT:8080" "$IMAGE")"
    local _ up=0
    for _ in $(seq 1 120); do
      if curl -fsS -o /dev/null --max-time 2 "$BASE/health/live" 2>/dev/null \
         && curl -s -o /dev/null --max-time 2 "$APP/upstream-hits" 2>/dev/null; then up=1; break; fi
      sleep 0.25
    done
    [ "$up" -eq 1 ] || { docker logs "$CONTAINER" >&2; echo "container did not come up ($scenario)" >&2; return 1; }
    linux="$(probe_set "$BASE" "$APP")" || return 1
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    CONTAINER=""

    printf '== %s\nnative:\n%s\nlinux:\n%s\n' "$scenario" "$native" "$linux"
    [ "$native" = "$linux" ]
  done
}
