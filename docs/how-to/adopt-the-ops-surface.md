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

- **`contracts/ops/v2/openapi.yaml`** — the fragment. It rides the same CI gates
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

  **Your own representation must also serve the v2 probe 503s as
  `application/problem+json`** — see
  [what actually changes on the wire](#what-actually-changes-on-the-wire).
  Actuator's own 503 body is the v1 envelope the checker reports as *unmigrated*,
  and this is the half a config-only route cannot reach: it needs code. Note the
  trap that makes it easy to miss — a healthy service never answers 503, so a
  green conformance run does **not** tell you this is done.
- **Python (non-Spring)** — use the blessed reference implementation bootstrap
  installs under your package (`ops_api.py` + `requirements.txt`); it serves the
  full surface on the management port and passes the conformance checker
  unchanged. See its `README.md`.

  Bootstrap installs the **resilience payload** alongside it (the two are placed
  together or not at all), which is what fills in the v1.1 half — per-dependency
  `components` on `/health` and the hard/soft readiness hinge, both read from
  circuit-breaker state. The blessed libraries are **`circuitbreaker` +
  `tenacity`** (a pair, because no Python library is resilience4j — `pybreaker`
  is deliberately rejected: it serializes every caller of one dependency behind a
  lock). Four things are yours to do, and three of them fail quietly if you skip
  them:

  - declare your direct dependencies in `resilience-dependencies.properties`
    (`<name>=hard|soft`, one per line, **full-line `#` comments only**), placed
    **beside `dependency_catalog.py`**, and **replace the shipped
    `orders-db`/`pricing-api` examples** — left verbatim they fail startup on
    `require_all_declared_guarded()` (nothing guards them), and if you skip that
    call `/health` reports two dependencies you do not have as `up`;
  - route every outbound call through `catalog.call(name, call, fallback)` (or
    `await catalog.call_async(...)` on asyncio), and give the call its **own
    timeout** — the one mandate the catalog cannot impose, because it does not
    own your socket. In Python it does double duty: `circuitbreaker` has no
    slow-call detection, so your timeout **is** the slow-call threshold, and a
    generous one lets a brownout pass unnoticed;
  - pass `dependencies=DependencyHealth(catalog)` to your `OpsConfig`, placing
    `dependency_health.py` in the same package as `ops_api.py` (it imports
    `Dependency` from it — relative-first behind an `except ImportError`
    fallback, so leave those intra-payload imports as shipped; flattening them
    to the bare form raises `ModuleNotFoundError` inside a package);
  - call `catalog.require_all_declared_guarded()` once at startup, after your
    clients are built. It is the only thing that catches a dependency you
    declared but never wired — whose breaker can never leave `closed`, so
    `/health` would report it `up` throughout an outage.

  `pricing_api_client.py` is a worked example, not service code: adapt it to a
  real dependency or leave it out. The payload's own `RESILIENCE.md` is the
  reference for the shape.
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
- **Go** — use the blessed reference implementation bootstrap installs
  (`opsapi.go` + a `go.mod.deps` require fragment): copy it to
  `internal/ops/opsapi.go`, fold in the requires (or run the `go get` line from
  its `README.md`), and call `ops.Serve(ctx, ops.DefaultAddr(), cfg)` from your
  startup. Give it its own directory: a Go file declares its package rather than
  deriving it from the directory, so `package ops` needs no fix-up there — but
  dropping it beside files declaring a different package is a compile error. It
  serves the full surface on the management port and passes the conformance
  checker unchanged.

  Two things are yours to do, and the first fails **silently**:

  - **make sure your `go.mod` says `go 1.22` or newer.** The payload routes with
    `http.ServeMux` method patterns (`GET /health`), and the standard library
    gates that grammar on the module's `go` directive rather than the installed
    toolchain — so a module still declaring `go 1.21` builds without a warning
    and then answers **404 on every ops endpoint**. Bootstrap raises the
    directive for you, or defers the whole payload if you decline the bump —
    a surface that 404s is worse than an absent one. If you are adopting by
    hand, this is the step to check first. Raising it is not a pure routing fix:
    `go 1.22` also switches the module to per-iteration `for`-loop variable
    scoping, which applies to all of your existing code — run your tests after.
    In a multi-module repo the directive that counts is the one in the `go.mod`
    of the module you place `opsapi.go` into, not the root's;
  - declare your API majors via `Config.ServedMajors` so `/info` carries the
    lifecycle table the deprecation machinery (#684) reads. A deprecated major
    must carry a sunset date and an active one must not, and `Config.Validate`
    rejects both at startup, so neither reaches production. What differs is what
    would catch it if that guard were ever dropped: the conformance job fails a
    deprecated major with no sunset, but nothing downstream checks the other
    direction — for that half `Validate` is the only enforcement anywhere.
    Leaving `ServedMajors` unset is not a no-op either: it defaults to a single
    **active major 1**, which conformance accepts, so an undeclared table is as
    wrong-but-green as the shipped illustration copied verbatim.

  Bootstrap installs the **resilience payload** alongside it (the two are placed
  together or not at all), which is what fills in the v1.1 half — per-dependency
  `components` on `/health` and the hard/soft readiness hinge, both read from
  circuit-breaker state. The blessed library is **`sony/gobreaker`**, and unlike
  Python it is a *single* library: mandate 3's bounded jittered retry is thirty
  lines of stdlib in the catalog rather than a second dependency. Five things are
  yours to do, and three fail quietly if you skip them:

  - declare your direct dependencies in `resilience-dependencies.properties`
    (`<name>=hard|soft`, one per line, **full-line `#` comments only**, no
    duplicates), placed **in the same directory as the `.go` files** — it is
    `//go:embed`-ed into the binary, so that path is resolved by the compiler and
    the declaration travels inside the deployable (the blessed ko/distroless image
    ships no data files, so a working-directory read would find nothing).
    `$OPS_DEPENDENCIES_FILE` still overrides it for a mounted ConfigMap. **Replace
    the shipped `orders-db`/`pricing-api` examples** — left verbatim they fail startup on `RequireAllDeclaredGuarded`
    (nothing guards them), and if you skip that call `/health` reports two
    dependencies you do not have as `up`;
  - **claim each dependency in its client's constructor** with
    `catalog.RequireDeclared(name)`. It is the only writer of the guarded set, so
    a service that claims only by routing through `resilience.Call` — which runs
    at request time, after the startup guard — reaches
    `catalog.RequireAllDeclaredGuarded()` below with an empty set, and it then
    refuses *every* declared dependency and the pod never boots;
  - route every outbound call through `resilience.Call(ctx, catalog, name, call,
    fallback)`, and give the call its **own timeout** — the one mandate the catalog
    cannot impose, because it does not own your socket. In Go it does double duty:
    gobreaker has **no slow-call detection**, so your timeout *is* the slow-call
    threshold, and a generous one lets a brownout pass unnoticed;
  - pass `resilience.NewDependencyHealth(catalog)` to `ops.Config.Dependencies`,
    and fix the one flagged import in `dependency_health.go` to your service's real
    ops package path (the payload's only placeholder);
  - call `catalog.RequireAllDeclaredGuarded()` once at startup, after your clients
    are built. It is the only thing that catches a dependency you declared but
    never wired — whose breaker can never leave `closed`, so `/health` would report
    it `up` throughout an outage.

  `pricing_api_client.go` is a worked example, not service code: adapt it to a real
  dependency or leave it out. The payload's own `README.md` is the reference for
  the shape, including why `gobreaker` was chosen and what its two silent gaps are.
- **Node (TypeScript)** — use the blessed reference implementation bootstrap
  installs (`opsApi.ts` + a `package.json.deps` dependency fragment): copy it to
  `src/ops/opsApi.ts`, merge the fragment's `dependencies` **and
  `devDependencies`** into your `package.json` — the payload imports `node:fs`,
  `node:http`, `node:path` and `node:url`, so `@types/node` is not optional —
  `npm install`, and `await serve(config)` from your startup. It serves the full
  surface on the management port and passes the conformance checker unchanged.
  See its `README.md`.

  Its HTTP layer is **`node:http` and nothing else** — no Express, no Fastify —
  so it drops into a framework-ful and a framework-less service alike, and all
  five endpoints share **one listener**: the OTel Prometheus exporter is
  constructed with `preventServerStart` and mounted on the management server, so
  nothing binds the exporter's own port behind your back.

  All of this assumes the package can **build TypeScript at all** — a
  `typescript` devDependency and a build step that emits the tree your entrypoint
  imports, since the wiring below imports the compiled `./ops/opsApi.js`. If you
  emit from the shipped `tsconfig.json`, add `"rootDir": "src"` to it: that
  config's own bar is `tsc --noEmit`, and TypeScript 7 refuses to emit without a
  `rootDir` (TS5011).

  Beyond that, three things are yours to do, and the first two fail at different
  moments:

  - **your `package.json` must say `"type": "module"`.** The payload is NodeNext
    ESM and reads `import.meta.url` to find your `package.json` for the `/info`
    version fallback; under CommonJS that is a compile error. It fails loudly —
    which is the good outcome — but nothing else names why, so check it first if
    you are adopting by hand. Bootstrap surfaces the switch as its own plan line,
    because it changes how every existing `require` in the package resolves, and
    defers the whole payload if you decline it;
  - **plumb `$GIT_SHA` in at build time.** `/info`'s `build.git_sha` has **no
    fallback** in Node — there is **no truthful fallback** to reach for, because
    Node stamps no VCS revision into a build the way the Go toolchain does, so an
    unset `$GIT_SHA` **fails the service at startup** naming the variable rather
    than serving a placeholder. A confidently-wrong commit in the ops surface
    sends an operator to the wrong diff during an incident. An `ARG GIT_SHA` /
    `ENV GIT_SHA` pair fed from CI is the usual shape — **and do it before you
    rely on the `ops-conformance` job**, which builds and runs your image without
    supplying `GIT_SHA` of its own, so the service refuses to start there and the
    job reports "service did not become ready" (the refusal naming the variable
    is in the container logs the same step dumps). Teaching the shared workflow to
    pass it is #1281. `build.version` is the opposite case and needs nothing: it
    falls back to `$BUILD_VERSION`, then to your own `package.json` version, which
    *is* truthful;
  - declare your API majors via `servedMajors` so `/info` carries the lifecycle
    table the deprecation machinery (#684) reads. A deprecated major must carry a
    sunset date and an active one must not, and `validateConfig` rejects both at
    startup, so neither reaches production. What differs is what would catch it if
    that guard were ever dropped: the conformance job fails a deprecated major
    with no sunset, but nothing downstream checks the other direction — nor the
    duplicate-major case, for which `validateConfig` is the only enforcement
    anywhere. Leaving `servedMajors` unset is not a no-op either: it
    defaults to a single **active major 1**, which conformance accepts, so an
    undeclared table is as wrong-but-green as the shipped illustration copied
    verbatim.

  The v1.1 half — per-dependency `components` on `/health` and the hard/soft
  readiness hinge — arrives with the **Node resilience payload** (#1145), which
  will bind `opossum` breaker state to this surface's seam. Until it lands the
  seam ships **unwired**, and an unwired surface is a conforming ops-api **v1.0**
  body: no `components` field, readiness from your own `readiness` function alone.
  You can implement `DependencyHealthSource` by hand in the meantime — return a
  freshly built object every call — but that is the escape hatch, not the default.
- **Swift** — bootstrap copies `OpsApi.swift` to
  `Sources/<ServiceTarget>/Ops/OpsApi.swift`, with the payload's `README.md`
  beside it, and pastes two blocks from `Package.swift.deps` into your
  `Package.swift`: the `.package(url:)` lines into the top-level `dependencies:`,
  the `.product(name:)` lines into the target that now holds the payload. It adds
  **dependencies only** and never edits `targets:` — where the payload sits is a
  structural decision about your package.

  Your manifest must declare `// swift-tools-version:6.1` or newer, and the
  payload's target should carry `swiftSettings: [.swiftLanguageMode(.v6)]`: the
  surface is verified under the Swift 6 language mode, and below 6.1 that
  per-target setting cannot be expressed, so the strict concurrency checking it is
  written against silently does not happen.

  Then bootstrap the metrics system once and serve:

  ```swift
  let metrics = try OpsMetrics.bootstrap()
  try await OpsApi.serve(
      config: OpsConfig(
          servedMajors: [
              APIMajor(major: 1, lifecycle: .deprecated, sunset: "2027-01-31"),
              APIMajor(major: 2, lifecycle: .active),
          ]
      ),
      metrics: metrics
  )
  ```

  Two Swift-specific facts are worth knowing before you adopt it:

  - **`$BUILD_VERSION` and `$GIT_SHA` have no fallback.** An unset one throws at
    startup naming the variable, before the listener binds. Swift fails closed on
    both, where Node fails closed on `$GIT_SHA` alone and the Python, Java and Go
    payloads fall back to `"unknown"`. With a Dockerfile, the `ops-conformance` job
    is where that lands — and it stays red until the startup wiring **and** this
    plumbing both land; without one, your first deploy is.
  - **`servedMajors` is required**, with no default at all. The Go payload's
    default of a single active major 1 is wrong-but-green for a v2-only service;
    Swift refuses to start instead.

  The v1.1 half arrives with the **Swift resilience payload** (#1146), which is not
  built yet. Until it lands the seam ships **unwired**, and an unwired surface is a
  conforming ops-api **v1.0** body: no `components` field at all, readiness from
  your own `readiness` closure alone. You can conform to `DependencyHealthSource`
  by hand in the meantime — return a freshly built dictionary every call — but that
  is the escape hatch, not the default.

  This payload serves the **service** shape only. A Swift *client* — an iOS/macOS
  app, a library-only package, a CLI tool — has no ops surface to expose, and
  bootstrap classifies it as a client rather than installing anything. That
  classification comes with two facts, and they are different facts: contract-consumer
  machinery for clients is tracked in **#1259**, which is where a Swift client's real
  machinery is coming from; and **client-side telemetry is deliberately not offered by
  the family** — a settled decision rather than a gap awaiting a payload (#1245 was
  closed as descoped on 2026-08-11 and is only the record of that decision, never a
  destination to wait on).

## Migrate an existing repo to ops v2

**This step is mandatory, manual and documented — there is no advisor that does it
for you.** If your repo carries `contracts/ops/v1/openapi.yaml` and nothing newer,
v1 is still your newest ops major, so `contracts-lint` still lints it — and once
your `.spectral.yaml` extends the org styleguide, its `org-problem-json-errors`
rule reddens that file, which you did not write. Adopting v2 is what clears that,
and nothing else does.

You will notice it in one of two ways:

- **`contracts-lint` goes red** on `contracts/ops/v1/openapi.yaml` with
  `org-problem-json-errors` on the `/health/live` and `/health/ready` `503`s —
  **but only once your `.spectral.yaml` extends the org styleguide ruleset**
  (#689). A repo still on the bootstrap starter (`extends: ["spectral:oas"]`,
  #692) does not carry that rule, so it stays green on ops v1 indefinitely.
  **Do not read that green as "migration not needed"** — migrate on the schedule
  below rather than waiting for a check that cannot fire yet.
- **`check-ops-conformance.zsh` fails** with a message naming the ops-api v1
  envelope and pointing back at this section — that is the checker telling you a
  probe answered 503 while the service is still on a v1 payload. Note the
  direction: it fires only when a probe actually 503s, so its *silence* is not
  evidence that you have migrated.

Four steps, in this order — and **step 0 is not optional**:

0. **Refresh `.github/workflows/contracts-lint.yml` from the current template.**
    Newest-major-only linting is what stops v1 being linted, and it shipped *with*
    v2 (#1330). If your repo was bootstrapped before that, its workflow still lints
    **every** `contracts/ops/vN`, so adding v2 alone leaves v1 red — and the next
    step forbids the obvious way out (deleting it). Refresh the workflow first and
    the rest of this section behaves as written.

    **Do not copy this one verbatim.** Unlike the ops fragment (which carries no
    placeholders, by design), `contracts-lint.yml.tmpl` contains
    `branches: ["{{DEFAULT_BRANCH}}"]`. Copied unsubstituted, its `pull_request`
    filter matches nothing and contract linting silently stops running on every PR
    — and because the check is path-conditional and never required, nothing goes
    red to tell you. The v1 redness would "clear" for entirely the wrong reason.
    So either:

    ```sh
    # preferred — renders the placeholder and re-stamps the provenance marker
    /development:bootstrap    # accept the contracts-lint.yml drift update
    ```

    or copy it by hand and substitute `{{DEFAULT_BRANCH}}` with your default
    branch yourself.

1. **Copy the v2 fragment in**, beside the old one:

    ```sh
    cp <bootstrap-templates>/common/contracts/ops/v2/openapi.yaml \
       contracts/ops/v2/openapi.yaml
    ```

    **Leave `contracts/ops/v1/openapi.yaml` exactly where it is, byte for byte.**
    Do not delete it. `contracts-semver` runs a second time with
    `--contracts-dir contracts/ops` and rejects a major that was live at the base
    ref and gone at `HEAD` — retiring a live major is its own flow, not a side
    effect of adopting the next one. Once v2 exists **and step 0 is done**, v1 is
    no longer linted.

2. **Replace your ops payload** with the v2 one for your language
    (`templates/languages/<lang>/ops-api/` — Node lives under `javascript/`, and
    Spring uses `spring/resilience/`). The payloads changed with the contract:
    **both probe `503`s** — liveness and readiness — now return
    `application/problem+json`.

3. **Re-run conformance** against the running service:

    ```sh
    zsh scripts/check-ops-conformance.zsh http://localhost:9090
    ```

    **A green run here does not verify step 2.** The checker can only inspect a 503
    body when a probe actually answers 503, and a healthy service answers `200`
    `{"status":"ok"}` on both probes — so an unmigrated-but-healthy service passes
    this command. To verify the bodies, either read the payload diff, or observe one
    503 for real: stop a hard dependency, or hit `/health/ready` during start-up.

### What actually changes on the wire

Only the two probes' `503` bodies. The `200`s are untouched, `/health` still
answers `200` with its aggregate, and **the runtime paths do not move** — `servers:
/v2` in the fragment is the version declaration for the semver triangle, not a URL
prefix. Your Kubernetes probe paths stay exactly as they are.

Before (v1), on `application/json`:

```json
{ "status": "down" }
```

After (v2), on `application/problem+json`:

```json
{
  "type": "urn:problem-type:ops:not-ready",
  "title": "Service Not Ready",
  "status": 503,
  "detail": "hard dependency 'orders-db' is down",
  "components": {
    "orders-db":   { "status": "down", "kind": "hard", "breaker": "open",   "since": "2026-08-13T09:14:22Z" },
    "pricing-api": { "status": "up",   "kind": "soft", "breaker": "closed", "since": "2026-08-13T08:02:10Z" }
  }
}
```

Note `status` is the **integer** HTTP code, not the health envelope's string —
that collision is the whole reason v2 exists. The `components` map is
byte-identical to the one `/health` serves and carries **all** declared
dependencies, not only the failing ones, so a shed pod and the dashboard show the
same picture. It is omitted **only** when the service declares no dependencies at
all — a `503` raised for a non-dependency reason still carries the full map.

Two details about `detail` that are easy to assume wrongly:

- A non-dependency 503 always reads **`the service is starting up`**, whether the
  cause was start-up or a graceful drain. The payloads cannot tell the two apart:
  your readiness hook returns a boolean, not a reason.
- The payloads therefore **define** a draining constant (`DETAIL_DRAINING` and its
  per-language spellings) but **never emit it**. It is a hook, with the wording
  fixed by the contract, for a service that does distinguish the two in its own
  readiness hook — so every service that bothers spells it identically.

**If anything consumes that body, update it before you migrate.** In practice a
kubelet reads only the status code, so most services have nothing to change — but
a bespoke dashboard or alert that parses `.status == "down"` on a probe will stop
matching.

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
