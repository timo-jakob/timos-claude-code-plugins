# Canonical ops-api implementation (Python, non-Spring) — #688

The blessed Python realization of the org-standard ops surface defined by
`contracts/ops/v2/openapi.yaml`: `/info`, `/health`, `/health/live`,
`/health/ready`, `/metrics`. It conforms to the same fragment Spring services get
via Actuator, and passes `scripts/check-ops-conformance.zsh` unchanged.

It binds a separate **management port** (default `9090`), never the public app
port — so `/info`'s build data is unreachable from outside. Enforcing that
boundary (NetworkPolicy + a Service that omits the management port + the probe
wiring) is the deployment layer's job (the composition repo).

## Placement

Drop `ops_api.py` into your package (e.g. `src/<pkg>/ops_api.py`) and add the
dependencies from `requirements.txt` to your project. Run it as a lightweight
ops surface on the management port:

```bash
BUILD_VERSION="$(git describe --tags --always)" GIT_SHA="$(git rev-parse HEAD)" \
  python -m <pkg>.ops_api          # serves on :9090 (override with OPS_PORT)
```

Declare the API majors your service serves so `/info` reports the lifecycle table
the deprecation machinery (#684) reads, and plug the **non-dependency half** of
readiness (liveness stays dependency-free):

```python
from <pkg>.ops_api import ApiMajor, OpsConfig, serve

serve(config=OpsConfig(
    served_majors=(
        ApiMajor(major=1, lifecycle="deprecated", sunset="2027-01-31"),
        ApiMajor(major=2, lifecycle="active"),
    ),
    readiness=lambda: not draining,  # NON-dependency reasons only: starting up, draining
))
```

## Dependency health (ops-api v1.1) — #1143

`/health` carries an optional `components` map: one entry per **direct**
dependency, read passively from that dependency's circuit-breaker state, plus a
`degraded` aggregate. A declared **hard** dependency being down also fails
`/health/ready`; a **soft** one never does. Wire it by passing a
`DependencyHealthSource`:

```python
serve(config=OpsConfig(dependencies=DependencyHealth(catalog)))
```

The blessed source is `DependencyHealth` from the **resilience payload** shipped
beside this one (`RESILIENCE.md` once placed) — bootstrap installs the two
together. Without it this module behaves exactly as before: no `components`
field, and readiness is your `readiness` callable alone. The binding is a
protocol over a plain dataclass, so this file needs no breaker library installed.

`readiness` remains the **non-dependency** half of the answer — still starting
up, draining during a graceful shutdown, an internal resource exhausted — and is
checked first. `internal_status` is the over-reporting hook: components set a
**floor** on the aggregate, so a service impaired for a reason no dependency
models must report a *more* severe aggregate, never a less severe one.

**`/health` answers HTTP 200 even when the aggregate is `down`** — the verdict is
in the body. 503 is the two probes' vocabulary (`/health/live`, `/health/ready`),
not the human-facing aggregate's. An earlier revision of this template aliased
`/health` to the readiness handler and answered 503, which the contract forbids
and the checker rejects (#1139, Python half — fixed here).

### What the readiness `503` carries (ops-api v2, #1330)

The 503 is not a bare status code: its body is an **RFC 9457 problem document**
served as **`application/problem+json`** — bare, so the response must not also
offer `application/json`.

```json
{
  "type": "urn:problem-type:ops:not-ready",
  "title": "Service Not Ready",
  "status": 503,
  "detail": "hard dependency 'orders-db' is down",
  "components": { "orders-db": { "status": "down", "kind": "hard", "breaker": "open" } }
}
```

Three things the shape is easy to get wrong:

- `status` is the **integer** HTTP code (RFC 9457), not the health envelope's
  `"ok"`/`"down"` string. That collision is why ops-api v2 exists.
- `components` is the **same map `/health` serves**, carrying **all** declared
  dependencies rather than only the failing ones — so a shed pod and the dashboard
  agree. It is omitted only when the service declares no dependencies at all.
- `detail` is a fixed vocabulary, not free prose: `hard dependency '<name>' is
  down` (several: names sorted lexicographically, comma-joined), or `the service is
  starting up` for a non-dependency reason.

The `200` responses are unchanged.

## Instrumentation is OpenTelemetry-only

Per the org policy (ARCHITECTURE.md, #688): the OTel SDK `MeterProvider` is the
single instrumentation source. **OTLP push to a collector is the primary
pipeline** — add `opentelemetry-exporter-otlp` and an OTLP reader to wire it.
`/metrics` is the **mandatory pull-compat surface**, served here by the OTel
SDK's `PrometheusMetricReader` feeding `prometheus_client` — a config wiring,
not a second metrics system. It stays curl-able so conformance and smoke checks
need no collector.

## Conformance

Verify your **real** service, not the template default. `python -m <pkg>.ops_api`
runs the module's `__main__`, which uses the default `OpsConfig` (a single
active major) — it passes the checker trivially and proves nothing about your
service's actual lifecycle table. Start the entrypoint that passes your real
`OpsConfig` (from the placement snippet above), then run the checker:

```bash
# in one shell — your service's real ops entrypoint (passes your OpsConfig),
# NOT `python -m <pkg>.ops_api` (that only exercises the template default)
python -m <pkg>
# in another — point the checker at the management port
zsh scripts/check-ops-conformance.zsh http://localhost:9090
```

The `ops-conformance` CI job (installed by bootstrap) does exactly this against
the canonical container on every PR that touches `contracts/ops/`.
