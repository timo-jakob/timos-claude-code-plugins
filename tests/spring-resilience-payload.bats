#!/usr/bin/env bats
#
# Structural tests for the canonical Spring resilience + dependency-health payload
# (#1141, epic #964 / sub-epic #967).
#
# Like ops-api-language-payloads.bats, these are grep-based and offline: the files
# are bootstrap templates copied into a target service, and their RUNTIME behaviour
# is verified downstream by that repo's ops-conformance CI job (this toolchain has
# no JVM and no service to run). What is cheap and worth guarding here is that the
# files the SKILL render blocks name still exist, and that the details which fail
# SILENTLY when broken stay in place -- a payload that compiles and starts but
# reports health wrongly is the failure mode this whole slice exists to prevent.
#
# THREE RULES THIS FILE HOLDS ITSELF TO, because a vacuous assertion here is worse
# than no assertion (it advertises a guard that is not there):
#
#   1. ANCHOR EVERY NEEDLE TO CODE, NOT PROSE. The payload documents its own
#      invariants in comments, so a bare `grep -q '<invariant>'` is satisfied by
#      the comment that explains the line even after the line itself is deleted.
#   2. NEGATIVES PIN STATUS 1, NOT "NOT ZERO". `run ! grep` also passes on grep's
#      error exit 2 (unreadable or missing path), so a renamed payload directory
#      would turn a negative assertion into an unconditional pass. Every negative
#      below is `run grep ...` followed by `[ "$status" -eq 1 ]`.
#   3. SCOPE A YAML NEEDLE TO ITS BLOCK, AND PIN ITS VALUE. Several resilience4j
#      keys are legal under more than one parent, and several values are prefixes
#      of the regression they are meant to exclude (`base-path: /` is a prefix of
#      `base-path: /actuator`). Extract the block with sed, guard it non-empty,
#      and match whole lines.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SPRING="$REPO_ROOT/development/skills/bootstrap/templates/languages/spring/resilience"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  YML="$SPRING/application-resilience.yml"
  HEALTH="$SPRING/DependencyHealth.java"
  ENDPOINT="$SPRING/OpsHealthEndpoint.java"
  CATALOG="$SPRING/DependencyCatalog.java"
  CLIENT="$SPRING/PricingApiClient.java"
  # Restrict recursive greps to the payload's own file types: a local Gradle build
  # leaves a gitignored .gradle/ tree here, and scanning it would make these
  # assertions depend on host state CI never has.
  INCLUDES=(--include='*.java' --include='*.kts' --include='*.yml' --include='*.md')
  # Code-only, for negatives about annotations/declarations: scanning *.md would let
  # a prose example inside a fence redden a code assertion.
  CODE_INCLUDES=(--include='*.java' --include='*.kts')
}

# Extract a top-level `resilience4j` sub-block (circuitbreaker | retry |
# timelimiter) and prove the range actually closed, so a reordering of the YAML
# cannot silently widen it to EOF and make the caller's assertions vacuous.
r4j_block() {
  block_between "^  $1:" "  $2:" "$YML"
}

# Extract <start-re>..<end-line> from a file and PROVE the range closed. A sed range
# whose end address never matches silently runs to EOF, which turns every
# block-scoped assertion built on it back into the whole-file matching the scoping
# exists to avoid. Command substitution strips trailing newlines, so a closed range
# ends with the end line EXACTLY -- checked as a suffix, not as a floating substring
# (`  retry:` is a substring of `    retry:`, so an unanchored check can false-pass).
block_between() {
  # nl MUST be ANSI-C quoted, not $(printf '\n'): command substitution strips
  # trailing newlines, so the latter expands to the empty string and the anchor
  # silently degrades to a floating suffix match -- the very false-pass this
  # guard exists to exclude.
  local start_re="$1" end_line="$2" file="$3" block nl=$'\n'
  block="$(sed -n "/${start_re}/,/^${end_line}\$/p" "$file")"
  [ -n "$block" ] || { echo "empty block for ${start_re} -- sed range did not match" >&2; return 1; }
  case "$block" in
    "${end_line}"|*"${nl}${end_line}") : ;;
    *) echo "block for ${start_re} never reached '${end_line}' -- range ran to EOF" >&2; return 1 ;;
  esac
  printf '%s\n' "$block"
}

# ---- payload presence ------------------------------------------------------

@test "spring resilience payload files exist at the SKILL render paths" {
  [ -f "$SPRING/build.gradle.kts" ]
  [ -f "$YML" ]
  [ -f "$CATALOG" ]
  [ -f "$HEALTH" ]
  [ -f "$ENDPOINT" ]
  [ -f "$CLIENT" ]
  [ -f "$SPRING/README.md" ]
}

@test "every payload .java file keeps the flagged placeholder package" {
  # Java couples a file's package to its directory, so placement MUST re-set it.
  # The flag is what makes an unset package a visible TODO rather than a silent
  # com.example.ops leak into a real service.
  local f
  for f in "$SPRING"/*.java; do
    grep -q '^package com.example.ops; // <-- CHANGE' "$f" || {
      echo "missing flagged placeholder package in $f" >&2
      return 1
    }
  done
}

@test "the SKILL render commands name every payload file" {
  # Anchored to the fenced render blocks, not to SKILL.md at large: the file is
  # mostly prose, so an unscoped grep would be satisfied by any sentence naming
  # the path even after the file is dropped from the command. -F throughout, so
  # the dots in the filenames are literal.
  local blocks f base
  blocks="$(sed -n '/render.zsh" \\/,/^```$/p' "$SKILL")"
  [ -n "$blocks" ]
  for f in "$SPRING"/*.java "$SPRING"/build.gradle.kts "$YML" "$SPRING"/README.md; do
    base="$(basename "$f")"
    contains "$blocks" "languages/spring/resilience/$base"
  done
}

@test "PricingApiClient is rendered by its own command, so the omit path can drop it" {
  # Placing it unadapted breaks every context load on ${pricing-api.base-url};
  # if it shared the main render command the omit path could not stage without it.
  local main_block
  main_block="$(sed -n '/languages\/spring\/resilience\/build.gradle.kts/,/^```$/p' "$SKILL")"
  [ -n "$main_block" ]
  lacks "$main_block" 'PricingApiClient.java'
}

# ---- the blessed library choice -------------------------------------------

@test "build fragment pins the Boot 4 resilience4j starter, not the Boot 3 one" {
  grep -qE '^[[:space:]]*implementation\("io\.github\.resilience4j:resilience4j-spring-boot4:' \
    "$SPRING/build.gradle.kts"
  # Scoped to DECLARATION lines: the prose above the block names the Boot 3
  # starter to explain why resilience4j-bom (which still manages only that one)
  # is deliberately not imported, so a whole-file grep would match the comment.
  run grep -qE '^[[:space:]]*implementation\(".*resilience4j-spring-boot3' \
    "$SPRING/build.gradle.kts"
  [ "$status" -eq 1 ]
}

@test "build fragment declares spring-boot-starter-aop (without it the annotations are inert)" {
  # Anchored to the declaration, NOT the comment that explains it: the comment is
  # the likeliest thing to survive a dependency-block edit, so an unanchored grep
  # would stay green while @CircuitBreaker/@Retry ship silently inert.
  grep -qE '^[[:space:]]*implementation\("org\.springframework\.boot:spring-boot-starter-aop"\)' \
    "$SPRING/build.gradle.kts"
}

@test "build fragment declares the Prometheus registry (without it /metrics 404s)" {
  # spring-boot-starter-actuator does NOT bring a Prometheus registry, and Boot
  # only auto-configures the `prometheus` endpoint when one is on the classpath.
  grep -qE '^[[:space:]]*implementation\("io\.micrometer:micrometer-registry-prometheus"\)' \
    "$SPRING/build.gradle.kts"
}

@test "build fragment declares the actuator and web starters" {
  grep -qE '^[[:space:]]*implementation\("org\.springframework\.boot:spring-boot-starter-actuator"\)' \
    "$SPRING/build.gradle.kts"
  grep -qE '^[[:space:]]*implementation\("org\.springframework\.boot:spring-boot-starter-web"\)' \
    "$SPRING/build.gradle.kts"
}

@test "Spring Cloud Circuit Breaker is not used" {
  # The abstraction hides the CircuitBreakerRegistry the /health binding reads,
  # and a swappable-library layer contradicts one-blessed-library.
  run grep -rqE "${CODE_INCLUDES[@]}" '^[[:space:]]*implementation\(".*spring-cloud-starter-circuitbreaker' \
    "$SPRING"
  [ "$status" -eq 1 ]
  # Positive control: grep -r --include also exits 1 when NOTHING matched the filters,
  # so without this an unscannable payload dir would "prove" the absence.
  grep -rq "${CODE_INCLUDES[@]}" 'implementation(' "$SPRING"
}

# ---- the two silent-failure wiring rules -----------------------------------

@test "the fallback is registered on @Retry, not on @CircuitBreaker" {
  # Retry is resilience4j's OUTERMOST aspect: a fallbackMethod on @CircuitBreaker
  # returns a success before Retry sees the failure, so the call is never retried.
  grep -qE '^  @Retry\(name = "pricing-api", fallbackMethod = "lastKnownPrice"\)$' "$CLIENT"
  # Anchored to the annotation's own two-space indentation. The six-mandate header
  # comment ends with the identical text, so a `$`-only anchor would match it and
  # survive the annotation being deleted outright.
  grep -qE '^  @CircuitBreaker\(name = "pricing-api"\)$' "$CLIENT"
  run grep -qE '^[[:space:]]*@CircuitBreaker\(.*fallbackMethod' "$CLIENT"
  [ "$status" -eq 1 ]
}

@test "retry ignores CallNotPermittedException, inside the RETRY block" {
  # `ignore-exceptions` is legal under resilience4j.circuitbreaker too, so moving
  # the stanza there -- a plausible tidy-up, the two configs being adjacent --
  # would keep a whole-file grep green while mandate 6's fast-fail is gone.
  local retry
  retry="$(r4j_block retry timelimiter)"
  contains "$retry" 'ignore-exceptions:'
  contains "$retry" 'io.github.resilience4j.circuitbreaker.CallNotPermittedException'
}

@test "the fallback method exists with the resilience4j (args..., Throwable) signature" {
  grep -q 'private PriceQuote lastKnownPrice(String sku, Throwable cause)' "$CLIENT"
}

@test "the fallback neither calls the dependency nor rethrows" {
  # Either would defeat the breaker it is protecting: a fallback that re-enters the
  # dead dependency reintroduces the hang, and one that rethrows turns the open
  # breaker back into a caller-visible failure.
  local body
  body="$(sed -n '/private PriceQuote lastKnownPrice/,/^  }/p' "$CLIENT")"
  [ -n "$body" ]
  lacks "$body" 'http.'
  lacks "$body" 'throw '
}

# ---- the six mandates ------------------------------------------------------

@test "config wires background reconnect inside the circuitbreaker block (mandate 5)" {
  local cb
  cb="$(r4j_block circuitbreaker retry)"
  contains "$cb" 'automatic-transition-from-open-to-half-open-enabled: true'
}

@test "config wires bounded retry with jittered backoff inside the retry block (mandate 3)" {
  local retry
  retry="$(r4j_block retry timelimiter)"
  # Bounded is the point, so the value is pinned WHOLE-LINE: 'max-attempts: 3' is a
  # prefix of 'max-attempts: 30', so a retry storm would pass a substring match.
  contains "$retry" 'max-attempts:'
  grep -qxF '        max-attempts: 3' "$YML"
  contains "$retry" 'enable-exponential-backoff: true'
  contains "$retry" 'enable-randomized-wait: true'
}

@test "config wires transport timeouts under the Boot 4 prefix (mandate 1)" {
  # @TimeLimiter is inert on a synchronous method, so the read/connect timeouts are
  # the only thing standing between a dead socket and a parked request thread.
  # The PREFIX is asserted, not the bare leaf: `spring.http.clients` (plural) is
  # the Boot 4 spelling, the singular `spring.http.client` is deprecated and binds
  # nothing -- a "correction" to it would silently unwire mandate 1.
  local block
  block="$(sed -n '/^spring:$/,$p' "$YML")"
  [ -n "$block" ]
  contains "$block" '  http:'
  contains "$block" '    clients:'
  contains "$block" '      connect-timeout:'
  contains "$block" '      read-timeout:'
}

@test "each declared dependency has its OWN breaker instance" {
  # One breaker per dependency is the unit /health reports; a declared dependency
  # with no instance is the payload's documented startup IllegalStateException.
  # Scoped to the circuitbreaker `instances:` block -- the same 6-space keys also
  # appear under retry and timelimiter, so an unscoped count passes even after the
  # circuit-breaker instance is deleted.
  local cb instances
  cb="$(r4j_block circuitbreaker retry)"
  instances="$(printf '%s\n' "$cb" | sed -n '/^    instances:/,$p')"
  [ -n "$instances" ]
  contains "$instances" '      orders-db:'
  contains "$instances" '      pricing-api:'
}

@test "the declared dependencies and their kinds bind to DependencyCatalog" {
  # The @ConfigurationProperties prefix and the yml keys are coupled by nothing but
  # convention. If either drifts, binding yields an EMPTY map: components() returns
  # nothing, /health omits `components` and reports "ok" straight through an
  # outage, and readiness never fails -- a silent, contract-violating payload that
  # starts perfectly.
  grep -q '@ConfigurationProperties(prefix = "resilience")' "$CATALOG"
  # ...and it must be a bean at all, or the prefix binds nothing.
  grep -qE '^@Component$' "$CATALOG"
  grep -qE '^    HARD,$' "$CATALOG"
  grep -qE '^    SOFT$' "$CATALOG"
  local declared
  declared="$(block_between '^resilience:$' 'resilience4j:' "$YML")"
  contains "$declared" '  dependencies:'
  contains "$declared" '    orders-db:'
  contains "$declared" '    pricing-api:'
  # PAIRED to their dependency, not asserted as a set: swapping the two kinds would
  # pass four independent needles while teaching the inverse of the policy (the
  # README and SKILL both rest on orders-db being the hard one).
  # Lower-case, as Spring's relaxed enum binding expects for HARD/SOFT.
  local hard soft
  hard="$(block_between '^    orders-db:$' '    pricing-api:' "$YML")"
  contains "$hard" '      kind: hard'
  soft="$(printf '%s\n' "$declared" | sed -n '/^    pricing-api:$/,$p')"
  [ -n "$soft" ]
  contains "$soft" '      kind: soft'
}

@test "an omitted breaker name defaults to the dependency name" {
  # The shipped example omits `breaker` for BOTH dependencies, so this default is
  # the only path the payload's own config takes: drop it and registry.find(null)
  # throws for every dependency at boot. The null-guard on the setter is the same
  # class of silent precondition for a service that declares none at all.
  grep -qF '(dep.breaker() == null || dep.breaker().isBlank()) ? name : dep.breaker()' "$CATALOG"
  grep -qF '(dependencies == null) ? new LinkedHashMap<>() : dependencies' "$CATALOG"
}

# ---- the ops-api v1.1 binding ----------------------------------------------

@test "the health surface is an Actuator @Endpoint, never a controller" {
  # This is structural, not stylistic. The management port is served by a CHILD
  # context whose MVC stack has no RequestMappingHandlerMapping, so a
  # @RestController there is never mapped; one in the main context is mapped on
  # the PUBLIC app port and leaks the dependency graph. @RestControllerEndpoint,
  # the old bridge, is deprecated for removal since Boot 3.3.
  grep -qE '^@Endpoint\(id = "opshealth"\)$' "$ENDPOINT"
  grep -qE '^@Component$' "$ENDPOINT"
  run grep -rqE "${CODE_INCLUDES[@]}" '^[[:space:]]*@(RestController|Controller|RestControllerEndpoint)' \
    "$SPRING"
  [ "$status" -eq 1 ]
  # Positive control: an empty/renamed payload dir also makes grep -r exit 1, which
  # would make the negative above pass while scanning nothing.
  grep -rq "${CODE_INCLUDES[@]}" 'package com.example.ops' "$SPRING"
}

@test "the endpoint id is path-mapped onto the contract's /health" {
  # Without the mapping the surface answers at /opshealth, which the conformance
  # checker never fetches; with Actuator's own `health` also exposed, two
  # endpoints map onto the same path.
  local web
  web="$(block_between '^  endpoints:$' 'resilience:' "$YML")"
  # Block-scoped for the parent keys, WHOLE-LINE anchored for the values: every one
  # of these is a prefix of the regression it excludes -- `base-path: /` of
  # `base-path: /actuator`, `opshealth: health` of `opshealth: healthz`,
  # `prometheus: metrics` of `metrics2`, and the include list of one with `health`
  # appended.
  contains "$web" '      base-path:'
  contains "$web" '      path-mapping:'
  grep -qxF '      base-path: /' "$YML"
  grep -qxF '        include: info,prometheus,opshealth' "$YML"
  grep -qxF '        opshealth: health' "$YML"
  grep -qxF '        prometheus: metrics' "$YML"
}

@test "both endpoint operations carry @ReadOperation" {
  # Without it the method is not an operation at all: the class still compiles, the
  # bean still registers, @Endpoint still passes every other test here, and the path
  # 404s. This is the mechanism the whole endpoint design rests on.
  run grep -cE '^  @ReadOperation$' "$ENDPOINT"
  [ "$output" -eq 2 ]
}

@test "the two probes are served from one selector operation" {
  grep -qE '^  public WebEndpointResponse<Health> probe\(@Selector String probe\) \{$' "$ENDPOINT"
  grep -q 'case "live" ->' "$ENDPOINT"
  grep -q 'case "ready" ->' "$ENDPOINT"
  # Anything else must 404 rather than silently answer as one of the two.
  grep -q 'default -> new WebEndpointResponse<>(WebEndpointResponse.STATUS_NOT_FOUND)' "$ENDPOINT"
}

@test "/health always answers 200 -- the verdict is in the body" {
  # The aggregate operation returns the body directly (no WebEndpointResponse), so
  # it cannot accidentally acquire a 503 the checker would reject.
  grep -qE '^  public Aggregate health\(\) \{$' "$ENDPOINT"
}

@test "the probes use the contract's binary vocabulary, with the polarity pinned" {
  # ops-api's probe envelope is {"status":"ok"} with 200 and {"status":"down"} with
  # 503. Both ARMS are asserted: pinning only the 503 arm would pass an inverted
  # ternary that reports every healthy pod as down.
  grep -q 'private static final Health OK = new Health("ok");' "$ENDPOINT"
  grep -q 'private static final Health DOWN = new Health("down");' "$ENDPOINT"
  local respond
  respond="$(sed -n '/private static WebEndpointResponse<Health> respond/,/^  }/p' "$ENDPOINT")"
  [ -n "$respond" ]
  contains "$respond" '? new WebEndpointResponse<>(OK, WebEndpointResponse.STATUS_OK)'
  contains "$respond" ': new WebEndpointResponse<>(DOWN, WebEndpointResponse.STATUS_SERVICE_UNAVAILABLE)'
}

@test "liveness is dependency-free" {
  # A dependency check in liveness turns a transient outage into a restart storm.
  grep -q 'case "live" -> respond(availability.getLivenessState() == LivenessState.CORRECT)' \
    "$ENDPOINT"
  grep -q 'case "ready" -> respond(health.ready())' "$ENDPOINT"
}

@test "the ops-api JSON field names are pinned to the record signatures" {
  # Jackson derives the wire keys from the record components, so renaming `since`
  # to `changedAt` compiles, starts, and breaks every consumer plus the
  # conformance checker (which reads .value.kind, .value.breaker, .status).
  grep -qF 'public record Component(String status, String kind, String breaker, String since) {}' \
    "$HEALTH"
  grep -qF 'public record Health(String status) {}' "$ENDPOINT"
  grep -qF 'public record Aggregate(String status, Map<String, DependencyHealth.Component> components) {}' \
    "$ENDPOINT"
}

@test "breaker state maps onto the contract's exact status vocabulary" {
  grep -q 'case OPEN, FORCED_OPEN -> "down";' "$HEALTH"
  grep -q 'case HALF_OPEN -> "degraded";' "$HEALTH"
  grep -q 'case CLOSED, DISABLED, METRICS_ONLY -> "up";' "$HEALTH"
  # All three arms of the `breaker` field too -- it is a validated ops-api value,
  # so a drift to "OPEN" or "opened" fails in the adopter's CI, not here.
  grep -q 'case OPEN, FORCED_OPEN -> "open";' "$HEALTH"
  grep -q 'case HALF_OPEN -> "half_open";' "$HEALTH"
  grep -q 'case CLOSED, DISABLED, METRICS_ONLY -> "closed";' "$HEALTH"
}

@test "the kind field is lower-cased for the wire" {
  # Every hard/soft decision downstream compares against the lower-case form, and
  # the checker rejects anything but hard|soft. Drop the toLowerCase and the
  # aggregate never returns down, readiness never fails for a hard dependency, and
  # /health reports ok straight through a hard outage.
  grep -qF 'dep.kind().name().toLowerCase(java.util.Locale.ROOT)' "$HEALTH"
}

@test "the aggregate implements the floor in both directions, and is 'ok' when healthy" {
  # Scoped to aggregate()'s own body so each needle is pinned to its branch, and
  # the verdict (`return "down";`) is asserted, not just the condition that
  # guards it. The healthy value is asserted because "up" there passes every other
  # test here and fails the downstream checker -- ops-api v1.0 shipped "ok".
  local body
  body="$(sed -n '/public String aggregate() {/,/^  }/p' "$HEALTH")"
  [ -n "$body" ]
  contains "$body" 'String floor = "ok";'
  contains "$body" 'if (down && "hard".equals(component.kind())) {'
  contains "$body" 'return "down";'
  # An OR: narrowing it to && silently drops "any dependency degraded => aggregate
  # degraded", so a half-open hard dependency would read "ok".
  contains "$body" 'if (down || "degraded".equals(component.status())) {'
  contains "$body" 'floor = "degraded";'
}

@test "readiness fails only for a hard dependency, with the polarity pinned" {
  # Polarity IS the contract: noneMatch -> anyMatch, or != -> ==, inverts the
  # hard/soft hinge completely while every substring still matches.
  grep -q 'availability.getReadinessState() != ReadinessState.ACCEPTING_TRAFFIC' "$HEALTH"
  grep -q '.noneMatch(c -> "hard".equals(c.kind()) && "down".equals(c.status()));' "$HEALTH"
  run grep -q 'anyMatch' "$HEALTH"
  [ "$status" -eq 1 ]
}

@test "the endpoint serves the contract's application/json, not the actuator vendor type" {
  # Actuator's default puts application/vnd.spring-boot.actuator.v3+json FIRST, so a
  # client that accepts anything gets a media type contracts/ops/v1/openapi.yaml does
  # not declare. Deleting this bean compiles, starts, and passes every other test.
  grep -qE '^  @Bean$' "$ENDPOINT"
  grep -qE '^  EndpointMediaTypes opsApiEndpointMediaTypes\(\) \{$' "$ENDPOINT"
  # BOTH lists, so a produced-only fix does not pass.
  grep -qF 'new EndpointMediaTypes(List.of("application/json"), List.of("application/json"))' \
    "$ENDPOINT"
}

@test "components is omitted entirely when no dependencies are declared" {
  # ops-api v1.0 consumers stay valid only if the key is absent, not empty.
  grep -q 'JsonInclude.Include.NON_NULL' "$ENDPOINT"
  grep -q 'components.isEmpty() ? null : components' "$ENDPOINT"
}

@test "a declared dependency with no breaker fails startup rather than reporting up" {
  # Pin the MECHANISM, not the vocabulary: swapping find(...).orElseThrow(...) for
  # the auto-creating circuitBreaker(...) would make a breaker-less dependency
  # report "up" forever -- the under-reporting the contract forbids.
  grep -qF '.find(dep.breaker())' "$HEALTH"
  grep -q 'orElseThrow(' "$HEALTH"
  grep -q 'IllegalStateException' "$HEALTH"
  # 'but has no' occurs only inside the thrown message; a bare 'has no' would also
  # match an unrelated javadoc sentence and could never fail.
  grep -q 'but has no' "$HEALTH"
  # ...and the validation must actually RUN: without the call, every assertion
  # above still passes while components() falls through to the auto-creating
  # registry.circuitBreaker(...).
  local ctor
  ctor="$(sed -n '/public DependencyHealth($/,/^  }/p' "$HEALTH")"
  [ -n "$ctor" ]
  contains "$ctor" 'subscribe();'
}

@test "state changes are timestamped so the since field is not frozen at boot" {
  # The whole statement, not just the subscription: onStateTransition(event -> {})
  # would register a listener that updates nothing, and every component's `since`
  # would stay fixed at startup -- indistinguishable to a dashboard from a
  # genuinely stable dependency.
  grep -qF 'breaker.getEventPublisher().onStateTransition(event -> since.put(name, now()));' \
    "$HEALTH"
}

@test "the Clock defaults without competing with an application's own Clock bean" {
  grep -qF 'clock.getIfAvailable(Clock::systemUTC)' "$HEALTH"
}

@test "health is read passively -- no scheduled probing, no transitive health calls" {
  run grep -q '@Scheduled' "$HEALTH"
  [ "$status" -eq 1 ]
  run grep -qE 'RestClient|WebClient|RestTemplate' "$HEALTH"
  [ "$status" -eq 1 ]
}

@test "the ops surface binds a separate internal management port" {
  # Scoped to the management block: a top-level `server: port: 9090` would satisfy
  # an unscoped grep while putting the dependency graph on the PUBLIC app port --
  # the information leak the separate port exists to prevent.
  local mgmt
  mgmt="$(block_between '^management:$' '  endpoints:' "$YML")"
  contains "$mgmt" '  server:'
  # Whole-line: 'port: 9090' is a prefix of 'port: 90901'.
  grep -qxF '    port: 9090' "$YML"
}

# ---- the SKILL's placement rules -------------------------------------------

@test "the SKILL keeps the three placement rules that stop a lying health surface" {
  # Each of these is a silent failure if the instruction is lost: an unadapted
  # PricingApiClient breaks the context load, un-replaced example dependencies make
  # /health report dependencies the service does not have, and a lost path-mapping
  # leaves the surface at /opshealth where nothing fetches it.
  local block
  block="$(sed -n '/^\*\*Spring resilience + dependency health (#1141)\.\*\*/,/^`spec-publish.yml` needs/p' "$SKILL")"
  [ -n "$block" ]
  # Prove the range closed, or it ran to the end of SKILL.md and the needles below
  # could be satisfied by text outside the placement-rules section.
  contains "$block" '`spec-publish.yml` needs'
  contains "$block" 'pricing-api.base-url'
  contains "$block" 'appear four times each'
  contains "$block" 'path-mapping.opshealth: health'
}

@test "the payload deliberately does NOT define pricing-api.base-url" {
  # This absence is what makes the adapt-or-omit rule load-bearing; defining it
  # would make an unadapted placement boot, and quietly wire a fictional client.
  run grep -rq "${INCLUDES[@]}" 'pricing-api.base-url:' "$SPRING"
  [ "$status" -eq 1 ]
  grep -rq "${INCLUDES[@]}" 'pricing-api' "$SPRING"
  # ...and the NESTED spelling, which is the form a Spring property would actually
  # take in this yml -- the flat needle above would never see it.
  run grep -qE '^[[:space:]]*base-url:' "$YML"
  [ "$status" -eq 1 ]
}
