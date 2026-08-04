"""Passive dependency health, read from circuit-breaker state, for Python (#1143, epic #964).

The unifying idea of the org resilience policy: THE CIRCUIT BREAKER KEEPS YOU SERVING;
THE DEPENDENCY-HEALTH SURFACE TELLS YOU WHAT'S DEGRADED. An open breaker IS a down
dependency, so health is read from the breaker rather than measured by a second mechanism.

PASSIVE means exactly that: this module never calls a dependency, never runs a scheduled
probe, and NEVER transitively calls a downstream's /health (the health-check-storm
anti-pattern, where one slow leaf hangs every ancestor's health check). Real request
traffic has already moved the state; reading it costs nothing and generates no traffic.

WHERE THE AGGREGATE AND THE READINESS RULE LIVE: not here. This module maps breaker state
to the per-dependency ``components`` entries and stops there; ``ops_api.OpsConfig`` derives
the aggregate floor and the readiness answer from those entries.

IT IMPORTS NO BREAKER LIBRARY, deliberately. It needs one thing from a breaker -- its
``state`` string -- so it reads that attribute and nothing else. Two things follow: the ops
surface can be unit-tested with a two-line fake breaker, and swapping the library (should
this family ever re-bless one) touches ``dependency_catalog`` alone.

PLACEMENT: copy into your service's package BESIDE ``ops_api.py`` and
``dependency_catalog.py``.
"""

from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime, timezone
from typing import TYPE_CHECKING, Callable

# PLACEMENT-PROOF IMPORT, and it is not boilerplate. The documented placement puts this
# module inside your package (``src/<pkg>/``), where Python 3 has no implicit relative
# imports: a bare ``from ops_api import Dependency`` then raises ModuleNotFoundError at
# startup, because ``sys.path`` carries ``src/``, not ``src/<pkg>/``. The relative form is
# therefore FIRST. The fallback covers the flat layout (files in one directory, run as
# top-level modules), which is how the payload's own tests exercise it.
try:
    from .ops_api import Dependency
except ImportError:  # not a package -- flat layout
    from ops_api import Dependency

if TYPE_CHECKING:  # pragma: no cover - import-time only, keeps this module library-free
    try:
        from .dependency_catalog import DependencyCatalog
    except ImportError:
        from dependency_catalog import DependencyCatalog

#: Breaker state -> the dependency status the contract reports.
#:
#: The mapping is exact and defined by the contract: closed = ``up``, half-open =
#: ``degraded`` (being re-probed), open = ``down``. ``circuitbreaker`` spells its three
#: states exactly as the contract's ``breaker`` field does, so the ``breaker`` value needs
#: no translation -- but map through this table rather than passing the raw string on, so a
#: library that ever spelled a state differently fails loudly here instead of emitting an
#: off-contract value the conformance checker rejects at deploy time.
_STATUS_BY_STATE = {
    "closed": "up",
    "half_open": "degraded",
    "open": "down",
}


class DependencyHealth:
    """Derives the ops-api v1.1 ``components`` map from circuit-breaker state.

    Wire it into the ops surface at startup::

        catalog = DependencyCatalog.load()
        ...build your dependency clients, each calling catalog.require_declared(...)...
        catalog.require_all_declared_guarded()
        serve(config=OpsConfig(dependencies=DependencyHealth(catalog)))
    """

    def __init__(self, catalog: DependencyCatalog, now: Callable[[], datetime] | None = None) -> None:
        """The ``now`` callable is injectable so a test can assert on ``since`` without sleeping."""
        self._catalog = catalog
        self._now = now or (lambda: datetime.now(timezone.utc))
        started_at = self._rfc3339(self._now())
        # name -> (last observed state, when this service first observed it)
        self._observed: dict[str, tuple[str, str]] = {
            name: (self._state_of(name), started_at) for name in catalog.dependencies
        }

    def components(self) -> Mapping[str, Dependency]:
        """One entry per DIRECT dependency, in declaration order.

        Empty when the service declares none, in which case ``ops_api`` omits the field
        entirely and the response stays a valid ops-api v1.0 body.
        """
        out: dict[str, Dependency] = {}
        for name, kind in self._catalog.dependencies.items():
            state = self._state_of(name)
            out[name] = Dependency(
                status=self._status_of(state, name),
                kind=kind,
                breaker=state,
                since=self._since(name, state),
            )
        return out

    def _since(self, name: str, state: str) -> str:
        """When this service first OBSERVED the dependency in its current state (RFC 3339).

        Observation-stamped, and the wording is the honest one. ``circuitbreaker`` publishes
        no state-change callback, so there is no transition to hook; what this can truthfully
        report is when the change was first SEEN. Every /health scrape is an observation, so
        the stamp lands within one scrape interval of the real transition. The alternative -- deriving it from the breaker's internals --
        would read a private attribute, and would still have nothing to offer for the closed
        state, which has no timestamp at all.
        """
        previous_state, previous_since = self._observed.get(name, (state, ""))
        if previous_state != state or not previous_since:
            stamp = self._rfc3339(self._now())
            self._observed[name] = (state, stamp)
            return stamp
        return previous_since

    def _state_of(self, name: str) -> str:
        """The breaker's own word for its state.

        Read as a plain attribute, with no call and no lock: ``circuitbreaker`` computes the
        open -> half-open transition from elapsed time inside the property itself. That is
        what makes MANDATE 5 (background reconnect) observable with no traffic and no deploy
        -- a recovering dependency shows up as ``degraded`` on the next scrape rather than
        staying ``down`` until something happens to call it.
        """
        return str(self._catalog.breaker(name).state)

    @staticmethod
    def _status_of(state: str, name: str) -> str:
        try:
            return _STATUS_BY_STATE[state]
        except KeyError:  # pragma: no cover - only reachable if the breaker library changes
            raise ValueError(
                f"dependency {name!r} reported unknown breaker state {state!r}; "
                f"expected one of {sorted(_STATUS_BY_STATE)}"
            ) from None

    @staticmethod
    def _rfc3339(moment: datetime) -> str:
        """RFC 3339 with a 'Z' offset and no sub-second noise.

        ``datetime.isoformat()`` renders UTC as ``+00:00``; both spell the same instant and
        the contract's ``date-time`` format accepts either, but ``Z`` is what every sibling
        payload emits and a dashboard grouping on the raw string should not see two forms.
        """
        return moment.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
