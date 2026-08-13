#!/usr/bin/env bats
#
# Structural tests for the canonical NON-Spring Java resilience + dependency-health
# payload (#1142, epic #964 / sub-epic #967).
#
# Like spring-resilience-payload.bats, these are grep-based and offline: the files
# are bootstrap templates copied into a target service, and their RUNTIME behaviour
# is verified downstream by that repo's ops-conformance CI job (this toolchain has
# no JVM and no service to run). What is cheap and worth guarding here is that the
# files the SKILL render blocks name still exist, and that the details which fail
# SILENTLY when broken stay in place -- a payload that compiles and starts but
# reports health wrongly is the failure mode this whole slice exists to prevent.
#
# THREE RULES THIS FILE HOLDS ITSELF TO, inherited from the Spring payload's tests
# because a vacuous assertion here is worse than no assertion (it advertises a
# guard that is not there):
#
#   1. ANCHOR EVERY NEEDLE TO CODE, NOT PROSE. The payload documents its own
#      invariants in comments, so a bare `grep -q '<invariant>'` is satisfied by
#      the comment that explains the line even after the line itself is deleted.
#   2. NEGATIVES PIN STATUS 1, NOT "NOT ZERO". `run ! grep` also passes on grep's
#      error exit 2 (unreadable or missing path), so a renamed payload directory
#      would turn a negative assertion into an unconditional pass. Every negative
#      below is `run grep ...` followed by `[ "$status" -eq 1 ]`.
#   3. SCOPE A NEEDLE TO ITS BLOCK WHEN THE SAME KEY IS LEGAL ELSEWHERE. Both
#      CircuitBreakerConfig and RetryConfig accept `ignoreExceptions`, and the two
#      blocks are adjacent, so a whole-file grep would stay green after a
#      plausible tidy-up moved the stanza to the config where it does nothing.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  JAVA="$REPO_ROOT/development/skills/bootstrap/templates/languages/java"
  RES="$JAVA/resilience"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  CATALOG="$RES/DependencyCatalog.java"
  HEALTH="$RES/DependencyHealth.java"
  CLIENT="$RES/PricingApiClient.java"
  DECL="$RES/resilience-dependencies.properties"
  OPSAPI="$JAVA/ops-api/OpsApi.java"
  CODE_INCLUDES=(--include='*.java' --include='*.kts')
}

# Extract <start-re>..<end-line> from a file and PROVE the range closed. A sed range
# whose end address never matches silently runs to EOF, which turns every
# block-scoped assertion built on it back into the whole-file matching the scoping
# exists to avoid.
block_between() {
  # nl MUST be ANSI-C quoted, not $(printf '\n'): command substitution strips
  # trailing newlines, so the latter expands to the empty string and the anchor
  # silently degrades to a floating suffix match.
  local start_re="$1" end_line="$2" file="$3" block nl=$'\n'
  block="$(sed -n "/${start_re}/,/^${end_line}\$/p" "$file")"
  [ -n "$block" ] || { echo "empty block for ${start_re} -- sed range did not match" >&2; return 1; }
  case "$block" in
    "${end_line}"|*"${nl}${end_line}") : ;;
    *) echo "block for ${start_re} never reached '${end_line}' -- range ran to EOF" >&2; return 1 ;;
  esac
  printf '%s\n' "$block"
}

# The payload documents its own invariants in comments, so a negative assertion
# about CODE must not be reddened -- or greened -- by the prose that explains it.
# Strip Java line and block comments before matching (the payload uses no trailing
# `//` after code, so whole-line filtering is exact here).
code_only() {
  grep -vE '^[[:space:]]*(//|\*|/\*)' "$1"
}

# ---- payload presence ------------------------------------------------------

@test "java resilience payload files exist at the SKILL render paths" {
  [ -f "$RES/build.gradle.kts" ]
  [ -f "$DECL" ]
  [ -f "$CATALOG" ]
  [ -f "$HEALTH" ]
  [ -f "$CLIENT" ]
  [ -f "$RES/README.md" ]
}

@test "every payload .java file keeps the flagged placeholder package" {
  # Java couples a file's package to its directory, so placement MUST re-set it.
  # The flag is what makes an unset package a visible TODO rather than a silent
  # com.example.ops leak into a real service.
  local f
  for f in "$RES"/*.java; do
    grep -q '^package com.example.ops; // <-- CHANGE' "$f" || {
      echo "missing flagged placeholder package in $f" >&2
      return 1
    }
  done
}

@test "the SKILL render commands name every payload file" {
  # Anchored to the fenced render blocks, not to SKILL.md at large: the file is
  # mostly prose, so an unscoped grep would be satisfied by any sentence naming
  # the path even after the file is dropped from the command.
  local blocks f base
  blocks="$(sed -n '/render.zsh" \\/,/^```$/p' "$SKILL")"
  [ -n "$blocks" ]
  for f in "$RES"/*.java "$RES"/build.gradle.kts "$DECL" "$RES"/README.md; do
    base="$(basename "$f")"
    contains "$blocks" "languages/java/resilience/$base"
  done
}

@test "the SKILL states the placement rules whose loss breaks a bootstrapped service" {
  # Naming the files in the render command is not enough: each of these rules is
  # silent when dropped. The properties file outside src/main/resources/ means
  # load() finds nothing -> empty catalog -> /health reports nothing wrong during
  # a total outage; DependencyHealth outside OpsApi's package does not compile
  # against the binding; the worked examples left verbatim make /health report two
  # dependencies the service does not have; and without requireAllDeclaredGuarded
  # a declared-but-unwired dependency reads `up` forever.
  local block
  block="$(sed -n '/^\*\*Java (non-Spring) resilience + dependency health (#1142)\.\*\*/,/^\*\*Spring resilience + dependency health (#1141)\.\*\*/p' "$SKILL")"
  [ -n "$block" ]
  # Prove the range closed, or a renamed Spring heading would silently extend it
  # to EOF and make every needle below match somewhere else in the file.
  contains "$block" '**Spring resilience + dependency health (#1141).**'
  contains "$block" 'src/main/resources/'
  contains "$block" 'SAME package as `OpsApi.java`'
  contains "$block" 'Replace the two worked-example dependencies'
  contains "$block" 'requireAllDeclaredGuarded()'
  contains "$block" 'RESILIENCE.md'
}

@test "the resilience payload's gate is a pure function of the ops-api block's outcome" {
  # The two blocks install together or not at all, so a condition that skips only
  # one of them re-creates the split the pairing exists to prevent (an OpsApi
  # wired to report components with no DependencyHealth to supply them). The
  # library test therefore lives in the OPS-API gate, not here.
  local block
  block="$(sed -n '/^\*\*Java (non-Spring) resilience + dependency health (#1142)\.\*\*/,/^\*\*Spring resilience + dependency health (#1141)\.\*\*/p' "$SKILL")"
  [ -n "$block" ]
  contains "$block" 'outcome and nothing else**'
  # A fresh library case HERE would be the regression.
  lacks "$block" 'A Java LIBRARY rather than a service'
  # ...because the ops-api block owns it.
  local ops_block
  ops_block="$(sed -n '/^\*\*Java canonical implementation (#935)\.\*\*/,/^\*\*Java (non-Spring) resilience/p' "$SKILL")"
  [ -n "$ops_block" ]
  contains "$ops_block" 'A Java LIBRARY rather than a service'
}

@test "PricingApiClient is rendered by its own command, so the omit path can drop it" {
  # It names a dependency the service does not have; if it shared the main render
  # command the omit path could not stage the payload without it.
  local main_block
  main_block="$(sed -n '/languages\/java\/resilience\/build.gradle.kts/,/^```$/p' "$SKILL")"
  [ -n "$main_block" ]
  lacks "$main_block" 'PricingApiClient.java'
}

# ---- the blessed library choice -------------------------------------------

@test "build fragment pins resilience4j through the BOM and declares the two core modules" {
  grep -qE '^[[:space:]]*implementation\(platform\("io\.github\.resilience4j:resilience4j-bom:[0-9]' \
    "$RES/build.gradle.kts"
  grep -qE '^[[:space:]]*implementation\("io\.github\.resilience4j:resilience4j-circuitbreaker"\)' \
    "$RES/build.gradle.kts"
  grep -qE '^[[:space:]]*implementation\("io\.github\.resilience4j:resilience4j-retry"\)' \
    "$RES/build.gradle.kts"
}

@test "resilience4j-all is not used" {
  # It drags in ratelimiter/bulkhead/cache/micrometer for one Decorators builder
  # the two static decorateSupplier calls replace. Scoped to DECLARATION lines:
  # the comment above the block names it to explain the rejection.
  run grep -qE '^[[:space:]]*implementation\(".*resilience4j-all' "$RES/build.gradle.kts"
  [ "$status" -eq 1 ]
}

@test "no Spring or AOP dependency leaks into the non-Spring payload" {
  run grep -rqE "${CODE_INCLUDES[@]}" '^[[:space:]]*implementation\(".*(springframework|resilience4j-spring)' "$RES"
  [ "$status" -eq 1 ]
  # Positive control: grep -r --include also exits 1 when NOTHING matched the
  # filters, so without this an unscannable payload dir would "prove" the absence.
  grep -rq "${CODE_INCLUDES[@]}" 'implementation(' "$RES"
}

@test "the annotation-driven API is not used (there is no AOP to weave it outside Spring)" {
  run grep -rqE "${CODE_INCLUDES[@]}" '^[[:space:]]*@(CircuitBreaker|Retry)\(' "$RES"
  [ "$status" -eq 1 ]
  grep -rq "${CODE_INCLUDES[@]}" 'class ' "$RES"
}

# ---- the two silent-failure wiring rules -----------------------------------

@test "the decoration order is fallback(retry(breaker(call)))" {
  # The breaker must be INNERMOST so its failure-rate window counts individual
  # attempts, and retry OUTSIDE it -- the same nesting Spring's aspect order
  # produces. Pinned as the single composed expression, so swapping the two
  # (which still compiles, still runs, and silently stops retrying correctly)
  # reddens here.
  grep -qF 'Retry.decorateSupplier(retry, CircuitBreaker.decorateSupplier(breaker, call))' "$CATALOG"
  # And the fallback is outermost: it lives in the catch around the composed
  # supplier, never inside the decoration.
  grep -qE '^[[:space:]]*return fallback\.apply\(failure\);$' "$CATALOG"
}

@test "retry ignores CallNotPermittedException, inside the RETRY config block" {
  # `ignoreExceptions` is legal on CircuitBreakerConfig too, and the two blocks are
  # adjacent -- moving the stanza there is a plausible tidy-up that would keep a
  # whole-file grep green while mandate 6's fast-fail is gone.
  local retry
  retry="$(block_between 'RetryConfig RETRY_CONFIG =' '          .build();' "$CATALOG")"
  contains "$retry" 'ignoreExceptions(CallNotPermittedException.class, NotADependencyFailure.class)'
}

@test "only RuntimeException is caught, so an Error is never swallowed by a fallback" {
  grep -qE '^[[:space:]]*\} catch \(RuntimeException failure\) \{$' "$CATALOG"
  # [[:space:]] rather than \b: \b is a GNU extension, and where it is not honoured
  # the pattern can never match, so the negative would pass unconditionally --
  # vacuous on the macOS leg while enforced on ubuntu. A catch clause always has
  # whitespace before its parameter name.
  run grep -qE '^[[:space:]]*\} catch \((Throwable|Error)[[:space:]]' "$CATALOG"
  [ "$status" -eq 1 ]
}

# ---- the mandates that live in configuration --------------------------------

@test "background reconnect is enabled (mandate 5)" {
  # Without it a breaker leaves OPEN only when a call arrives after the wait
  # duration, so a dependency that lost all its traffic while down stays reported
  # down forever. Anchored to the builder call, not the comment explaining it.
  grep -qE '^[[:space:]]*\.automaticTransitionFromOpenToHalfOpenEnabled\(true\)$' "$CATALOG"
}

@test "the retry is BOUNDED and JITTERED (mandate 3)" {
  # PIN THE VALUE, not just "some integer": `.maxAttempts([0-9]+)` passes on
  # maxAttempts(30), i.e. on the retry storm the test is named after.
  grep -qE '^[[:space:]]*\.maxAttempts\(3\)$' "$CATALOG"
  # ofExponentialBackoff (no jitter) is the one-word edit that removes the
  # randomization and re-creates the thundering herd, so pin the RANDOM variant --
  # AND its arguments: a randomization factor quietly edited to 0.0d is the same
  # regression with the same function name.
  grep -qF 'IntervalFunction.ofExponentialRandomBackoff(' "$CATALOG"
  grep -qF 'Duration.ofMillis(200), 2.0d, 0.5d, Duration.ofSeconds(2)' "$CATALOG"
}

@test "the breaker's blessed knobs are pinned, including the slow-call thresholds" {
  # Block-scoped: `.build();` at this indentation is shared with the retry config
  # below, so an unscoped needle would not prove which config carries what.
  local breaker
  breaker="$(block_between 'CircuitBreakerConfig BREAKER_CONFIG =' '          .build();' "$CATALOG")"
  contains "$breaker" '.slidingWindowType(CircuitBreakerConfig.SlidingWindowType.COUNT_BASED)'
  contains "$breaker" '.slidingWindowSize(20)'
  contains "$breaker" '.minimumNumberOfCalls(10)'
  contains "$breaker" '.failureRateThreshold(50f)'
  contains "$breaker" '.waitDurationInOpenState(Duration.ofSeconds(10))'
  contains "$breaker" '.permittedNumberOfCallsInHalfOpenState(3)'
  # The slow-call half is the one whose ABSENCE is invisible: a brownout produces
  # a 0% failure rate, so without these a breaker never opens while every request
  # blocks and /health still reports the dependency up.
  contains "$breaker" '.slowCallDurationThreshold(Duration.ofSeconds(2))'
  contains "$breaker" '.slowCallRateThreshold(100f)'
}

@test "a caller error is excluded from BOTH the breaker and the retry" {
  # NotADependencyFailure in only one of the two configs is worse than in neither,
  # because the remaining half still misattributes user input to the dependency --
  # so assert it in each block separately rather than once over the file.
  local breaker retry
  breaker="$(block_between 'CircuitBreakerConfig BREAKER_CONFIG =' '          .build();' "$CATALOG")"
  retry="$(block_between 'RetryConfig RETRY_CONFIG =' '          .build();' "$CATALOG")"
  contains "$breaker" '.ignoreExceptions(CallNotPermittedException.class, NotADependencyFailure.class)'
  contains "$retry" '.ignoreExceptions(CallNotPermittedException.class, NotADependencyFailure.class)'
  # And the worked client actually raises it for the two cases it exists for.
  # Scoped per SITE: one whole-file needle is satisfied by EITHER throw, so
  # reverting the interrupt one to a retryable type would stay green -- and that is
  # the worse regression (the backoff's Thread.sleep clears the interrupt flag).
  local fetch flat
  fetch="$(block_between 'private PriceQuote fetch(String sku)' '  }' "$CLIENT")"
  contains "$fetch" 'new DependencyCatalog.NotADependencyFailure("interrupted while calling pricing-api", e)'
  contains "$fetch" '(caller error)'
  # ORDER: the 4xx branch is only a caller-error branch because it precedes the
  # non-2xx one. Swap them and every 404 becomes a recorded dependency failure again.
  flat="$(printf '%s' "$fetch" | tr -d '[:space:]')"
  contains "$flat" 'if(status/100==4){thrownewDependencyCatalog.NotADependencyFailure('
  lacks "${flat%%if(status/100==4)*}" 'if(status/100!=2)'
}

@test "one breaker PER DEPENDENCY, created eagerly at construction" {
  # Lazy-by-name registries mean an uncalled dependency would have no breaker for
  # DependencyHealth to read and would be missing from /health entirely.
  local ctor
  ctor="$(block_between 'private DependencyCatalog($' '  }' "$CATALOG")"
  contains "$ctor" 'breakers.circuitBreaker(name)'
  contains "$ctor" 'retries.retry(name)'
}

# ---- the declaration and its guards ----------------------------------------

@test "the declaration file uses <name>=hard|soft and ships both worked examples" {
  grep -qE '^orders-db=hard$' "$DECL"
  grep -qE '^pricing-api=soft$' "$DECL"
}

@test "an unreadable declaration file is a startup failure, not silently empty" {
  # Degrading a mistyped mount path to "no dependencies" would produce a health
  # surface that reports nothing wrong during a total outage.
  #
  # PIN THE BRANCH-UNIQUE MESSAGES, not the bare `throw new UncheckedIOException(`:
  # load() throws that type in TWO places, so replacing the FILE branch's throw
  # with a silent empty catalog -- the exact regression named above -- would leave
  # the classpath branch's throw satisfying a whole-file needle.
  grep -qF 'cannot read the dependency declaration named by ' "$CATALOG"
  grep -qF 'cannot read classpath ' "$CATALOG"
  grep -qE '^[[:space:]]*public static final String FILE_ENV = "OPS_DEPENDENCIES_FILE";$' "$CATALOG"
}

@test "a dependency guarded in code but undeclared is refused" {
  # Scoped to the method: the two needles were previously unrelated whole-file
  # matches that only worked because the file happened to hold exactly one
  # IllegalStateException, and would go vacuous the moment a second one appeared.
  local req
  req="$(block_between 'public String requireDeclared(String name)' '  }' "$CATALOG")"
  contains "$req" 'if (!dependencies.containsKey(name))'
  contains "$req" 'throw new IllegalStateException('
  contains "$req" 'is guarded in code but not declared'
  # And the worked client actually calls it from its CONSTRUCTOR, which is what
  # turns the refusal into a boot failure rather than a first-request failure.
  local ctor
  ctor="$(block_between 'public PricingApiClient(DependencyCatalog catalog, URI baseUrl)' '  }' "$CLIENT")"
  contains "$ctor" 'catalog.requireDeclared(DEPENDENCY);'
}

@test "a dependency declared but guarded by NOBODY is refused too" {
  # The mirror guard, and the one an adopter who keeps the shipped declaration
  # actually hits: the name gets an eager breaker that nothing ever calls through,
  # so it stays CLOSED forever and /health reports it `up` during a total outage.
  local all
  all="$(block_between 'public void requireAllDeclaredGuarded()' '  }' "$CATALOG")"
  contains "$all" '!guarded.contains(name)'
  contains "$all" 'throw new IllegalStateException('
  contains "$all" 'declared but not guarded by any client'
  # requireDeclared must actually RECORD the claim, or the guard above can never pass.
  local req
  req="$(block_between 'public String requireDeclared(String name)' '  }' "$CATALOG")"
  contains "$req" 'guarded.add(name);'
}

@test "the declaration parser's branches are all guarded" {
  local parse
  parse="$(block_between 'private static Map<String, Kind> parse(List<String> lines)' '  }' "$CATALOG")"
  # The comment-skip is load-bearing: the shipped .properties is ~35 comment lines
  # plus 2 entries, so losing this branch bricks EVERY bootstrapped service at boot.
  contains "$parse" 'if (line.isEmpty() || line.startsWith("#")) {'
  contains "$parse" 'want <name>=hard|soft'
  # LinkedHashMap, not Properties: order is what /health reports in, and Properties
  # is an unordered Hashtable whose stream form also decodes ISO-8859-1.
  contains "$parse" 'new LinkedHashMap<>()'
  run grep -q 'java.util.Properties;' "$CATALOG"
  [ "$status" -eq 1 ]
  # The legitimately-empty path is what makes the components-omission reachable.
  grep -qF 'return new DependencyCatalog(Map.of(), BREAKER_CONFIG, RETRY_CONFIG);' "$CATALOG"
}

@test "the kind is lower-cased for the wire" {
  # wire() is what turns HARD/SOFT into the contract's hard/soft, and every
  # downstream decision compares against the lower-case form. A tidy-up to
  # `return name();` compiles, starts, and silently disarms readiness AND the
  # aggregate while emitting a kind the conformance checker rejects.
  local kind
  kind="$(block_between 'public enum Kind {' '  }' "$CATALOG")"
  contains "$kind" 'return name().toLowerCase(Locale.ROOT);'
  contains "$kind" 'case "hard" -> HARD;'
  contains "$kind" 'case "soft" -> SOFT;'
}

@test "an unknown kind is loud, not defaulted" {
  # Defaulting an unparseable kind to soft would silently disarm readiness for a
  # dependency someone meant to declare hard.
  grep -qF 'want hard|soft' "$CATALOG"
  run grep -qE '^[[:space:]]*default -> (HARD|SOFT);$' "$CATALOG"
  [ "$status" -eq 1 ]
}

# ---- breaker state -> ops-api status ---------------------------------------

@test "all six breaker states map to the contract's three statuses" {
  # resilience4j has six states and the contract names three. A missing arm is a
  # compile error in the switch, but a WRONG arm is silent -- FORCED_OPEN reading
  # `up` would hide an operator-forced outage.
  grep -qE '^[[:space:]]*case OPEN, FORCED_OPEN -> "down";$' "$HEALTH"
  grep -qE '^[[:space:]]*case HALF_OPEN -> "degraded";$' "$HEALTH"
  grep -qE '^[[:space:]]*case CLOSED, DISABLED, METRICS_ONLY -> "up";$' "$HEALTH"
}

@test "the breaker field reports the contract's three-value vocabulary" {
  grep -qE '^[[:space:]]*case OPEN, FORCED_OPEN -> "open";$' "$HEALTH"
  grep -qE '^[[:space:]]*case HALF_OPEN -> "half_open";$' "$HEALTH"
  grep -qE '^[[:space:]]*case CLOSED, DISABLED, METRICS_ONLY -> "closed";$' "$HEALTH"
}

@test "dependency health is PASSIVE -- it never calls a dependency or a downstream /health" {
  # The health-check-storm anti-pattern: one slow leaf hanging every ancestor.
  # Comment-stripped, because the file's own prose names /health repeatedly to
  # explain the rule -- matching that would redden a correct payload.
  # Counted rather than `run grep`: the needle is a PIPELINE, whose stdin is always
  # readable, so grep's exit 2 (the case rule 2 guards against) cannot arise here.
  local hits
  hits="$(code_only "$HEALTH" | grep -cE '(HttpClient|HttpURLConnection|URI|\.send\()' || true)"
  [ "$hits" -eq 0 ]
  # Positive control: the stripped file is still non-empty and is the right one.
  code_only "$HEALTH" | grep -q 'class DependencyHealth'
}

# ---- the OpsApi binding (#1142 extends #935) --------------------------------

@test "OpsApi serves /health from the aggregate handler, not the readiness handler" {
  # This IS the #1139 Java fix: /health must answer 200 with the verdict in the
  # body. Routing it back to readinessHandler would 503 during an outage, which
  # the contract forbids and check-ops-conformance.zsh rejects.
  grep -qE '^[[:space:]]*server\.createContext\("/health", healthHandler\(config\)\);$' "$OPSAPI"
  grep -qE '^[[:space:]]*server\.createContext\("/health/ready", readinessHandler\(config\)\);$' "$OPSAPI"
}

@test "/health answers 200 even when the aggregate is down" {
  local handler
  handler="$(block_between 'private static HttpHandler healthHandler(OpsConfig config)' '  }' "$OPSAPI")"
  contains "$handler" 'respond(exchange, 200, "application/json", body);'
  # A 503 anywhere in this handler would mean the verdict moved back into the
  # status code. (405 for a non-GET is the shared method guard and stays.)
  lacks "$handler" '503'
  # ONE snapshot per request: re-reading config.components() for the aggregate and
  # again for the map lets a breaker flip mid-request and produce a body whose
  # headline contradicts its own component list.
  contains "$handler" 'body = config.healthJson(config.components());'
  # A throwing dependency source must report `down`, not `ok` and not an empty
  # 200 -- reporting healthy because the health source itself broke is exactly the
  # under-reporting the contract forbids.
  contains "$handler" '} catch (RuntimeException e) {'
  contains "$handler" 'body = "{\"status\":\"down\"}";'
}

@test "the DependencyHealth -> ops-api record mapping cannot be silently transposed" {
  # All four record components are String, so ANY permutation compiles and starts:
  # swapping args 2 and 3 emits {"kind":"closed","breaker":"hard"}, which breaks
  # readiness, the aggregate and the conformance checker with nothing reddening.
  grep -qF 'public record Dependency(String status, String kind, String breaker, String since) {}' "$OPSAPI"
  local ctor flat
  ctor="$(block_between 'out.put($' '                      rfc3339(since.getOrDefault(name, now()))));' "$HEALTH")"
  # ORDER IS THE ASSERTION. Three independent `contains` are all satisfied by a
  # transposition -- the very regression this test is named for -- so normalize the
  # whitespace and pin the argument SEQUENCE as one needle. Also reformat-proof.
  flat="$(printf '%s' "$ctor" | tr -d '[:space:]')"
  contains "$flat" 'newOpsApi.Dependency(statusOf(state),kind.wire(),breakerOf(state),rfc3339('
}

@test "the aggregate's worst-wins comparator and enum order are pinned" {
  # aggregate() never compares statuses directly -- it calls Status.max, which is
  # `a.ordinal() >= b.ordinal()`. So the verdict rests entirely on the CONSTANT
  # ORDER. An alphabetical tidy-up to DEGRADED, DOWN, OK keeps all three wire-value
  # assertions green while max() starts returning OK as the worst, and /health then
  # reports "ok" straight through a hard dependency being down.
  local status_enum flat
  status_enum="$(block_between 'public enum Status {' '  }' "$OPSAPI")"
  flat="$(printf '%s' "$status_enum" | tr -d '[:space:]')"
  contains "$flat" 'OK("ok"),DEGRADED("degraded"),DOWN("down");'
  # And the comparator itself: flipping >= to <= is the same silent inversion.
  grep -qF 'return a.ordinal() >= b.ordinal() ? a : b;' "$OPSAPI"
}

@test "the worked client encodes the SKU and preserves the base path" {
  # Both traps turn CALLER input into a reported dependency outage: an unencoded SKU
  # makes URI throw INSIDE the guarded supplier (recorded as a dependency failure),
  # and resolving an ABSOLUTE path discards the base path, so a service behind a
  # gateway prefix silently calls the wrong endpoint.
  local uri
  uri="$(block_between 'private URI priceUri(String sku)' '  }' "$CLIENT")"
  contains "$uri" 'base.endsWith("/") ? base : base + "/"'
  contains "$uri" 'URLEncoder.encode(sku, StandardCharsets.UTF_8).replace("+", "%20")'
  # RELATIVE -- a leading slash is what discards the base path.
  contains "$uri" '.resolve("v1/prices/"'
  # Comment-stripped: priceUri's own javadoc quotes the absolute-resolve trap as
  # the thing NOT to do, so a raw whole-file negative matches the explanation.
  local abs
  abs="$(code_only "$CLIENT" | grep -cF '.resolve("/v1/prices/' || true)"
  [ "$abs" -eq 0 ]
}

@test "the three-arg of() overload exists and the ctor actually uses its parameters" {
  # The seam for a third-party client's own not-a-failure type. A ctor regression to
  # the CONSTANTS compiles, starts, keeps every other assertion green, and silently
  # discards the adopter's extra ignoreExceptions.
  local ctor
  ctor="$(block_between 'private DependencyCatalog($' '  }' "$CATALOG")"
  contains "$ctor" 'CircuitBreakerRegistry.of(breakerConfig)'
  contains "$ctor" 'RetryRegistry.of(retryConfig)'
  grep -qF 'Map<String, Kind> dependencies, CircuitBreakerConfig breakerConfig, RetryConfig retryConfig) {' "$CATALOG"
  grep -qF 'return new DependencyCatalog(dependencies, breakerConfig, retryConfig);' "$CATALOG"
}

@test "the emitted /health JSON keys are the contract's" {
  # Renaming any of them compiles and breaks every consumer.
  # Since ops-api v2 (#1330) the component serialization lives in appendComponents,
  # shared by the /health aggregate and the readiness problem body — one serializer,
  # so a shed pod and the dashboard cannot disagree about a dependency's shape.
  local components_json
  components_json="$(block_between 'private static void appendComponents(StringBuilder json, Map<String, Dependency> components)' '    }' "$OPSAPI")"
  contains "$components_json" '",\"components\":{"'
  contains "$components_json" '"\"status\":"'
  contains "$components_json" '",\"kind\":"'
  contains "$components_json" '",\"breaker\":"'
  contains "$components_json" '",\"since\":"'
  # …and both bodies really do go through it.
  local health_json
  health_json="$(block_between 'String healthJson(Map<String, Dependency> components)' '    }' "$OPSAPI")"
  contains "$health_json" 'appendComponents(json, components);'
  local problem_json
  problem_json="$(block_between 'String readinessProblemJson(Map<String, Dependency> components)' '    }' "$OPSAPI")"
  contains "$problem_json" 'appendComponents(json, components);'
}

@test "the since timestamp tracks state transitions rather than freezing at boot" {
  # Replace the lambda body with a no-op and every component's `since` freezes at
  # process start -- indistinguishable on a dashboard from a genuinely stable
  # dependency, which is the entire reason the field exists.
  grep -qF '.onStateTransition(event -> since.put(name, now()));' "$HEALTH"
  grep -qF 'since.put(name, startedAt);' "$HEALTH"
  grep -qF 'truncatedTo(ChronoUnit.MILLIS)' "$HEALTH"
}

@test "the no-dependencies default path is preserved for existing #935 adopters" {
  # OpsApi promises it "behaves exactly as before" without this payload; three
  # things carry that promise and all three are silent when broken.
  grep -qF 'this(version, gitSha, servedMajors, readiness, Map::of, () -> Status.OK);' "$OPSAPI"
  grep -qF 'return snapshot == null ? Map.of() : snapshot;' "$OPSAPI"
}

@test "the aggregate floor is hard-down => down, any down/degraded => degraded" {
  local aggregate
  aggregate="$(block_between 'Status aggregate(Map<String, Dependency> components)' '    }' "$OPSAPI")"
  contains "$aggregate" 'if (down && "hard".equals(d.kind()))'
  contains "$aggregate" 'Status.max(status, Status.DOWN)'
  contains "$aggregate" 'Status.max(status, Status.DEGRADED)'
  # THE DISJUNCTION IS THE CONTRACT. Narrowing `||` to `&&`, or dropping the
  # degraded arm, leaves all three needles above matching while a half-open HARD
  # dependency reports a clean "ok" straight through a partial outage.
  contains "$aggregate" '} else if (down || "degraded".equals(d.status())) {'
  # The over-reporting hook seeds the floor; losing it silently caps the aggregate
  # at whatever the dependencies say, which the contract explicitly forbids.
  contains "$aggregate" 'Status status = internalStatus.get();'
}

@test "the aggregate wire values are the contract's exact spellings" {
  # "up" passes every other test in this file and fails the conformance checker:
  # the healthy aggregate is "ok", and has been since ops-api v1.0.
  grep -qE '^[[:space:]]*OK\("ok"\),$' "$OPSAPI"
  grep -qE '^[[:space:]]*DEGRADED\("degraded"\),$' "$OPSAPI"
  grep -qE '^[[:space:]]*DOWN\("down"\);$' "$OPSAPI"
}

@test "readiness fails on a HARD dependency down and never on a SOFT one" {
  local ready
  ready="$(block_between 'boolean ready(Map<String, Dependency> components)' '    }' "$OPSAPI")"
  # POLARITY IS THE CONTRACT: the predicate alone matches whether the terminal is
  # noneMatch or anyMatch, and flipping it makes every pod with a HEALTHY hard
  # dependency report unready. Pin the whole terminal, and the non-dependency
  # half's polarity with it.
  contains "$ready" '.noneMatch(d -> "hard".equals(d.kind()) && "down".equals(d.status()));'
  contains "$ready" 'if (!readiness.getAsBoolean()) {'
  run grep -q 'anyMatch' "$OPSAPI"
  [ "$status" -eq 1 ]
  # `soft` must not appear: any mention would mean a soft dependency can influence
  # readiness, which inverts the whole hard/soft hinge.
  lacks "$ready" 'soft'
}

@test "the readiness PROBE still answers 200/503 with the right bodies" {
  # The #1139 rework moved /health off this handler; the probe must keep speaking
  # in status codes. Pinning one arm only would pass an inverted ternary, which
  # reports every unready pod as ready and routes traffic into a dead hard
  # dependency -- so pin both arms and the polarity together.
  local ready_h
  ready_h="$(block_between 'private static HttpHandler readinessHandler(OpsConfig config)' '  }' "$OPSAPI")"
  # The snapshot is read ONCE and reused for the verdict and the body: calling
  # components() again would re-enter the source, and the 503 could then name a
  # dependency the verdict was not taken on.
  contains "$ready_h" 'components = config.components();'
  contains "$ready_h" 'ready = config.ready(components);'
  lacks "$ready_h" 'ready = config.ready(config.components());'
  # ops-api v2 (#1330): 200 keeps the health envelope; the 503 is an RFC 9457
  # problem document on application/problem+json. Bare-ness is part of the
  # contract — a correctly shaped body on application/json is still an
  # org-problem-json-errors failure.
  contains "$ready_h" 'respond(exchange, 200, "application/json", "{\"status\":\"ok\"}");'
  contains "$ready_h" 'body = config.readinessProblemJson(components);'
  contains "$ready_h" 'respond(exchange, 503, "application/problem+json", body);'
  lacks "$ready_h" '"{\"status\":\"down\"}"'
  # A throwing dependency probe must degrade to 503, never an aborted connection —
  # and must reset the snapshot so a half-read map cannot reach the problem body.
  contains "$ready_h" '} catch (RuntimeException e) {'
  contains "$ready_h" 'ready = false;'
  contains "$ready_h" 'components = Map.of();'
}

@test "the java readiness detail is canonical and lexicographically sorted" {
  # The wording is asserted by the conformance checker and the acceptance lane, so
  # it is a contract string, not prose. The sort is what makes it deterministic:
  # without it the same outage yields different bodies on different pods.
  local detail
  detail="$(block_between 'static String readinessDetail(Map<String, Dependency> components)' '  }' "$OPSAPI")"
  contains "$detail" 'Collections.sort(down);'
  contains "$detail" '"hard dependency " + joined + " is down"'
  contains "$detail" '"hard dependencies " + joined + " are down"'
  contains "$detail" 'return DETAIL_STARTING_UP;'
  grep -qF 'static final String DETAIL_STARTING_UP = "the service is starting up";' "$OPSAPI"
  grep -qF 'static final String DETAIL_DRAINING = "the service is draining";' "$OPSAPI"
  # Host-free URNs: a docs URL here would ship a link that rots when the site moves.
  grep -qF 'static final String PROBLEM_TYPE_NOT_READY = "urn:problem-type:ops:not-ready";' "$OPSAPI"
  grep -qF 'static final String PROBLEM_TYPE_NOT_ALIVE = "urn:problem-type:ops:not-alive";' "$OPSAPI"
}

@test "components is omitted entirely when the service declares no dependencies" {
  # An ops-api v1.0 consumer must stay valid, and `"components":{}` is not the
  # same as an absent field.
  # The guard moved into appendComponents with the serialization (#1330), so it now
  # protects the readiness problem body too: a 503 raised for a non-dependency
  # reason carries no components member either.
  local components_json
  components_json="$(block_between 'private static void appendComponents(StringBuilder json, Map<String, Dependency> components)' '    }' "$OPSAPI")"
  contains "$components_json" 'if (components.isEmpty()) {'
  contains "$components_json" 'return;'
}

@test "OpsApi carries no breaker-library import, so it stands alone without this payload" {
  # The binding is an interface over plain records precisely so a service with no
  # outbound dependencies can serve the ops surface without resilience4j.
  run grep -qE '^import io\.github\.resilience4j' "$OPSAPI"
  [ "$status" -eq 1 ]
  grep -qE '^import ' "$OPSAPI"
}

@test "DependencyHealth implements the OpsApi binding interface" {
  # Anchored to the DECLARATION line: the file's own header comment contains the
  # literal string "implements OpsApi.DependencyHealthSource", so a whole-file
  # needle survives the clause being deleted outright.
  grep -qE '^public final class DependencyHealth implements OpsApi\.DependencyHealthSource \{$' "$HEALTH"
  grep -qE '^[[:space:]]*Map<String, Dependency> components\(\);$' "$OPSAPI"
}

# ---- the worked client's own mandate (timeouts) -----------------------------

@test "the worked client sets BOTH timeouts (mandate 1)" {
  # connectTimeout alone leaves the classic overloaded-dependency shape unbounded:
  # the socket is accepted and then never answered. The breaker cannot save you --
  # a call that never returns never fails, so it never counts toward the rate.
  grep -qE '^[[:space:]]*this\.http = HttpClient\.newBuilder\(\)\.connectTimeout\(' "$CLIENT"
  grep -qF '.timeout(Duration.ofSeconds(3))' "$CLIENT"
  # The request timeout must stay ABOVE the breaker's slow-call threshold, or the
  # transport gives up before a call is ever recorded as slow and the slow-call
  # half of the breaker config can never fire.
  grep -qF '.slowCallDurationThreshold(Duration.ofSeconds(2))' "$CATALOG"
}

@test "the worked client turns a non-2xx into a failure the breaker records" {
  # java.net.http does NOT throw on 4xx/5xx (unlike Spring's RestClient), so
  # without this a broken dependency returns 503 to every call and the breaker
  # never sees a failure.
  grep -qE '^[[:space:]]*if \(status / 100 != 2\) \{$' "$CLIENT"
}

@test "the metrics proxy does not pin a carrier thread" {
  # HttpURLConnection does its blocking I/O inside synchronized methods, which on
  # JDK 21 pins the carrier for the whole read. On a 1-CPU pod that blocks every
  # other virtual thread -- including the two probe handlers the dedicated executor
  # exists to protect. Reverting is a silent latency/restart bug, so pin both the
  # positive (HttpClient) and the negative (no HttpURLConnection anywhere).
  local proxy flatc
  proxy="$(block_between 'private static HttpHandler metricsProxy(URI upstream)' '  }' "$OPSAPI")"
  contains "$proxy" 'client.send(request.build(), HttpResponse.BodyHandlers.ofByteArray())'
  local pinning
  pinning="$(code_only "$OPSAPI" | grep -cF 'HttpURLConnection' || true)"
  [ "$pinning" -eq 0 ]
  # ONE haystack for every needle below, and it is COMMENT-STRIPPED: this method's
  # comments quote `headersSent` and the 502 at length, and `tr -d [:space:]` alone
  # leaves that prose in -- which would let a comment satisfy a code assertion
  # (rule 1) or inflate a count.
  flatc="$(printf '%s\n' "$proxy" | grep -vE '^[[:space:]]*//' | tr -d '[:space:]')"
  # headersSent must flip AFTER the headers are on the wire, or a pre-send failure
  # skips the 502 it exists to enable.
  contains "$flatc" 'exchange.sendResponseHeaders(response.statusCode(),payload.length==0?-1:payload.length);'
  lacks "${flatc%%exchange.sendResponseHeaders*}" 'headersSent=true;'
  # HttpClient has NO client-level read timeout, so the PER-REQUEST one is the only
  # bound on a wedged exporter. Dropping it compiles and re-creates the unbounded
  # call this whole payload teaches against -- one parked virtual thread and one
  # un-closed exchange per scrape.
  contains "$flatc" 'HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();'
  contains "$flatc" 'HttpRequest.newBuilder(upstream).timeout(Duration.ofSeconds(5)).GET();'
  # The 502 must be present on BOTH catch arms, or a dead exporter becomes a
  # silently dropped connection that check-ops-conformance.zsh misreads. Count the
  # WHOLE respond call, not the guard and not the message: counting `if(!headersSent){`
  # alone stays at 2 when an arm's body is emptied, and a bare message needle never
  # pins the status code (200 or 503 would sail through).
  local five02
  five02="$(printf '%s' "$flatc" | grep -oF 'respond(exchange,502,"application/json","{\"error\":\"metricsupstreamunavailable\"}");' | wc -l | tr -d ' ')"
  [ "$five02" -eq 2 ]
  # The count pins the TOTAL, not the DISTRIBUTION or the guard, so pin each arm
  # whole -- guard, call, status and message together. Without this, deleting an
  # arm's `if (!headersSent)` wrapper ships green, and respond() then runs after the
  # headers are already on the wire: the second sendResponseHeaders throws out of
  # the handler on every client-gone-mid-scrape. Moving one arm's 502 into the other
  # also keeps the total at 2.
  contains "$flatc" 'catch(IOExceptione){if(!headersSent){respond(exchange,502,"application/json","{\"error\":\"metricsupstreamunavailable\"}");}}'
  contains "$flatc" 'if(!headersSent){try{respond(exchange,502,"application/json","{\"error\":\"metricsupstreamunavailable\"}");}catch(IOExceptionignored){}}'
  # The interrupt arm exists only because of the HttpClient switch (HttpURLConnection
  # never threw InterruptedException). The flag must be restored in a FINALLY, and
  # the 502 attempted BEFORE it: restoring first makes the write throw
  # ClosedByInterruptException out of this arm on every drained scrape.
  contains "$flatc" '}finally{Thread.currentThread().interrupt();}'
  # SCOPE THE ORDERING CHECK TO THE ARM. Truncating the whole method at its first
  # `respond(` lands on the 405 method-guard near the top, leaving a prefix that
  # could never contain an interrupt restore -- an assertion that always passes.
  local irq_arm
  irq_arm="${flatc#*catch(InterruptedExceptione){}"
  # Load-bearing: `#*pat` returns the value UNCHANGED when the pattern misses, which
  # would silently restore that always-pass behaviour if the arm is ever renamed.
  [ "$irq_arm" != "$flatc" ]
  lacks "${irq_arm%%respond(*}" 'Thread.currentThread().interrupt();'
  contains "$flatc" '}finally{exchange.close();}'
}

@test "mandate 1 is documented for NON-HTTP dependencies too" {
  # The payload ships orders-db=hard, and a pool's connectionTimeout does NOT bound
  # a query already on the wire -- the same unbounded-call shape the HTTP guidance
  # warns about, on the dependency whose loss sheds all traffic.
  grep -qF 'socketTimeout' "$CATALOG"
  grep -qF 'socketTimeout' "$RES/README.md"
}

@test "the worked client restores the interrupt flag" {
  # Swallowing it leaves the thread un-interruptible, so a graceful shutdown hangs
  # on exactly the dead dependency this class is about.
  grep -qE '^[[:space:]]*Thread\.currentThread\(\)\.interrupt\(\);$' "$CLIENT"
}

@test "the fallback does not call the dependency or rethrow" {
  local fallback
  fallback="$(block_between 'private Optional<PriceQuote> lastKnownPrice(String sku, Throwable cause)' '  }' "$CLIENT")"
  lacks "$fallback" 'http.send'
  lacks "$fallback" 'throw '
  # The POSITIVE half of the contract. Returning a zero-priced quote instead of an
  # empty Optional passes both `lacks` above and bills callers on a fabricated
  # number; and `stale` is a positional boolean, so `false` compiles and serves a
  # fallback price as live.
  contains "$fallback" 'return Optional.empty();'
  contains "$fallback" 'new PriceQuote(sku, cached.amount(), cached.currency(), true)'
  # A caller error must take the honest-absence path, not the outage path.
  contains "$fallback" 'cause instanceof DependencyCatalog.NotADependencyFailure'
  grep -qE '^[[:space:]]*public Optional<PriceQuote> quote\(String sku\) \{$' "$CLIENT"
}
