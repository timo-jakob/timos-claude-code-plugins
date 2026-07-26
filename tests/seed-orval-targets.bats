#!/usr/bin/env bats
#
# Behavioral tests for seed-orval-targets.zsh (#727, slice 2 of #683) — the
# detector + seeder for the contract-consumer machinery. It reads package.json,
# finds pinned *-api-spec deps (the #684 naming convention), and seeds an
# editable orval.config.ts with one target per spec. Its exit code is the
# detection signal the bootstrap flow branches §3k on: 0 = consumer, 3 = not a
# consumer, 2 = usage/precondition error. jq-driven, so fully hermetic.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SEED="$REPO_ROOT/development/skills/bootstrap/scripts/seed-orval-targets.zsh"
  WORK="$BATS_TEST_TMPDIR/repo"
  # ISO holds ONLY the utilities the script needs — but NOT jq — so the
  # jq-absent precondition branch can be exercised hermetically (mirrors
  # gather-javascript.bats). zsh launches the script; jq is deliberately omitted.
  ISO="$BATS_TEST_TMPDIR/iso-bin"
  mkdir -p "$WORK" "$ISO"
  for util in zsh env cat rm mktemp mv sort; do
    ln -sf "$(command -v "$util")" "$ISO/$util"
  done
}

pkg() { printf '%s' "$1" > "$WORK/package.json"; }

@test "seed-orval: no argument -> usage error, exit 2" {
  run zsh "$SEED"
  [ "$status" -eq 2 ]
  contains "$output" "usage: seed-orval-targets.zsh"
}

@test "seed-orval: jq not on PATH -> precondition error, exit 2" {
  pkg '{ "name": "x", "dependencies": { "orders-api-spec": "1.0.0" } }'
  run env PATH="$ISO" zsh "$SEED" "$WORK"
  [ "$status" -eq 2 ]
  contains "$output" "jq is required"
}

@test "seed-orval: malformed package.json -> precondition error exit 2 (NOT silently 'not a consumer')" {
  pkg '{ not json'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 2 ]
  contains "$output" "not a valid JSON object"
  [ ! -f "$WORK/orval.config.ts" ]
}

@test "seed-orval: repo path that does not exist -> exit 2" {
  run zsh "$SEED" "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
}

@test "seed-orval: repo without package.json -> exit 2, no config written" {
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 2 ]
  [ ! -f "$WORK/orval.config.ts" ]
}

@test "seed-orval: a misordered '<repo> --plan' is rejected (exit 2), NOT a silent write" {
  pkg '{ "name": "x", "dependencies": { "orders-api-spec": "1.0.0" } }'
  run zsh "$SEED" "$WORK" --plan
  [ "$status" -eq 2 ]
  contains "$output" "usage: seed-orval-targets.zsh"
  [ ! -f "$WORK/orval.config.ts" ]
}

@test "seed-orval: a multi-document package.json is a precondition error (exit 2)" {
  pkg '[] {}'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 2 ]
  contains "$output" "not a valid JSON object"
}

@test "seed-orval: --plan detects but writes NOTHING (safe during Step 2 planning)" {
  pkg '{ "name": "x", "dependencies": { "@acme/orders-api-spec": "2.4.0" } }'
  run zsh "$SEED" --plan "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.planned == true' >/dev/null
  echo "$output" | jq -e '.seeded == false' >/dev/null
  # the targets that WOULD be seeded are reported…
  [ "$(jq -r '.targets[0].name' <<<"$output")" = "orders" ]
  # …but no file was written (the pre-approval safety guarantee)
  [ ! -f "$WORK/orval.config.ts" ]
}

@test "seed-orval: --plan on a non-consumer still exits 3 and writes nothing" {
  pkg '{ "name": "x", "dependencies": { "react": "^18.0.0" } }'
  run zsh "$SEED" --plan "$WORK"
  [ "$status" -eq 3 ]
  [ ! -f "$WORK/orval.config.ts" ]
}

@test "seed-orval: no *-api-spec dependency -> exit 3, seeded false, nothing written" {
  pkg '{ "name": "x", "dependencies": { "react": "^18.0.0" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 3 ]
  echo "$output" | jq -e '.seeded == false' >/dev/null
  [ "$(jq -r '.targets | length' <<<"$output")" = "0" ]
  [ ! -f "$WORK/orval.config.ts" ]
}

@test "seed-orval: a dep merely containing 'api' but not ending -api-spec is ignored" {
  pkg '{ "name": "x", "dependencies": { "my-api-client": "1.0.0", "api-spec-helper": "2.0.0" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 3 ]
  [ ! -f "$WORK/orval.config.ts" ]
}

@test "seed-orval: one unscoped *-api-spec dep -> exit 0, one target, config written" {
  pkg '{ "name": "x", "dependencies": { "billing-api-spec": "1.2.0" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.seeded == true' >/dev/null
  echo "$output" | jq -e '.reason == null' >/dev/null
  # config_path in the summary points at the file actually written
  echo "$output" | jq -e --arg cp "$WORK/orval.config.ts" '.config_path == $cp' >/dev/null
  [ "$(jq -r '.targets | length' <<<"$output")" = "1" ]
  [ "$(jq -r '.targets[0].name' <<<"$output")" = "billing" ]
  [ "$(jq -r '.targets[0].package' <<<"$output")" = "billing-api-spec" ]
  [ "$(jq -r '.targets[0].input' <<<"$output")" = "./node_modules/billing-api-spec/openapi.yaml" ]
  [ "$(jq -r '.targets[0].output' <<<"$output")" = "src/api/generated/billing" ]
  [ -f "$WORK/orval.config.ts" ]
}

@test "seed-orval: a hyphenated bare name -> QUOTED TS key (valid config, not a syntax error)" {
  # order-service-api-spec -> target order-service; an UNquoted `order-service: {`
  # is invalid TypeScript. The key must be quoted.
  pkg '{ "name": "x", "dependencies": { "order-service-api-spec": "1.0.0" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.targets[0].name' <<<"$output")" = "order-service" ]
  grep -q '  "order-service": {' "$WORK/orval.config.ts"
  # every emitted target key is quoted
  run ! grep -qE '^  [a-zA-Z0-9_-]+: \{$' "$WORK/orval.config.ts"
}

@test "seed-orval: a scoped @scope/*-api-spec dep -> target name strips scope + suffix" {
  pkg '{ "name": "x", "dependencies": { "@acme/orders-api-spec": "2.4.0" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.targets[0].name' <<<"$output")" = "orders" ]
  [ "$(jq -r '.targets[0].package' <<<"$output")" = "@acme/orders-api-spec" ]
  [ "$(jq -r '.targets[0].input' <<<"$output")" = "./node_modules/@acme/orders-api-spec/openapi.yaml" ]
}

@test "seed-orval: specs in devDependencies and peerDependencies are also detected" {
  pkg '{ "name": "x",
    "devDependencies": { "orders-api-spec": "1.0.0" },
    "peerDependencies": { "billing-api-spec": "1.0.0" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.targets | length' <<<"$output")" = "2" ]
  [ "$(jq -r '[.targets[].name] | sort | join(",")' <<<"$output")" = "billing,orders" ]
}

@test "seed-orval: multiple specs -> multiple targets in one config" {
  pkg '{ "name": "x", "dependencies": {
    "@acme/orders-api-spec": "2.4.0", "billing-api-spec": "1.0.0", "react": "^18" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.targets | length' <<<"$output")" = "2" ]
  # both targets present in the written config (keys are quoted)
  grep -q '  "orders": {' "$WORK/orval.config.ts"
  grep -q '  "billing": {' "$WORK/orval.config.ts"
}

@test "seed-orval: same bare name from two scopes -> disambiguated (orders, orders-2)" {
  pkg '{ "name": "x", "dependencies": {
    "@a/orders-api-spec": "1.0.0", "@b/orders-api-spec": "2.0.0" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.targets | length' <<<"$output")" = "2" ]
  # deterministic (sort -u orders @a before @b): the actual naming scheme, not
  # just that the dirs differ
  [ "$(jq -r '[.targets[].name] | sort | join(",")' <<<"$output")" = "orders,orders-2" ]
  [ "$(jq -r '[.targets[].output] | unique | length' <<<"$output")" = "2" ]
}

@test "seed-orval: a suffixed name that would re-collide keeps looping to a free name" {
  # @a/orders + @b/orders -> orders, orders-2; a real orders-2-api-spec must NOT
  # silently share the orders-2 output dir.
  pkg '{ "name": "x", "dependencies": {
    "@a/orders-api-spec": "1", "@b/orders-api-spec": "2", "orders-2-api-spec": "3" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.targets | length' <<<"$output")" = "3" ]
  # all three names distinct, all three output dirs distinct (no overwrite)
  [ "$(jq -r '[.targets[].name] | unique | length' <<<"$output")" = "3" ]
  [ "$(jq -r '[.targets[].output] | unique | length' <<<"$output")" = "3" ]
}

@test "seed-orval: generated orval.config.ts is a coherent starter" {
  pkg '{ "name": "x", "dependencies": { "@acme/orders-api-spec": "2.4.0" } }'
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 0 ]
  grep -q 'import { defineConfig } from "orval";' "$WORK/orval.config.ts"
  grep -q 'export default defineConfig({' "$WORK/orval.config.ts"
  grep -q 'client: "fetch",' "$WORK/orval.config.ts"
  grep -q 'mock: true,' "$WORK/orval.config.ts"
  grep -q 'mode: "tags-split",' "$WORK/orval.config.ts"
  grep -q 'clean: true,' "$WORK/orval.config.ts"
  grep -q 'baseUrl: "/api",' "$WORK/orval.config.ts"
  grep -q 'target: "src/api/generated/orders",' "$WORK/orval.config.ts"
  # No leaked shell assignments (the local-var scoping bug regression guard).
  run ! grep -qE '^(t_name|t_input|t_output|name)=' "$WORK/orval.config.ts"
}

@test "seed-orval: existing orval.config.ts is NEVER clobbered (idempotency rule 3)" {
  pkg '{ "name": "x", "dependencies": { "orders-api-spec": "1.0.0" } }'
  printf '// hand-edited config\n' > "$WORK/orval.config.ts"
  run zsh "$SEED" "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.seeded == false' >/dev/null
  contains "$output" "left untouched"
  # still the user's file, and it still lists the target it detected
  [ "$(cat "$WORK/orval.config.ts")" = "// hand-edited config" ]
  [ "$(jq -r '.targets | length' <<<"$output")" = "1" ]
}
