# Canonical ops-api implementation (Python, non-Spring) — #688

The blessed Python realization of the org-standard ops surface defined by
`contracts/ops/v1/openapi.yaml`: `/info`, `/health`, `/health/live`,
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
the deprecation machinery (#684) reads, and plug your readiness check (liveness
stays dependency-free):

```python
from <pkg>.ops_api import ApiMajor, OpsConfig, serve

serve(config=OpsConfig(
    served_majors=(
        ApiMajor(major=1, lifecycle="deprecated", sunset="2027-01-31"),
        ApiMajor(major=2, lifecycle="active"),
    ),
    readiness=lambda: db_pool.healthy(),  # /health/ready + /health; liveness never checks deps
))
```

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
