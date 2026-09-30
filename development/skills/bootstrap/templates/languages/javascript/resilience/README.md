# Canonical resilience + dependency health (Node / TypeScript) — #1145

The blessed Node realization of the org resilience policy: every outbound dependency call is
circuit-broken, and the ops-api `/health` surface reports what those breakers know.

**The unifying idea: the circuit breaker keeps you serving; the dependency-health surface tells
you what's degraded.** An open breaker *is* a down dependency, so health is **read** from the
breaker rather than measured by a second mechanism.

This payload **extends** the ops-api payload beside it (`opsApi.ts`) rather than standing alone:
`DependencyHealth` implements the `DependencyHealthSource` seam that payload already ships. The
import direction is one-way and load-bearing — **`resilience` imports `ops`, never the reverse** —
and even that import is `import type`, erased at compile time, so the ops module stays free of any
breaker library exactly as its own doc comment promises.

It is **TypeScript, NodeNext ESM** (`"type": "module"`), type-checks clean under the strict
`tsconfig.json` bootstrap installs, and every relative import carries its explicit `.js`
specifier, as NodeNext resolution requires.

## The blessed library: `opossum` — and the fit-check

The choice was *confirmed*, not assumed. Measured against opossum 10.0.0 on Node 26, compiled
under the shipped strict `tsconfig.json`:

| property | measured | why it matters |
| --- | --- | --- |
| Concurrent callers through one breaker | 4 × 1s calls took **1.00s** | Python's `pybreaker` was rejected in #1143 because it serialised them (4.01s). Node is single-threaded, so opossum holds no lock across the call. |
| Per-dependency instances, readable state | one `CircuitBreaker` per dependency; `closed` / `halfOpen` / `opened` getters, `open` / `halfOpen` / `close` events | the `/health` binding and the `since` stamp |
| Open → half-open with **zero traffic** | after `resetTimeout` (10s) with **no calls at all**, the component read `breaker: "half_open"`, `status: "degraded"` | mandate 5: recovery is visible on `/health` with no traffic and no deploy. opossum moves the state on its own (unref'd) timer. |
| Open-breaker call | rejected with `EOPENBREAKER` in **0.0000s**; the action was invoked **0** times; the catalog went straight to the fallback | mandate 6, fast-fail |
| An action that hangs and ignores its signal | 3 attempts ended in the fallback with `ETIMEDOUT` in **6.11s** (3 × 2s) | mandate 1 holds even against a client that never honours its `AbortSignal` |
| Caller-provoked 4xx | 30 of them left the breaker **closed** | user-driven 4xx cannot open a breaker on a healthy dependency |

### What opossum gets wrong on its own — and what the catalog does instead

opossum's exclusion hook, `errorFilter`, does not do what the contract needs, and the failure is
silent:

1. **A filtered error is counted as a SUCCESS.** Measured: 30 filtered 404s left
   `fires=30 successes=30 failures=0`. The contract wants a caller error to be *neither* success
   nor failure.
2. **So excluded traffic dilutes the failure rate.** Measured: 100 filtered 404s followed by 20
   straight real failures, with `volumeThreshold: 10` and a 50% threshold, read `20/120` and left
   the breaker **closed** — `/health` reporting a dead dependency `up`. That is the same gap the Go
   sibling found in gobreaker's denominator.
3. **Its rolling window counts rejections too.** Every `fire()` increments `fires`, including the
   ones an open breaker rejects, and the window is not cleared on close — so a recovered
   dependency's rate is diluted by its own outage.

So the catalog **keeps opossum for state and disables its trip rule**. `volumeThreshold:
Number.MAX_SAFE_INTEGER` means opossum never trips a closed breaker itself, while it still
re-opens a breaker whose half-open probe fails. The catalog trips instead, from a **count-based
window of the last 20 counted outcomes** (minimum 10, trip at ≥ 50%). It counts real successes
and real failures only. Excluded errors and an open breaker's own rejections are never written,
and the window starts fresh on every state change. Measured on the same traffic as (2): 100
caller 404s, then real failures — the breaker opened on the **10th** counted failure.

The numbers are the Java sibling's resilience4j settings (`COUNT_BASED`, 20, 10, 50%, 10s open),
so a dependency trips and recovers at the same moment in every language.

**`errorFilter` still matters in half-open**, where opossum acts on a single probe: a caller error
there proves the dependency answered, so it closes the breaker; a caller's *cancellation* proves
nothing, so it re-opens it.

### No slow-call detection

opossum counts failures, not durations — so **the per-attempt timeout IS the slow-call
threshold** (`ATTEMPT_TIMEOUT_MS`, 2s, the Java and Spring siblings' slow-call bound). Raise it
generously and a brownout passes unnoticed: the dependency answers every call in 9s, nothing ever
*fails*, the breaker stays closed and `/health` reports it `up` while the service is unusable.

### Node floor, typing and the ESM import

- **Node floor.** opossum `^10.0.0` declares `engines.node` `^26 || ^24 || ^22`. That is stricter
  than the ops-api payload's OpenTelemetry floor, and because the two payloads are placed together
  or not at all, it is the pair's **joint floor**. Odd majors (23, 25) are outside it. Under npm's
  default `engine-strict=false` an engines mismatch only warns, so a runtime outside the floor is
  **unsupported**, not uninstallable.
- **Types.** opossum ships none, and the strict NodeNext config rejects an untyped import, so
  `@types/opossum` `^8.1.9` rides in the fragment's `devDependencies`. It types the 8.x API, and
  that is sound for 10.x: opossum's **entire runtime (`lib/` and `index.js`) is byte-identical from
  8.5.0 through 9.0.0 to 10.0.0** (`diff -r` of the three published tarballs). The two majors only
  narrowed `engines.node` (`^16`–`^24` → `^20 || ^22 || ^24` → `^22 || ^24 || ^26`). Every opossum
  API this payload calls — the constructor with `name`, `timeout`, `resetTimeout`,
  `volumeThreshold`, `errorFilter` and `enableSnapshots`, `fire`, `open`, the
  `closed` / `halfOpen` / `opened` / `enabled` getters and the three state events — is typed there,
  so no local `opossum.d.ts` ships.
- **Importing CommonJS from ESM.** opossum is a CommonJS package whose `module.exports` *is* the
  class. `import CircuitBreaker from "opossum"` is correct: Node hands an ESM importer the CJS
  `module.exports` as the default export, and `esModuleInterop` (on in the shipped config) maps
  `@types/opossum`'s `export =` onto the same default import. A *named* import would compile and
  be `undefined` at runtime.

### Why not `cockatiel`

`cockatiel` 4.0.0 is the obvious runner-up: TypeScript-native, ESM, with retry, timeout and
bulkhead in the same package. It is **dismissed on mandate 5**, measured: its open → half-open
transition is **lazy** — made inside `execute()`, on the next call. A breaker opened, then left
for twice its `halfOpenAfter` with **zero calls**, still read `state === Open`; it became
half-open (and closed) only when a call arrived. `/health` reads state passively, so on a quiet
service a recovered dependency would be reported **down indefinitely** — and for a `hard` one,
readiness would keep failing with no traffic ever arriving to change it. Working around that
means recomputing the transition from cockatiel's internal `openedAt` and backoff, which is
re-implementing the breaker's state machine beside it.

Its bundled retry is not a reason to prefer it either: the retry has to be breaker-aware
regardless (below), so it would be wrapped in that predicate anyway.

### Why opossum and no retry library

Mandate 3 needs bounded retry with jittered backoff, and opossum does not provide it. The Python
sibling answered the same gap with a second library; Node, like Go, does not need one:

- the retry must be **breaker-aware regardless** — it must never retry an open breaker's rejection
  (that is mandate 6), never retry a caller's own error, and never retry past a spent deadline or
  an aborted `AbortSignal` — so any library would be wrapped in that predicate anyway;
- full-jitter exponential backoff over `node:timers/promises` is about thirty lines you can read in
  `dependencyCatalog.ts` in less time than a library's options;
- every bootstrapped repo would otherwise carry a second version surface for it.

## Placement

Copy `dependencyCatalog.ts`, `dependencyHealth.ts` and (optionally) `pricingApiClient.ts` into
**one directory** in your service — `src/resilience/`, beside the ops-api payload's `src/ops/` —
with `resilience-dependencies.properties` beside them. Merge this directory's `package.json.deps`
into the **same** `package.json` you merged the ops-api fragment into, then `npm install`. The two
fragments are different files, and both must be merged.

**The declaration must reach the compiled output.** It is read at startup from beside the
**compiled** `dependencyCatalog.js`, and `tsc` does not copy non-TypeScript files. Add a copy step
to your build, e.g.
`"build": "tsc && cp src/resilience/resilience-dependencies.properties dist/resilience/"`.
A build that forgets fails **startup** loudly, naming the path it looked for — never a silent
default. `$OPS_DEPENDENCIES_FILE` overrides it at runtime for a mounted ConfigMap, and an
unreadable override fails loudly rather than falling back, because a typo'd path that quietly used
the default would boot the pod with the wrong readiness hinge.

**There is exactly one placement-dependent path**, and it is flagged in the source:

```ts
// <-- CHANGE THIS IMPORT if the ops-api payload is not at src/ops/opsApi.ts beside
import type { Dependency, DependencyHealthSource } from "../ops/opsApi.js";
```

Then wire it at startup:

```ts
import { serve } from "./ops/opsApi.js";
import { DependencyCatalog } from "./resilience/dependencyCatalog.js";
import { DependencyHealth } from "./resilience/dependencyHealth.js";
// Your own client; PricingApiClient is the worked example, placed only if you adapted it.
import { PricingApiClient } from "./resilience/pricingApiClient.js";

const catalog = DependencyCatalog.load(); // beside the module, or $OPS_DEPENDENCIES_FILE when set
const dependencies = new DependencyHealth(catalog); // BEFORE any traffic — see below

const pricing = new PricingApiClient(catalog); // each client CLAIMS its dependency

// AFTER every client is built — see "Four things are yours to do" below.
catalog.requireAllDeclaredGuarded();

// ONE more field on the OpsConfig the ops-api README has you build — keep your
// servedMajors and readiness there; a bare { dependencies } drops both.
const ops = await serve({ ...opsConfig, dependencies });
```

Construct `DependencyHealth` **before the breakers see traffic**: it attaches the listeners that
keep `since` honest. A breaker that transitioned earlier still reports the right *status* — that
is read live — but its `since` would be the construction time.

## Four things are yours to do, and three fail quietly

1. **Declare your real dependencies** in `resilience-dependencies.properties` (`<name>=hard|soft`,
   one per line, **full-line `#` comments only**, no duplicates — a repeated name is rejected at
   startup, because last-wins could silently downgrade a `hard` dependency and disarm the
   readiness hinge) and **replace the shipped `orders-db` / `pricing-api` examples**. Left
   verbatim they fail startup on `requireAllDeclaredGuarded` (nothing guards them) — and if you
   skip that call, `/health` reports two dependencies you do not have as `up`.
2. **Claim each dependency in its client's constructor** with `catalog.requireDeclared(name)` —
   it is the only writer of the guarded set, so a service whose clients never claim theirs has an
   empty one and step 4 then refuses *every* declared dependency at boot. Then **route every
   outbound call through `catalog.call(name, action, fallback, { signal })`**, and **pass the
   action's `AbortSignal` to your I/O** — fetch's `signal`, your driver's equivalent. The catalog
   owns the timeout, but only your action owns the socket.
3. **Pass `new DependencyHealth(catalog)` as `OpsConfig.dependencies`.** Without it the ops
   surface is a conforming ops-api **v1.0** — no `components`, readiness from your `readiness`
   function alone — which is correct but blind.
4. **Call `catalog.requireAllDeclaredGuarded()` once at startup, after your clients are built.**
   It is the only thing that catches a dependency you declared but never wired — whose breaker can
   never leave `closed`, so `/health` would swear it was up throughout a total outage.

Under-reporting is refused from **both** sides, which is the only way the pair is useful:
`requireDeclared` refuses a dependency guarded in code but undeclared, and
`requireAllDeclaredGuarded` refuses one declared but guarded by nobody.

## The six mandates, and where each one lives

| # | mandate | where |
| --- | --- | --- |
| 1 | Timeout | `ATTEMPT_TIMEOUT_MS` (2s), imposed **by the catalog** twice over: an `AbortSignal.timeout` joined to the caller's signal and handed to your action, and opossum's own `timeout`, which rejects the attempt even if the action ignores the signal. Doubles as the slow-call threshold. **Yours:** pass the signal to your I/O. |
| 2 | Circuit breaker, one per dependency | `DependencyCatalog`, created eagerly per declared dependency |
| 3 | Bounded retry + jittered backoff | `call`'s loop — 3 attempts, full jitter over an exponential delay capped at 2s (`backoffDelayMs`) |
| 4 | Registered fallback | `call`'s `fallback` argument. The catalog enforces that one is *wired*; what it returns is your business logic |
| 5 | Background reconnect | opossum's `resetTimeout` (10s) — open → half-open on its own timer, so recovery shows on `/health` with no traffic |
| 6a | Stay stable — fast-fail | what `call` does **not** do: an open breaker's rejection arrives immediately, un-retried, and goes straight to the fallback |
| 6b | Stay stable — the rest | **yours.** `call` cannot stop you blocking the event loop around it (a synchronous `readFileSync`, a CPU-bound loop, a sync crypto call), awaiting it without a fallback that *resolves*, or leaving an unread response body pinning a socket in the pool |

## Node's own crash hazard: an unhandled rejection

Node **terminates the process** on an unhandled promise rejection by default. So a dependency
call whose outage ends in a *rejected* promise that nobody awaits turns an upstream outage into a
pod crash — the outage-time crash mandate 6 forbids. That is why the fallback is mandatory and why
the worked example's fallback **resolves** with an honest absence (`{ available: false, cause }`)
rather than throwing. `call` itself rejects only for a programming error that surfaces on the
first call (an undeclared dependency, a missing fallback) or when **your fallback** throws — never
because a dependency is down.

## Two vocabularies

| Where | Healthy | Impaired | Failed |
| --- | --- | --- | --- |
| `/health` aggregate | `ok` | `degraded` | `down` |
| a `components` entry | `up` | `degraded` | `down` |

Breaker state maps to a component status exactly: `closed` → `up`, `half_open` → `degraded`,
`open` → `down`. A **hard** dependency merely half-open floors the aggregate at `degraded`, not
`down` — only a hard dependency fully down forces `down` and fails readiness. The ops module
derives that aggregate and the readiness answer; this payload only supplies the entries.

## Caller errors are not dependency failures

Throw them wrapped with `notADependency(err)`. They are then excluded from the trip rule entirely
— neither success nor failure — so thirty user-provoked 404s cannot open a breaker on a perfectly
healthy dependency and, if it is declared `hard`, start failing readiness for the whole pod.
The worked example (`pricingApiClient.ts` in this payload's template, placed only if you adapted it)
classifies the **whole 4xx range**, not just the 404 you happened to think of.

A caller who goes away mid-attempt — a client disconnect, a drain aborting in-flight requests
through the signal you passed to `call` — is re-classified the same way by the catalog, whatever
your action threw: fetch reports it as a plain `AbortError`, which would otherwise be charged to a
dependency that never misbehaved.
