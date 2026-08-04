# Canonical resilience + dependency health (Go) — #1144

The blessed Go realization of the org resilience policy: every outbound dependency call is
circuit-broken, and the ops-api `/health` surface reports what those breakers know.

**The unifying idea: the circuit breaker keeps you serving; the dependency-health surface tells
you what's degraded.** An open breaker *is* a down dependency, so health is **read** from the
breaker rather than measured by a second mechanism.

This payload **extends** the ops-api payload beside it (`opsapi.go`) rather than standing alone:
`DependencyHealth` implements the `DependencyHealthSource` seam that payload already ships. The
import direction is one-way and load-bearing — **`resilience` imports `ops`, never the reverse** —
which is what keeps the ops package free of any breaker library, exactly as its own doc comment
promises.

## The blessed library: `sony/gobreaker` — and the fit-check

The issue asked for gobreaker to be *confirmed*, not assumed. Measured against v2.4.0:

| property | measured | why it matters |
| --- | --- | --- |
| Concurrent callers through one breaker | 4 × 1s calls took **1.00s** | Python's `pybreaker` was **rejected** for this in #1143: it holds a lock across the guarded call, so the same test took 4.01s — a breaker that makes contention *worse* than none, which is the parked-caller behaviour mandate 6 forbids. gobreaker holds its mutex only around bookkeeping. |
| Open-breaker call | returns `ErrOpenState` in **0.0000s**, never invoking the call | mandate 6, fast-fail |
| Open → half-open | `State()` reads `half-open` after `Timeout` with **zero traffic** | mandate 5: recovery is visible on `/health` with no traffic and no deploy |
| `IsExcluded` | 30 caller-provoked 404s left the breaker **closed** (`TotalExclusions: 30`) | user-driven 4xx cannot open a breaker on a healthy dependency |
| State readability | `State()` per instance, `OnStateChange` hook | the `/health` binding and the `since` stamp |

### The gaps, which are load-bearing because each fails silently

1. **No slow-call detection.** gobreaker counts failures, not durations — so **your client's
   transport timeout IS the slow-call threshold**. Set it generously and a brownout passes
   unnoticed: the dependency answers every call in 9s, nothing ever *fails*, the breaker stays
   closed, and `/health` reports it `up` while the service is unusable. resilience4j has an
   explicit `slowCallDurationThreshold`; Go does not, so the timeout carries that weight. This is
   the same gap the Python payload documents for `circuitbreaker`.
2. **`ReadyToTrip` defaults to five *consecutive* failures.** Consecutive-only never trips a
   dependency that fails every other call. `BreakerSettings` therefore ships a **failure rate with
   a minimum volume** (50% over ≥10 *counted* requests — excluded caller errors are removed from
   the denominator, or a crawler's 404s would hold a dead dependency's breaker closed).
3. **No retry.** gobreaker is a breaker and nothing else — see below.

### Why gobreaker and no retry library

Mandate 3 needs bounded retry with jittered backoff, and gobreaker does not provide it. The Python
sibling answered the same gap by blessing a **pair** (`circuitbreaker` + `tenacity`). Go does not
need one:

- the retry must be **breaker-aware regardless** — it must never retry an open breaker's rejection
  (that is mandate 6), never retry a caller's own error, and never retry past a spent context — so
  any library would be wrapped in that predicate anyway;
- with `math/rand/v2` and `time`, full-jitter exponential backoff is about thirty lines, which you
  can read in `dependency_catalog.go` in less time than you could read a library's options;
- every bootstrapped repo would otherwise carry a second version surface for it.

So: **one blessed library, one pin.** If you later need something richer (per-attempt deadlines,
retry budgets), replace `Call`'s loop — the mandate is that retry is bounded and jittered, not that
it comes from any particular place.

## Placement

Copy `dependency_catalog.go`, `dependency_health.go` and (optionally)
`pricing_api_client.go` into **one directory** in your service — `internal/resilience/` is the
conventional spot — with `resilience-dependencies.properties` **in that same directory**. Every
file here declares `package resilience`, so splitting them across directories does not compile,
and the declaration's location is a **build-time** requirement: it is `//go:embed`-ed, so the
compiler resolves that path. Fold `go.mod.deps`' require line into the same `go.mod` you folded
the ops-api payload's into, then `go mod tidy`.

**The declaration is compiled into the binary**, not read from the working directory. That is
what makes it reach the runtime at all: the blessed Go image is ko onto `distroless/static`,
which ships the binary and a CA bundle and nothing else, so a file read from the cwd would simply
not be there. `$OPS_DEPENDENCIES_FILE` still overrides it at runtime for a mounted ConfigMap —
and an unreadable override fails loudly rather than silently falling back, because a typo'd path
that quietly used the embedded default would boot the pod with the wrong readiness hinge.

**Place the `.go` files before running `go mod tidy`**: tidy removes any requirement no package in
the working tree imports, so running it against a tree that does not yet contain them silently
strips the gobreaker line and exits 0.

**There is exactly one placeholder in this payload**, and it is flagged in the source:

```go
// <-- CHANGE THIS IMPORT to your service's real module path for the ops payload.
ops "example.com/service/internal/ops"
```

Nothing else needs editing on placement — a Go file declares its own package name, so unlike the
Java sibling there is no `package` line to re-set.

Then wire it at startup:

```go
catalog, err := resilience.Load()   // the embedded declaration, or $OPS_DEPENDENCIES_FILE when set
if err != nil { log.Fatalf("resilience: %v", err) }

pricing, err := resilience.NewPricingAPIClient(catalog)   // each client CLAIMS its dependency
if err != nil { log.Fatalf("pricing client: %v", err) }

// AFTER every client is built — see "Four things are yours to do" below.
if err := catalog.RequireAllDeclaredGuarded(); err != nil { log.Fatalf("%v", err) }

ops.Serve(ctx, ops.DefaultAddr(), ops.Config{
    Dependencies: resilience.NewDependencyHealth(catalog),
})
```

Construct `DependencyHealth` **before the breakers see traffic**: it attaches the
`OnStateChange` hooks that keep `since` honest. A breaker that transitioned earlier still reports
the right *status* — that is read live — but its `since` would be the construction time.

## Four things are yours to do, and three fail quietly

1. **Declare your real dependencies** in `resilience-dependencies.properties` (`<name>=hard|soft`,
   one per line, **full-line `#` comments only**, no duplicates — a repeated name is rejected at
   startup, because last-wins could silently downgrade a `hard` dependency and disarm the
   readiness hinge) and **replace the shipped `orders-db` / `pricing-api` examples**. Editing it
   changes the binary, so it is a rebuild, not a restart. Left verbatim they fail startup on `RequireAllDeclaredGuarded`
   (nothing guards them) — and if you skip that call, `/health` reports two dependencies you do
   not have as `up`.
2. **Claim each dependency in its client's constructor** with
   `catalog.RequireDeclared(name)` — it is the only writer of the guarded set, so a
   service whose clients never claim theirs has an empty one and step 4 then
   refuses *every* declared dependency at boot. Then **route every outbound call
   through `resilience.Call`**, and give the call its **own timeout** —
   the one mandate the catalog cannot impose, because it does not own your socket. In Go it does
   double duty as the slow-call threshold (gap 1 above).
3. **Pass `resilience.NewDependencyHealth(catalog)` to `ops.Config.Dependencies`.** Without it the
   ops surface is a conforming ops-api **v1.0** — no `components`, readiness from your `Readiness`
   func alone — which is correct but blind.
4. **Call `catalog.RequireAllDeclaredGuarded()` once at startup, after your clients are built.** It
   is the only thing that catches a dependency you declared but never wired — whose breaker can
   never leave `closed`, so `/health` would swear it was up throughout a total outage.

Under-reporting is refused from **both** sides, which is the only way the pair is useful:
`RequireDeclared` refuses a dependency guarded in code but undeclared, and
`RequireAllDeclaredGuarded` refuses one declared but guarded by nobody.

## The six mandates, and where each one lives

| # | mandate | where |
| --- | --- | --- |
| 1 | Timeout | **yours** — on the client (`http.Client.Timeout`, a context deadline). Doubles as the slow-call threshold. |
| 2 | Circuit breaker, one per dependency | `Catalog`, created eagerly per declared dependency |
| 3 | Bounded retry + jittered backoff | `Call`'s loop — 3 attempts, full jitter over an exponential delay capped at 2s |
| 4 | Registered fallback | `Call`'s `fallback` argument. The payload enforces that one is *wired*; what it returns is your business logic |
| 5 | Background reconnect | `BreakerSettings.Timeout` — open → half-open, computed from elapsed time, so recovery shows on `/health` with no traffic |
| 6a | Stay stable — fast-fail | what `Call` does **not** do: an open breaker's rejection arrives immediately, un-retried, and goes straight to the fallback |
| 6b | Stay stable — the rest | **yours.** `Call` cannot stop you holding a lock or a `WaitGroup` *across* it, spawning a goroutine per request around it, leaking a response body inside your `call` closure, uncapping `SetMaxOpenConns`, or `log.Fatal`-ing on what the fallback returns |

## `Components()` must return a snapshot

The seam's contract **requires** a freshly built map, and this is the one rule whose violation is
not survivable: `/health` and `/health/ready` both range over what you return, and a map another
goroutine writes is a concurrent map read/write — a Go **fatal** error, not a panic. The ops
handler's `recover` guards cannot catch it, so the process dies mid-scrape. That is the
outage-time crash mandate 6 forbids, arriving through the one door those guards do not cover.

`DependencyHealth.Components()` builds a fresh map every call and copies its `since` stamps under
a lock. If you write your own source, do the same.

## Two vocabularies

| Where | Healthy | Impaired | Failed |
| --- | --- | --- | --- |
| `/health` aggregate | `ok` | `degraded` | `down` |
| a `components` entry | `up` | `degraded` | `down` |

Breaker state maps to a component status exactly: `closed` → `up`, `half_open` → `degraded`,
`open` → `down`. A **hard** dependency merely half-open floors the aggregate at `degraded`, not
`down` — only a hard dependency fully down forces `down` and fails readiness.

Returning the wrong spelling (`"ok"` for a component) is coerced by the ops payload to the **most
severe** reading, never the least — loudly, which is the intended outcome.

## Caller errors are not dependency failures

Wrap them with `resilience.NotADependency(err)`. They are then excluded from the breaker's counters
entirely — neither success nor failure — so thirty user-provoked 404s cannot open a breaker on a
perfectly healthy dependency and, if it is declared `hard`, start failing readiness for the whole
pod. `pricing_api_client.go` classifies the **whole 4xx range**, not just the 404 you happened to
think of.

The same wrapper covers a local cancellation (an interrupt during a drain): the retry loop must not
sleep through a shutdown on a dependency that is already gone.
