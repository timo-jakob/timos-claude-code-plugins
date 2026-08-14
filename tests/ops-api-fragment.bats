#!/usr/bin/env bats
#
# Structural tests for the ops-api/v1 fragment + its CI discovery (#688).
#
# The fragment (templates/common/contracts/ops/v1/openapi.yaml) is a versioned
# contract artifact linted by Spectral in target-repo CI; its zero-error lint is
# verified against .spectral.yaml at authoring time and by the contracts-lint job
# the checker's discovery must cover. The test toolchain has no spectral (and
# runs offline), so these tests assert the fragment's STRUCTURE — via `yq`, which
# the contracts suites already depend on — and that both workflow templates
# discover contracts/ops/v[0-9]*/, the parts that gate correctness here. Full
# spectral linting is the target repo's contracts-lint job.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  COMMON="$REPO_ROOT/development/skills/bootstrap/templates/common"
  FRAG="$COMMON/contracts/ops/v1/openapi.yaml"
  # The CURRENT major (#1330). v1 stays below as the freeze guard.
  V2="$COMMON/contracts/ops/v2/openapi.yaml"
}

@test "fragment exists at the contracts/ops/v1 path" {
  [ -f "$FRAG" ]
}

# ---- ops-api v2: the RFC 9457 probe 503s (#1330) ----------------------------
#
# The v2 fragment is the change's central artifact and the thing every payload
# and the conformance checker are written against — but the checker validates a
# LIVE SERVICE and the payload suites grep source, so without these the fragment
# itself is unpinned: a hand edit dropping `type: integer`, moving `components`
# onto the liveness Problem, or reverting a 503 to application/json would ship
# green.

@test "v2: the version triangle holds (info.version 2.x == v2 dir == servers /v2)" {
  [ -f "$V2" ]
  run yq -r '.info.version' "$V2"
  [ "$output" = "2.0.0" ]
  run yq -r '.servers[0].url' "$V2"
  [ "$output" = "/v2" ]
}

@test "v2: both probe 503s are BARE application/problem+json" {
  # Exactly ONE content key: bare-ness is what org-problem-json-errors requires,
  # so a body that also offers application/json is a conformance failure even
  # with perfect members.
  local p
  for p in /health/live /health/ready; do
    run yq -r ".paths.\"$p\".get.responses.\"503\".content | keys | join(\",\")" "$V2"
    [ "$output" = "application/problem+json" ]
  done
  # …and each resolves to the right schema: readiness carries components,
  # liveness must not.
  run yq -r '.paths."/health/ready".get.responses."503".content."application/problem+json".schema."$ref"' "$V2"
  [ "$output" = "#/components/schemas/ReadinessProblem" ]
  run yq -r '.paths."/health/live".get.responses."503".content."application/problem+json".schema."$ref"' "$V2"
  [ "$output" = "#/components/schemas/Problem" ]
}

@test "v2: both problem schemas are FLAT and require all four RFC 9457 members" {
  # Flat by necessity, not style: an allOf composition still fails
  # org-problem-json-errors, because the rule reads the resolved schema's own
  # top-level `required` and a composition has none.
  local s
  for s in Problem ReadinessProblem; do
    run yq -r ".components.schemas.$s.required | join(\",\")" "$V2"
    [ "$output" = "type,title,status,detail" ]
    run yq -r ".components.schemas.$s | has(\"allOf\")" "$V2"
    [ "$output" = "false" ]
    # `status` is the HTTP code as an INTEGER — the collision with the health
    # envelope's "ok"/"down" string is the entire reason this major exists.
    run yq -r ".components.schemas.$s.properties.status.type" "$V2"
    [ "$output" = "integer" ]
  done
}

@test "v2: components hangs off ReadinessProblem ONLY, and reuses DependencyHealth" {
  # A components map on a dependency-free liveness 503 would be a lie.
  run yq -r '.components.schemas.Problem.properties | has("components")' "$V2"
  [ "$output" = "false" ]
  run yq -r '.components.schemas.ReadinessProblem.properties.components.additionalProperties."$ref"' "$V2"
  [ "$output" = "#/components/schemas/DependencyHealth" ]
}

@test "v2: the 200s are UNCHANGED — v2 changes the two 503s and nothing else" {
  local p
  for p in /health/live /health/ready; do
    run yq -r ".paths.\"$p\".get.responses.\"200\".content | keys | join(\",\")" "$V2"
    [ "$output" = "application/json" ]
    run yq -r ".paths.\"$p\".get.responses.\"200\".content.\"application/json\".schema.\"\$ref\"" "$V2"
    [ "$output" = "#/components/schemas/Health" ]
  done
  # /health is not a probe: it has no 503 at all (#1139).
  run yq -r '.paths."/health".get.responses | has("503")' "$V2"
  [ "$output" = "false" ]
  run yq -r '.paths."/health".get.responses."200".content."application/json".schema."$ref"' "$V2"
  [ "$output" = "#/components/schemas/AggregateHealth" ]
}

@test "v2: contracts/ops/v1 is FROZEN — byte-identical to its committed state" {
  # The migration flow requires it: contracts-semver rejects a major that was
  # live at the base ref and gone at HEAD, so v1 must survive untouched.
  run git -C "$REPO_ROOT" diff --exit-code origin/main -- \
    development/skills/bootstrap/templates/common/contracts/ops/v1/openapi.yaml
  [ "$status" -eq 0 ]
}

@test "fragment declares /info, /health, /metrics" {
  grep -qE '^\s+/info:' "$FRAG"
  grep -qE '^\s+/health:' "$FRAG"
  grep -qE '^\s+/metrics:' "$FRAG"
}

@test "fragment splits liveness and readiness as distinct probes (#688)" {
  grep -qE '^\s+/health/live:' "$FRAG"
  grep -qE '^\s+/health/ready:' "$FRAG"
  grep -q 'operationId: getLiveness' "$FRAG"
  grep -q 'operationId: getReadiness' "$FRAG"
}

@test "fragment declares the internal management-port trust model (#688)" {
  grep -qi 'management port' "$FRAG"
  # /info minimal-by-contract: no framework/server/OS version disclosure
  grep -qiE 'MUST NOT expose (framework|.*framework)' "$FRAG"
}

@test "version triangle: info.version 1.x and servers /v1" {
  grep -qE 'version:\s*"1\.' "$FRAG"
  grep -qE 'url:\s*/v1' "$FRAG"
}

@test "each operation has a unique operationId (spectral operation-operationId)" {
  grep -q 'operationId: getInfo' "$FRAG"
  grep -q 'operationId: getHealth' "$FRAG"
  grep -q 'operationId: getMetrics' "$FRAG"
}

@test "/metrics accepts both prometheus and openmetrics content types" {
  grep -qE '^\s+text/plain:' "$FRAG"
  grep -qE '^\s+application/openmetrics-text:' "$FRAG"
}

@test "Info schema requires build + api; ApiMajor requires major + lifecycle" {
  grep -q 'required: \["build", "api"\]' "$FRAG"
  grep -q 'required: \["major", "lifecycle"\]' "$FRAG"
}

@test "deprecated major requires a sunset date (if/then rule)" {
  # the conditional: if lifecycle == deprecated then required sunset
  grep -q 'const: deprecated' "$FRAG"
  grep -q 'required: \["sunset"\]' "$FRAG"
  grep -qE 'enum:\s*\["active", "deprecated"\]' "$FRAG"
}

# ---- dependency health, ops-api v1.1 (#965) --------------------------------
#
# These use `yq` for STRUCTURAL assertions rather than substring greps: an enum
# or a `required` list only means something attached to a specific property, and
# a grep can tell neither AggregateHealth.status from DependencyHealth.status nor
# DependencyHealth.status's list from DependencyHealth.breaker's. yq is already
# a hard dependency of the contracts suites (tests/render-contracts-templates.bats
# calls it unguarded), so an absent yq fails these red rather than silently
# skipping — which is the right direction for a contract assertion.

# enum_of <schema> <property> <key> — the named enum list, comma-joined.
enum_of() {
  yq -r ".components.schemas.$1.properties.$2[\"$3\"] | join(\",\")" "$FRAG"
}

# health_schema <path> <http-status> — the $ref that path's response resolves to.
health_schema() {
  yq -r ".paths[\"$1\"].get.responses[\"$2\"].content[\"application/json\"].schema[\"\$ref\"]" "$FRAG"
}

@test "v1.1: the additive extension bumped the minor, not the major" {
  # Additive per oasdiff => at least a MINOR bump, and the major stays 1 so the
  # version triangle (info.version / v1 dir / servers /v1) still agrees.
  grep -qE 'version:\s*"1\.1\.' "$FRAG"
  grep -qE 'url:\s*/v1' "$FRAG"
}

@test "v1.1: AggregateHealth and DependencyHealth schemas exist" {
  [ "$(yq -r '.components.schemas.AggregateHealth | type' "$FRAG")" = "!!map" ]
  [ "$(yq -r '.components.schemas.DependencyHealth | type' "$FRAG")" = "!!map" ]
}

@test "v1.1: /health serves AggregateHealth; the probes stay on binary Health" {
  # The tri-state aggregate + components belong to /health alone. /health/live is
  # dependency-free BY CONTRACT, so it must never gain a components-bearing shape.
  [ "$(health_schema /health 200)" = "#/components/schemas/AggregateHealth" ]
  [ "$(health_schema /health/live 200)" = "#/components/schemas/Health" ]
  [ "$(health_schema /health/live 503)" = "#/components/schemas/Health" ]
  [ "$(health_schema /health/ready 200)" = "#/components/schemas/Health" ]
  [ "$(health_schema /health/ready 503)" = "#/components/schemas/Health" ]
}

@test "v1.1: the aggregate keeps \"ok\" as its healthy value (additive, not a rename)" {
  # Renaming ok -> up would be a BREAKING response change (a new ops major), and
  # would silently break every v1.0 consumer and the conformance checker.
  [ "$(enum_of AggregateHealth status x-extensible-enum)" = "ok,degraded,down" ]
}

@test "v1.1: a widened response enum is declared OPEN (oasdiff-additive)" {
  # oasdiff flags response-property-enum-value-added as breaking, so the widened
  # aggregate states are declared as x-extensible-enum rather than enum —
  # otherwise this change could never ship as an ops MINOR.
  [ "$(yq -r '.components.schemas.AggregateHealth.properties.status.enum' "$FRAG")" = "null" ]
  # ...while the binary probe envelope keeps its CLOSED enum.
  [ "$(enum_of Health status enum)" = "ok,down" ]
}

@test "v1.1: DependencyHealth requires status + kind, with kind a CLOSED enum" {
  # kind is the readiness hinge — an undeclared or novel kind leaves readiness
  # undefined, so it is the one field that must never be extensible.
  [ "$(yq -r '.components.schemas.DependencyHealth.required | join(",")' "$FRAG")" = "status,kind" ]
  [ "$(enum_of DependencyHealth kind enum)" = "hard,soft" ]
  [ "$(yq -r '.components.schemas.DependencyHealth.properties.kind["x-extensible-enum"]' "$FRAG")" = "null" ]
}

@test "v1.1: dependency status + breaker states are declared on the right properties" {
  # Asserted per-PROPERTY: a whole-file (or even whole-schema) grep would pass
  # with the two lists swapped onto each other's property.
  [ "$(enum_of DependencyHealth status x-extensible-enum)" = "up,degraded,down" ]
  [ "$(enum_of DependencyHealth breaker x-extensible-enum)" = "closed,open,half_open" ]
}

@test "v1.1: DependencyHealth.since is an RFC 3339 timestamp" {
  # The checker validates `since` as a string; the contract must keep declaring it.
  [ "$(yq -r '.components.schemas.DependencyHealth.properties.since.type' "$FRAG")" = "string" ]
  [ "$(yq -r '.components.schemas.DependencyHealth.properties.since.format' "$FRAG")" = "date-time" ]
}

@test "v1.1: components hangs off AggregateHealth, is OPTIONAL, and \$refs DependencyHealth" {
  # The $ref is the whole point of the map — pin it, not just the two words.
  [ "$(yq -r '.components.schemas.AggregateHealth.properties.components.additionalProperties["$ref"]' "$FRAG")" \
    = "#/components/schemas/DependencyHealth" ]
  # Optional: the required list is EXACTLY status, under any spelling.
  [ "$(yq -r '.components.schemas.AggregateHealth.required | join(",")' "$FRAG")" = "status" ]
  # ...and the probes' envelope never gained it.
  [ "$(yq -r '.components.schemas.Health.properties.components' "$FRAG")" = "null" ]
}

@test "v1.1: the fragment states the direct-only (non-transitive) health rule" {
  grep -qi 'never transitively calls' "$FRAG"
  grep -qi 'direct' "$FRAG"
}

@test "v1.1: readiness formalized — only a HARD dependency fails it" {
  # The ONLY is scoped to dependencies: startup and shutdown-drain must still be
  # able to fail readiness, so the rule is stated as "AMONG DEPENDENCIES".
  grep -qi 'AMONG DEPENDENCIES, readiness fails ONLY' "$FRAG"
  grep -qi 'MUST NOT fail' "$FRAG"
  grep -qi 'draining during a graceful shutdown' "$FRAG"
}

@test "contracts-lint discovery covers contracts/ops/v[0-9]* (#688)" {
  local tmpl="$COMMON/.github/workflows/contracts-lint.yml.tmpl"
  # Since #1330 the per-major glob is parameterised by family and only the NEWEST
  # major of each is linted, so the fully-qualified ops glob is no longer a literal.
  # What must remain true — and is what this test is actually about — is that the
  # ops family is discovered at all.
  grep -q 'for family in contracts contracts/ops' "$tmpl"
  # The per-major glob is now parameterised by FILENAME too (the selector reuses
  # it to find the newest vN directory), so the literal no longer carries
  # openapi.yaml — the per-major shape and the ops family are what matter here.
  grep -q 'v\[0-9\]\*/' "$tmpl"
  grep -q 'newest_major "\$family"' "$tmpl"
}

@test "contracts-semver discovery covers contracts/ops (#688)" {
  local tmpl="$COMMON/.github/workflows/contracts-semver.yml.tmpl"
  # a second gate invocation scoped to the ops surface, writing its own findings
  grep -q "contracts-dir contracts/ops" "$tmpl"
  grep -q "contracts-ops-semver-findings.json" "$tmpl"
}

@test "contracts-semver runs the ops gate UNCONDITIONALLY (no HEAD-only guard, #688)" {
  local tmpl="$COMMON/.github/workflows/contracts-semver.yml.tmpl"
  # a `git rm -r contracts/ops/` must still be gated (retire-a-live-major),
  # so the ops invocation must not be behind an existence guard.
  # Anchor the negative: grep on a missing/renamed file exits 2, which would
  # satisfy `run !` vacuously and report green on a check never performed.
  [ -f "$tmpl" ]
  run ! grep -q "compgen -G 'contracts/ops" "$tmpl"
}
