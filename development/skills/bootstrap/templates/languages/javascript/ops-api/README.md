# Canonical ops-api implementation (Node) — #936

The blessed Node realization of the org-standard ops surface defined by
`contracts/ops/v2/openapi.yaml`: `/info`, `/health`, `/health/live`,
`/health/ready`, `/metrics`. It conforms to the same fragment Spring services get
via Actuator, and passes `scripts/check-ops-conformance.zsh` unchanged.

It binds a separate **management port** (default `9090`, override with
`$OPS_PORT`), never the public app port — so `/info`'s build data is unreachable
from outside. Enforcing that boundary (NetworkPolicy + a Service that omits the
management port + the probe wiring) is the deployment layer's job (the
composition repo).

**No web framework.** The HTTP layer is `node:http` and nothing else, so this
drops into an Express service, a Fastify service and a service with no framework
alike. Its only runtime dependencies are OpenTelemetry packages — and no
circuit-breaker library, ever (see *the seam*, below).

## Placement

Copy `opsApi.ts` into your service — `src/ops/opsApi.ts` is the conventional
spot — and add the dependencies.

**Merging `package.json.deps` (beside this file) into your `package.json` is the
recommended route**, because it carries the version floors and the constraints
between them. The commands below are the same set typed out with **major-only**
ranges — the fragment carries the exact floors — and they are floors, not pins;
Renovate/Dependabot move them from there:

```bash
npm install @opentelemetry/api@^1 \
            @opentelemetry/sdk-metrics@^2 \
            @opentelemetry/exporter-prometheus \
            @opentelemetry/exporter-metrics-otlp-grpc \
            @opentelemetry/exporter-metrics-otlp-proto
npm install --save-dev @types/node@^24
```

The three `exporter-*` packages are deliberately left unversioned **in one
command**, which is what keeps them on a single 0.x train (see below).

**This payload needs Node `^18.19.0 || >=20.6.0`** — the `engines.node` those OTel
packages declare. Below it they do not install at all.

**In a workspaces repo, run these from the workspace root.** npm resolves and
locks workspace packages there; a nested install writes a second
`package-lock.json` and a second `node_modules` beside the hoisted tree, which
diverges from what CI installs while appearing to work locally.

Two more things a bare `npm install` would get wrong, both silently:

- **`@types/node@^24`, pinned to your Node major.** Its major types the Node
  release you *run*; unpinned, npm resolves the newest, and types ahead of the
  runtime make `tsc` accept APIs that are absent at run time — a failure that
  lands in production rather than in your build. `^24` is what this scaffold
  ships; **change it to the Node major you actually run** — read it from
  `engines.node`, an existing `.nvmrc`, the Dockerfile's `FROM node:<major>`, then
  the CI `setup-node` version, in that order, with the base image winning a
  disagreement for a containerized service. Only an **exact** major counts: a
  range like `">=20"` is a floor, not the runtime, so fall through to the next
  source. If none of the four yields an exact major, keep `^24` when your ranges
  admit 24, and otherwise pin to the highest major they do admit — never to a
  range's lower bound, which is how a service that actually runs 22 ends up typed
  against 20.
- **The three `@opentelemetry/exporter-*` packages are one release train** and
  must move together; a mixed set fails at runtime on an API mismatch.
  `@opentelemetry/api` (1.x) and `@opentelemetry/sdk-metrics` (2.x) are
  upstream's own separate lines — do not "fix" them to match each other.

**Your `package.json` must declare `"type": "module"`.** The payload is NodeNext
ESM and reads `import.meta.url` to locate your `package.json` for the `/info`
version fallback; under CommonJS that is a compile error. It fails loudly, which
is the good outcome — but it is the one adoption step nothing else names.

It **type-checks** clean under the strict shipped `tsconfig.json` (NodeNext ESM,
ES2022, `strict`, `noUnusedLocals`, `noUnusedParameters`, `noImplicitReturns`)
with `tsc --noEmit`, which is that config's own bar.

**To EMIT from that config, add `"rootDir": "src"`** — TypeScript 7 refuses to
emit without one (TS5011). You need an emitting build, because the wiring below
imports the compiled `./ops/opsApi.js`, not the `.ts` source.

Then call it from your startup:

```ts
import { serve } from "./ops/opsApi.js";

const ops = await serve({
  servedMajors: [
    { major: 1, lifecycle: "deprecated", sunset: "2027-01-31" },
    { major: 2, lifecycle: "active" },
  ],
  readiness: () => !draining, // NON-dependency reasons only
});

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => {
    void ops.close().then(() => process.exit(0));
  });
}
```

**The two majors above are an illustration — declare your real ones.** Copied
verbatim, that snippet makes `/info` advertise a deprecation of major 1 with a
sunset your service never agreed to, and the #684 deprecation machinery treats it
as real. The `/info` lifecycle table is exactly what makes that machinery
observable, so it has to be true. Omitting `servedMajors` altogether is the same
trap by another route: it defaults to a single **active major 1**, which
`validateConfig` accepts and conformance passes — so a v2-only service that never
sets it advertises a major it does not serve, green all the way. A deprecated
major **must** carry a sunset date and an active one **must not**, and
`validateConfig` rejects both at startup. Only the first is also caught
downstream: `check-ops-conformance.zsh` fails a deprecated major with no sunset,
but neither it nor the fragment's schema *checks* "active majors carry no
sunset" — so for that half `validateConfig` is the only enforcement anywhere.
It also rejects a **duplicate** major, which nothing downstream inspects, and a
non-integer or **below-1** major — which the conformance checker also rejects,
merely later.

`serve` resolves once the surface is **listening**, so a port clash rejects there
rather than surfacing later as an unhandled `error` event. Its `close()` drains
in-flight requests and *then* flushes the meter provider — wire it to SIGTERM as
above so a rolling update stops answering probes only after in-flight work
finishes.

To mount the surface on a management server you already run, use
`createOpsHandler` with the handler `installMetrics` returns instead of `serve` —
and then `shutdown()` that returned `MeterProvider` yourself on the way out.
`serve` does that for you; `createOpsHandler` does not, and skipping it drops the
final OTLP flush.

### `/info`'s build data — one fallback, one fail-fast

`build.version` resolves `OpsConfig.version` → `$BUILD_VERSION` → your
`package.json` `version` → `"0.0.0"`. The `package.json` step is a *truthful*
fallback: it is the service's own declared version, not a placeholder. The lookup
walks up from the module's own directory, so it works from `src/` and from a
compiled `dist/` alike, and in a monorepo it finds the **service's** manifest.

`build.git_sha` resolves `OpsConfig.gitSha` → `$GIT_SHA` → **throws**.
It has **no fallback**, deliberately: Node has no equivalent of the VCS revision
the Go toolchain stamps into a binary, so there is **no truthful fallback** to
reach for and every candidate placeholder is either a lie or a conformance
failure — and a confidently-wrong commit in the ops surface sends an operator to
the wrong diff during an incident. Startup fails naming the variable while
someone is still watching the deploy.

So `$GIT_SHA` is **build plumbing you owe**: set it in your image build (a
`ARG GIT_SHA` / `ENV GIT_SHA` pair fed from CI) or in the deployment's
environment.

**Do this before you rely on the `ops-conformance` CI job.** That job builds and
runs your image without supplying `GIT_SHA` of its own, so until your Dockerfile
carries the value the service refuses to start there. The job's headline failure
is *"service did not become ready"* — the refusal naming `GIT_SHA` is one step
further down, in the container logs that same step dumps. Teaching the shared
workflow to pass it is tracked as issue #1281; wiring your own Dockerfile is the
fix that works today, and is what you want in production regardless.

`$OPS_PORT` is validated the same way — a malformed value is a startup error, not
a silent fall back to 9090, because an operator who set it meant to move the
surface.

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
`OpsConfig.dependencies` to any object implementing `DependencyHealthSource`.

**The blessed source is the Node resilience payload** (#1145), which bootstrap
installs alongside this one once it lands — the two are placed together or not at
all. It wires `opossum` around your dependency clients and derives these entries
from breaker state. Leaving `OpsConfig.dependencies` unset is still legal and
still conforms: the surface is then an ops-api **v1.0** body, with no `components`
field and readiness decided by your `readiness` function alone.

The binding is an interface over plain objects, so this module needs no breaker
library on its import path — and must never grow one. **The import direction is
one-way**: the resilience payload imports this module, never the reverse.

If you implement `DependencyHealthSource` by hand in the meantime, **return a
freshly built object every call.** Node is single-threaded, so unlike the Go
sibling there is no concurrent-map fault to fear — but `/health` serializes what
you hand back, so returning your live registry lets any later mutation of it be
observed as a health report you never intended.

`readiness` remains the **non-dependency** half of the answer — still starting up,
draining during a graceful shutdown, an internal resource exhausted — and is
checked first. `internalStatus` is the over-reporting hook: components set a
**floor** on the aggregate, never an equality, so a service impaired for a reason
no dependency models (a backed-up queue, a full disk) reports a *more* severe
aggregate. Reporting a *less* severe one is a conformance failure.

Two vocabularies are easy to confuse, and confusing them under-reports health:

| Where | Healthy | Impaired | Failed |
| --- | --- | --- | --- |
| `/health` aggregate | `ok` | `degraded` | `down` |
| a `components` entry | `up` | `degraded` | `down` |

The aggregate is spelled `ok` — never `up` — because that is what ops-api v1.0
shipped; v1.1 only added `degraded` beside it. TypeScript's types are erased at
runtime, so a hand-written `DependencyHealthSource` (or a value parsed from JSON)
that returns the wrong spelling (`"ok"`, `"Hard"`) is coerced to the **most
severe** reading, never the least — a mistake shows up as a loud conformance
failure instead of a silent all-clear during an outage. An off-contract `breaker`
is dropped rather than coerced, because the checker rejects a present-but-invalid
one and accepts an absent one.

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

Every other path on the management port answers `404` naming the path, and a
non-`GET`/`HEAD` method answers `405` with an `Allow` header — a management
surface that silently 404s a POST reads as "wrong path" rather than "wrong
method". A trailing slash is normalized (`/health/` routes to `/health`), but a
**percent-encoded** slash is not: `/health%2F` is the one-segment path `health/`
and rightly 404s.

An aggregate of `down` is a legitimate runtime state but **not** a conforming one:
`check-ops-conformance.zsh` asserts a service that is *serving*, so it fails on
`down` and on a readiness 503. Both are correct answers from a service whose hard
dependency is gone — the checker is telling you the truth about the outage, not
about the template.

If a hand-written `DependencyHealthSource` **throws**, `/health` still answers 200
with `{"status":"down"}` and readiness fails closed. That `try`/`catch` is the
contract, not defensive habit: unhandled, the exception escapes into `node:http`,
which destroys the socket with no response — and the checker then reports
`/health: unreachable` instead of a diagnosis.

## Metrics

Instrumentation is **OpenTelemetry only**. `installMetrics` hangs two readers off
one `MeterProvider`:

- the **Prometheus exporter**, constructed with `preventServerStart: true` so it
  binds no port of its own, and mounted on the management server through its
  `getMetricsRequestHandler` — the mandatory pull-compat surface, so conformance
  and smoke checks need no collector. All five endpoints therefore share **one**
  `node:http` listener. Constructing that exporter *without* the flag starts a
  second server on port 9464 behind your back;
- an **OTLP periodic reader**, the primary pipeline, wired only when
  `OTEL_EXPORTER_OTLP_ENDPOINT` (or `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`) is set.
  `OTEL_EXPORTER_OTLP_PROTOCOL` picks `grpc` (the default when unset) or
  `http/protobuf`, and `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL` overrides it for
  metrics — the same signal-specific precedence the endpoint pair uses.

Those two are the whole accepted set. Anything else — including `http/json`,
which the JS SDK's metrics exporters do not implement — is a **startup error**,
deliberately: a silent fallback to protobuf would hand a JSON-expecting collector
the wrong encoding and fail every export interval while the config looked
accepted.

No endpoint configured is the normal local/CI case, not an error — the exporters
would otherwise dial localhost and log a failure every interval.

Record your own instruments through `metrics.getMeter(...)` from
`@opentelemetry/api` — `installMetrics` has already set the global provider by the
time `serve` binds the port. Without that global registration every instrument
would go to a no-op and `/metrics` would be empty: silently useless, yet still
conforming.
