# Adopt the standardized ops surface on your service

Every backend service exposes one org-standard operations surface — `/info`,
`/health`, `/metrics` — defined as a shared, versioned OpenAPI fragment so
"standardised" is testable rather than aspirational. For the design and *why*,
see the [WebUI plugin family design](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/docs/superpowers/specs/2026-07-10-webui-plugin-family-design.md)
§5.

Bootstrap installs the surface alongside the contracts machinery when your repo
has an API surface. You get three things:

- **`contracts/ops/v1/openapi.yaml`** — the fragment. It rides the same CI gates
  as your business contract: `contracts-lint` (Spectral) and `contracts-semver`
  (oasdiff) discover `contracts/ops/v[0-9]*/openapi.yaml`, so a breaking change
  to the ops surface is a new ops major, never an in-place edit.
- **`scripts/check-ops-conformance.zsh`** — the conformance checker.
- **`.github/workflows/ops-conformance.yml`** — a standalone CI job that builds
  the canonical container, waits for `/health`, and runs the checker. Installed
  only when your repo has a **Dockerfile** (the container the job builds); on a
  Dockerfile-less repo you get the fragment + checker and a TODO to wire the job
  once a canonical container exists.

## Verify a running service

```bash
zsh scripts/check-ops-conformance.zsh http://localhost:8080
```

It curls `/info`, `/health`, and `/metrics` and validates them against the
fragment — including the rule that a **deprecated** API major must carry a
sunset date (RFC 8594). Exit 0 means conformant; any failure names the offending
path:

```text
::error:: /metrics: expected HTTP 200, got 404
ops conformance FAILED: 1 problem(s) at http://localhost:8080
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

- **Spring** — Actuator does **not** conform out of the box. Expose `health`,
  `info`, `prometheus`; remap them to the root (`management.endpoints.web.base-path:
  /` and `path-mapping.prometheus: metrics`); add `micrometer-registry-prometheus`
  and an `InfoContributor` emitting the served-majors table; and represent
  `/health` as `{"status":"ok"}` (Actuator returns `UP` — this part needs a small
  custom health representation, not just config). `spring-config-advisor` flags a
  non-conforming config with these specifics.
- **Python (non-Spring)** — use the blessed reference implementation bootstrap
  installs under your package (`ops_api.py` + `requirements.txt`); it passes the
  conformance checker unchanged. See its `README.md`.
- **Other languages** — canonical implementations are tracked per language
  (Java non-Spring, Node, Swift).

Ops endpoints stay **internal** — never published as APIM products.
