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

- **Spring** — Actuator does **not** conform out of the box. Put it on a
  management port (`management.server.port: 9090`); expose `health`, `info`,
  `prometheus`; remap to the root (`management.endpoints.web.base-path: /` and
  `path-mapping.prometheus: metrics`); enable the probes
  (`management.endpoint.health.probes.enabled: true`) for `/health/live` +
  `/health/ready`, keeping liveness dependency-free; add
  `micrometer-registry-prometheus` and an `InfoContributor` for the served-majors
  table; and represent `/health` as `{"status":"ok"}` (Actuator returns `UP` —
  this part needs a small custom health representation, not just config).
  `spring-config-advisor` flags a non-conforming config with these specifics.
- **Python (non-Spring)** — use the blessed reference implementation bootstrap
  installs under your package (`ops_api.py` + `requirements.txt`); it serves the
  full surface on the management port and passes the conformance checker
  unchanged. See its `README.md`.
- **Other languages** — canonical implementations are tracked per language
  (Java non-Spring, Node, Swift).

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
