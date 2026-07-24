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
   OpsApi.serve(
       "0.0.0.0",
       9090,
       OpsApi.OpsConfig.defaults()
           .withServedMajors(
               OpsApi.ApiMajor.deprecated(1, "2027-01-31"),
               OpsApi.ApiMajor.active(2))
           .withReadiness(dbPool::isHealthy)); // /health/ready + /health; liveness never checks deps
   ```

`OpsApi.main` exists only as a **template smoke-run** of the shipped defaults (a
single active major) — it proves nothing about your service, so wire `serve(...)`
into your real entrypoint rather than shipping the bare `main`.

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
