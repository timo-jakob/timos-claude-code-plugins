# Spring Boot resilience + dependency health

The blessed Spring Boot realization of the org resilience policy and the ops-api
v1.1 dependency-health contract (issue #1141, epic #964). Copied into your
service by `/development:bootstrap`; this file explains what landed and what you
still have to do.

The idea in one line: **the circuit breaker keeps you serving; the
dependency-health surface tells you what's degraded.** An open breaker *is* a
down dependency, so `/health` reads breaker state rather than running a second
health mechanism.

## The blessed library: resilience4j

**resilience4j is *the* circuit-breaker library for Spring Boot in this family.**
One library, no options.

- `io.github.resilience4j:resilience4j-spring-boot4:2.4.0` — the Spring Boot 4
  starter. It gives a **named `CircuitBreaker` per dependency in a registry you
  can read**, which is exactly the unit the ops-api `components` map reports.
- **Spring Cloud Circuit Breaker is deliberately not used.** Its
  `CircuitBreakerFactory` abstraction exists to make the breaker library
  swappable — a portability layer we do not want, since we bless exactly one
  library — and it hides the registry the `/health` binding has to read.
- The version is **pinned directly, not through `resilience4j-bom`**: the BOM
  (2.4.0) still lists only the Boot 3 starter, so importing it would leave this
  artifact unmanaged while implying otherwise. **Two bots keep it current, in two
  different places**: Renovate's gradle manager reads this pin out of the shipped
  template — the fragment needs no surrounding Gradle project — so each new
  bootstrap starts on a current version; and once you have folded the block into
  your build, the copy in **your** repo is yours, kept moving by your own
  Renovate/Dependabot. An upstream bump never reaches you retroactively.
- `spring-boot-starter-aop` is **required, not optional** — `@CircuitBreaker`,
  `@Retry` and `@TimeLimiter` are Spring AOP aspects, and without it they are
  silently inert: the calls run unprotected and nothing warns you.
- `io.micrometer:micrometer-registry-prometheus` is **also required** — for
  `/metrics`, not for resilience. `spring-boot-starter-actuator` does not bring a
  Prometheus registry, and Boot only auto-configures the `prometheus` endpoint
  when one is on the classpath, so without it `/metrics` 404s and
  `check-ops-conformance.zsh` fails in your CI rather than here.

## Files

| File | Goes to | What it does |
|---|---|---|
| `build.gradle.kts` | fold into your `build.gradle.kts` | the dependency block |
| `application-resilience.yml` | merge into your `application.yml` | breaker/retry/timeout config, the management port, and the hard/soft declaration |
| `DependencyCatalog.java` | `src/main/java/<pkg>/ops/` | binds `resilience.dependencies` — the hard/soft declaration |
| `DependencyHealth.java` | `src/main/java/<pkg>/ops/` | reads breaker state into ops-api components, the aggregate, and the readiness answer |
| `OpsHealthEndpoint.java` | `src/main/java/<pkg>/ops/` | the Actuator endpoint serving `/health`, `/health/live`, `/health/ready` |
| `PricingApiClient.java` | **adapt first — see below** | the worked six-mandate client — copy the shape, not the domain |

Every `.java` file ships with `package com.example.ops;` flagged **`<-- CHANGE`**.
Java couples a file's package to its directory, so re-set it to wherever you place
the file.

**`PricingApiClient.java` must be adapted before you place it, or not placed at
all.** It is a `@Component` whose constructor reads
`@Value("${pricing-api.base-url}")`, and **nothing in this payload defines that
property** — deliberately, because `pricing-api` is an example, not your
dependency. Dropped into a scanned source set as-is, it fails application startup
and every `@SpringBootTest` context load on an unresolvable placeholder. So either
rename/repackage it to your real dependency and define that dependency's
`base-url` in your config, or leave it out and keep this README as the reference
for the shape.

## The six mandates

Every governed outbound call MUST have all six. `PricingApiClient` is the
reference:

| # | Mandate | Where it lives |
|---|---|---|
| 1 | timeout | `spring.http.clients.{connect,read}-timeout` (plural `clients` — the singular Boot 3 spelling is deprecated and binds nothing) |
| 2 | circuit breaker (one **per dependency**) | `@CircuitBreaker(name = "...")` + `resilience4j.circuitbreaker.instances` |
| 3 | bounded retry + jittered backoff | `@Retry(name = "...")` + `enable-exponential-backoff` and `enable-randomized-wait` |
| 4 | registered fallback | `fallbackMethod` on `@Retry` |
| 5 | background reconnect | `automatic-transition-from-open-to-half-open-enabled: true` |
| 6 | stay-stable | an open breaker fast-fails into the fallback — never a parked thread |

Two wiring details that are easy to get wrong and silent when you do:

- **`fallbackMethod` belongs on `@Retry`, not `@CircuitBreaker`.** resilience4j
  makes Retry the outermost aspect (`retryAspectOrder` 2147483642 <
  `circuitBreakerAspectOrder` 2147483643; in Spring AOP the lower order is the
  outer aspect). A fallback on `@CircuitBreaker` turns the failure into a
  successful return *before* Retry sees it, so the call is never retried.
- **`CallNotPermittedException` is in the retry's `ignore-exceptions`.** Because
  Retry is outermost, without this an open breaker's fast-fail is itself retried
  — burning the whole backoff schedule on a dependency already known to be down.

The plugin enforces that a fallback is **wired**, never what it returns.
Structure is the org's business; the degraded behaviour is yours.

## Hard vs soft: the readiness hinge

Declare every direct dependency in `application.yml`:

```yaml
resilience:
  dependencies:
    orders-db:
      kind: hard      # nothing works without it
    pricing-api:
      kind: soft      # degraded operation is possible
```

- **hard down** → `/health/ready` returns 503, Kubernetes sheds traffic away from
  the pod, and `/health` reports `down`.
- **soft down** → readiness is **unaffected**. The breaker opens, the pod stays
  ready, `/health` reports `degraded`, and the background reconnect restores full
  function with no deploy.

That single classification is what resolves the tension between naive readiness
(shed traffic on any dependency loss) and resilience (stay up and degrade).

### What the probe 503s carry (ops-api v2, #1330)

This payload is the **Spring** replacement the ops how-to's migration step names,
so what changed on the wire is here rather than in an `ops-api/` README: both
probe 503s are **RFC 9457 problem documents** on **`application/problem+json`** —
bare, so the response must not also offer `application/json`.

```json
{
  "type": "urn:problem-type:ops:not-ready",
  "title": "Service Not Ready",
  "status": 503,
  "detail": "hard dependency 'orders-db' is down",
  "components": { "orders-db": { "status": "down", "kind": "hard", "breaker": "open" } }
}
```

- `status` is the **integer** HTTP code (RFC 9457), not the health envelope's
  `"ok"`/`"down"` string. That collision is why ops-api v2 exists.
- `components` is the **same map `/health` serves**, carrying **all** declared
  dependencies rather than only the failing ones; omitted only when the service
  declares none.
- `detail` is a fixed vocabulary: `hard dependency '<name>' is down` (several:
  names sorted lexicographically, comma-joined), or `the service is starting up`.

**Spring is the one payload that can also answer a liveness 503.** The other five
serve `/health/live` unconditionally 200 — a process that can answer HTTP is
alive — but here liveness reads `ApplicationAvailability.LivenessState`, which a
service can set to `BROKEN` independently of any dependency. That 503 carries
`urn:problem-type:ops:not-alive` / `Service Not Alive` / `the process is not alive
and should be restarted`, and **no `components`**: liveness is dependency-free by
contract, so a map there would be a lie.

The `200` responses are unchanged.

**Liveness is never a function of a dependency.** `/health/live` reflects only
the process; wiring a dependency into it turns a transient outage into a restart
storm.

A declared dependency with **no matching breaker is a startup failure**, on
purpose: without a breaker there is nothing to read, and the endpoint would
report the dependency `up` unconditionally — exactly the under-reporting the
contract forbids. Better a loud boot failure than a health surface that lies
during an outage.

## What `/health` looks like

```json
{
  "status": "degraded",
  "components": {
    "orders-db":   {"status": "up",   "kind": "hard", "breaker": "closed",
                    "since": "2026-08-02T09:14:22.311Z"},
    "pricing-api": {"status": "down", "kind": "soft", "breaker": "open",
                    "since": "2026-08-02T11:03:57.882Z"}
  }
}
```

- `/health` **always answers HTTP 200** while the process can respond — the
  verdict is in the body. 503 is the two probes' vocabulary; a `/health` that
  503s during an outage is unreadable exactly when someone needs to read it.
- Breaker → status is exact: closed = `up`, half-open = `degraded`, open =
  `down`.
- The components set a **floor** on the aggregate, not an equality: `down` if any
  **hard** dependency is down, else `degraded` if **any** dependency is down or
  degraded, else `ok`. Reporting something *more* severe is legal and expected —
  add your own internal degradation (a backed-up queue, a full disk) to
  `DependencyHealth.aggregate()`. Reporting something *less* severe is a
  conformance failure.
- **Direct dependencies only.** Never transitively call a downstream's
  `/health`: that is the health-check-storm anti-pattern, where one slow leaf
  hangs every ancestor's health check. Each service reports one hop and the
  observability layer assembles the graph.
- `components` is **omitted entirely** when the service declares no dependencies,
  so an ops-api v1.0 consumer stays valid.

## Why an Actuator endpoint, and not a `@RestController`

Actuator supplies `/info`, `/metrics` (given the Prometheus registry dependency
above), and the `ApplicationAvailability` state that readiness builds on — so
startup and graceful-shutdown behaviour is Spring's own, not re-implemented. But
its **health** endpoint cannot express this contract: it spells states `UP`/`DOWN`
and nests a component's custom fields under `details`, whereas ops-api needs
`{status, kind, breaker, since}` at the component root.

So the ops health surface is our own — served as an Actuator **`@Endpoint`**, for
a reason worth knowing before you "simplify" it into a controller:

- The management port is served by a **child application context**, and that child
  runs a deliberately minimal MVC stack — a `DispatcherServlet` plus a
  `CompositeHandlerMapping` that only collects the `HandlerMapping` beans present.
  There is **no `RequestMappingHandlerMapping`** and no `RouterFunctionMapping`
  there, so a `@RestController` registered into that context is **never mapped at
  all**.
- A `@RestController` in the **main** context is mapped — on the **public app
  port**, publishing the dependency graph exactly where the management port exists
  to keep it from.
- `@RestControllerEndpoint`, which used to bridge this, has been **deprecated for
  removal since Spring Boot 3.3**.

An `@Endpoint` has none of those problems: it is an ordinary bean of the main
context (so `DependencyHealth` injects normally) and Actuator's own endpoint
handler mapping serves it on the management port.

Its id is **`opshealth`**, not `health`, because Actuator's own `HealthEndpoint`
bean exists whenever Actuator is on the classpath and two endpoints sharing an id
fail endpoint discovery at startup. `management.endpoints.web.path-mapping`
then puts it at the contract's path:

```yaml
management:
  endpoints:
    web:
      base-path: /
      exposure:
        include: info,prometheus,opshealth   # NOT actuator's own `health`
      path-mapping:
        opshealth: health                    # -> /health, /health/live, /health/ready
        prometheus: metrics
```

The payload also replaces Boot's `EndpointMediaTypes` bean so the ops endpoints
produce plain **`application/json`** — the media type the contract declares.
Actuator's default lists `application/vnd.spring-boot.actuator.v3+json` first, so
without the override a client that accepts anything (curl, a probe, a spec-driven
mock) is served the vendor type. This also brings `/info` onto `application/json`;
`/metrics` is unaffected, since the Prometheus endpoint declares its own exposition
types. Do not delete the bean when tidying the class — nothing fails loudly if you
do.

`/health/live` and `/health/ready` come from the endpoint's `@Selector` operation,
so all three paths are one endpoint. Adding Actuator's `health` back to the
exposure list would map two endpoints onto `/health`.

## What this payload does NOT give you

It covers the **health** third of the ops surface. Two gaps remain, and
`check-ops-conformance.zsh` fails on them until you close them — so read this
before you conclude the payload is broken:

- **`/info` still needs an `InfoContributor`.** The checker requires a non-empty
  `build.version`, a non-empty `build.git_sha`, and an `api[]` served-majors
  table with a `lifecycle` per major (and a sunset date on a deprecated one).
  Stock Actuator `/info` has none of that shape. Wire build-info into the Gradle
  build and add a custom `InfoContributor` that emits the majors your service
  serves.
- **`/metrics` needs the Prometheus registry dependency**, shipped in
  `build.gradle.kts` above — but only if you actually folded that block in.

Health itself — `/health`, `/health/live`, `/health/ready` — conforms out of the
box once the sources are placed and the config merged.

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
   reports `down`;
3. a half-open breaker → that component reads `degraded`, and a **hard**
   dependency that is merely half-open floors the aggregate at `degraded`, not
   `down`;
4. with the dependency dead, the fallback returns and no request thread is parked
   on the dead socket (mandate 6).

`CircuitBreakerRegistry` makes 1–3 easy to drive from a test:
`registry.circuitBreaker("pricing-api").transitionToOpenState()`.
