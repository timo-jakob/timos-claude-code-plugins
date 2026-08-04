# Adopt the standardized ops surface on your service

Every backend service that exposes an HTTP surface carries one org-standard
operations surface — `/info`, `/health` (aggregate), `/health/live` (K8s
liveness), `/health/ready` (K8s readiness), `/metrics` — defined as a shared,
versioned OpenAPI fragment so "standardised" is testable rather than
aspirational. For the design and *why*, see the [WebUI plugin family design](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/docs/superpowers/specs/2026-07-10-webui-plugin-family-design.md)
§5.

**Liveness and readiness are distinct on purpose.** Liveness answers "is the
process wedged — restart it?" and must be dependency-free; readiness answers "can
it serve traffic right now?" and is where dependency checks belong. Wiring a
single `/health` to both probes is the anti-pattern where a transient dependency
blip restarts every pod at once.

**The surface is INTERNAL.** It is served on a separate **management port**
(default `9090`), never the public app port, so `/info`'s build data is
unreachable from outside without any per-endpoint auth. Enforcing that boundary —
a `NetworkPolicy` restricting the management port to the kubelet + the monitoring
namespace, a `Service`/`Ingress` that exposes only the app port, and the
liveness/readiness probe wiring — is the **deployment layer's** job (the
composition repo), not this contract's. `/info` is minimal by contract (build
version, git SHA, API-major lifecycle only) — never framework/server/OS versions.

Bootstrap installs the surface alongside the contracts machinery when your repo
has an API surface. You get three things:

- **`contracts/ops/v1/openapi.yaml`** — the fragment. It rides the same CI gates
  as your business contract: `contracts-lint` (Spectral) and `contracts-semver`
  (oasdiff) discover `contracts/ops/v[0-9]*/openapi.yaml`, so a breaking change
  to the ops surface is a new ops major, never an in-place edit.
- **`scripts/check-ops-conformance.zsh`** — the conformance checker.
- **`.github/workflows/ops-conformance.yml`** — a standalone CI job that builds
  the canonical container, waits for `/health/ready`, and runs the checker.
  Installed only when your repo has a **Dockerfile** (the container the job
  builds); on a Dockerfile-less repo you get the fragment + checker and a TODO to
  wire the job once a canonical container exists.

## Verify a running service

Point the checker at the **management** base URL (the port your ops surface
listens on, not the public app port):

```bash
zsh scripts/check-ops-conformance.zsh http://localhost:9090
```

It curls `/info`, `/health`, `/health/live`, `/health/ready`, and `/metrics` and
validates them against the fragment — including the rule that a **deprecated**
API major must carry a sunset date (RFC 8594). Exit 0 means conformant; any
failure names the offending path:

```text
::error:: /metrics: expected HTTP 200, got 404
ops conformance FAILED: 1 problem(s) at http://localhost:9090
```

The `/info` payload is what makes the deprecation lifecycle observable:

```json
{
  "build": {"version": "1.4.2", "git_sha": "9f3c2ab"},
  "api": [
    {"major": 1, "lifecycle": "deprecated", "sunset": "2027-01-31"},
    {"major": 2, "lifecycle": "active"}
  ]
}
```

## Implement the surface

Instrumentation is **OpenTelemetry only** (OTel SDK + semantic conventions);
OTLP push to a collector is the primary pipeline and `/metrics` is the mandatory
pull-compat surface served by the SDK's Prometheus exporter.

- **Spring** — Actuator does **not** conform out of the box. Use the blessed
  reference implementation bootstrap installs, the **Spring resilience payload**
  (`templates/languages/spring/resilience/`, #1141): its `OpsHealthEndpoint`
  serves `/health`, `/health/live` and `/health/ready` in the contract's shape,
  including the per-dependency `components` map read from circuit-breaker state,
  and it brings the hard/soft declaration that drives readiness. See its
  `README.md`.

  Adopting it is three steps — mechanical except where noted: place its sources,
  **merge its `application-resilience.yml`** into your `application.yml`, and fold
  its `build.gradle.kts` block into your build. Three things in there are **not**
  mechanical, and each fails quietly if you skip it: re-set every `.java` file's
  flagged `package com.example.ops;` line to the package you place it in;
  **adapt `PricingApiClient.java` to a real dependency before placing it, or leave
  it out** (as shipped it reads `${pricing-api.base-url}`, which the payload
  deliberately never defines, so an unadapted placement breaks startup and every
  `@SpringBootTest` context load); and **replace the worked-example `orders-db` /
  `pricing-api` entries with your real direct dependencies** during the merge —
  merged verbatim they *work*, and `/health` then reports two dependencies you do
  not have as `up`, which is the lying health surface this payload exists to
  prevent. Those three steps supply the management
  port (`management.server.port: 9090`), the `info,prometheus,opshealth` exposure
  list — deliberately **without** Actuator's own `health`, which would map onto
  the same path — the root remap (`management.endpoints.web.base-path: /`,
  `path-mapping.opshealth: health`, `path-mapping.prometheus: metrics`), and
  `micrometer-registry-prometheus`.

  What is genuinely still yours: Gradle **build-info** plus a custom
  **`InfoContributor`** emitting `build.version`, `build.git_sha` and the
  served-majors `api[]` table, which the payload does not provide and the
  conformance checker requires.

  *Not adopting the payload?* Then the pre-#1141 route still applies — expose
  `health` too and write your own health representation, since Actuator returns
  `UP` and that part needs code, not config. Note that
  `management.endpoint.health.probes.enabled: true` is **not** enough for the two
  probe paths: its groups are named `liveness`/`readiness`, so they serve
  `/health/liveness` and `/health/readiness` while the checker fetches
  `/health/live` and `/health/ready`. Declare groups named to match —
  `management.endpoint.health.group.live.include: livenessState` and
  `…group.ready.include: readinessState` — keeping the `live` group
  dependency-free. `spring-config-advisor` flags a non-conforming config with
  these specifics either way, and branches on whether the payload is present.
- **Python (non-Spring)** — use the blessed reference implementation bootstrap
  installs under your package (`ops_api.py` + `requirements.txt`); it serves the
  full surface on the management port and passes the conformance checker
  unchanged. See its `README.md`.
- **Java (non-Spring)** — use the blessed reference implementation bootstrap
  installs (`OpsApi.java` + a `build.gradle.kts` dependency fragment): place it
  under a package in your service's source set, set its `package` line to match,
  fold in the OTel dependencies, and call `OpsApi.serve(...)` from your startup
  with your `OpsConfig`. It serves the full surface on the management port and
  passes the conformance checker unchanged. See its `README.md`.

  Bootstrap installs the **resilience payload** alongside it (the two are placed
  together or not at all), which is what fills in the v1.1 half — per-dependency
  `components` on `/health` and the hard/soft readiness hinge, both read from
  circuit-breaker state. Four things are yours to do, and three of them fail
  quietly if you skip them:

  - declare your direct dependencies in `resilience-dependencies.properties`
    (`<name>=hard|soft`, one per line, **full-line `#` comments only**) and
    **replace the shipped `orders-db`/`pricing-api` examples** — left verbatim
    they fail startup on `requireAllDeclaredGuarded()` (nothing guards them), and
    if you skip that call `/health` reports two dependencies you do not have as
    `up`;
  - route every outbound call through `catalog.call(name, call, fallback)`, and
    give the call its own connect **and** request timeout — the one mandate the
    catalog cannot impose, because it does not own your socket;
  - wire `.withDependencies(new DependencyHealth(catalog))` into your
    `OpsConfig`, and set its `package` line as for `OpsApi.java` (it must live in
    the same package);
  - call `catalog.requireAllDeclaredGuarded()` once at startup, after your
    clients are built. It is the only thing that catches a dependency you
    declared but never wired — whose breaker can never leave `CLOSED`, so
    `/health` would report it `up` throughout an outage.

  `PricingApiClient.java` is a worked example, not service code: adapt it to a
  real dependency or leave it out. The payload's own `RESILIENCE.md` is the
  reference for the shape.
- **Other languages** — canonical implementations are tracked per language
  (Node, Swift).

## Who enforces the boundary — you, or the platform?

The **service** provides the seam (the management port); the **platform /
composition repo** enforces the boundary, because reachability is a deployment
fact the app can't assert about itself:

| Concern | Owned by |
| --- | --- |
| Distinct liveness/readiness endpoints; minimal `/info`; a management port | Here (the service + this contract) |
| `NetworkPolicy` restricting the management port to kubelet + monitoring | Composition repo (`#687`/`#719`/`#720`) |
| `Service`/`Ingress` exposing only the app port | Composition repo |
| `livenessProbe`/`readinessProbe` wiring; Prometheus `ScrapeConfig`/`ServiceMonitor` | Composition repo |

Ops endpoints stay **internal** — never published as APIM products, never on the
public app port.
