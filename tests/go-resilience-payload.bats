#!/usr/bin/env bats
#
# Structural tests for the canonical Go resilience + dependency-health payload
# (#1144, epic #964) — the Go sibling of tests/java-resilience-payload.bats and
# tests/python-resilience-payload.bats.
#
# The Go toolchain is NOT in the test image (see tests/Dockerfile), so these are
# grep-based: the payload's compilation, its lint-cleanliness and its live
# behaviour are verified out-of-band at authoring time and downstream by the
# bootstrapped repo's own CI. What they pin is the contract shape a careless edit
# would break silently.
#
# THREE RULES, inherited from tests/ops-api-language-payloads.bats (#1192) because
# each was learned from a defect that shipped green:
#
#   1. ANCHOR EVERY NEEDLE TO CODE, NEVER TO PROSE. This payload documents its own
#      contract at length, in the same words the contract is written in, so an
#      unscoped grep is satisfied by a doc comment even after the code it names is
#      deleted. `go_flat` STRIPS comment lines, which makes the rule structural.
#   2. PIN A GUARD TOGETHER WITH ITS BODY, AS ONE NEEDLE. A condition and its
#      consequence asserted separately cannot tell `A && B` from `A || B`, nor an
#      arm from its transposed twin. `go_flat` collapses whitespace so a whole
#      `if … { … }` fits one needle, immune to gofmt re-alignment.
#   3. NO NEEDLE MAY SPAN A SOURCE LINE. A multi-line single-quoted needle whose
#      opening line contains a paren establishes a PHANTOM quote carry in
#      tests/find-inert-bracket-assertions.zsh, silently exempting the span that
#      follows from the suite's own inert-assertion lint (#1068's residual gap).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GO="$REPO_ROOT/development/skills/bootstrap/templates/languages/go/resilience"
  OPS="$REPO_ROOT/development/skills/bootstrap/templates/languages/go/ops-api"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
}

# go_func <file> <signature-prefix> — one top-level Go declaration, proven closed
# by a SENTINEL the terminating branch emits rather than by inspecting the result:
# a Go file's last line is `}` too, so a runaway extraction that ran to EOF would
# pass a shape check while silently returning every following declaration as the
# haystack — which is exactly what makes a `lacks` assertion vacuous.
go_func() {
  local body
  body="$(awk -v sig="$2" '
    index($0, "func " sig) == 1 { inside = 1 }
    inside { print }
    inside && /^}$/ { print "//go_func:closed"; exit }
  ' "$1")"
  case "$body" in
    *"//go_func:closed") printf '%s' "${body%//go_func:closed}" ;;
    *) echo "go_func: 'func $2' not found in $1, or its block never closed" >&2; return 1 ;;
  esac
}

# flatten — drop whole-line comments, then collapse every whitespace run to one
# space. Rules 1 and 2 in one helper.
flatten() { printf '%s' "$1" | grep -v '^[[:space:]]*//' | tr -s ' \t\n' ' '; }

catalog_flat() { local b; b="$(go_func "$GO/dependency_catalog.go" "$1")" || return 1; flatten "$b"; }
health_flat() { local b; b="$(go_func "$GO/dependency_health.go" "$1")" || return 1; flatten "$b"; }
client_flat() { local b; b="$(go_func "$GO/pricing_api_client.go" "$1")" || return 1; flatten "$b"; }

@test "go resilience payload files exist at the SKILL render paths" {
  [ -f "$GO/dependency_catalog.go" ]
  [ -f "$GO/dependency_health.go" ]
  [ -f "$GO/pricing_api_client.go" ]
  [ -f "$GO/go.mod.deps" ]
  [ -f "$GO/resilience-dependencies.properties" ]
  [ -f "$GO/README.md" ]
}

@test "go_func proves closure rather than inferring it (self-test)" {
  run ! go_func "$GO/dependency_catalog.go" 'ThisDeclarationDoesNotExist('
}

@test "go resilience files all declare package resilience, not package ops" {
  # The import direction is the invariant: resilience imports ops, never the
  # reverse. Folding these into `package ops` would put a breaker library on the
  # ops package's import path, which its own doc comment forbids outright.
  grep -qE '^package resilience$' "$GO/dependency_catalog.go"
  grep -qE '^package resilience$' "$GO/dependency_health.go"
  grep -qE '^package resilience$' "$GO/pricing_api_client.go"
  # …and the ops package must still import no breaker. Guarded and positively
  # controlled: on a missing file `cat` yields an empty haystack and `lacks` would
  # pass unconditionally, turning the invariant into an unconditional green.
  [ -f "$OPS/opsapi.go" ]
  # Scoped to CODE, not the whole file: the ops payload's doc comment legitimately
  # NAMES gobreaker when it points at the blessed source, so a whole-file negative
  # would fire on prose. What must never appear is the import.
  local opscode; opscode="$(grep -v '^[[:space:]]*//' "$OPS/opsapi.go")"
  contains "$opscode" 'type DependencyHealthSource interface {'
  # The seam's METHOD SIGNATURE, on the ops side. dependency_health.go stakes a
  # compile-time assertion on it, but no Go toolchain runs in this image — so a
  # rename there would ship green through both payloads' suites and break the
  # build of every bootstrapped repo (the two are placed together or not at all).
  contains "$opscode" 'Components() map[string]Dependency'
  lacks "$opscode" 'gobreaker'
}

@test "go dependency_health keeps the FLAGGED ops import (must be re-pointed on placement)" {
  # The payload's one and only placeholder. The Java sibling's analogue is its
  # flagged `package` line, and that test exists for the same reason: a
  # placeholder shipped unflagged is a placeholder nobody re-points.
  grep -qF 'ops "example.com/service/internal/ops"' "$GO/dependency_health.go"
  grep -qF 'CHANGE THIS IMPORT' "$GO/dependency_health.go"
}

@test "go dependency_health proves at COMPILE TIME that it satisfies the ops seam" {
  # Without this line a contract change would not break the build — it would
  # quietly leave /health with no components map, which is the failure the whole
  # payload exists to prevent.
  grep -qF 'var _ ops.DependencyHealthSource = (*DependencyHealth)(nil)' "$GO/dependency_health.go"
}

@test "go dependency_health maps breaker state to the contract's vocabulary exactly" {
  # closed = up, half_open = degraded, open = down. A component is healthy as
  # "up"; returning the AGGREGATE's spelling "ok" here would be coerced to down.
  local fn; fn="$(health_flat 'statusOf(')"
  contains "$fn" 'case gobreaker.StateOpen: return "down"'
  contains "$fn" 'case gobreaker.StateHalfOpen: return "degraded"'
  contains "$fn" 'case gobreaker.StateClosed: return "up"'
  # An unknown state must fail TOWARD severity, never render as healthy.
  contains "$fn" 'default: return "down"'
  lacks "$fn" '"ok"'
  local br; br="$(health_flat 'breakerOf(')"
  contains "$br" 'case gobreaker.StateOpen: return "open"'
  contains "$br" 'case gobreaker.StateHalfOpen: return "half_open"'
  contains "$br" 'case gobreaker.StateClosed: return "closed"'
  contains "$br" 'default: return "open"'
}

@test "go dependency_health builds the ops-api v1.1 entry from the right sources" {
  # The single line where the contract is realized. Status/Breaker transposed, a
  # dropped Kind (the readiness hinge — an empty kind is coerced to `hard` by the
  # ops payload, so a soft dependency's outage would start failing readiness), or
  # a non-RFC3339 Since all ship green without this.
  local fn; fn="$(health_flat '(d *DependencyHealth) Components(')"
  contains "$fn" 'out[name] = ops.Dependency{ Status: statusOf(state), Kind: kind.Wire(), Breaker: breakerOf(state), Since: at.UTC().Format(time.RFC3339), }'
  # Ranged over the COPY, never the catalog's live map.
  contains "$fn" 'dependencies := d.catalog.Dependencies()'
  # Breaker states are read BEFORE the since snapshot: gobreaker computes the
  # open -> half-open transition inside State() and dispatches synchronously, so a
  # scrape can be what moves a breaker — snapshotting first would report the new
  # state with the previous timestamp.
  # The fill loop AND the lock that follows, as one needle: asserting only the
  # allocation would let the loop be deleted, after which every dependency falls
  # into the !known arm and /health reports the whole service down.
  contains "$fn" 'states := make(map[string]gobreaker.State, len(dependencies)) for name := range dependencies { if breaker := d.catalog.Breaker(name); breaker != nil { states[name] = breaker.State() } } d.mu.Lock()'
  # A declared dependency with no breaker is reported DOWN, never omitted:
  # silently dropping one is the under-reporting the two startup guards refuse.
  contains "$fn" 'if !known { out[name] = ops.Dependency{'
  contains "$fn" 'Status: "down", Kind: kind.Wire(), Breaker: "open",'
}

@test "go dependency_health registers the observer that keeps since honest" {
  # Without the registration `since` freezes at construction forever, while the
  # stamp test, the dispatch test and the Components test all stay green.
  local fn; fn="$(health_flat 'newDependencyHealth(')"
  contains "$fn" 'd.since[name] = startedAt'
  # The callback's OWN name, not the captured loop variable: capturing is correct
  # only under Go >= 1.22 per-iteration scoping, and this payload is documented as
  # copy-pasteable by hand.
  contains "$fn" 'catalog.observe(name, func(n string, _, _ gobreaker.State) { d.stamp(n) })'
  # The exported constructor adopters are told to call, by name.
  grep -qF 'func NewDependencyHealth(catalog *Catalog) *DependencyHealth {' "$GO/dependency_health.go"
  local ctor; ctor="$(health_flat 'NewDependencyHealth(')"
  contains "$ctor" 'return newDependencyHealth(catalog, time.Now)'
  # …and the catalog side of the registration.
  local obs; obs="$(catalog_flat '(c *Catalog) observe(')"
  contains "$obs" 'c.mu.Lock() defer c.mu.Unlock() c.observers[name] = append(c.observers[name], fn)'
}

@test "go dependency_health is PASSIVE: no probing machinery of any kind" {
  # Its header, the README and the SKILL block all state it never calls a
  # dependency, never probes on a schedule, and never transitively calls a
  # downstream's /health — the health-check-storm anti-pattern, where one slow leaf
  # hangs every ancestor's health check. An edit adding a client or a ticker would
  # otherwise pass every other test in this file.
  local code; code="$(grep -v '^[[:space:]]*//' "$GO/dependency_health.go")"
  # Positive control: the strip did not eat the file.
  contains "$code" 'func (d *DependencyHealth) Components() map[string]ops.Dependency {'
  lacks "$code" 'net/http'
  lacks "$code" 'time.Ticker'
  lacks "$code" 'time.AfterFunc'
  lacks "$code" 'go func'
}

@test "go Load prefers the env override and otherwise uses the EMBEDDED declaration" {
  # The declaration must travel inside the binary: the blessed Go image is ko onto
  # distroless/static, which ships no data files, so a working-directory read would
  # simply not exist there and every bootstrapped service would die at startup.
  grep -qE '^//go:embed resilience-dependencies\.properties$' "$GO/dependency_catalog.go"
  grep -qE '^var embeddedDeclaration string$' "$GO/dependency_catalog.go"
  local fn; fn="$(catalog_flat 'Load()')"
  contains "$fn" 'source, origin := embeddedDeclaration, "the embedded "+DeclarationFile'
  contains "$fn" 'if path := os.Getenv(DeclarationFileEnv); path != "" { content, err := os.ReadFile(path)'
  # …and the line that APPLIES the override. Without it Load validates the file
  # and then throws it away, booting every pod with the embedded declaration while
  # a test named "prefers the env override" stays green.
  contains "$fn" 'source, origin = string(content), path'
  # An unreadable override fails LOUDLY rather than silently falling back to the
  # embedded default — otherwise a typo'd ConfigMap path would boot the pod with
  # the wrong hard/soft declaration and no error anywhere.
  contains "$fn" 'is set to %q but it cannot be read'
  ends_with "$fn" 'return Of(declared), nil } '
}

@test "go declaration constants match the shipped file and the family env name" {
  # DeclarationFile drifting from the filename shipped beside it breaks the
  # embed at build time; DeclarationFileEnv drifting from OPS_DEPENDENCIES_FILE
  # silently stops the mounted-ConfigMap override being read, so the pod comes up
  # with the WRONG hard/soft declaration and nothing reports it. That env name is a
  # cross-language contract, shared with the Java and Python payloads.
  grep -qE '^const DeclarationFile = "resilience-dependencies.properties"$' "$GO/dependency_catalog.go"
  grep -qE '^const DeclarationFileEnv = "OPS_DEPENDENCIES_FILE"$' "$GO/dependency_catalog.go"
  [ -f "$GO/resilience-dependencies.properties" ]
}

@test "go parseDeclaration refuses a duplicate before it validates the kind" {
  # Last-wins is the one malformation a silent parser would swallow, and it
  # DISARMS THE READINESS HINGE: a ConfigMap assembled from two sources can quietly
  # downgrade a hard dependency to soft, after which its outage never fails
  # readiness while /health still lists it and looks conformant.
  local fn; fn="$(catalog_flat 'parseDeclaration(')"
  contains "$fn" 'if previous, duplicate := out[name]; duplicate { return nil, fmt.Errorf('
  contains "$fn" 'is declared twice'
  # Checked BEFORE the kind switch, so `a=hard` + `a=maybe` reports the duplicate
  # rather than making the operator fix the kind and meet the duplicate next boot.
  # Positive control FIRST: `##` with no match leaves the operand untouched, so
  # without this the ordering comparison passes whenever the anchor is absent —
  # e.g. after a rename to `switch value {` — and silently stops asserting.
  contains "$fn" 'switch strings.ToLower(value) {'
  local before after
  before="${fn%%is declared twice*}"
  after="${before##*switch strings.ToLower(value)}"
  [ "$before" = "$after" ]
  # The malformed-line guard: a stray `=hard` must not register a nameless
  # dependency that can never be guarded.
  contains "$fn" 'name, value, found := strings.Cut(text, "=")'
  contains "$fn" 'if !found || name == "" { return nil, fmt.Errorf('
  contains "$fn" 'if err := scanner.Err(); err != nil { return nil, fmt.Errorf('
}

@test "go dependency_health returns a FRESH map, never the live one" {
  # The one rule whose violation is not survivable: /health and /health/ready both
  # range over the result, and a map another goroutine writes is a concurrent map
  # read/write — a Go FATAL error the ops handler's recover guards cannot catch,
  # so the process dies mid-scrape.
  local fn; fn="$(health_flat '(d *DependencyHealth) Components()')"
  contains "$fn" 'out := make(map[string]ops.Dependency, len(dependencies))'
  # The since stamps are copied under the lock, not read live.
  contains "$fn" 'd.mu.Lock() stamps := make(map[string]time.Time, len(d.since))'
  contains "$fn" 'd.mu.Unlock()'
  ends_with "$fn" 'return out } '
}

@test "go dependency_health stamps the since timestamp under its lock" {
  # OnStateChange runs on whichever goroutine moved the breaker; Components runs
  # on the goroutine serving /health. The two genuinely race.
  local fn; fn="$(health_flat '(d *DependencyHealth) stamp(')"
  contains "$fn" 'd.mu.Lock() defer d.mu.Unlock() d.since[name] = d.now().UTC()'
}

@test "go catalog creates one breaker per dependency, EAGERLY" {
  # One breaker per dependency is mandate 2, and it is what makes the components
  # map meaningful. Eager creation is what lets RequireAllDeclaredGuarded tell
  # "declared but unguarded" from "not declared" — a lazy map could not.
  local fn; fn="$(catalog_flat 'Of(')"
  contains "$fn" 'c.breakers[name] = gobreaker.NewCircuitBreaker[any](settings)'
  # The dispatching hook is installed HERE, not in BreakerSettings — otherwise Of
  # would have to overwrite a hook BreakerSettings set, and the two would disagree.
  contains "$fn" 'settings.OnStateChange = func(n string, from, to gobreaker.State) { c.dispatch(n, from, to) }'
}

@test "go catalog's breaker settings trip on a RATE with a minimum volume" {
  # gobreaker's default is five CONSECUTIVE failures, which never trips a
  # dependency that fails every other call. The minimum volume is what stops one
  # failure after a counter reset reading as a 100% failure rate on a sample of 1.
  local fn; fn="$(catalog_flat 'BreakerSettings(')"
  # The denominator EXCLUDES excluded calls. gobreaker counts every admitted call
  # in Requests and never decrements it on exclusion, so dividing by Requests lets
  # a crawler's 404s (or a drain's cancellations) hold a DEAD dependency's breaker
  # closed — measured before the fix: 100 excluded + 20 straight real failures =
  # 0.17, breaker closed, /health reporting a dead dependency up.
  # The floor's VALUE, not just its shape: Interval and minimumVolume are ONE
  # decision (a dependency called fewer than the floor per Interval can never
  # trip), and the Java sibling pins its .minimumNumberOfCalls(10) outright.
  contains "$fn" 'const minimumVolume = 10'
  contains "$fn" 'if c.Requests < c.TotalExclusions { return false } counted := c.Requests - c.TotalExclusions if counted < minimumVolume { return false }'
  # Interval and minimumVolume are ONE decision, and getting it wrong is silent:
  # gobreaker clears the closed-state counters every Interval, so a dependency
  # called fewer than minimumVolume times per Interval can NEVER trip — /health
  # would report it up straight through a total outage.
  contains "$fn" 'Interval: 5 * time.Minute'
  contains "$fn" 'return float64(c.TotalFailures)/float64(counted) >= 0.5'
  # …and never against the raw Requests again.
  lacks "$fn" 'float64(c.Requests)'
  # MANDATE 5, background reconnect: open -> half-open after Timeout.
  # At PARITY with the Java and Python siblings, so recovery becomes visible on
  # /health at the same moment across every language in the fleet.
  contains "$fn" 'Timeout: 10 * time.Second'
  # Caller errors are EXCLUDED — neither success nor failure — so 4xx cannot move
  # the breaker in either direction.
  contains "$fn" 'IsExcluded: func(err error) bool { var notADependency *NotADependencyFailure if errors.As(err, &notADependency) { return true } return errors.Is(err, context.Canceled) }'
  # A cancelled CALLER is not a failing dependency: net/http cancels the request
  # context on a client disconnect and a drain cancels every in-flight one, so
  # without this a burst of disconnects opens a healthy dependency's breaker.
  # DeadlineExceeded must NOT join it — that is the brownout signal.
  lacks "$fn" 'DeadlineExceeded'
  # Name is load-bearing in a non-obvious way: dispatch resolves observers by the
  # name gobreaker hands the hook, which IS the breaker's Name. Drop it and every
  # transition dispatches to observers[""], so `since` silently never updates.
  contains "$fn" 'Name: name'
  contains "$fn" 'MaxRequests: 3'
  # BreakerSettings must NOT set its own OnStateChange (see the Of test).
  lacks "$fn" 'OnStateChange'
}

@test "go catalog dispatches transitions WITHOUT holding its lock" {
  # gobreaker calls OnStateChange while holding its own mutex. An observer that
  # touched the catalog under c.mu would invert the lock order and deadlock the
  # first time a breaker tripped — during an outage, the worst possible moment.
  local fn; fn="$(catalog_flat '(c *Catalog) dispatch(')"
  contains "$fn" 'c.mu.Lock() listeners := make([]func(string, gobreaker.State, gobreaker.State), len(c.observers[name])) copy(listeners, c.observers[name]) c.mu.Unlock()'
  contains "$fn" 'for _, fn := range listeners { fn(name, from, to) }'
}

@test "go catalog refuses under-reporting from BOTH sides" {
  # The pair is only useful together: one catches a dependency guarded in code but
  # undeclared (it would appear nowhere in /health), the other one declared but
  # guarded by nobody (its breaker can never leave closed, so /health would swear
  # it was up through a total outage).
  local declared; declared="$(catalog_flat '(c *Catalog) RequireDeclared(')"
  contains "$declared" 'if _, ok := c.dependencies[name]; !ok { return "", fmt.Errorf('
  contains "$declared" 'is guarded in code but not declared in'
  # The WRITER half. Drop it and RequireAllDeclaredGuarded reports every declared
  # dependency as unguarded, so every service following the README dies at boot.
  contains "$declared" 'c.mu.Lock() defer c.mu.Unlock() c.guarded[name] = true'
  ends_with "$declared" 'return name, nil } '
  local guarded; guarded="$(catalog_flat '(c *Catalog) RequireAllDeclaredGuarded()')"
  contains "$guarded" 'if !c.guarded[name] { unguarded = append(unguarded, name) }'
  contains "$guarded" 'but no client claimed them'
  # The message must name the CONSTRUCTOR claim: advising 'route a client through
  # Call' sends the operator to something that happens after this check runs.
  contains "$guarded" 'RequireDeclared from the client'"'"'s constructor'
  # Deterministic output — an unordered map range would make the message vary.
  contains "$guarded" 'sort.Strings(unguarded)'
}

@test "go Call wires the six mandates and bounds the retry" {
  local fn; fn="$(catalog_flat 'Call[T any](')"
  # A dependency must be declared before it can be called.
  contains "$fn" 'if _, err := catalog.RequireDeclared(name); err != nil { return zero, err }'
  # An already-expired caller context must reach the FALLBACK without touching the
  # breaker: the dependency was never contacted, and charging it would let
  # caller-side overload (an exhausted upstream budget, the last hop in a chain)
  # open a HEALTHY dependency's breaker and, when declared hard, shed traffic from
  # a sound pod. The guard sits ahead of the breaker, so it must be pinned
  # together with what follows it.
  contains "$fn" 'if err := ctx.Err(); err != nil { return fallback(fmt.Errorf("resilience: %s not attempted, caller context already done: %w", name, err)) } breaker := catalog.Breaker(name)'
  # MANDATE 3: bounded. The loop cannot run past MaxAttempts.
  contains "$fn" 'for attempt := 1; attempt <= MaxAttempts; attempt++ {'
  # The call runs THROUGH the breaker — mandate 2.
  contains "$fn" 'result, err := breaker.Execute(func() (any, error) { return call(ctx) })'
  # The retry stops on a non-retryable error OR the attempt ceiling — as ONE
  # needle, because `&&` here would retry an open breaker to exhaustion.
  contains "$fn" 'if !retryable(ctx, err) || attempt == MaxAttempts { break }'
  # MANDATE 3 is only "bounded retry WITH JITTERED BACKOFF" because of this call.
  # Delete it and sleepBackoff's own test still passes in full, while every
  # bootstrapped service hammers a sick dependency three times with zero delay.
  contains "$fn" 'if sleepErr := sleepBackoff(ctx, attempt); sleepErr != nil {'
  # The real cause must survive a context error during the backoff, or the
  # fallback sees only "context deadline exceeded" and the failure that actually
  # caused the degradation is gone.
  contains "$fn" 'lastErr = errors.Join(lastErr, sleepErr)'
  # The success arm's type assertion is the sole reason Call is generic.
  contains "$fn" 'if err == nil { value, _ := result.(T) return value, nil }'
  # A nil fallback must be refused on the FIRST call, not the first outage.
  contains "$fn" 'if call == nil || fallback == nil { return zero, fmt.Errorf('
  # A non-positive budget would skip the loop entirely and hand the fallback a nil
  # cause on every request, with the dependency never contacted.
  contains "$fn" 'if MaxAttempts < 1 { return zero, fmt.Errorf('
  # MANDATE 4: the fallback is what the function returns when attempts run out.
  ends_with "$fn" 'return fallback(lastErr) } '
}

@test "go Call's retry predicate refuses every non-retryable class" {
  # Each false branch is a mandate, not a preference. Guard and body in one needle
  # so an inverted condition cannot pass.
  local fn; fn="$(catalog_flat 'retryable(')"
  # A spent caller context: the budget is gone.
  contains "$fn" 'if ctx.Err() != nil { return false }'
  # MANDATE 6: an open (or half-open-saturated) breaker means the dependency is
  # already known down — retrying only parks the caller. Both sentinels as ONE
  # needle: dropping either half silently re-enables one of them.
  contains "$fn" 'if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) { return false }'
  # A caller's own error reproduces exactly on retry while counting nothing.
  contains "$fn" 'return !errors.As(err, &notADependency)'
}

@test "go Call's backoff is exponential, capped, FULL-jittered and context-aware" {
  local fn; fn="$(catalog_flat 'sleepBackoff(')"
  # The shift is CLAMPED, not just its result: MaxAttempts is exported and the
  # README invites changing the budget, and a large attempt would overflow int64
  # into a negative duration that a result-only cap cannot catch — after which
  # rand.Int64N panics on a non-positive bound.
  # Clamped at BOTH ends: a large attempt would overflow int64 into a negative
  # duration a result-only cap cannot catch, and attempt 0 is a shift by a
  # negative count, which panics — reachable the moment an adopter rewrites the
  # loop as `for attempt := 0; attempt < MaxAttempts; attempt++`.
  contains "$fn" 'shift := attempt - 1 if shift < 0 { shift = 0 } delay := RetryMaxDelay if shift <= 20 { if grown := RetryBaseDelay << shift; grown > 0 && grown < RetryMaxDelay { delay = grown } }'
  # FULL jitter — a uniform draw over the whole delay. Equal jitter still leaves
  # every caller in the fleet retrying inside one narrow window, which is the
  # synchronized stampede the backoff exists to break.
  contains "$fn" 'rand.Int64N(int64(delay) + 1)'
  # A drain must not be held up by a retry sleeping on a dependency already gone.
  contains "$fn" 'case <-ctx.Done(): return ctx.Err()'
}

@test "go retry budget is bounded by named constants, not magic numbers" {
  grep -qE '^[[:space:]]*MaxAttempts = 3$' "$GO/dependency_catalog.go"
  grep -qE '^[[:space:]]*RetryBaseDelay = 100 \* time\.Millisecond$' "$GO/dependency_catalog.go"
  grep -qE '^[[:space:]]*RetryMaxDelay = 2 \* time\.Second$' "$GO/dependency_catalog.go"
}

@test "go catalog's gosec dismissals are scoped and justified, not a blanket silence" {
  # The payload must lint clean in EVERY bootstrapped repo — a golangci-lint
  # failure here is a failure in every repo bootstrap touches — so both findings
  # are dismissed at the line, each with the reason it is a false positive.
  # G404, the jitter draw: a sleep duration is not a secret.
  grep -qF 'rand.Int64N(int64(delay) + 1)) //nolint:gosec // jitter is a sleep duration, not a secret' \
    "$GO/dependency_catalog.go"
  # G304, the declaration file: reading an operator-supplied config path is the
  # whole point of $OPS_DEPENDENCIES_FILE.
  grep -qF 'os.ReadFile(path) //nolint:gosec // the path is operator-supplied config, by design' \
    "$GO/dependency_catalog.go"
  # Exactly those two: a third would mean the exception spread, and should have to
  # be justified here before it lands.
  local n
  n="$(grep -c 'nolint:gosec' "$GO/dependency_catalog.go")"
  [ "$n" -eq 2 ]
  # …and it is a TRAILING directive, not a line of its own. A directive that
  # starts a line applies to the whole following block or file, which is the
  # blanket this test exists to forbid.
  run ! grep -qE '^[[:space:]]*//nolint' "$GO/dependency_catalog.go"
}

@test "go declaration parser accepts hard/soft and rejects anything else" {
  local fn; fn="$(catalog_flat 'parseDeclaration(')"
  contains "$fn" 'case "hard": out[name] = Hard'
  contains "$fn" 'case "soft": out[name] = Soft'
  # A trailing `# comment` would make the kind "hard # primary" — rejected rather
  # than guessed, because a misparsed kind decides whether an outage sheds traffic.
  contains "$fn" 'default: return nil, fmt.Errorf('
  contains "$fn" 'FULL-LINE'
  # Full-line comments and blanks are skipped.
  contains "$fn" 'if text == "" || strings.HasPrefix(text, "#") { continue }'
}

@test "go Kind maps to the contract's wire spelling" {
  local fn; fn="$(catalog_flat '(k Kind) Wire()')"
  contains "$fn" 'if k == Soft { return "soft" }'
  contains "$fn" 'return "hard"'
}

@test "go worked-example client carries its own timeout and classifies the whole 4xx range" {
  # MANDATE 1 is the one the catalog cannot impose — it does not own the socket —
  # and in Go it doubles as the slow-call threshold, because gobreaker has no
  # slow-call detection of its own.
  local ctor; ctor="$(client_flat 'NewPricingAPIClient(')"
  contains "$ctor" 'Timeout: 2 * time.Second'
  # Claiming at CONSTRUCTION turns an undeclared dependency into a startup failure.
  contains "$ctor" 'if _, err := catalog.RequireDeclared(DependencyName); err != nil { return nil, err }'
  # The claimed name must match the shipped declaration line, or an as-shipped
  # payload fails startup in every repo that keeps the worked example.
  grep -qE '^const DependencyName = "pricing-api"$' "$GO/pricing_api_client.go"
  # An unset base URL must fail at CONSTRUCTION: left empty the transport fails
  # with "no Host in request URL", which this client would report as a DEPENDENCY
  # failure — so a missing env var would open the breaker and make /health blame a
  # dependency that was never called.
  contains "$ctor" 'baseURL := os.Getenv("PRICING_API_BASE_URL")'
  # Validated, not merely non-empty: a service name with no scheme is the commonest
  # spelling of this misconfiguration, and it would otherwise reach the COUNTED
  # transport arm and open a breaker on a dependency never contacted.
  contains "$ctor" 'if parseErr != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" { return nil, fmt.Errorf('
  local fetch; fetch="$(client_flat '(c *PricingAPIClient) fetch(')"
  # The WHOLE 4xx range, not just the 404 anyone would think of first.
  contains "$fetch" 'case response.StatusCode >= 400 && response.StatusCode < 500:'
  contains "$fetch" 'NotADependency(fmt.Errorf("pricing-api: status %d", response.StatusCode))'
  # 5xx IS the dependency failing, so it must NOT be excluded.
  contains "$fetch" 'case response.StatusCode >= 500: return Price{}, fmt.Errorf("pricing-api: status %d", response.StatusCode)'
  # Caller input is ESCAPED: unescaped, a SKU containing "?" injects a query and a
  # control character makes the request fail outright — charged to the breaker, so
  # caller input would move a healthy dependency's health.
  contains "$fetch" 'neturl.PathEscape(sku)'
  # A cancelled CALLER is not a failing dependency.
  # The cancel arm AND the default transport arm as one needle, so they cannot be
  # transposed. The default arm is the brownout signal: gobreaker has no slow-call
  # detection, so wrapping it in NotADependency — the exact defect the review
  # dimension is told to flag — would mean no timeout could ever open a breaker.
  contains "$fetch" 'if errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled) { return Price{}, NotADependency(err) } return Price{}, fmt.Errorf("pricing-api: %w", err)'
  # The canonical caller-error case the whole NotADependency story is told around.
  # The switch is an EXPRESSION switch: first match wins, so the CATCH-ALL must
  # come last. Hoisting `< 200 || >= 300` above the 4xx arms is compile-clean and
  # would return every caller-provoked 404 UN-wrapped — counted by the breaker, so
  # a crawler on dead SKUs opens a healthy dependency. Both caller-error arms are
  # therefore pinned in order, ahead of it.
  contains "$fetch" 'case response.StatusCode == http.StatusNotFound: return Price{}, NotADependency(fmt.Errorf("pricing-api: no such sku %q", sku)) case response.StatusCode >= 400 && response.StatusCode < 500: return Price{}, NotADependency(fmt.Errorf("pricing-api: status %d", response.StatusCode)) case response.StatusCode >= 500: return Price{}, fmt.Errorf("pricing-api: status %d", response.StatusCode) case response.StatusCode < 200 || response.StatusCode >= 300:'
  # A body the dependency cannot serialize IS the dependency misbehaving, so the
  # decode failure must stay counted — but a caller who went away mid-body is not.
  contains "$fetch" 'if errors.Is(ctx.Err(), context.Canceled) { return Price{}, NotADependency(err) }'
  contains "$fetch" 'return Price{}, fmt.Errorf("pricing-api: decoding response: %w", err)'
  contains "$fetch" 'defer func() { _ = response.Body.Close() }()'
  # …and success is explicit, not residual: a 204/304 would otherwise reach the
  # decoder and be reported as a malformed body.
  contains "$fetch" 'case response.StatusCode < 200 || response.StatusCode >= 300:'
}

@test "go worked-example fallback never calls the dependency, and never invents a price" {
  local fn; fn="$(client_flat '(c *PricingAPIClient) Price(')"
  contains "$fn" 'return Call(ctx, c.catalog, DependencyName,'
  # The fallback's WHOLE body in one needle: a fallback that called the dependency
  # would defeat the breaker entirely, and pinning the body in full is what proves
  # it does not — a `lacks` on the call cannot, because the sibling CALL closure
  # legitimately contains exactly that expression.
  #
  # It must also not fabricate a money-shaped value: returning Cents: 0 with a nil
  # error hands a caller a number they might bill on, and the Degraded flag only
  # helps a caller who checks it. A degraded path owes a usable answer or an
  # honest absence.
  contains "$fn" 'func(cause error) (Price, error) { return Price{}, fmt.Errorf("pricing-api unavailable, no cached price for %q: %w", sku, cause) }'
  # …and the real call goes through Call's first closure, exactly once.
  contains "$fn" 'func(ctx context.Context) (Price, error) { return c.fetch(ctx, sku) }'
}

@test "go NotADependencyFailure unwraps and is nil-total" {
  grep -qF 'func NotADependency(err error) error { return &NotADependencyFailure{Err: err} }' "$GO/dependency_catalog.go"
  # NotADependency is EXPORTED and both the README and the review dimension tell
  # adopters to call it, so a nil cause is reachable — and the panic would fire
  # only where the error is FORMATTED, i.e. inside the fallback's %w during an
  # outage, never in a green test. Same class as Call's nil-fallback guard.
  local e; e="$(catalog_flat '(e *NotADependencyFailure) Error()')"
  contains "$e" 'if e == nil || e.Err == nil { return "not a dependency failure: <nil>" }'
  local u; u="$(catalog_flat '(e *NotADependencyFailure) Unwrap()')"
  contains "$u" 'if e == nil { return nil }'
}

@test "go.mod.deps pins gobreaker v2 and nothing else" {
  # ONE library, deliberately: the bounded jittered retry is stdlib in the catalog
  # rather than a second dependency with its own version surface.
  grep -qE '^require github\.com/sony/gobreaker/v2 v' "$GO/go.mod.deps"
  local requires
  requires="$(grep -c '^require ' "$GO/go.mod.deps")"
  [ "$requires" -eq 1 ]
  # The /v2 path is load-bearing: v2 made the breaker generic, which is what lets
  # one catalog hold breakers for calls returning different types.
  contains "$(cat "$GO/dependency_catalog.go")" '"github.com/sony/gobreaker/v2"'
}

@test "go declaration file ships replaceable examples and states the hard/soft consequence" {
  grep -qE '^orders-db=hard$' "$GO/resilience-dependencies.properties"
  grep -qE '^pricing-api=soft$' "$GO/resilience-dependencies.properties"
  local decl; decl="$(cat "$GO/resilience-dependencies.properties")"
  contains "$decl" 'REPLACE THE TWO EXAMPLES BELOW'
  # The file's own account of where it is read from must match the loader — this
  # is the one artifact an adopter edits, so a stale claim here sends them to a
  # read path that does not exist and makes them expect a restart to take effect.
  contains "$decl" 'COMPILED INTO THE BINARY'
  contains "$decl" 'REBUILD,'
  lacks "$decl" 'The file is read from the working directory'
  contains "$decl" 'FULL-LINE `#` COMMENTS ONLY'
  # Both directions of the choosing-wrong consequence.
  contains "$decl" 'A cache marked hard'
  contains "$decl" 'a database marked soft'
}

@test "go resilience README records the gobreaker fit-check and its silent gaps" {
  local readme; readme="$(cat "$GO/README.md")"
  # Acceptance criterion 1: the library was CONFIRMED, with evidence.
  contains "$readme" 'pybreaker'
  contains "$readme" 'No slow-call detection'
  contains "$readme" 'Why gobreaker and no retry library'
  # The wiring the SKILL block explicitly DEFERS to this README ("Record — do not
  # perform … the placed README.md shows both wirings"). If it drifts, the
  # generated Step-5 checklist dangles and the adopter never wires either guard.
  contains "$readme" 'resilience.Load()'
  contains "$readme" 'catalog.RequireDeclared(name)'
  contains "$readme" 'catalog.RequireAllDeclaredGuarded()'
  contains "$readme" 'Dependencies: resilience.NewDependencyHealth(catalog)'
  contains "$readme" 'OPS_DEPENDENCIES_FILE'
  # The measured evidence, not just the claim.
  contains "$readme" '4 × 1s calls took **1.00s**'
}

@test "bootstrap SKILL.md renders every go resilience file from the GO block" {
  # Doubly scoped: SKILL.md is mostly prose and discusses these filenames, and the
  # sed range restarts at each render.zsh invocation, so an unscoped grep would be
  # satisfied by a sentence — or by the Java or Python block's command.
  # The two fences are asserted SEPARATELY. A single range restarts at every
  # render.zsh invocation and concatenates both, which would make every needle
  # pass regardless of which command a path lives in — and the invariant that
  # pricing_api_client.go has its OWN command is exactly what makes "omit it"
  # followable. Folded into the main command, bootstrap would place a client for a
  # `pricing-api` the repo does not have into every Go service.
  local block main example
  block="$(sed -n '/^\*\*Go resilience + dependency health (#1144)\.\*\*/,/^\*\*Node canonical implementation (#936)\.\*\*/p' "$SKILL")"
  contains "$block" '**Node canonical implementation (#936).**'          # proves the range closed
  main="$(printf '%s\n' "$block" | sed -n '/render.zsh" \\/,/^```$/p' | sed -n '1,/^```$/p')"
  ends_with "$main" '```'                              # proves the FIRST fence closed
  contains "$main" 'languages/go/resilience/dependency_catalog.go'
  contains "$main" 'languages/go/resilience/dependency_health.go'
  contains "$main" 'languages/go/resilience/go.mod.deps'
  contains "$main" 'languages/go/resilience/resilience-dependencies.properties'
  contains "$main" 'languages/go/resilience/README.md'
  lacks "$main" 'pricing_api_client.go'
  example="$(printf '%s\n' "$block" | sed -n '/render.zsh" \\/,/^```$/p' | sed -n '/^```$/,$p' | sed -n '2,$p')"
  contains "$example" 'languages/go/resilience/pricing_api_client.go'
  ends_with "$example" '```'                           # proves the SECOND fence closed
}

@test "bootstrap SKILL.md gates the go resilience payload on the ops-api block alone" {
  # "Placed together or not at all" is only true because every skip condition is
  # tested in the ops-api gate. A second gate here would silently re-introduce the
  # split — a Config.Dependencies wired with no source to supply it.
  local block
  block="$(sed -n '/^\*\*Go resilience + dependency health (#1144)\.\*\*/,/^\*\*Node canonical implementation (#936)\.\*\*/p' "$SKILL")"
  contains "$block" '**Node canonical implementation (#936).**'
  contains "$block" 'the Go ops-api block'
  contains "$block" 'skipped or deferred'
  contains "$block" 'installed** → **install**'
  # The placement invariants that keep the ops package breaker-free and the one
  # placeholder findable.
  contains "$block" 'internal/resilience/'
  contains "$block" 'imports `ops`, never the reverse'
  contains "$block" 'CHANGE THIS IMPORT'
  # The tidy-order trap and its failure branch, same as the ops-api block's.
  contains "$block" 'strips the gobreaker line'
  contains "$block" 'keep the folded require'
  # The declaration must be embedded, not read from a working directory that does
  # not exist in the distroless image.
  contains "$block" 'go:embed'
  contains "$block" 'ships no data files'
  # Record-do-not-perform, both wirings.
  contains "$block" 'Record — do not perform'
  contains "$block" 'RequireAllDeclaredGuarded()'
  # The README/go.mod.deps clobber both siblings warn about.
  contains "$block" 'silently clobbers the first'
  # Two different go.mod.deps files must BOTH be folded.
  contains "$block" 'they are different files'
}

@test "go review dimension records the payload carve-out it must not re-review" {
  # Without this block the reviewer re-reports mandates 2-5 on every catalog-routed
  # call (the review-loop noise it exists to suppress) and stops flagging the
  # client-owned concerns the wrapper genuinely cannot supply.
  local agent
  agent="$(cat "$REPO_ROOT/development-go/agents/go-resilience-reviewer.md")"
  contains "$agent" 'sony/gobreaker'
  contains "$agent" 'resilience.Call(ctx, catalog, name, call,'
  # The waiver must NOT cover all of mandate 6: section 4's hang/crash shapes are
  # outside the wrapper, and waiving them suppresses a CRITICAL class.
  contains "$agent" 'already carries mandates 2-5 and'
  contains "$agent" "mandate 6's open-breaker fast-fail, need no re-review"
  contains "$agent" 'Four'
  contains "$agent" 'the rest of mandate 6'
  # …and the three client-owned concerns.
  contains "$agent" 'no slow-call detection'
  contains "$agent" 'resilience.NotADependency'
  contains "$agent" 'hard/soft declaration'
  # The scoping rule must not make the declaration checks unreachable.
  matches "$agent" 'always in[[:space:]]+scope FOR THOSE CALLS'
  contains "$agent" 'the diff actually touches'
}
