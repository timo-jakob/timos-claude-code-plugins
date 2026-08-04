"""A worked six-mandate dependency client for Python (#1143, epic #964).

The reference for how EVERY governed outbound call in this service should be wired. Copy
the shape, not the domain: pricing-api is an example SOFT dependency (the catalogue still
sells when pricing is unavailable -- it quotes the last known price instead). A HARD
dependency is wired identically; only the ``pricing-api=soft`` line in
resilience-dependencies.properties differs, and with it what happens to /health/ready when
its breaker opens.

THE SIX MANDATES, and where each one lives:
  1. TIMEOUT               the ``timeout=`` on the request, below -- the ONLY mandate the
                           catalog cannot impose for you, because it does not own your socket
  2. CIRCUIT BREAKER       DependencyCatalog.call -> one breaker per dependency
  3. BOUNDED RETRY +
     JITTERED BACKOFF      DependencyCatalog's tenacity policy
  4. REGISTERED FALLBACK   the third argument to call(...), _last_known_price below
  5. BACKGROUND RECONNECT  the breaker's recovery timeout, read passively by /health
  6. STAY-STABLE           an open breaker fast-fails into the fallback; no unbounded wait,
                           no worker parked on a dead socket

SO THE CLIENT'S OWN JOB IS SMALL: set the timeout, route the call through catalog.call(...),
and write a degraded path worth having. That is deliberate -- the mandates that can be
centralized ARE centralized, so the thing a reviewer has to check on each new client is a
handful of lines.

WHY THE STANDARD LIBRARY: this family blesses no HTTP client, and a worked example that
pinned one would either contradict the service's own choice or add a dependency for a
template. ``urllib.request`` shows the shape with nothing to install. Your real client uses
whatever the service already uses (httpx, requests, aiohttp) -- that choice is orthogonal to
the six mandates, and the async shape is in the payload README (placed as RESILIENCE.md).

PLACEMENT: copy into your service beside its domain code -- but keep it in the SAME
PACKAGE as dependency_catalog.py, because the relative import below only resolves
there. If it must live in a different package, replace that try/except pair with an
absolute ``from <pkg>.dependency_catalog import DependencyCatalog,
NotADependencyFailure``: the relative form would raise ModuleNotFoundError (an
ImportError subclass, so the fallback fires) and the bare fallback fails too under a
src/ layout.
"""

from __future__ import annotations

import logging
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from decimal import Decimal

# PLACEMENT-PROOF IMPORT — see the same note in dependency_health.py. Relative first,
# because the documented placement is inside your package, where the bare form raises
# ModuleNotFoundError at startup; the fallback covers a flat layout.
try:
    from .dependency_catalog import DependencyCatalog, NotADependencyFailure
except ImportError:  # not a package -- flat layout
    from dependency_catalog import DependencyCatalog, NotADependencyFailure

logger = logging.getLogger(__name__)

#: The declared dependency name. It is the key in resilience-dependencies.properties, the
#: name of the breaker, and the key /health reports this dependency under -- one string, so
#: the three can never drift apart.
DEPENDENCY = "pricing-api"

#: Mandate 1. Bounds connect AND each socket read.
#:
#: READ THE LIMIT: it is per socket OPERATION, not per call. A dependency that dribbles a
#: byte every second resets the clock forever, so the call is still unbounded -- rare, but
#: it is exactly the shape mandate 6 forbids, and the breaker cannot save you (a call that
#: never returns never fails, so it never counts toward the threshold). Where that matters,
#: enforce a whole-call deadline as well: a real client library's total-timeout setting
#: (``httpx.Timeout``), or a watchdog around the call.
#:
#: KEEP IT TIGHT. resilience4j also opens a breaker on a SLOW-call rate; ``circuitbreaker``
#: has no such notion, so in Python THIS VALUE IS THE SLOW-CALL THRESHOLD. A dependency in
#: the classic brownout -- accepting connections and answering in 30s, never erroring --
#: produces no exceptions at all with a generous timeout, so the breaker never opens, the
#: fallback never fires, and /health reports the dependency ``up`` for the whole event.
TIMEOUT_SECONDS = 3.0

#: The 4xx codes that are the DEPENDENCY's problem, not the caller's.
#:
#: The rest of the 4xx band is reclassified as a caller error below, on the reasoning that
#: it is deterministic and cannot succeed on repeat. These two are neither: 429 means the
#: dependency is shedding load and 408 that it gave up waiting — both say "come back", which
#: is exactly what a bounded jittered retry does.
#:
#: MISCLASSIFYING THESE COSTS MORE THAN A LOST RETRY, because of the library trap the
#: catalog documents: an exception the breaker's predicate rejects is recorded as a SUCCESS.
#: So a rate-limit storm — precisely when the dependency is struggling — would zero the
#: failure count on every 429, hold the breaker closed (or close a half-open one), and take
#: the caller-error fallback branch that returns nothing instead of the last known price.
RETRYABLE_4XX = frozenset({408, 429})


@dataclass(frozen=True)
class PriceQuote:
    """A unit price for one stock-keeping unit."""

    sku: str
    amount: Decimal
    currency: str
    stale: bool


class PricingApiClient:
    """Reads unit prices from the pricing service, degrading to the last known price."""

    def __init__(self, catalog: DependencyCatalog, base_url: str) -> None:
        # Fail at WIRING time if nobody declared this dependency. Without it the client would
        # work perfectly and be missing from /health -- a health surface that stays quiet
        # through an outage, which is the exact failure this payload exists to prevent.
        catalog.require_declared(DEPENDENCY)
        self._catalog = catalog
        self._base_url = base_url
        # The degraded path's data: the last successful quote PER SKU, re-served marked
        # `stale` so callers can tell a live price from a fallback one.
        #
        # PER SKU MATTERS. A single-slot cache looks equivalent and is not: every fetch would
        # evict every other SKU, so during an outage the fallback would miss for all but the
        # most recently fetched one. Bound it (an LRU) before you ship a catalogue large
        # enough for this dict to matter; unbounded per-key caches are their own outage.
        self._last_known_good: dict[str, PriceQuote] = {}

    def quote(self, sku: str) -> PriceQuote | None:
        """Fetch the current unit price for a SKU, e.g. ``ESP-1042-BLK``.

        One call to :meth:`DependencyCatalog.call` is the whole protection: breaker, bounded
        jittered retry, and the fallback, composed in the order that makes each of them work.

        :return: the quote, or ``None`` when pricing is unavailable and nothing is cached for
            this SKU. ``None`` rather than a zero-priced quote on purpose: a degraded path
            owes the caller a usable answer or an honest absence, never a fabricated number
            they might bill on.
        """
        return self._catalog.call(
            DEPENDENCY,
            lambda: self._fetch(sku),
            lambda cause: self._last_known_price(sku, cause),
        )

    def _fetch(self, sku: str) -> PriceQuote:
        """The raw outbound call. Everything it raises is a dependency failure the breaker records.

        EXCEPT what this method reclassifies, and that reclassification is the one thing here
        that fails silently if you drop it. ``urllib`` RAISES on a 4xx/5xx (unlike Java's
        ``java.net.http``, which returns the status and makes you check it), so the failure is
        never missed -- the Python trap is the mirror image: a 4xx arrives as an exception
        that looks exactly like an outage. Left unclassified, a burst of lookups for
        nonexistent SKUs -- user-controlled traffic -- opens the breaker on a dependency that
        answered every request correctly, and /health then reports it ``down``.
        """
        request = urllib.request.Request(self._price_url(sku), method="GET")  # noqa: S310 (https URL from config)
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:  # noqa: S310
                body = response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            if 400 <= error.code < 500 and error.code not in RETRYABLE_4XX:
                # A CALLER error -- an unknown SKU, a malformed request. Deterministic, so
                # retrying only burns backoff, and counting it toward the failure rate is how
                # a healthy dependency gets reported down.
                raise NotADependencyFailure(
                    f"pricing-api answered HTTP {error.code} for sku {sku} (caller error)"
                ) from error
            raise
        # The example endpoint answers a bare decimal, so this payload needs no JSON parsing
        # and stays about resilience. Decimal, not float: a price is money.
        quote = PriceQuote(sku=sku, amount=Decimal(body.strip()), currency="EUR", stale=False)
        self._last_known_good[sku] = quote
        return quote

    def _price_url(self, sku: str) -> str:
        """Build the request URL safely. Two traps, both of which turn a CALLER's input into a
        reported dependency outage:

        1. THE SKU MUST BE ENCODED. Interpolated raw, a ``?``, ``#`` or ``../`` silently
           injects a query, a fragment or a different path -- and a space makes the request
           fail inside the guarded call, so the breaker records it as a dependency failure.
           ``quote`` with an empty ``safe`` also encodes ``/``, which a SKU may legitimately
           contain and which would otherwise walk the path.
        2. RESOLVING AN ABSOLUTE PATH DISCARDS THE BASE PATH. ``urljoin("https://gw/pricing",
           "/v1/prices/X")`` is ``https://gw/v1/prices/X``, not ``https://gw/pricing/v1/...``
           -- so a service behind a gateway prefix silently calls the wrong endpoint.
           Resolving a RELATIVE path against a base normalized to end in ``/`` keeps the prefix.
        """
        base = self._base_url if self._base_url.endswith("/") else self._base_url + "/"
        return urllib.parse.urljoin(base, "v1/prices/" + urllib.parse.quote(sku, safe=""))

    def _last_known_price(self, sku: str, cause: BaseException) -> PriceQuote | None:
        """The registered fallback (mandate 4).

        It MUST NOT call the dependency, and MUST NOT re-raise -- either would defeat the
        breaker it is protecting. Returning quickly is the point: this is what keeps the
        service answering while pricing is down.

        What it returns is business logic and yours to decide; that it EXISTS and is wired is
        the org mandate.
        """
        # A CALLER ERROR IS NOT AN OUTAGE, and the fallback sees both because call()'s except
        # clause cannot tell them apart. Two things go wrong without this branch: a SKU that
        # was priced before and now 404s -- delisted -- would be re-served its OLD price, when
        # the dependency just told us authoritatively that it no longer exists; and every
        # bad-SKU lookup would log a warning claiming pricing-api is unavailable, flooding the
        # log with false outage reports about a dependency that answered correctly.
        if isinstance(cause, NotADependencyFailure):
            # EVICT, or the honest absence lasts only until the next outage: the entry would
            # survive, and the generic branch below would then re-serve the delisted SKU's
            # old price -- the very thing this branch exists to refuse. Conservative on
            # purpose (any caller error drops one entry); the next success repopulates it.
            self._last_known_good.pop(sku, None)
            logger.debug("no price for sku %s: %s", sku, cause)
            return None
        logger.warning("pricing-api unavailable for sku %s, serving last known price", sku, exc_info=cause)
        cached = self._last_known_good.get(sku)
        if cached is not None:
            return PriceQuote(sku=sku, amount=cached.amount, currency=cached.currency, stale=True)
        # No cached price for THIS sku, so there is nothing honest to serve. None is the
        # signal; a zero-priced quote would be a plausible-looking lie a caller could bill on.
        # Note it still RETURNS -- a fallback that re-raises defeats the breaker.
        return None
