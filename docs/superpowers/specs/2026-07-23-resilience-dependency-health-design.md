# Resilience & dependency health — design

**Date:** 2026-07-23
**Status:** Approved design, pre-implementation
**Builds on:** the ops-api surface (#688 — `/health`, `/health/live`,
`/health/ready`, the management-port trust model); ARCHITECTURE.md
"Standardized operations surface + OpenTelemetry-only instrumentation"

## 1. Context and goals

A service depends on things it does not control — a database, downstream
services, a message broker, a cache. Two gaps follow, and they are two halves of
one story:

1. **Observability** — a service should report its own health, the health of
   each **direct** upstream dependency it calls, and the aggregate of both.
2. **Resilience** — losing a dependency must never make the service
   unresponsive. It should degrade gracefully (serve what it still can),
   reconnect in the background, and above all **stay stable for itself**.

The unifying idea: **the circuit breaker keeps you serving; the dependency-health
surface tells you what's degraded.** They are two views of one truth — an open
breaker *is* a degraded dependency. So the plugin family should think in this
pattern by default: every outbound dependency call is circuit-broken, and the
ops-api `/health` surface reads breaker state.

Constraints carried throughout:

- **Minimize options, one good default** per decision.
- **Additive, not breaking** — this extends the #688 ops-api contract; it never
  breaks it.
- **The plugin enforces structure, not business logic** — it mandates that a
  fallback path exists, not what the fallback returns.

## 2. The health model — passive, from breaker state, direct-only

A service determines each dependency's health by **reading its circuit
breaker's state**, not by actively probing the dependency:

- **Passive** — an open breaker means the dependency is failing; a closed breaker
  means it is healthy; half-open means it is being re-probed. No extra
  health-check traffic is generated: the breaker already knows, because real
  request traffic (or its background probe) drives it.
- **Direct dependencies only** — a service reports the health of the dependencies
  **it** calls. It **never transitively calls a downstream's `/health`** to fold
  that into its own — that is the cascading health-check-storm anti-pattern (a
  single slow leaf makes every ancestor's health check hang). Each service
  reports one hop; the composition/observability layer assembles the graph.

```text
GET /health  (management port)
{
  "status": "degraded",
  "components": {
    "orders-db":   {"status": "up",   "kind": "hard"},
    "pricing-api": {"status": "down", "kind": "soft",
                    "breaker": "open", "since": "2026-07-23T09:12:04Z"}
  }
}
```

### Hard vs. soft dependencies — the readiness hinge

Each dependency is declared **hard** or **soft**, and that single classification
resolves the tension between "shed traffic when a dependency is down" (naive
readiness) and "stay up and degrade" (resilience):

- **Hard** — nothing works without it. Its failure **fails `/health/ready`** →
  Kubernetes sheds traffic (correct: the pod genuinely cannot serve). It never
  affects `/health/live` (liveness is process-only).
- **Soft** — degraded operation is possible. Its failure does **not** fail
  readiness. The breaker opens, the service serves degraded responses,
  reconnects in the background, and the dependency shows `down`/`degraded` in
  `/health` — but the pod **stays ready**.

The components put a **floor** under the aggregate `status`, not an equality:
`down` if any *hard* component is **down**; else at least `degraded` if **any**
component, hard or soft, is down **or degraded**; else `ok`. The middle branch is
deliberately **kind-agnostic** — a hard dependency that is merely `degraded`
(breaker half-open, re-probing) floors the aggregate at `degraded`, not `down`;
only a hard dependency fully down forces `down`.

**Over-reporting is legal** — a service may be `degraded` for an internal reason
no dependency models — so conformance rejects *under*-reporting. It separately
fails a `down` aggregate **outright**, because the check asserts a *serving*
service: `down` is a legitimate runtime state, not one a conformance job can
pass in.

**On the wire the AGGREGATE's healthy value is `ok`, not `up`** — renaming it
would break every v1.0 ops-api consumer. Component `status` values are a
different vocabulary and follow the breaker mapping directly: closed = `up`,
half-open = `degraded`, open = `down`. ARCHITECTURE.md's "Resilience policy +
dependency health" section (its ops-api v1 → v1.1 bullet) is authoritative on
both; see §4.

## 3. The resilience policy — the six mandates

Every outbound dependency call the pattern governs MUST have:

1. **Timeout** — a bounded wait; no call blocks forever.
2. **Circuit breaker** — opens on a failure threshold, half-opens to probe
   recovery. One breaker per dependency (the unit `/health` reports).
3. **Bounded retry + jittered backoff** — retries are finite and backed off;
   never an unbounded or tight retry loop (which turns a blip into a stampede).
4. **Registered fallback / degraded path** — the breaker has a fallback the
   service returns when the circuit is open. The plugin enforces that a fallback
   is *wired*; the business logic of the fallback is the application's.
5. **Background reconnect** — an open breaker periodically probes; full
   functionality resumes automatically when the dependency returns, with no
   deploy or manual step.
6. **Stay stable** — a lost dependency fast-fails through the open breaker; it
   never exhausts threads/connections, hangs the event loop, or crashes the
   process.

These are the non-negotiables the review dimension checks and the per-language
implementations satisfy. Liveness is deliberately **never** a function of a
dependency — mandate 6 is what keeps the process alive when a dependency dies.

## 4. Contract extension — additive ops-api minor (v1 → v1.1)

The dependency-health surface is an **additive** extension of the #688 ops-api
fragment (`contracts/ops/v1/openapi.yaml`), so it ships as an ops-api **minor**
through the existing `contracts-semver` gate — never a breaking change:

- `/health` gains an optional `components` object (per-dependency `status`,
  `kind: hard|soft`, `breaker`, `since`) and the aggregate `status` widens to
  `ok|degraded|down`. **Two encoding constraints are load-bearing, and this
  document's original wording got both wrong** (corrected in place, #1060): the
  healthy value stays **`ok`** (not `up`), and the widening ships as
  **`x-extensible-enum`**, not a plain `enum` — oasdiff classifies
  `response-property-enum-value-added` as breaking, so a plain widening would
  force an ops **major** for a semantically additive change. ARCHITECTURE.md's
  "Resilience policy + dependency health" section (its ops-api v1 → v1.1
  bullet) carries the authoritative statement of both.
- The `/health/ready` semantics are **formalized** (fails only on a hard dep
  down) — a documentation/behaviour tightening, not a schema break.
- `check-ops-conformance.zsh` gains optional validation of the `components`
  shape when present (a service with no declared dependencies simply omits it).

## 5. Decomposition

Structured exactly like the ops-api epic: **the contract + policy centrally, the
realization per language.**

### A. Resilience policy + dependency-health contract *(central foundation)*

The standard everything else realizes: the additive ops-api `/health` extension
(components + hard/soft), the six-mandate resilience policy document, the passive
breaker→health binding contract, and the ARCHITECTURE.md / CONTRACTS.md
sections. Language-agnostic; blocks the rest.

### B. Resilience review dimension

A review agent (per-language, following the `*-reviewer` convention) that flags,
on a diff: an outbound dependency call with no breaker/timeout/registered
fallback; an unbounded or un-backed-off retry; a code path where a lost
dependency hangs or crashes the service; and a hard/soft misdeclaration (e.g. a
cache marked hard). Wired into the review panels as a new dimension alongside
bugs/security/performance. Blocked by A.

### C. Per-language canonical resilience implementations *(sub-epic)*

Itself decomposes into **one child per service language** (spring, java, python,
go, javascript, swift). Each child: picks the language's **one blessed** breaker
library, ships bootstrap scaffolding that wires it around dependency clients,
binds breaker state to the ops-api `/health` components, provides the hard/soft
declaration mechanism, and adds a conformance test. Blocked by A; the per-language
children are mutually independent (different plugins). Spring/Java lead
(resilience4j is the reference).

### D. Resilience maintenance advisor

A maintenance-pipeline advisor (per language) that surfaces the review
dimension's findings as maintenance issues on existing code — un-broken
dependency calls, missing timeouts, unbounded retries — so the pattern is
enforced on the back catalogue, not only on new diffs. Blocked by A; reuses C's
per-language wiring knowledge.

**Ordering:** A first (blocks B, C, D). B, C, D then proceed independently; C is
the largest and becomes its own sub-epic when work starts (per-language
children).

## 6. Adjacencies

- **#688 (ops-api)** — this extends its `/health`/readiness surface additively;
  the management-port trust model and the `readiness()` seam are already
  forward-compatible with the hard/soft rule.
- **#724 (chaos/resilience testing)** — that epic *injects faults under load*;
  this epic is the app-side resilience it exercises. They meet at the assertion
  "a soft dependency killed under load leaves the service `degraded` but `ready`,
  and it recovers when the dependency returns."
- **Messaging (NATS JetStream + CloudEvents 1.0, #1060)** — a broker is a
  dependency like any other: its client gets a breaker, and its loss is hard or
  soft per the service. Note which way the messaging position pushes that
  classification: under transactional-outbox publishing the broker is **off**
  the synchronous write path, so a producer's broker loss is characteristically
  **soft** — the write commits, the relay lags, the service is degraded but
  ready. Declaring it hard there would shed traffic on a path that still works,
  which is the naive-readiness anti-pattern §2 retires. Hard is for a service
  whose core function is driven by what it **consumes**, and for the other
  producer shape the position carves out: a producer holding no transactional
  state of its own publishes **directly**, so the broker *is* its synchronous
  path — and when that direct publish IS the service's core function (the
  bridge case), its broker is **hard**. Only a genuinely ancillary direct
  publish may be declared soft. The breaker policy itself is broker-agnostic
  and unchanged by the messaging position.

## 7. Considered and rejected

- **Active health probing of each dependency** — a service pings each
  dependency's health on a schedule. Rejected: it adds health-check traffic, and
  if it calls a downstream's `/health` it reintroduces the cascade storm. Breaker
  state is a truer, traffic-free signal.
- **Transitive health aggregation** (fold each downstream's `/health` into mine)
  — rejected for the same cascade reason; each service reports one hop and the
  observability layer assembles the graph.
- **Locking one breaker library for every language up front** — rejected: some
  ecosystems (Python, Swift) have no clear single winner, and the choice is best
  made in the slice that owns that language. The *policy* is central; the *lib*
  is per-slice.
- **Making liveness reflect dependencies** — rejected outright: it is the
  restart-storm anti-pattern #688 already split away from. Liveness is
  process-only; dependencies live in readiness (hard) or degradation (soft).
- **Enforcing the fallback's business logic** — out of scope: the plugin
  mandates that a fallback is wired and the service stays stable; what the
  degraded response contains is the application's domain decision.
