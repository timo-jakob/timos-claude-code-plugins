# Python resilience + dependency health

The blessed Python realization of the org resilience policy and the ops-api v1.1
dependency-health contract (issue #1143, epic #964). Copied into your service by
`/development:bootstrap`; this file explains what landed and what you still have to
do.

The idea in one line: **the circuit breaker keeps you serving; the dependency-health
surface tells you what's degraded.** An open breaker *is* a down dependency, so
`/health` reads breaker state rather than running a second health mechanism.

This payload is the sibling of `languages/python/ops-api/` and **extends it** —
`ops_api` serves the endpoints, this payload supplies the dependency view it reports.
If you are adopting both (the normal case), place them together.

## The blessed libraries: `circuitbreaker` + `tenacity`

**Python has no resilience4j.** Java's payload gets the breaker and the retry from one
library; no maintained Python library ships both. So the blessed choice is a **pair**,
and the pairing is the decision — not a menu:

| Mandate | Library | Why it, and not the alternative |
|---|---|---|
| 2 — circuit breaker | [`circuitbreaker`](https://github.com/fabfuel/circuitbreaker) `>=2.1,<3` | its `state` is a plain, side-effect-free property spelling exactly the contract's `closed`/`open`/`half_open`, so `/health` reads it from the ops thread with no lock, no coroutine and no traffic |
| 3 — bounded jittered retry | [`tenacity`](https://github.com/jd/tenacity) `>=9.0,<10` | the de-facto Python retry library; `wait_random_exponential` is the "Full Jitter" algorithm by name |

`dependency_catalog` composes them into `fallback(retry(breaker(call)))` — the same
nesting resilience4j's decorator order produces, spelled out rather than configured.

### Rejected, and why

- **`pybreaker` — rejected, and it is the popular one.** `CircuitBreaker.call()` holds
  a `threading.RLock` for the entire guarded call, so every caller of one dependency
  **serializes**: four concurrent 1-second calls through one breaker take 4 seconds,
  measured on 1.4.1. Parking every worker behind one slow dependency is precisely the
  behaviour mandate 6 exists to forbid — a breaker that makes contention *worse* than
  no breaker. Its async support is Tornado's `gen.coroutine`, so an asyncio service
  would take a Tornado dependency and *still* hold a threading lock across an `await`.
- **`purgatory` — rejected, though it is a good library.** Genuinely asyncio-native and
  concurrent. But its sync and async APIs are separate factories, and in async mode
  reading a circuit's state is itself a coroutine (`await uow.contexts.get(...)`) —
  awkward from the synchronous ops thread that serves `/health`, which is the one thing
  this payload has to do. Its state names (`opened`, `half-opened`) also need
  translating, and adoption is thin.
- **`tenacity` alone — rejected as a breaker, adopted as the retry.** It retries; it
  has no breaker, so a dead dependency would be re-attempted by every request forever.
  It is half the answer, and it *is* the half we take.

### What `circuitbreaker` does not give you, and what this payload does about it

Three gaps, each with a mitigation you should understand before you tune anything:

1. **No slow-call detection.** resilience4j opens a breaker when calls get slow;
   `circuitbreaker` only counts exceptions. So **your transport timeout IS the
   slow-call threshold** — a brownout (a dependency answering in 30s and never
   erroring) raises nothing, and a breaker that sees no exception never opens. This is
   why `TIMEOUT_SECONDS` in the worked client is tight and prominent.
2. **Consecutive failures, not a failure rate.** The counter resets on every success,
   so a dependency failing half its calls keeps the breaker closed. `FAILURE_THRESHOLD`
   is set low enough that a real outage (which fails every call) trips in well under a
   second of traffic.
3. **No state-change callback**, so `since` is stamped when the change was first
   *observed* rather than when it happened. Every `/health` scrape is an observation,
   so the stamp lands within one scrape interval of the transition.

One thing it does *better* than resilience4j's default: the open → half-open
transition is computed from elapsed time inside the `state` property, so a recovering
dependency shows as `degraded` on the next scrape **with no traffic and no deploy**.
That is mandate 5's visibility, for free — resilience4j needs
`automaticTransitionFromOpenToHalfOpenEnabled` switched on for the same effect.

## Files

| File | Goes to | What it does |
|---|---|---|
| `requirements.txt` | fold into your dependency set | the two pins |
| `resilience-dependencies.properties` | **beside `dependency_catalog.py`** | the hard/soft declaration |
| `dependency_catalog.py` | `src/<pkg>/` | the declaration, the breakers/retries, and the six-mandate `call` wrapper |
| `dependency_health.py` | `src/<pkg>/` — **beside `ops_api.py`** | reads breaker state into the ops-api `components` map |
| `pricing_api_client.py` | **adapt first — see below** | the worked six-mandate client — copy the shape, not the domain |

`dependency_health` imports `Dependency` from `ops_api` and is passed to `OpsConfig`,
so **the two belong in the same package**; `dependency_catalog` normally sits there
too.

**The client may sit beside its domain code — but then fix its import.** The three
modules import each other relative-first (`from .dependency_catalog import …`), which
resolves when they share a package. Put `pricing_api_client.py` in a *different*
package and that relative import raises `ModuleNotFoundError` — an `ImportError`
subclass, so the `except ImportError` fallback fires, and the bare form then fails too
under a `src/` layout. Either keep it in the same package as `dependency_catalog.py`,
or replace its try/except pair with an absolute `from <pkg>.dependency_catalog import
DependencyCatalog, NotADependencyFailure`.

**`pricing_api_client.py` is a worked EXAMPLE — adapt it before you place it, or leave
it out.** It cannot break startup (nothing imports it until you do, and it takes its
base URL as a constructor argument), so placing it unadapted leaves dead code rather
than a red build — but it names a dependency your service does not have.

## Wiring it up

Four lines at startup, and the order matters:

```python
from <pkg>.dependency_catalog import DependencyCatalog
from <pkg>.dependency_health import DependencyHealth
from <pkg>.ops_api import OpsConfig, serve

catalog = DependencyCatalog.load()          # 1. read the declaration
clients = build_clients(catalog)            # 2. each client calls catalog.require_declared(...)
catalog.require_all_declared_guarded()      # 3. refuse a declared dependency nobody guards
serve(config=OpsConfig(dependencies=DependencyHealth(catalog)))
```

(`<pkg>` is your package — the same one the ops-api README's `python -m
<pkg>.ops_api` names. The payload's own *intra*-module imports need no such edit:
they are written `try: from .sibling import X / except ImportError: from sibling
import X`, relative first, so they resolve inside a package and still work in a
flat layout. Do not flatten them to the bare form — Python 3 has no implicit
relative imports, so inside `src/<pkg>/` that raises `ModuleNotFoundError` at
startup.)

**Step 3 is the one that gets skipped, and skipping it is silent.** A name declared in
the properties file but wired to no client still gets a breaker (created eagerly, so it
can never be missing from `components`) — and that breaker stays `closed` forever
because nothing calls through it. `/health` would then report the dependency `up`
straight through a total outage, and a `hard` one would never shed traffic. Its mirror,
`require_declared` from each client's `__init__`, catches the same mistake from the
other side: a dependency guarded in code that nobody declared is invisible to `/health`.
The pair is only useful as a pair.

## The six mandates

Every governed outbound call MUST have all six. Five of them are centralized in
`dependency_catalog`; the client owns one.

| # | Mandate | Where it lives |
|---|---|---|
| 1 | timeout | **your client** — `timeout=` on the request. The catalog cannot impose one on a socket it does not own |
| 2 | circuit breaker, one per dependency | `DependencyCatalog` — one `CircuitBreaker` per declared name |
| 3 | bounded retry + jittered backoff | `DependencyCatalog` — tenacity, 3 attempts total, Full Jitter capped at 2s |
| 4 | registered fallback | the third argument to `catalog.call(...)` |
| 5 | background reconnect | the breaker's `RECOVERY_TIMEOUT`, visible on `/health` without traffic |
| 6 | stay-stable | an open breaker fast-fails into the fallback — no unbounded wait, no worker on a dead socket |

**Mandate 1 is the one to check on review, and it is not only an HTTP concern.** For a
DB driver, the pool's checkout timeout bounds only *acquiring* a connection: a query
already on the wire when the database stalls is unbounded unless you also set the
driver's statement timeout. For a message broker, it is the publish/confirm timeout.
An unbounded call never returns, so it never fails, so the breaker never opens — and
`/health` reports the dependency `up` for the whole event.

**Mandate 6 has a Python-specific trap that this payload handles for you, and that you
must not "simplify" away.** `circuitbreaker`'s `call()` and its context manager do
**not** check whether the circuit is open — they record the outcome but still run the
call; only its decorator form gates on state. `DependencyCatalog._reject_if_open` is
that check. Delete it and the breaker still opens and `/health` still says `down`,
while every request keeps hammering the dead dependency for its full timeout: a service
that correctly reports a dependency down while behaving exactly as if it had no breaker.

## Hard vs soft: the readiness hinge

Each dependency is declared `hard` or `soft` in
`resilience-dependencies.properties`, and that single classification resolves the
tension between naive readiness (shed traffic on any dependency loss) and resilience
(stay up and degrade):

- **`hard`** — nothing works without it. Its loss **fails `/health/ready`**, so
  Kubernetes sheds traffic away from the pod, and `/health` reports `down`.
- **`soft`** — degraded operation is possible. Its loss **never** fails readiness: the
  breaker opens, the pod stays ready, `/health` reports `degraded`, and full function
  returns with no deploy.

**Liveness is never a function of a dependency.** `/health/live` reflects only that the
process is serving; wiring a dependency into it turns a transient outage into a
pod-restart storm.

The declaration is read at startup from `$OPS_DEPENDENCIES_FILE` when that is set (a
mounted ConfigMap, so hard-vs-soft can be re-judged without a rebuild), else from the
file beside `dependency_catalog.py`. Two rules that bite quietly:

- **A NAMED file that cannot be read is a startup failure**, deliberately. A mistyped
  mount path must not degrade into "no dependencies" — that is a `/health` reporting
  nothing wrong during a total outage. Only the *absence* of the default file is a
  legitimate empty catalog.
- **Full-line `#` comments only.** The parser splits on the first `=`, so a trailing
  `orders-db=hard  # the main store` makes the kind `hard  # the main store` and fails
  loudly at startup. That is the intended behaviour — a typo must never silently drop a
  dependency from `/health` — but the fix is to put the comment on its own line.

## Not every exception is a dependency failure

A caller error is not an outage, and treating it as one is how a **healthy** dependency
gets reported `down`. A burst of lookups for nonexistent SKUs — user-controlled traffic —
would otherwise open the breaker on a dependency that answered every request correctly,
and if that dependency is `hard`, readiness then sheds all traffic from a perfectly good
pod.

`NotADependencyFailure` is the type that says so. It is ignored by **both** the breaker
and the retry: it never counts toward the failure threshold, and it is never re-attempted
(it cannot succeed on repeat). Raise it for a 4xx **other than 408 and 429**, a
malformed argument, or a local cancellation — the worked client shows the shape.

**408 and 429 stay dependency failures**, and the worked client excludes them by name.
429 means the dependency is shedding load and 408 that it gave up waiting; both say
"come back", which is exactly what a bounded jittered retry does. Misclassifying them
costs more than a lost retry, because of the trap below: every 429 in a rate-limit
storm would zero the breaker's failure count — holding it closed on a dependency that
is visibly struggling — and take the caller-error path that returns nothing instead of
the last known good value.

For a third-party client that raises **its own** type for a 404, pass it in:

```python
catalog = DependencyCatalog.load(not_a_dependency_failure=(TheirNotFound,))
```

**It EXTENDS the built-in set rather than replacing it** — `NotADependencyFailure` and
`CircuitBreakerError` are always ignored, and one tuple feeds both the breaker predicate
and the retry policy. This is a deliberate divergence from resilience4j, whose
`ignoreExceptions` *assigns*: there, widening the list silently drops the built-ins, and
widening only the breaker's leaves the caller error burning the full retry schedule. Here
neither mistake is expressible.

**One `circuitbreaker`-specific trap to respect when you classify.** The library treats an
exception its failure predicate rejects as a **success** — it calls `reset()`, closing the
circuit and zeroing the failure count. So a caller error arriving while the breaker is
half-open closes it exactly as a real successful probe would. That is the library's
behaviour, not something the catalog can override, and it is why you should raise
`NotADependencyFailure` only for things genuinely not the dependency's fault:
over-classify, and a stream of bad requests will hold a broken dependency's breaker closed.

## What `/health` looks like

```json
{
  "status": "degraded",
  "components": {
    "orders-db":   {"status": "up",   "kind": "hard", "breaker": "closed", "since": "2026-08-04T09:12:31Z"},
    "pricing-api": {"status": "down", "kind": "soft", "breaker": "open",   "since": "2026-08-04T11:02:07Z"}
  }
}
```

The components set a **floor** on the aggregate, not an equality:

- any **hard** dependency `down` ⇒ aggregate `down` (and readiness fails);
- any dependency `down` or `degraded` ⇒ aggregate at least `degraded`;
- otherwise `ok`.

Over-reporting is legal and sometimes required: a service impaired for a reason no
dependency models (a backed-up work queue) **must** report a more severe aggregate than
its components imply — that is what `OpsConfig(internal_status=...)` is for.
Under-reporting is a conformance failure.

**`/health` always answers HTTP 200** while the process can respond, even when the
aggregate is `down` — the verdict is in the body. 503 is the two *probes'* vocabulary
(`/health/live`, `/health/ready`); an operator reading `/health` during an outage needs
the diagnosis, not a bare error page.

## Async services

`DependencyCatalog.call_async` is the asyncio twin of `call`, with the same decoration
order and the same rules:

```python
async def quote(self, sku: str) -> PriceQuote | None:
    return await self._catalog.call_async(
        DEPENDENCY,
        lambda: self._fetch(sku),                       # an async def
        lambda cause: self._last_known_price(sku, cause),
    )
```

The **same breaker object** serves both paths, so an async service's `/health` reads
exactly what a sync one does. Two async-specific notes: give the client an explicit
timeout (`httpx.Timeout`, `aiohttp.ClientTimeout`) or wrap the call in
`asyncio.timeout` — `await` on a socket with no timeout is an unbounded wait that never
raises, so the breaker never opens; and `asyncio.CancelledError` is deliberately not
caught into the fallback (it inherits from `BaseException`), so a graceful shutdown
still unwinds instead of hanging on the dead dependency.

The worked client is synchronous because the standard library has no async HTTP client
and this family blesses none — a worked async example would have to pin one.

## Verifying it

The dependency view is exercised by the ops-conformance job bootstrap installs **when
the repo has a canonical container** (a Dockerfile), and that job runs on PRs touching
`contracts/ops/`. Either way you can run the checker directly:

```bash
zsh scripts/check-ops-conformance.zsh http://localhost:9090
```

It validates the `components` shape and rejects an aggregate that **under-reports** its
components — a hard dependency down while the aggregate still claims to serve. Note it
asserts a *serving* service: a `down` aggregate fails conformance, because `down` is a
legitimate runtime state that the conformance job cannot pass in.

To see the degraded path for real, take a soft dependency away (stop it, or point it at
a black hole) and watch `/health` go `degraded` with that component `down`, while
`/health/ready` keeps answering 200. Do the same to a hard one and `/health/ready`
turns 503.

## What this payload does NOT give you

- **It does not find your dependencies.** Nothing here can detect a dependency you call
  but never declared — that gap is the `python-resilience-reviewer` dimension's on new
  diffs, and the maintenance advisor's on the back catalogue.
- **It does not decide what a fallback returns.** That it exists and is wired is the
  org mandate; what it serves is your business logic.
- **It does not bound the retry's blast radius across dependencies.** There is no
  bulkhead here: a slow dependency's retries still occupy the worker that issued them
  (mandate 1's timeout is what bounds that), and nothing caps concurrent in-flight calls
  per dependency.
- **It does not probe.** Health is read from breaker state, which real traffic moves. A
  dependency nothing calls stays `up` until something calls it — by design: the
  alternative is scheduled health traffic, and calling a downstream's `/health` is the
  cascading storm this contract exists to avoid.
