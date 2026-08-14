# Canonical ops-api implementation (Swift) — #937

The blessed Swift realization of the org-standard ops surface defined by
`contracts/ops/v2/openapi.yaml`: `/info`, `/health`, `/health/live`,
`/health/ready`, `/metrics`. It conforms to the same fragment Spring services get
via Actuator, and passes `scripts/check-ops-conformance.zsh` unchanged.

It binds a separate **management port** (default `9090`, override with
`$OPS_PORT`), never the public app port — so `/info`'s build data is unreachable
from outside. Enforcing that boundary (NetworkPolicy + a Service that omits the
management port + the probe wiring) is the deployment layer's job (the
composition repo).

This payload serves the **service** shape: a runnable Swift server with a
long-lived listener, deployed on Linux. A Swift *client* — an iOS/macOS app, a
library-only SwiftPM package, a CLI tool — has no ops surface to expose, and
bootstrap's gate classifies it as such rather than installing this.

## Placement

Copy `OpsApi.swift` into your service as `Sources/<ServiceTarget>/Ops/OpsApi.swift`,
with this `README.md` beside it. There are **no placeholders** — the file is copied
verbatim.

Then paste the two blocks from `Package.swift.deps` (beside this file) into your
`Package.swift`: the `.package(url:)` lines into the top-level `dependencies:`, and
the `.product(name:)` lines into the `dependencies:` of the target that now holds
`Ops/OpsApi.swift`. Keep the fragment where it is — it is the record of what those
pastes were, and this README refers to it by name.

**Bootstrap adds dependencies only — it performs no `targets:` edit.** Which target
owns the payload, and whether you give it a dedicated one, is a structural decision
about your package. The manifest must declare `// swift-tools-version:6.1` or newer
and the payload's target should carry `swiftSettings: [.swiftLanguageMode(.v6)]`:
the payload compiles with zero concurrency diagnostics under the Swift 6 language
mode, and that is the bar it is verified against.

Then call it from your startup:

```swift
// Bootstrap the metrics system ONCE, before serving.
let metrics = try OpsMetrics.bootstrap()

try await OpsApi.serve(
    config: OpsConfig(
        servedMajors: [
            APIMajor(major: 1, lifecycle: .deprecated, sunset: "2027-01-31"),
            APIMajor(major: 2, lifecycle: .active),
        ],
        readiness: { !draining.load(ordering: .relaxed) },  // NON-dependency reasons only
        dependencies: nil                                   // the v1.1 seam; see below
    ),
    metrics: metrics
)
```

**The two majors above are an illustration — declare your real ones.** Copied
verbatim, that snippet makes `/info` advertise a deprecation of major 1 with a
sunset your service never agreed to, and the #684 deprecation machinery treats it
as real. The `/info` lifecycle table is exactly what makes that machinery
observable, so it has to be true.

Unlike the Go payload, `servedMajors` has **no default**: an empty table refuses
startup. A defaulted "active major 1" is the same trap by another route — a v2-only
service that never set it would advertise a major it does not serve, and pass
conformance while doing so. Declaring the table is one line; guessing it wrong is
an outage-shaped lie in your build metadata.

Both halves of the lifecycle-sunset invariant are enforced at startup by
`OpsConfig.validated()`: a **deprecated** major must carry a sunset date (RFC 8594),
and an **active** one must not. Only the first is also caught downstream —
`check-ops-conformance.zsh` fails a deprecated major with no sunset, but neither it
nor the fragment's schema checks that an active major carries none, so for that half
this validation is the only enforcement anywhere.

## Build metadata fails fast — by design

`/info`'s `build.version` comes from `$BUILD_VERSION` and `build.git_sha` from
`$GIT_SHA`, and **neither has a fallback**. An unset one throws at startup naming
the variable, before the listener binds. There is no `"unknown"`, no render-time
constant, no placeholder.

This is deliberate, and it is the strictest position in the family: Python, Java and
Go fall back to `"unknown"`, and Node fails closed on `$GIT_SHA` alone (its
`build.version` still falls back). Swift fails closed on both. A build stamp that
lies is worse than one that is absent, because `/info` is the first thing that both
the #684 deprecation machinery and an incident triage read.

**Where the refusal lands first depends on whether your repo has a Dockerfile.**
With one, the `ops-conformance` job bootstrap installs builds and runs the container
*without* passing these variables, so that job — not your first deploy — is where the
service refuses to start; its headline failure is "service did not become ready", and
the variable is named in the `docker logs` dump the same step emits. Wire an
`ARG`/`ENV` pair into the Dockerfile with a CI-supplied value. Without a Dockerfile,
no such job is installed and the first *deploy* is where it lands: whatever runs the
service owes both variables.

## Conformance

Start your service, then point the shipped checker at the **management** base URL:

```bash
zsh scripts/check-ops-conformance.zsh http://localhost:9090
```

Run it against your **real entrypoint**, not a scratch main built around the
template: what conforms is the surface your service actually serves. Bootstrap
also wires this as an `ops-conformance` CI job, gated on the repo having a
Dockerfile.

Note what a *failure* means — see **Status codes** below: a `down` aggregate and a
readiness 503 both fail the checker, and both are correct answers from a service
whose hard dependency is gone.

## Linux

The deployment target is Linux, and the payload is written against portable APIs
only — Foundation, swift-nio, swift-metrics, swift-prometheus, swift-service-lifecycle
and swift-otel, every one of which builds on Linux — with no Darwin-only API and no
platform conditionals anywhere in `OpsApi.swift`. (That is the full package set; see
*What swift-otel costs* for what the last of them drags in.) `Package.swift.deps`
states `.macOS(.v13), .iOS(.v16)` because SwiftPM's `platforms:` covers Apple
platforms only — it says nothing about Linux, which has no floor to declare.

Those two values are a **floor for building on a Mac**, not something bootstrap sets:
the fragment has no paste site for `platforms:` and nothing in the adoption path edits
it. If your manifest already declares a lower Apple floor, raise it to at least these
before resolution will succeed on macOS; a Linux-only service can leave `platforms:`
alone entirely.

Build and run it on the official Swift image; the `ops-conformance` job does exactly
that (`ubuntu-latest`, `docker build`, then curl the management port).

## Dependency health (ops-api v1.1) — the seam

`/health` carries an optional `components` map: one entry per **direct** dependency,
read passively from that dependency's circuit-breaker state, plus a `degraded`
aggregate. A declared **hard** dependency being down also fails `/health/ready`; a
**soft** one never does. Wire it by setting `OpsConfig.dependencies` to any type
conforming to `DependencyHealthSource`:

```swift
public protocol DependencyHealthSource: Sendable {
    func components() async -> [String: Dependency]
}
```

**The blessed source is the Swift resilience payload (#1146)**, which is not built
yet. Until it lands, leaving `dependencies` unset is entirely legal and still
conforms: `/health` is then a byte-identical ops-api **v1.0** body — **no
`components` key at all**, not an empty object — with readiness decided by your
`readiness` closure alone.

If you implement `DependencyHealthSource` by hand in the meantime, **return a freshly
built dictionary every call.** The protocol is `Sendable` and the method is `async`
precisely so the compiler holds you to a snapshot: handing back a registry's live,
mutating dictionary while `/health` reads it is a data race. Swift 6's strict
concurrency checking makes that hard to write by accident, which is the whole reason
the seam is shaped this way rather than as a synchronous property.

The binding is a protocol over a plain struct, so **this file imports no
circuit-breaker library — and must never grow one.**

`readiness` remains the **non-dependency** half of the answer — still starting up,
draining during a graceful shutdown, an internal resource exhausted — and is checked
first. `internalStatus` is the over-reporting hook: components set a **floor** on the
aggregate, never an equality, so a service impaired for a reason no dependency models
(a backed-up queue, a full disk) reports a *more* severe aggregate. Reporting a *less*
severe one is a conformance failure, and the worst-wins combination makes it
unreachable.

Two vocabularies are easy to confuse, and confusing them under-reports health:

| Where | Healthy | Impaired | Failed |
| --- | --- | --- | --- |
| `/health` aggregate | `ok` | `degraded` | `down` |
| a `components` entry | `up` | `degraded` | `down` |

The aggregate is spelled `ok` — never `up` — because that is what ops-api v1.0
shipped; v1.1 only added `degraded` beside it. The enums make the wrong spelling a
compile error rather than a silent all-clear during an outage, which is the one
advantage Swift has here over the dynamically-typed siblings.

Breaker state maps to a component status exactly: `closed` → `up`, `half_open` →
`degraded`, `open` → `down`. Note that a **hard** dependency merely half-open floors
the aggregate at `degraded`, not `down` — only a hard dependency fully down forces
`down` and fails readiness. The wire spelling of the half-open breaker state is
`half_open`; the `BreakerState.halfOpen` case carries that as its raw value.

## Status codes

| Path | Code | Why |
| --- | --- | --- |
| `/health` | always `200` | The verdict is in the **body**. An operator reading this during an outage needs the diagnosis, and a 503 here is an unreadable page exactly when it matters. |
| `/health/live` | `200` | Liveness is process-only and never a function of a dependency — that is the pod-restart-storm anti-pattern. |
| `/health/ready` | `200` / `503` | A probe: the verdict is in the **status code**. 503 sheds traffic without a restart. |

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

An aggregate of `down` is a legitimate runtime state but **not** a conforming one:
`check-ops-conformance.zsh` asserts a service that is *serving*, so it fails on
`down` and on a readiness 503. Both are correct answers from a service whose hard
dependency is gone — the checker is telling you the truth about the outage, not
about the template.

## Metrics — two packages, one instrumentation API

`OpsMetrics.bootstrap()` bootstraps the process-global `MetricsSystem` **exactly
once**, with both backends behind swift-metrics' `MultiplexMetricsHandler`:

- **swift-prometheus** owns a `PrometheusCollectorRegistry`, which `/metrics` renders
  via `registry.emit(into:)` — the mandatory pull-compat surface, so conformance and
  smoke checks need no collector;
- **swift-otel** supplies the OTLP push pipeline, wired only when
  `OTEL_EXPORTER_OTLP_ENDPOINT` (or `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`) is set.

Your service records through the ordinary swift-metrics API (`Counter`, `Gauge`,
`Timer`) and every instrument lands in **both** pipelines. That is the seam that
makes two packages one instrumentation API: neither is a second metrics system, they
are two `MetricsFactory` backends behind one façade.

No endpoint configured is the normal local/CI case, not an error — the exporter would
otherwise dial its default endpoint and log a failure every interval.

### Why not swift-otel alone

Because **swift-otel ships no Prometheus exporter**. That is an inventory fact, not a
preference: at 1.5.0 the package declares exactly one library product, `OTel`, and its
module set is

`OTLPCore`, `OTLPCore+Extensions`, `OTLPGRPC`, `OTLPHTTP`, `OTelAPI`, `OTelCore`

— OTLP over gRPC and OTLP over HTTP, and nothing that speaks the Prometheus text
exposition format. `/metrics` is mandatory in the ops-api contract, so a
swift-otel-only payload could not serve the surface at all.

The mirror question — why not swift-prometheus alone — has the same shape: it has no
OTLP exporter, and OTLP push is the primary pipeline per ARCHITECTURE.md. Each package
covers exactly what the other lacks.

### The single-bootstrap rule, and why `OTel.bootstrap()` is not used

swift-metrics permits **one** `MetricsSystem.bootstrap` per process; a second traps.
swift-otel's headline API, `OTel.bootstrap()`, spends that one call itself. Using it
would leave the Prometheus registry with nothing recorded into it and `/metrics`
serving an empty body — green in CI, useless in production.

So the payload takes swift-otel's factory *without* its bootstrap, via
`OTel.makeMetricsBackend()`, which returns `(factory:, service:)` for exactly this
purpose, and multiplexes that factory with swift-prometheus'. The returned `service`
is swift-otel's background exporter and **must be run** for anything to be exported;
`OpsApi.serve` runs it alongside the listener, so callers who use `serve` get it for
free. If you mount the router on a management server you already run, you own running
that service yourself.

### What swift-otel costs

swift-otel's single `OTel` product is not decomposable, so depending on it pulls in
**grpc-swift-2**, **grpc-swift-nio-transport**, **grpc-swift-protobuf** and
**swift-protobuf** whether or not you ever export over gRPC — plus their own
transitive graph (swift-nio-http2, swift-nio-ssl, swift-crypto, and friends). There is
no build setting that trims this; the product either comes whole or not at all.

That cost is recorded here rather than discovered in your `Package.resolved`. It is
accepted for a **service**, which already runs a NIO stack and is deployed in a
container where binary size is not the constraint. It is emphatically *not* accepted
for a client — dragging gRPC and protobuf into a shipped app binary is one of the two
reasons the family ships **no client-side telemetry payload** (#1245, closed as
descoped 2026-08-11).
