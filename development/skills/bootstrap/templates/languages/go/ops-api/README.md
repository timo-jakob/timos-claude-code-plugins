# Canonical ops-api implementation (Go) — #1192

The blessed Go realization of the org-standard ops surface defined by
`contracts/ops/v1/openapi.yaml`: `/info`, `/health`, `/health/live`,
`/health/ready`, `/metrics`. It conforms to the same fragment Spring services get
via Actuator, and passes `scripts/check-ops-conformance.zsh` unchanged.

It binds a separate **management port** (default `9090`, override with
`$OPS_PORT`), never the public app port — so `/info`'s build data is unreachable
from outside. Enforcing that boundary (NetworkPolicy + a Service that omits the
management port + the probe wiring) is the deployment layer's job (the
composition repo).

## Placement

Copy `opsapi.go` into your service — `internal/ops/opsapi.go` is the conventional
spot — and add the dependencies:

```bash
go get github.com/prometheus/client_golang \
       go.opentelemetry.io/otel \
       go.opentelemetry.io/otel/sdk/metric \
       go.opentelemetry.io/otel/exporters/prometheus \
       go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc \
       go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp
go mod tidy
```

`go.mod.deps` beside this file carries the same set as a `require` block with the
version floors, if you would rather fold it in by hand.

**Your `go.mod` must declare `go 1.22` or newer.** This package registers
`http.ServeMux` method patterns (`GET /health`), and the standard library gates
that grammar on the *module's* `go` directive, not on the installed toolchain — so
a module still saying `go 1.21` parses `"GET /health"` as a host-prefixed pattern
under the newest Go, matches nothing, and answers **404 on every ops endpoint**
with no build error and no warning. Verified against Go 1.26: `go 1.21` → 404,
`go 1.22` → 200.

Raising the directive is not a pure routing fix, though: `go 1.22` also switches
the module to **per-iteration `for`-loop variable scoping**, which applies to all
of your existing code. Run your tests after raising it.

Then call it from your startup:

```go
ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
defer stop()

if err := ops.Serve(ctx, ops.DefaultAddr(), ops.Config{
    ServedMajors: []ops.APIMajor{
        {Major: 1, Lifecycle: ops.LifecycleDeprecated, Sunset: "2027-01-31"},
        {Major: 2, Lifecycle: ops.LifecycleActive},
    },
    Readiness: func() bool { return !draining.Load() }, // NON-dependency reasons only
}); err != nil {
    log.Fatalf("ops surface: %v", err)
}
```

**The two majors above are an illustration — declare your real ones.** Copied
verbatim, that snippet makes `/info` advertise a deprecation of major 1 with a
sunset your service never agreed to, and the #684 deprecation machinery treats it
as real. The `/info` lifecycle table is exactly what makes that machinery
observable, so it has to be true. Omitting `ServedMajors` altogether is the same
trap by another route: it defaults to a single **active major 1**, which
`Validate` accepts and conformance passes — so a v2-only service that never sets
it advertises a major it does not serve, green all the way. A deprecated major **must** carry a sunset date
and an active one **must not**, and `Config.Validate` rejects both at startup.
Only the first is also caught downstream: `check-ops-conformance.zsh` fails a
deprecated major with no sunset, but neither it nor the fragment's schema
*checks* "active majors carry no sunset" — so for that half `Validate` is the
only enforcement anywhere. (Both *could* check it; today neither does.)

`Version` and `GitSHA` default to `$BUILD_VERSION` / `$GIT_SHA`, and `GitSHA`
falls back to the VCS revision the Go toolchain stamps into the binary — so
`/info` reports a real commit with no ldflags and no env plumbing. `ops.Serve`
runs until the context is cancelled, then drains: wire it to SIGTERM as above so
a rolling update stops answering probes only after in-flight requests finish.

To mount the surface on a management server you already run, use `NewHandler`
with the handler `InstallMetrics` returns instead of `Serve` — and then
`Shutdown` that returned `MeterProvider` yourself on the way out. `Serve` does
that for you; `NewHandler` does not, and skipping it drops the final OTLP flush.

## Conformance

Start your service, then point the shipped checker at the **management** base URL:

```bash
zsh scripts/check-ops-conformance.zsh http://localhost:9090
```

Run it against your **real entrypoint**, not a scratch main built around the
template: what conforms is the surface your service actually serves. Bootstrap
also wires this as an `ops-conformance` CI job, gated on the repo having a
Dockerfile.

Note what a *failure* means — see **Status codes** below: a `down` aggregate and
a readiness 503 both fail the checker, and both are correct answers from a service
whose hard dependency is gone.

## Dependency health (ops-api v1.1) — the seam

`/health` carries an optional `components` map: one entry per **direct**
dependency, read passively from that dependency's circuit-breaker state, plus a
`degraded` aggregate. A declared **hard** dependency being down also fails
`/health/ready`; a **soft** one never does. Wire it by setting
`Config.Dependencies` to any type implementing `DependencyHealthSource`.

**The blessed source is the Go resilience payload** (#1144), which bootstrap
installs alongside this one — the two are placed together or not at all. It wires
`sony/gobreaker` around your dependency clients and derives these entries from
breaker state; its own `README.md` covers the wiring and the two startup guards.
Leaving `Config.Dependencies` unset is still legal and still conforms: the surface
is then an ops-api **v1.0** body, with no `components` field and readiness decided
by your `Readiness` func alone.

If you implement `DependencyHealthSource` by hand in the meantime, **return a
freshly built map every call.** Handing back your registry's live map lets a
breaker goroutine write it while `/health` ranges over it, and a concurrent map
read/write is a Go **fatal** error rather than a panic — so the recover guards
below cannot catch it and the process dies mid-scrape. Copy under your own lock.

The binding is an interface over a plain struct, so this package needs no breaker
library on its import path — and must never grow one.

`Readiness` remains the **non-dependency** half of the answer — still starting up,
draining during a graceful shutdown, an internal resource exhausted — and is
checked first. `InternalStatus` is the over-reporting hook: components set a
**floor** on the aggregate, never an equality, so a service impaired for a reason
no dependency models (a backed-up queue, a full disk) reports a *more* severe
aggregate. Reporting a *less* severe one is a conformance failure.

Two vocabularies are easy to confuse, and confusing them under-reports health:

| Where | Healthy | Impaired | Failed |
| --- | --- | --- | --- |
| `/health` aggregate | `ok` | `degraded` | `down` |
| a `components` entry | `up` | `degraded` | `down` |

The aggregate is spelled `ok` — never `up` — because that is what ops-api v1.0
shipped; v1.1 only added `degraded` beside it. A hand-written
`DependencyHealthSource` that returns the wrong spelling (`"ok"`, `"Hard"`) is
coerced to the **most severe** reading, never the least, so a mistake shows up as
a loud conformance failure instead of a silent all-clear during an outage.

Breaker state maps to a component status exactly: `closed` → `up`, `half_open` →
`degraded`, `open` → `down`. Note that a **hard** dependency merely half-open
floors the aggregate at `degraded`, not `down` — only a hard dependency fully
down forces `down` and fails readiness.

## Status codes

| Path | Code | Why |
| --- | --- | --- |
| `/health` | always `200` | The verdict is in the **body**. An operator reading this during an outage needs the diagnosis, and a 503 here is an unreadable page exactly when it matters. |
| `/health/live` | `200` | Liveness is process-only and never a function of a dependency — that is the pod-restart-storm anti-pattern. |
| `/health/ready` | `200` / `503` | A probe: the verdict is in the **status code**. 503 sheds traffic without a restart. |

An aggregate of `down` is a legitimate runtime state but **not** a conforming one:
`check-ops-conformance.zsh` asserts a service that is *serving*, so it fails on
`down` and on a readiness 503. Both are correct answers from a service whose hard
dependency is gone — the checker is telling you the truth about the outage, not
about the template.

If a hand-written `DependencyHealthSource` **panics**, `/health` still answers 200
with `{"status":"down"}` and readiness fails closed. That recover is the contract,
not defensive habit: unhandled, the panic closes the connection with no response
and the checker reports `/health: unreachable` instead of a diagnosis. It covers
panics only — a concurrent map fault is fatal and unrecoverable, which is why
`Components()` must return a snapshot (above).

## Metrics

Instrumentation is **OpenTelemetry only**. `InstallMetrics` hangs two readers off
one `MeterProvider`:

- the **Prometheus exporter**, registered into a dedicated `prometheus.Registry`
  that `promhttp` serves as `/metrics` — the mandatory pull-compat surface, so
  conformance and smoke checks need no collector;
- an **OTLP periodic reader**, the primary pipeline, wired only when
  `OTEL_EXPORTER_OTLP_ENDPOINT` (or `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`) is set.
  `OTEL_EXPORTER_OTLP_PROTOCOL` picks `grpc` (the default when unset) or
  `http/protobuf`, and `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL` overrides it for
  metrics — the same signal-specific precedence the endpoint pair uses.

Those two are the whole accepted set. Anything else — including `http/json`,
which the Go SDK does not implement — is a **startup error**, deliberately: a
silent fallback to protobuf would hand a JSON-expecting collector the wrong
encoding and fail every export interval while the config looked accepted.

No endpoint configured is the normal local/CI case, not an error — the exporters
would otherwise dial `localhost:4317` and log a failure every interval.

The registry is dedicated rather than `prometheus.DefaultRegisterer`, so
`/metrics` carries what the OTel SDK recorded and nothing a second metrics system
smuggled in. Record your own instruments through `otel.Meter(...)` — `Serve` has
already set the global provider by the time it binds the port.
