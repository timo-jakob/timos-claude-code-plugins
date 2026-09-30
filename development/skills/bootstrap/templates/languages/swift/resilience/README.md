# Canonical resilience + dependency health (Swift) — #1146

The blessed Swift realization of the org resilience policy: every outbound dependency call is
circuit-broken, and the ops-api `/health` surface reports what those breakers know.

**The unifying idea: the circuit breaker keeps you serving; the dependency-health surface tells
you what's degraded.** An open breaker *is* a down dependency, so health is **read** from the
breaker rather than measured by a second mechanism.

This payload **extends** the ops-api payload beside it (`Ops/OpsApi.swift`) rather than standing
alone: `DependencyHealth` conforms to the `DependencyHealthSource` seam that payload already ships.
The dependency direction is one-way and load-bearing — **resilience depends on ops, never the
reverse** — which is what keeps `OpsApi.swift` free of any breaker, exactly as its own header
promises.

## Why a payload-owned actor breaker

No maintained Swift circuit-breaker library is the obvious choice, so this payload does not assume
one. It ships its own: the `CircuitBreaker` **actor** in `DependencyCatalog.swift`, with **no
third-party dependency** — the Go payload set the precedent with its retry half, a few dozen lines
of stdlib rather than a second blessed library. The choice was made on evidence, against every
Swift circuit-breaker library a GitHub search surfaced with a push since 2022 (the older ones —
last touched between 2016 and 2020 — fail maintenance health on their face):

| candidate | async/await-native | one instance per dependency | state readable without traffic | maintenance health | Swift 6 strict-concurrency clean | builds + tests on Linux |
| --- | --- | --- | --- | --- | --- | --- |
| `Kitura/CircuitBreaker` 5.1.0 | ✗ callback `run(commandArgs:fallbackArgs:)` over Dispatch | ✓ | ✓ `breakerState` | ✗ last release 2022-07 | ✗ concurrency diagnostics | ✓ builds |
| `AlexanderNey/CircuitBreaker` 0.2.0 | ✗ `run` is not `public` | ✗ every breaker shares one global actor | ✗ `state` is not `public` | ✗ 0.x, no license declared | ✗ a `Sendable` diagnostic | ✓ builds |
| `atacan/UsefulThings` 1.0.0 | ✓ 4 × 1s calls took **1.01s** | ✓ | ✗ still reads `open` with no traffic | ✗ one tag, a utility grab-bag | ✓ | ✓ builds |
| `harryngict/ResilientNetworkKit` 0.0.1 | ✗ a synchronous class inside a URLSession pipeline | ✗ not `public` | ✗ not `public` | ✗ 0.0.1, iOS-only | ✗ `@unchecked Sendable` over unguarded state | ✗ **does not build** |
| **payload-owned `CircuitBreaker` actor** | ✓ 4 × 1s calls took **1.01s** | ✓ one per declared dependency | ✓ open → half-open computed on read | ✓ ships in this repo, versioned with the payload | ✓ zero diagnostics | ✓ tests green on Linux |

The candidates' Linux and strict-concurrency columns were measured by building each one on
`swift:6.1` with `-strict-concurrency=complete`. The payload's own row was measured on `swift:6.2`
and on macOS: its unit tests and live acceptance cases compile it beside the ops-api payload,
whose dependency graph (through swift-otel) now resolves packages that need a 6.2 toolchain to
build — the 6.1 floor below is the manifest's tools-version, not the toolchain you can build the
pair with today. The concurrency figure is the test that got `pybreaker` rejected in #1143 (4.01s
for the same four calls — it holds a lock across the guarded call).

### Rejected, and why

- **`Kitura/CircuitBreaker` — rejected, and it is the best-known one.** Its API predates Swift
  concurrency: a breaker is constructed around a command and a fallback, and `run` returns `Void`
  and reports through callbacks on Dispatch queues guarded by a `DispatchSemaphore`. Wrapping that
  in `async`/`await` means continuations around a callback API that was never written for
  cancellation. It is not clean under strict concurrency (its `MonitorCollection.sharedInstance`
  is nonisolated global mutable state — an error in the Swift 6 language mode), and its last
  release is from July 2022, after the Kitura project wound down.
- **`AlexanderNey/CircuitBreaker` — rejected; it cannot be used from outside its own module.**
  The actor-isolated design is the right idea, but `run` and `state` are internal, so a service can
  neither call through it nor read the state `/health` needs. Every breaker also shares one
  global actor, so one busy dependency's bookkeeping queues behind another's. It is a 0.x release
  with no declared license.
- **`atacan/UsefulThings` — rejected, though its breaker is the closest fit.** A proper `actor`,
  concurrent, clean under Swift 6, builds on Linux. It fails on behaviour, measured against 1.0.0:
  `currentState` read **400ms after a 200ms reset window with no traffic still reads `open`**,
  because the open → half-open transition is taken only when a call arrives — so `/health` would
  report a recovering dependency down until someone happened to call it. It has **no exclusion
  predicate**: 30 caller errors opened it, so user-provoked 404s would open a breaker on a healthy
  dependency. It counts **consecutive** failures: 100 calls failing every other one left it closed.
  It admits unlimited concurrent half-open probes and exposes no transition timestamp for `since`.
  And the breaker is one type in a general utility package (process runners, file-handle streams,
  a rate limiter) with a single tag, which is a poor thing to pin into every bootstrapped service.
- **`harryngict/ResilientNetworkKit` — rejected; it does not build on Linux.** `swift build` on
  `swift:6.1` fails with `cannot find type 'URLRequest' in scope` (it never imports
  `FoundationNetworking`). The breaker is also an internal class inside an iOS networking stack,
  not a standalone type, and it is declared `@unchecked Sendable` over mutable state no lock guards.

So: **no third-party dependency, one payload-owned breaker.** `Package.swift.deps` says so rather
than pinning anything. If a maintained Swift breaker later passes every column above, replacing the
actor is a contained change — `DependencyHealth` reads only `snapshot()`.

### What the actor does, and why each choice is load-bearing

- **The guarded call never runs on the actor.** `acquire()` and `record(_:for:)` are the only
  isolated steps, so concurrent callers of one dependency run in parallel (the 1.01s above).
- **Failure *rate* over a *count*-based window, with a minimum volume** — 50% of the last 20 counted
  calls, never on fewer than 10. A rate is what describes a sick dependency (consecutive-only never
  trips one failing every other call), the floor stops one failure after a reset reading as 100%,
  and a count-based window never time-resets — gobreaker's `Interval` shows why that matters: a
  dependency called less often than the floor per interval could never trip.
- **Open → half-open is computed from the clock on read** (mandate 5). A recovering dependency shows
  as `half_open` on the next `/health` scrape with **no traffic and no scheduler**.
- **Half-open admits three probes**, and three successes close it; one failure re-opens it.
- **`since` is stamped on every transition** and never on a read that changed nothing, and
  `snapshot()` reads state and stamp in one actor hop, so the two always describe the same moment.
- **A stale outcome is discarded.** A call admitted while closed that lands after the breaker
  tripped carries an old generation, so it cannot be mistaken for a half-open probe.

## Placement

Copy `DependencyCatalog.swift`, `DependencyHealth.swift` and (optionally)
`PricingAPIClient.swift` into **`Sources/<ServiceTarget>/Resilience/`** — the **same target** that
holds `Ops/OpsApi.swift`, with `resilience-dependencies.properties`, `Package.swift.deps` (a
record of why there is nothing to paste) and this `README.md` beside them. SwiftPM warns that
those three non-source files (and the ops payload's `README.md` and `Package.swift.deps`) are
unhandled; add them to the target's `exclude:` list to silence it — they are documentation, not
resources, and nothing reads them at runtime. **Bootstrap performs no `targets:` edit** (that
`exclude:` list is yours), and the payload needs none to compile: it has no package to add, and
it reads the ops types from its own module. There are **no placeholders**.

Within one module, imports cannot express a direction, so the one-way rule is held by the files
themselves: `OpsApi.swift` names no resilience type. `DependencyCatalog.swift` and
`DependencyHealth.swift` open with `#if canImport(Ops) import Ops #endif` (the worked example
names no ops type), so they compile unchanged if you ever split `Ops` and
`Resilience` into two targets — where any reverse reference becomes a compile error.

Your manifest needs **`// swift-tools-version:6.1` or newer**, and the target should carry
`swiftSettings: [.swiftLanguageMode(.v6)]` — the same floor as the ops-api payload. The payload
compiles with **zero concurrency diagnostics** in that mode.

### The declaration is compiled in

`resilience-dependencies.properties` declares your direct dependencies, and **the same text is
compiled into the binary** as `bundledDependencyDeclaration` in `DependencyCatalog.swift`. Swift
has no `//go:embed`, and the resource-bundle alternative (`Bundle.module`) needs a `resources:`
line in `targets:` *and* a Dockerfile that copies the `.resources` bundle into the runtime stage —
miss either and the declaration is absent in the image, and every pod dies at startup. A string
literal reaches the runtime on every platform with no manifest edit.

**Edit the two together** — the literal is what the binary carries, the `.properties` file is the
same declaration in the shape you mount as a ConfigMap. Changing it is a rebuild, not a restart.
`$OPS_DEPENDENCIES_FILE` overrides it at runtime, and an override that cannot be read **fails
startup** rather than silently falling back: a typo'd path that quietly used the compiled default
would boot the pod with the wrong readiness hinge.

## Wiring it up

```swift
let catalog = try DependencyCatalog.load()        // compiled-in, or $OPS_DEPENDENCIES_FILE when set

let pricing = try await PricingAPIClient(catalog: catalog)   // each client CLAIMS its dependency

// AFTER every client is built — see "What is yours to do" below.
try await catalog.requireAllDeclaredGuarded()

let metrics = try OpsMetrics.bootstrap()
try await OpsApi.serve(
    config: OpsConfig(
        servedMajors: [APIMajor(major: 1, lifecycle: .active)],   // declare your real ones
        dependencies: DependencyHealth.seam(for: catalog)
    ),
    metrics: metrics
)
```

**Wire the seam with `DependencyHealth.seam(for:)`, not the initializer.** It returns `nil` when the
catalog declares nothing, which leaves `/health` a byte-identical ops-api **v1.0** body with **no
`components` key**. An empty catalog behind a non-nil source would serve `"components":{}` instead —
a v1.1 body announcing dependency health and then reporting none.

## What is yours to do — and what fails quietly if you skip it

1. **Declare your real dependencies** in `resilience-dependencies.properties` **and** the compiled
   literal (`<name>=hard|soft`, one per line, **full-line `#` comments only**, no duplicates — a
   repeated name is rejected at startup, because last-wins could silently downgrade a `hard`
   dependency and disarm the readiness hinge) and **replace the shipped `orders-db` /
   `pricing-api` examples**. Left verbatim they fail startup on `requireAllDeclaredGuarded()`
   (nothing guards them) — and if you skip that call, `/health` reports two dependencies you do
   not have as `up`.
2. **Claim each dependency in its client's initializer** with `catalog.requireDeclared(name)` — it is
   the only writer of the guarded set, so a service whose clients never claim theirs reaches step 4
   with an empty set, which refuses *every* declared dependency at boot. Then **route every
   outbound call through `catalog.call`**.
3. **Pass `DependencyHealth.seam(for: catalog)` to `OpsConfig.dependencies`.** Without it the ops
   surface is a conforming ops-api **v1.0** — no `components`, readiness from your `readiness`
   closure alone — which is correct but blind.
4. **Call `catalog.requireAllDeclaredGuarded()` once at startup, after your clients are built.** It is
   the only thing that catches a dependency you declared but never wired — whose breaker can never
   leave `closed`, so `/health` would swear it was up throughout a total outage.

Under-reporting is refused from **both** sides, which is the only way the pair is useful:
`requireDeclared` refuses a dependency guarded in code but undeclared, and
`requireAllDeclaredGuarded` refuses one declared but guarded by nobody.

## The six mandates, and where each one lives

| # | mandate | where |
| --- | --- | --- |
| 1 | Timeout | `catalog.call`'s `timeout:` (default **2s**): the operation is raced against the clock and cancelled when it loses, and the `DependencyTimeout` **counts** — so a brownout opens the breaker |
| 2 | Circuit breaker, one per dependency | `DependencyCatalog`, one `CircuitBreaker` actor created eagerly per declared dependency |
| 3 | Bounded retry + jittered backoff | `catalog.call`'s loop — 3 attempts, full jitter over an exponential delay capped at 2s; **breaker-aware** (never retries `CallNotPermitted`) and **cancellation-aware** (stops when the caller's `Task` is cancelled, including mid-backoff) |
| 4 | Registered fallback | `catalog.call`'s `fallback:` argument. The payload enforces that one is *wired*; what it returns is your business logic |
| 5 | Background reconnect | the breaker's half-open probe — open → half-open computed from elapsed time on read, three probes admitted, no scheduler and no synthetic traffic |
| 6a | Stay stable — fast-fail | an open breaker's rejection arrives immediately, un-retried, and goes straight to the fallback; the guarded call never runs on the actor, so no caller waits behind another |
| 6b | Stay stable — the rest | **yours.** `catalog.call` cannot stop you blocking a thread inside your operation, ignoring cancellation (the timeout works by cancelling — URLSession, AsyncHTTPClient and NIO all honour it), spawning an unstructured `Task` per request around it, or `try!`-ing what the fallback throws |

## Caller errors are not dependency failures

Wrap them in `NotADependencyFailure`. They are then excluded from the breaker entirely — neither
success nor failure — and never retried, so thirty user-provoked 404s cannot open a breaker on a
healthy dependency and, if it is declared `hard`, start failing readiness for the whole pod.
`PricingAPIClient.swift` classifies the **whole 4xx range**, not just the 404 you happened to think
of.

A cancelled **caller** is excluded too, and `Task.isCancelled` — not the error's type — is the
authority: URLSession reports its own cancellation as `URLError(.cancelled)`, and a graceful drain
cancelling every in-flight task must not open a healthy dependency's breaker. A timeout is *not* a
cancelled caller — the caller is still there — so it counts.

## Two vocabularies

| Where | Healthy | Impaired | Failed |
| --- | --- | --- | --- |
| `/health` aggregate | `ok` | `degraded` | `down` |
| a `components` entry | `up` | `degraded` | `down` |

Breaker state maps to a component status exactly: `closed` → `up`, `half_open` → `degraded`,
`open` → `down`. A **hard** dependency merely half-open floors the aggregate at `degraded`, not
`down` — only a hard dependency fully down forces `down` and fails readiness. The ops enums make
the wrong spelling a compile error, and the mapping switch has no `default`, so a fourth breaker
state would be a compile error here rather than a guess.

`DependencyHealth` covers **direct dependencies only** and never calls a downstream's `/health`:
each service reports one hop, and the observability layer assembles the graph.
