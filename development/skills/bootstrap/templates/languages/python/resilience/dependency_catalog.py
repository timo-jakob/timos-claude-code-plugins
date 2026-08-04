"""The hard/soft declaration and the six-mandate call wrapper, for Python (#1143, epic #964).

This module is the whole resilience scaffolding: it owns the declared direct
dependencies, the circuit breaker and the retry policy that protect each one, and
the ``call`` wrapper every governed outbound call goes through. ``dependency_health``
reads the breakers it creates; nothing else has to know they exist.

WHY THE DECLARATION LIVES IN A FILE AND NOT IN CODE: hard-vs-soft is an OPERATIONAL
judgement that changes without the code changing (a cache that was optional becomes
load-bearing), and a reviewer can audit the whole dependency set by reading one short
file. Spring services declare the same thing under ``resilience.dependencies`` in
application.yml and plain-Java ones in ``resilience-dependencies.properties``; this is
the Python spelling of it, deliberately the SAME file name and format as Java's so the
one thing an operator has to find is in the same place in every service.

TWO LIBRARIES, NOT ONE. Java gets breaker and retry from resilience4j; no maintained
Python library ships both, so the blessed pair is ``circuitbreaker`` (mandate 2) and
``tenacity`` (mandate 3), composed here in the same nesting order resilience4j's
decorators produce. See the payload README (placed as RESILIENCE.md) for why those two and not
the alternatives.

PLACEMENT: copy into your service's package beside ``ops_api.py``, e.g.
``src/<pkg>/ops_api.py`` -> ``src/<pkg>/dependency_catalog.py``.

Requires: circuitbreaker, tenacity (see requirements.txt beside this file).
"""

from __future__ import annotations

import os
from collections.abc import Awaitable, Callable, Iterable, Mapping
from pathlib import Path
from typing import TypeVar

from circuitbreaker import CircuitBreaker, CircuitBreakerError
from tenacity import (
    AsyncRetrying,
    Retrying,
    retry_if_exception_type,
    retry_if_not_exception_type,
    stop_after_attempt,
    wait_random_exponential,
)

T = TypeVar("T")

#: The declaration file read from BESIDE THIS MODULE when no explicit path is given.
#:
#: Beside the module, not relative to the working directory: a container's CWD is whatever
#: the entrypoint happened to set, and a declaration that resolves differently under
#: ``python -m pkg.app`` than under a process manager would leave /health silently empty --
#: an empty catalog is legal, so nothing would complain. Packaged next to the code, it
#: travels with the deployable exactly as Java's classpath resource does.
DEFAULT_DECLARATION_FILE = "resilience-dependencies.properties"

#: Env var pointing at a declaration file on disk (a mounted ConfigMap, typically).
DECLARATION_FILE_ENV = "OPS_DEPENDENCIES_FILE"

#: How a dependency's loss affects readiness. ``hard`` fails /health/ready; ``soft`` never does.
KIND_HARD = "hard"
KIND_SOFT = "soft"
KINDS = (KIND_HARD, KIND_SOFT)


class NotADependencyFailure(Exception):
    """Raised by a guarded call for something that is NOT the dependency's fault.

    A caller mistake (a malformed argument, a 4xx for a resource that legitimately does
    not exist), or a local cancellation such as a shutdown interrupting in-flight work.

    It is ignored by BOTH the retry and the breaker, which is the whole point. Without
    such a type every exception a call raises is a dependency failure, so a burst of
    user-driven 404s -- or a drain that cancels in-flight work -- opens the breaker on a
    dependency that never failed; ``/health`` then reports it ``down``, and if it is
    declared ``hard``, readiness sheds all traffic from a perfectly healthy pod.

    Retrying these is equally wrong: they cannot succeed on repeat, so the attempts only
    burn the backoff schedule while the caller waits.

    ONE PYTHON-SPECIFIC TRAP, and it is silent: ``circuitbreaker`` treats an exception its
    failure predicate rejects as a SUCCESS -- it calls ``reset()``, which closes the
    circuit and zeroes the failure count. So a caller error arriving while the breaker is
    half-open closes it, exactly as a real successful probe would. That is the library's
    behaviour, not something this module can override, and it is the reason to raise this
    type ONLY for things that are genuinely not the dependency's fault: over-classify, and
    a stream of bad requests will hold a broken dependency's breaker closed.
    """


class DependencyCatalog:
    """The service's declared direct dependencies, each with the breaker and retry that protect it.

    DIRECT dependencies only. A service reports the one hop it calls itself and never
    transitively calls a downstream's ``/health`` -- that is the health-check-storm
    anti-pattern, where one slow leaf hangs every ancestor's health check.
    """

    #: Consecutive failures that trip a breaker open (mandate 2).
    #:
    #: CONSECUTIVE, not a failure rate over a window: ``circuitbreaker`` resets the counter
    #: on every success, so unlike resilience4j's sliding window this cannot open on "50% of
    #: the last 20 calls". A dependency failing half its calls therefore keeps this breaker
    #: closed. That is the library's model; the value below is chosen low enough that a real
    #: outage (which fails every call) trips in well under a second of traffic.
    FAILURE_THRESHOLD = 5

    #: Seconds an open breaker stays open before the next call is allowed through as the
    #: half-open trial (mandate 5's timer).
    RECOVERY_TIMEOUT = 10.0

    #: The whole call budget: one try plus two retries, NOT three retries (mandate 3).
    MAX_ATTEMPTS = 3

    #: Backoff bounds, in seconds. ``wait_random_exponential`` is tenacity's "Full Jitter"
    #: (its own docstring names the algorithm): each wait is drawn uniformly from
    #: ``[0, multiplier * 2**attempt]``, capped at ``MAX_BACKOFF``. Randomizing the whole
    #: window -- not just adding a jitter term to a fixed one -- is what stops every client
    #: retrying a recovering dependency at the same instant and turning a recovery into a
    #: second outage.
    #:
    #: The cap is load-bearing even though the shipped 3 attempts never approach it: this is
    #: a template adopters tune, and raising attempts to 6 without a ceiling silently parks a
    #: caller on a multi-second final wait.
    INITIAL_BACKOFF = 0.2
    MAX_BACKOFF = 2.0

    def __init__(
        self,
        dependencies: Mapping[str, str],
        *,
        failure_threshold: int | None = None,
        recovery_timeout: float | None = None,
        max_attempts: int | None = None,
        not_a_dependency_failure: Iterable[type[BaseException]] = (),
    ) -> None:
        """Declare the dependencies directly.

        ``not_a_dependency_failure`` is the seam for the one thing the blessed defaults
        cannot decide for you: WHICH EXCEPTIONS ARE NOT DEPENDENCY FAILURES.
        :class:`NotADependencyFailure` covers it when your own code raises, but a
        third-party client that raises its own type for a 404 needs that type here too --
        and without this argument the only way to add it would be to edit this file.

        Unlike resilience4j's ``ignoreExceptions`` (which ASSIGNS the list, so a naive
        override silently drops the built-ins), this argument EXTENDS the built-in set:
        :class:`NotADependencyFailure` and ``CircuitBreakerError`` are always ignored.
        Widening one and forgetting the other is not possible here -- the same tuple feeds
        both the breaker's failure predicate and the retry's, because widening only the
        breaker's stops the caller error counting toward the threshold but still burns the
        full retry schedule on every one.
        """
        self._dependencies: dict[str, str] = {}
        for name, raw in dependencies.items():
            self._dependencies[name] = _parse_kind(raw, name)

        # `is None`, never `or`: an explicit 0 is a caller MISTAKE for all three, and `or`
        # would silently swap it for the default instead of rejecting it below.
        self._failure_threshold = self.FAILURE_THRESHOLD if failure_threshold is None else failure_threshold
        self._recovery_timeout = self.RECOVERY_TIMEOUT if recovery_timeout is None else recovery_timeout
        self._max_attempts = self.MAX_ATTEMPTS if max_attempts is None else max_attempts
        if self._failure_threshold < 1 or self._max_attempts < 1 or self._recovery_timeout <= 0:
            # recovery_timeout must be strictly POSITIVE, and 0 is the interesting case:
            # `circuitbreaker` computes `state` from elapsed time, so with a zero window an
            # open breaker reads half_open immediately and `breaker.opened` is never True.
            # _reject_if_open would then never fire -- every request would hammer the dead
            # dependency for its full transport timeout, and /health would report a total
            # outage as `degraded` forever instead of `down`. That is mandate 6 disabled by
            # a config value, so it is refused rather than silently accepted.
            raise ValueError(
                "failure_threshold and max_attempts must be >= 1 and recovery_timeout > 0; got "
                f"{self._failure_threshold}, {self._max_attempts}, {self._recovery_timeout}"
            )
        self._ignored: tuple[type[BaseException], ...] = (
            NotADependencyFailure,
            CircuitBreakerError,
            *tuple(not_a_dependency_failure),
        )
        self._guarded: set[str] = set()

        # Create every declared dependency's breaker EAGERLY. Created lazily on first call, a
        # dependency nothing has called yet would have no breaker for dependency_health to
        # read and would be missing from /health entirely -- under-reporting the contract
        # forbids, and at the worst possible moment (startup, when an operator is watching).
        self._breakers: dict[str, CircuitBreaker] = {
            name: CircuitBreaker(
                failure_threshold=self._failure_threshold,
                recovery_timeout=self._recovery_timeout,
                expected_exception=self._is_dependency_failure,
                name=name,
            )
            for name in self._dependencies
        }

    @classmethod
    def load(
        cls,
        *,
        failure_threshold: int | None = None,
        recovery_timeout: float | None = None,
        max_attempts: int | None = None,
        not_a_dependency_failure: Iterable[type[BaseException]] = (),
    ) -> DependencyCatalog:
        """Load the declaration from ``$OPS_DEPENDENCIES_FILE``, else from the default file, else empty.

        An EMPTY catalog is legitimate, not an error: a service with no direct dependencies
        omits the ``components`` map entirely and stays a valid ops-api v1.0 responder. What
        is NOT legitimate is having dependencies and not declaring them, which nothing here
        can detect -- that gap is the review dimension's and the maintenance advisor's to
        close.

        :raises OSError: if a declaration file is NAMED but cannot be read. A mistyped mount
            path must not degrade silently into "no dependencies", which would produce a
            health surface that reports nothing wrong during a total outage.
        """
        named = os.environ.get(DECLARATION_FILE_ENV, "").strip()
        if named:
            # No try/except: an unreadable NAMED file must fail startup loudly. Only the
            # ABSENCE of the default file is a legitimate "this service has no dependencies".
            declared = parse_declaration(Path(named).read_text(encoding="utf-8"))
        else:
            default = Path(__file__).with_name(DEFAULT_DECLARATION_FILE)
            declared = parse_declaration(default.read_text(encoding="utf-8")) if default.is_file() else {}
        return cls(
            declared,
            failure_threshold=failure_threshold,
            recovery_timeout=recovery_timeout,
            max_attempts=max_attempts,
            not_a_dependency_failure=not_a_dependency_failure,
        )

    @property
    def dependencies(self) -> Mapping[str, str]:
        """The declared dependencies (name -> ``hard``/``soft``), in declaration order."""
        return dict(self._dependencies)

    def breaker(self, name: str) -> CircuitBreaker:
        """The circuit breaker guarding ``name``. One breaker per dependency -- the unit /health reports.

        A PURE READ, and deliberately not routed through :meth:`require_declared`. This is the
        path ``dependency_health`` takes for every declared dependency on every /health scrape;
        if it recorded guardedness as a side effect, building ``DependencyHealth`` (or a single
        scrape) before :meth:`require_all_declared_guarded` would mark every dependency guarded
        and that guard could never fire again -- silently restoring the failure it exists to
        prevent. Recording guardedness is the job of the call clients make from ``__init__``.
        """
        self._assert_declared(name)
        return self._breakers[name]

    def require_declared(self, name: str) -> str:
        """Assert that ``name`` is declared, RECORD it as guarded, and return it.

        Call this from a dependency client's ``__init__``. A client that guards a dependency
        nobody declared would work perfectly and be invisible on /health -- the
        under-reporting the contract forbids -- and :meth:`call` alone would only catch it on
        the first request. Failing at wiring time turns that into a boot failure an operator
        sees immediately.
        """
        self._assert_declared(name)
        self._guarded.add(name)
        return name

    def _assert_declared(self, name: str) -> None:
        """The membership check both public entry points share, with no guardedness side effect."""
        if name not in self._dependencies:
            raise LookupError(
                f"dependency {name!r} is guarded in code but not declared. "
                f"Add '{name}={KIND_HARD}' or '{name}={KIND_SOFT}' to "
                f"{DEFAULT_DECLARATION_FILE}, so /health reports it."
            )

    def require_all_declared_guarded(self) -> None:
        """Assert that every DECLARED dependency has a client guarding it.

        The mirror of :meth:`require_declared`, and just as load-bearing. Call it from startup
        AFTER every dependency client is constructed.

        Without it the two guards only cover one direction. A name declared in the file but
        wired to no client still gets a breaker (created eagerly so it can never be missing
        from ``components``), and that breaker stays closed forever because nothing ever calls
        through it -- so ``/health`` reports the dependency ``up`` unconditionally, straight
        through a total outage, and a ``hard`` one never sheds traffic either.

        :raises RuntimeError: naming every declared dependency no client claimed.
        """
        unguarded = [name for name in self._dependencies if name not in self._guarded]
        if unguarded:
            raise RuntimeError(
                "declared but not guarded by any client: "
                + ", ".join(unguarded)
                + ". Their breakers can never leave 'closed', so /health would report them 'up'"
                + " during an outage. Wire a client through call(...) for each, or remove them"
                + f" from {DEFAULT_DECLARATION_FILE}."
            )

    def call(
        self,
        name: str,
        call: Callable[[], T],
        fallback: Callable[[BaseException], T],
    ) -> T:
        """Run an outbound call under all six mandates and fall back if it fails.

        THE DECORATION ORDER IS THE POINT, and it is the same nesting resilience4j's
        decorators produce, spelled out rather than configured::

            fallback( retry( breaker( call ) ) )

        The breaker is INNERMOST, so it observes each individual attempt. Retry wraps it, so
        a transient blip is re-attempted with jittered backoff. The fallback is OUTERMOST, so
        it fires only once the bounded retries are exhausted -- a fallback inside the retry
        would convert the first failure into a success and the call would never be retried.

        Only :class:`Exception` is caught: a :class:`BaseException` such as
        ``KeyboardInterrupt`` or ``SystemExit`` is not a dependency failure and must not be
        swallowed by a fallback.

        :param call: the actual outbound call. It MUST carry its own transport timeout
            (mandate 1); nothing here can impose one on a socket it does not own. FOR HTTP
            that is the client's connect AND read timeout. FOR A DB DRIVER it is not only the
            pool's checkout timeout, which bounds only ACQUIRING a connection: a query already
            on the wire when the database stalls is unbounded, so set the driver's statement
            timeout as well.

            THE TIMEOUT CARRIES MORE WEIGHT HERE THAN IN JAVA. resilience4j also opens a
            breaker on a SLOW-call rate, which catches the classic brownout -- a dependency
            answering in 2.9s and never erroring. ``circuitbreaker`` has no notion of a slow
            call, so in Python the transport timeout IS the slow-call threshold: without a
            tight one, a brownout produces no exceptions at all, the breaker never opens, the
            fallback never fires, and /health reports the dependency ``up`` for the whole event.
        :param fallback: the degraded path (mandate 4). It MUST NOT call the dependency and
            MUST NOT re-raise -- either defeats the breaker it is protecting. WHAT it returns
            is your business logic; THAT it exists is the org mandate.
        """
        # require_declared, not breaker(): routing a call through the catalog IS guarding the
        # dependency, so it records that. breaker() is the pure READ path /health takes.
        breaker = self._breakers[self.require_declared(name)]
        try:
            for attempt in self._retrying():
                with attempt:
                    return self._guarded_attempt(breaker, call)
        except Exception as failure:
            # Broad on purpose: the fallback IS this call's general handler. It catches
            # Exception and not BaseException so a cancellation still unwinds.
            return fallback(failure)
        raise AssertionError("unreachable: tenacity either returns a value or raises")  # pragma: no cover

    async def call_async(
        self,
        name: str,
        call: Callable[[], Awaitable[T]],
        fallback: Callable[[BaseException], T],
    ) -> T:
        """The asyncio twin of :meth:`call`, with the same decoration order and the same rules.

        The same breaker object serves both -- ``circuitbreaker`` keeps no lock and no loop
        affinity, so an async service's ``/health`` reads the same state a sync one does.

        Mandate 1 is unchanged and just as easy to lose: ``await`` on a socket with no timeout
        is an unbounded wait that never raises, so the breaker never opens. Give the client an
        explicit timeout (``httpx.Timeout``, ``aiohttp.ClientTimeout``) or wrap the call in
        ``asyncio.timeout``.

        ``asyncio.CancelledError`` is deliberately NOT caught: it inherits from
        ``BaseException``, and swallowing a cancellation into the fallback would make a
        graceful shutdown hang on exactly the dead dependency this module is about.
        """
        # require_declared, not breaker(): routing a call through the catalog IS guarding the
        # dependency, so it records that. breaker() is the pure READ path /health takes.
        breaker = self._breakers[self.require_declared(name)]
        try:
            async for attempt in self._retrying_async():
                with attempt:
                    return await self._guarded_attempt_async(breaker, call)
        except Exception as failure:
            # Broad on purpose: the fallback IS this call's general handler. It catches
            # Exception and not BaseException so a cancellation still unwinds.
            return fallback(failure)
        raise AssertionError("unreachable: tenacity either returns a value or raises")  # pragma: no cover

    # -- internals ----------------------------------------------------------------------

    def _guarded_attempt(self, breaker: CircuitBreaker, call: Callable[[], T]) -> T:
        self._reject_if_open(breaker)
        with breaker:
            return call()

    async def _guarded_attempt_async(self, breaker: CircuitBreaker, call: Callable[[], Awaitable[T]]) -> T:
        self._reject_if_open(breaker)
        with breaker:
            return await call()

    @staticmethod
    def _reject_if_open(breaker: CircuitBreaker) -> None:
        """Fast-fail through an open breaker (mandate 6) -- and DO NOT DELETE THIS.

        ``CircuitBreaker.call()`` and its context manager do NOT check whether the circuit is
        open: they record the outcome, but they still RUN the call. Only the library's
        decorator form gates on the state. So without this check the breaker would open, be
        reported ``down`` on /health -- and every request would keep hammering the dead
        dependency for its full timeout anyway. The observable symptom is a service that
        correctly says a dependency is down while still behaving exactly as if it had no
        breaker at all.

        Raised OUTSIDE the ``with breaker`` block on purpose: raised inside, the rejection
        would itself be recorded as a dependency failure.
        """
        if breaker.opened:
            raise CircuitBreakerError(breaker)

    def _is_dependency_failure(self, exc_type: type[BaseException], exc: BaseException) -> bool:
        """The breaker's failure predicate: True counts toward the threshold.

        ``circuitbreaker`` inverts resilience4j's polarity -- it asks which exceptions ARE
        failures rather than which are ignored -- so this returns False for the ignored set.

        THE ``Exception`` BOUND IS THE SAME ONE :meth:`_retry_predicate` CARRIES, and it is
        needed here for the same reason: ``circuitbreaker`` hands EVERY exception to this
        predicate, ``BaseException`` included. Without the bound, an
        ``asyncio.CancelledError`` unwinding through ``with breaker:`` -- an ASGI client
        disconnecting mid-call, or a graceful shutdown draining in-flight work -- counts as
        a dependency failure. Enough of those in a row open the breaker on a dependency that
        never failed; ``/health`` then reports it ``down``, and a ``hard`` one sheds all
        traffic from a healthy pod. A cancellation is OUR event, not the dependency's.

        THE COST OF THE BOUND, stated plainly because this library makes it: an exception
        this predicate rejects is recorded as a SUCCESS (``circuitbreaker`` calls
        ``reset()``), so a cancellation also zeroes the failure count. That is the lesser
        evil -- under-counting a real outage costs one more failing call to re-open the
        breaker, while over-counting cancellations takes a healthy dependency down.
        """
        return issubclass(exc_type, Exception) and not issubclass(exc_type, self._ignored)

    def _retry_predicate(self) -> object:
        """Which exceptions are re-attempted -- and, just as importantly, which are not.

        TWO CLAUSES, AND BOTH ARE LOAD-BEARING.

        ``retry_if_exception_type(Exception)`` bounds retrying to ordinary exceptions.
        It looks redundant and is not: tenacity's attempt context manager records EVERY
        exception, ``BaseException`` included, and defers the decision to this predicate.
        Tenacity's *default* predicate happens to be `retry_if_exception_type(Exception)`,
        so overriding it without this clause silently widens retrying to
        ``asyncio.CancelledError``, ``KeyboardInterrupt`` and ``SystemExit`` -- a
        graceful-shutdown drain would then be swallowed, backoff-slept, and the dead
        dependency re-called for the rest of the budget before the cancellation finally
        propagated. That is precisely the hang :meth:`call_async` promises not to cause.

        ``retry_if_not_exception_type(self._ignored)`` subtracts the two things that must
        never be retried: an open breaker's rejection (retry is the OUTER decorator, so
        retrying it burns the whole backoff schedule on a dependency already known to be
        down -- the parked-caller behaviour mandate 6 forbids) and a caller error, which
        cannot succeed on repeat.
        """
        return retry_if_exception_type(Exception) & retry_if_not_exception_type(self._ignored)

    def _retrying(self) -> Retrying:
        return Retrying(
            stop=stop_after_attempt(self._max_attempts),
            wait=wait_random_exponential(multiplier=self.INITIAL_BACKOFF, max=self.MAX_BACKOFF),
            retry=self._retry_predicate(),
            # Re-raise the dependency's own exception rather than tenacity's RetryError wrapper,
            # so the fallback receives the real cause and can tell a caller error from an outage.
            reraise=True,
        )

    def _retrying_async(self) -> AsyncRetrying:
        # The same three settings as the sync policy, from the same source -- an async service
        # that quietly retried cancellations is the one place this divergence would hurt most.
        return AsyncRetrying(
            stop=stop_after_attempt(self._max_attempts),
            wait=wait_random_exponential(multiplier=self.INITIAL_BACKOFF, max=self.MAX_BACKOFF),
            retry=self._retry_predicate(),
            reraise=True,
        )


def parse_declaration(text: str) -> dict[str, str]:
    """Parse ``<name>=hard|soft`` lines, preserving declaration order.

    Hand-parsed rather than handed to :mod:`configparser`, for two reasons that both show up
    in the health surface: configparser REQUIRES a ``[section]`` header, so the file an
    operator can read at a glance would need ceremony that means nothing; and it LOWER-CASES
    keys by default, so a dependency named ``OrdersDB`` becomes ``ordersdb`` and then matches
    no client's ``require_declared`` call. Python dicts preserve insertion order, so the order
    a human wrote -- the order /health reports dependencies in -- survives for free.

    :raises ValueError: on a malformed line or an unknown kind. A typo must be loud: silently
        skipping the line would drop a dependency from /health entirely.
    """
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, sep, kind = line.partition("=")
        name = name.strip()
        if not sep or not name:
            raise ValueError(f"malformed dependency declaration {line!r} (want <name>=hard|soft)")
        if name in out:
            # Last-wins is the one malformation a silent parser would swallow, and it
            # disarms the readiness hinge: a file that gained a stray second
            # `orders-db=soft` after `orders-db=hard` -- which is how a merged or
            # appended-to ConfigMap evolves -- would quietly keep `soft`, so a total
            # outage of a hard dependency would never fail readiness, while /health
            # still lists it and looks perfectly conformant.
            # The second kind is rendered RAW, not through _parse_kind: validating it here
            # would raise the kind error first on `a=hard` + `a=maybe`, so the operator
            # would fix the kind and only meet the duplicate on the next boot.
            raise ValueError(
                f"dependency {name!r} is declared twice ({out[name]!r} then "
                f"{kind.strip().lower()!r}); one line per dependency"
            )
        out[name] = _parse_kind(kind, name)
    return out


def _parse_kind(raw: str, name: str) -> str:
    kind = raw.strip().lower()
    if kind not in KINDS:
        raise ValueError(f"dependency {name!r} has kind {raw.strip()!r} (want hard|soft)")
    return kind
