# Canonical ops-api implementation (Java, non-Spring) — #935

The blessed Java realization of the org-standard ops surface defined by
`contracts/ops/v1/openapi.yaml`: `/info`, `/health`, `/health/live`,
`/health/ready`, `/metrics`. It conforms to the same fragment Spring services get
via Actuator, and passes `scripts/check-ops-conformance.zsh` unchanged. Spring
services are covered by `spring-config-advisor`'s conforms-to-ops-api check — use
this only for **plain, non-Spring** Java services.

It binds a separate **management port** (default `9090`), never the public app
port — so `/info`'s build data is unreachable from outside. Enforcing that
boundary (NetworkPolicy + a Service that omits the management port + the probe
wiring) is the deployment layer's job (the composition repo).

## Placement

Java couples a file's `package` to its directory, so adopting `OpsApi.java` is
three steps (unlike the Python module, which has no package-line coupling):

1. Drop `OpsApi.java` into your service's source set under a package of your
   choosing, e.g. `src/main/java/com/acme/orders/ops/OpsApi.java`.
2. Set its `package` line to match — `package com.acme.orders.ops;` (the shipped
   file's `package com.example.ops;` is a placeholder flagged at the top) — and
   **fold the dependencies from `build.gradle.kts`** (beside this file) into your
   service's own `build.gradle.kts`; it is a dependency fragment, not a
   standalone build script.
3. **Call `OpsApi.serve(...)` from your service's startup code** with your real
   `OpsConfig`, declaring the API majors you serve (so `/info` reports the
   lifecycle table the deprecation machinery (#684) reads) and your readiness
   check (liveness stays dependency-free):

   ```java
   DependencyCatalog dependencies = DependencyCatalog.load();
   // ... construct your dependency clients over `dependencies` here ...
   dependencies.requireAllDeclaredGuarded();   // <- do not skip; see below

   OpsApi.serve(
       "0.0.0.0",
       9090,
       OpsApi.OpsConfig.defaults()
           .withServedMajors(
               OpsApi.ApiMajor.deprecated(1, "2027-01-31"),
               OpsApi.ApiMajor.active(2))
           // Readiness has TWO halves. This supplier is the NON-dependency one:
           // still starting up, draining, an internal resource exhausted.
           .withReadiness(() -> !draining)
           // Dependencies are the other half — declared hard/soft and read from
           // breaker state, then ANDed with the supplier above. Do NOT probe a
           // datastore in withReadiness: declare it `hard` instead, or it never
           // appears in /health's components.
           .withDependencies(new DependencyHealth(dependencies)));
   ```

   **`requireAllDeclaredGuarded()` is not optional whenever you wire
   `withDependencies(...)`.** A dependency you declared but never routed through
   `dependencies.call(...)` still gets a breaker — which nothing can ever open — so
   `/health` would report it `up` straight through an outage. The guard turns that
   into a boot failure naming the offender. The resilience payload's
   `RESILIENCE.md` has the full wiring and both startup guards.

`OpsApi.main` exists only as a **template smoke-run** of the shipped defaults (a
single active major) — it proves nothing about your service, so wire `serve(...)`
into your real entrypoint rather than shipping the bare `main`.

**Dependency health (ops-api v1.1, #1142).** `/health` can also report one entry
per **direct** dependency under `components`, read passively from that
dependency's circuit-breaker state, with a `hard` dependency's loss failing
`/health/ready` and a `soft` one leaving readiness untouched. Wire it with
`.withDependencies(...)`; the blessed source is `DependencyHealth` from the
**resilience payload** beside this one
(`templates/languages/java/resilience/`, its own `README.md`). The binding is an
interface over plain records, so this class needs no breaker library on the
classpath and behaves exactly as before when you do not use it — no `components`
field, readiness from your `BooleanSupplier` alone.

Two contract points this implies, worth knowing before you change either:

- **`/health` answers 200 even when the aggregate is `down`** — the verdict is in
  the body. Only the two *probes* (`/health/live`, `/health/ready`) speak in
  status codes, because an operator reading `/health` during an outage needs the
  diagnosis rather than a bare 503.
- **`withReadiness` is now the non-dependency half of readiness** (still starting
  up, draining, an internal resource exhausted). Declared hard dependencies are
  the other half and are ANDed with it.

The run commands below assume your service starts as a **runnable jar with the
OTel dependencies on the runtime classpath** — an application/shadow jar, or
`./gradlew run`. A plain Gradle `jar` task produces neither the `Main-Class`
manifest nor the bundled deps, so `java -jar build/libs/your-service.jar` would
fail with `no main manifest attribute` / `NoClassDefFoundError: io/opentelemetry/…`;
use `./gradlew run` or put the OTel deps on the classpath explicitly.

## Instrumentation is OpenTelemetry-only

Per the org policy (ARCHITECTURE.md, #688): the OTel SDK `SdkMeterProvider` is
the single instrumentation source. **OTLP push to a collector is the primary
pipeline** — `OpsApi` wires an OTLP metric reader automatically when the standard
`OTEL_EXPORTER_OTLP_ENDPOINT` env var is set (honoring `OTEL_EXPORTER_OTLP_PROTOCOL`
= `grpc` (default) or `http/protobuf`; a malformed endpoint is logged and skipped,
never fatal). `/metrics` is the **mandatory pull-compat surface**, served by the
OTel SDK's Prometheus exporter (`PrometheusHttpServer`) — a config wiring, not a
second metrics system. It stays curl-able so conformance and smoke checks need no
collector.

Unlike Python's `PrometheusMetricReader` (which feeds a registry the app serves
itself), OTel Java's Prometheus exporter ships only as `PrometheusHttpServer` — a
reader that runs its **own** embedded HTTP server. To present all five ops
endpoints on one management port, `OpsApi` binds `PrometheusHttpServer` to
loopback on an internal port (`OPS_PROMETHEUS_PORT`, default management port + 1)
and reverse-proxies `GET /metrics` to it. The OTel exporter still owns the
exposition; nothing bypasses the SDK.

## Conformance

Verify your **real** service, not the template default: start the entrypoint that
calls `serve(...)` with your `OpsConfig` (placement step 3 above), then run the
checker against the management port:

```bash
# in one shell — your service's real entrypoint (the one that calls OpsApi.serve
# with your OpsConfig), NOT the bare OpsApi main (that only exercises the defaults)
java -jar build/libs/your-service.jar
# in another — point the checker at the management port
zsh scripts/check-ops-conformance.zsh http://localhost:9090
```

The `ops-conformance` CI job — installed by bootstrap **when the repo has a
Dockerfile** (otherwise bootstrap records a TODO to wire it once the service has a
canonical container, since the job builds the Docker image) — does exactly this on
every PR that touches `contracts/ops/`.
