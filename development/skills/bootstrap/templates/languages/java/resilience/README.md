# Java (non-Spring) resilience + dependency health

The blessed plain-Java realization of the org resilience policy and the ops-api
v1.1 dependency-health contract (issue #1142, epic #964). Copied into your service
by `/development:bootstrap`; this file explains what landed and what you still have
to do.

The idea in one line: **the circuit breaker keeps you serving; the
dependency-health surface tells you what's degraded.** An open breaker *is* a down
dependency, so `/health` reads breaker state rather than running a second health
mechanism.

This payload is the sibling of `languages/java/ops-api/` and **extends it** —
`OpsApi` serves the endpoints, this payload supplies the dependency view it
reports. If you are adopting both (the normal case), place them together.

## The blessed library: resilience4j

**resilience4j is *the* circuit-breaker library for Java in this family** — the
same one the Spring payload blesses, so the two realizations differ only in how a
breaker is *applied*, never in what a breaker *means*. One library, no options.

- `io.github.resilience4j:resilience4j-circuitbreaker` and `:resilience4j-retry`,
  versions managed by `resilience4j-bom:2.4.0`.
- **The BOM is used here and deliberately not in the Spring payload.** It manages
  every module a plain-Java service needs; what it does *not* manage is the Boot 4
  starter (it still lists only `resilience4j-spring-boot3`), which is why the
  Spring payload pins that one artifact directly. Neither is a mistake — they are
  the same reasoning applied to two different artifact sets.
- **`resilience4j-all` is deliberately not used.** It also drags in ratelimiter,
  bulkhead, cache and micrometer; the only thing it adds that we would use is the
  `Decorators` builder, and the six mandates compose from two static
  `decorateSupplier` calls in one readable line where the nesting order is *visible*
  (`DependencyCatalog.call`) rather than implied by a fluent chain.
- **No annotations, and no AOP module.** `@CircuitBreaker` / `@Retry` are Spring
  AOP aspects; outside Spring there is nothing to weave them. This payload
  decorates programmatically, which is resilience4j's supported non-Spring usage.
- `slf4j-api` arrives transitively at `runtime` scope — you do not declare it. If
  your service has no SLF4J binding you will see a one-time "No SLF4J providers
  were found" notice at startup; resilience4j then logs nothing and works normally.

## Files

| File | Goes to | What it does |
|---|---|---|
| `build.gradle.kts` | fold into your `build.gradle.kts` | the dependency block |
| `resilience-dependencies.properties` | `src/main/resources/` | the hard/soft declaration |
| `DependencyCatalog.java` | `src/main/java/<pkg>/ops/` | the declaration, the breakers/retries, and the six-mandate `call` wrapper |
| `DependencyHealth.java` | `src/main/java/<pkg>/ops/` — **beside `OpsApi.java`** | reads breaker state into the ops-api `components` map |
| `PricingApiClient.java` | **adapt first — see below** | the worked six-mandate client — copy the shape, not the domain |

Every `.java` file ships with `package com.example.ops;` flagged **`<-- CHANGE`**.
Java couples a file's package to its directory, so re-set it to wherever you place
the file. `DependencyHealth` implements `OpsApi.DependencyHealthSource` and returns
`OpsApi.Dependency` records, so **it belongs in the same package as `OpsApi`**
(`<base>.ops`); `DependencyCatalog` is normally there too, and `PricingApiClient`
takes whatever domain package it sits beside.

**`PricingApiClient.java` is a worked EXAMPLE — adapt it before you place it, or
leave it out.** Unlike its Spring counterpart it will not break your application
context (nothing scans it, and it takes its base URL as a constructor argument), so
the failure mode here is milder: dead code naming a dependency you do not have.
Either rename/repackage it to your real dependency, or omit it and keep this README
as the reference for the shape.

## Wiring it up

Four lines at startup, and every mandate is in force:

```java
DependencyCatalog dependencies = DependencyCatalog.load();
var pricing = new PricingApiClient(dependencies, URI.create(pricingBaseUrl));  // your clients
dependencies.requireAllDeclaredGuarded();   // <- do not skip; see below
OpsApi.serve("0.0.0.0", 9090,
    OpsApi.OpsConfig.defaults()
        .withServedMajors(OpsApi.ApiMajor.active(1))
        .withDependencies(new DependencyHealth(dependencies)));
```

Then route every governed outbound call through the catalog:

```java
Optional<PriceQuote> quote = dependencies.call(
    "pricing-api",                             // must be declared, or this throws
    () -> Optional.of(fetchFromPricingApi(sku)),  // your call — it carries its own timeout
    cause -> lastKnownPrice(sku));             // your degraded path — returns, never rethrows
```

## The six mandates

Every governed outbound call MUST have all six. `PricingApiClient` is the
reference:

| # | Mandate | Where it lives |
|---|---|---|
| 1 | timeout | **your client** — `HttpClient.connectTimeout` + `HttpRequest.timeout` |
| 2 | circuit breaker (one **per dependency**) | `DependencyCatalog.BREAKER_CONFIG`, one instance per declared name |
| 3 | bounded retry + jittered backoff | `DependencyCatalog.RETRY_CONFIG` — `maxAttempts(3)`, `ofExponentialRandomBackoff` |
| 4 | registered fallback | the third argument to `call(...)` |
| 5 | background reconnect | `automaticTransitionFromOpenToHalfOpenEnabled` |
| 6 | stay-stable | an open breaker fast-fails into the fallback — never a parked thread |

**Mandate 1 is the one the catalog cannot do for you**, because it does not own
your socket. It is also the one whose absence the breaker cannot compensate for: a
call that never returns never *fails*, so it never counts toward the failure rate,
the breaker stays closed, and every caller thread piles up behind a dependency that
is technically "healthy". Set both timeouts.

**And it is not just an HTTP concern** — the shipped declaration makes `orders-db`
a *hard* dependency, so get this right for your datastore too. A connection pool's
`connectionTimeout` (HikariCP and friends) bounds only *acquiring* a connection; a
query already on the wire when the database stalls is unbounded, which is precisely
the shape above. Set the driver's `socketTimeout` as well — or
`Statement.setQueryTimeout` / JPA's `jakarta.persistence.query.timeout`. Whatever
the transport, keep the per-call timeout **above** the breaker's 2s slow-call
threshold, so a brownout is recorded as slow before the transport gives up.

Two wiring details that are easy to get wrong and silent when you do:

- **The decoration order is `fallback(retry(breaker(call)))`.** The breaker is
  innermost so its failure-rate window counts individual attempts; the fallback is
  outermost so it fires only once the bounded retries are exhausted. A fallback
  placed *inside* the retry converts the first failure into a success and the call
  is never retried — the same trap the Spring payload avoids by putting
  `fallbackMethod` on `@Retry` rather than `@CircuitBreaker`.
- **`CallNotPermittedException` is in the retry's `ignoreExceptions`.** Retry is
  the outer decorator, so without this an open breaker's instant rejection is
  itself retried — burning the whole backoff schedule on a dependency already known
  to be down. With it, an open breaker returns the fallback in single-digit
  milliseconds.

The plugin enforces that a fallback is **wired**, never what it returns. Structure
is the org's business; the degraded behaviour is yours.

**Not every exception is a dependency failure.** A caller mistake (a malformed
argument, a 4xx for something that legitimately does not exist) and a local
cancellation (an interrupt during a drain) are *not* the dependency's fault, and
counting them opens a breaker on a dependency that answered every request
correctly — after which `/health` reports it `down` and, if it is `hard`,
readiness sheds all traffic from a healthy pod. Retrying them is equally pointless
since they cannot succeed on repeat; retrying an *interrupt* is actively harmful,
because the backoff's `Thread.sleep` throws immediately **and clears** the
interrupt flag.

So throw `DependencyCatalog.NotADependencyFailure` for those — it is in both the
retry's and the breaker's `ignoreExceptions`, so it goes straight to your fallback
on the first attempt. `PricingApiClient` does exactly this for 4xx and for the
interrupt path; 5xx and transport errors stay real failures.

If a third-party client throws *its own* type for these cases, pass your own
config instead of editing this file:

```java
DependencyCatalog.of(declared,
    CircuitBreakerConfig.from(DependencyCatalog.BREAKER_CONFIG)
        .ignoreExceptions(CallNotPermittedException.class,
            DependencyCatalog.NotADependencyFailure.class, TheirNotFoundException.class)
        .build(),
    RetryConfig.from(DependencyCatalog.RETRY_CONFIG)
        .ignoreExceptions(CallNotPermittedException.class,
            DependencyCatalog.NotADependencyFailure.class, TheirNotFoundException.class)
        .build());
```

Two things that snippet is showing you deliberately. **Widen both configs** — doing
only the breaker stops the caller error counting toward the failure rate but still
burns the whole retry schedule on every one. And **re-list the blessed types**:
`ignoreExceptions` *assigns* the list rather than appending to it, so passing only
your own type silently drops `CallNotPermittedException` and `NotADependencyFailure`
and re-creates both of the defects this section exists to prevent.

## Hard vs soft: the readiness hinge

Declare every direct dependency in `resilience-dependencies.properties`:

```properties
# orders-db: nothing works without it
orders-db=hard
# pricing-api: degraded operation is possible
pricing-api=soft
```

**Comments are full-line only.** The parser skips a line that *starts* with `#`;
it does not strip a trailing one, so `orders-db=hard   # nothing works without it`
makes the value `hard   # nothing works without it`, which is not a valid kind and
fails at startup. That is the parser being deliberately loud rather than guessing
— but it means annotations go on their own line, as above.

- **hard down** → `/health/ready` returns 503, Kubernetes sheds traffic away from
  the pod, and `/health` reports `down`.
- **soft down** → readiness is **unaffected**. The breaker opens, the pod stays
  ready, `/health` reports `degraded`, and the background reconnect restores full
  function with no deploy.

That single classification is what resolves the tension between naive readiness
(shed traffic on any dependency loss) and resilience (stay up and degrade).

**Liveness is never a function of a dependency.** `/health/live` reflects only the
process; wiring a dependency into it turns a transient outage into a restart storm.

Set `OPS_DEPENDENCIES_FILE` to read the declaration from a mounted ConfigMap
instead of the classpath, so hard-vs-soft can be re-judged without a rebuild. A
path that is set but unreadable is a **startup failure**, not a silent fallback to
"no dependencies" — the latter would produce a health surface that reports nothing
wrong during a total outage.

**Both directions are startup failures, and you need both.**

- *Guarded in code but not declared* — `DependencyCatalog.requireDeclared`, called
  from your client's constructor. Without it the client works perfectly and is
  invisible on `/health`.
- *Declared but guarded by nobody* — `DependencyCatalog.requireAllDeclaredGuarded()`,
  called once at startup after your clients are built. This is the one that bites
  an adopter who keeps the shipped declaration: the name still gets a breaker (they
  are created eagerly, so a dependency can never be *missing* from `components`),
  but nothing ever calls through it, so it stays `CLOSED` forever and `/health`
  reports the dependency `up` straight through a total outage. A `hard` one never
  sheds traffic either.

Both are the same under-reporting the contract forbids, approached from opposite
sides — which is why one without the other leaves half the hole open.

## What `/health` looks like

```json
{
  "status": "degraded",
  "components": {
    "orders-db":   {"status": "up",   "kind": "hard", "breaker": "closed",
                    "since": "2026-08-03T09:14:22.311Z"},
    "pricing-api": {"status": "down", "kind": "soft", "breaker": "open",
                    "since": "2026-08-03T11:03:57.882Z"}
  }
}
```

- `/health` **always answers HTTP 200** while the process can respond — the verdict
  is in the body. 503 is the two probes' vocabulary; a `/health` that 503s during an
  outage is unreadable exactly when someone needs to read it.
- Breaker → status is exact: closed = `up`, half-open = `degraded`, open = `down`.
- The components set a **floor** on the aggregate, not an equality: `down` if any
  **hard** dependency is down, else `degraded` if **any** dependency is down or
  degraded, else `ok`. Note the hard/degraded case — a hard dependency that is
  merely half-open floors the aggregate at `degraded`, **not** `down`.
- Reporting something *more* severe is legal and expected: pass
  `OpsConfig.withInternalStatus(...)` to raise the aggregate for an impairment no
  dependency models (a backed-up queue, a full disk). Reporting something *less*
  severe is a conformance failure.
- **Direct dependencies only.** Never transitively call a downstream's `/health`:
  that is the health-check-storm anti-pattern, where one slow leaf hangs every
  ancestor's health check. Each service reports one hop and the observability layer
  assembles the graph.
- `components` is **omitted entirely** when the service declares no dependencies,
  so an ops-api v1.0 consumer stays valid.

## Verifying it

```bash
scripts/check-ops-conformance.zsh http://localhost:9090
```

The checker validates the `components` shape and enforces the aggregate floor. It
asserts a **serving** service, so a `down` aggregate fails it outright — `down` is
a legitimate runtime state, not one a conformance job can pass in.

Beyond the conformance run, the behaviour worth testing in your own suite:

1. force a **soft** dependency's breaker open → `/health/ready` still 200,
   `/health` reports `degraded` with that component `down`;
2. force a **hard** dependency's breaker open → `/health/ready` 503 and `/health`
   reports `down` (still HTTP 200);
3. a half-open breaker → that component reads `degraded`, and a **hard** dependency
   that is merely half-open floors the aggregate at `degraded`, not `down`;
4. with the breaker open, the guarded call is never attempted and returns the
   fallback in milliseconds (mandate 6).

The registry makes 1–3 easy to drive from a test — no fake dependency needed:

```java
catalog.breakers().circuitBreaker("pricing-api").transitionToOpenState();
```

## What this payload does NOT give you

It covers dependency health. `/info` and `/metrics` come from the `ops-api`
payload beside it, and `check-ops-conformance.zsh` still requires `/info` to carry
a non-empty `build.version`, a non-empty `build.git_sha`, and an `api[]`
served-majors table — supply those through `OpsConfig`.
