"""Canonical ops-api implementation for non-Spring Python services (issue #688).

This is the blessed Python realization of the org-standard ops surface defined by
``contracts/ops/v1/openapi.yaml`` — ``/info``, ``/health``, ``/metrics`` — so a
Python service conforms to the same fragment Spring gets via Actuator. It passes
``scripts/check-ops-conformance.zsh`` unchanged.

Instrumentation is **OpenTelemetry only** (ARCHITECTURE.md policy): metrics come
from the OTel SDK ``MeterProvider``. OTLP push to a collector is the primary
pipeline; ``/metrics`` is the mandatory pull-compat surface, served here by the
OTel SDK's Prometheus exporter (``PrometheusMetricReader`` feeds the
``prometheus_client`` registry — a config wiring, not a second metrics system).

Endpoints: ``/info``, ``/health`` (aggregate), ``/health/live`` (K8s liveness —
process only, dependency-free), ``/health/ready`` (K8s readiness — plug the
NON-dependency half via ``OpsConfig.readiness``; the dependency half comes from
``OpsConfig.dependencies``, below), and ``/metrics``.

DEPENDENCY HEALTH (ops-api v1.1, #1143 / epic #964): ``/health`` carries an
optional ``components`` map — one entry per DIRECT dependency, read PASSIVELY
from that dependency's circuit-breaker state — and a declared ``hard``
dependency being down also fails ``/health/ready``. Wire it with
``OpsConfig(dependencies=...)``; the blessed source is ``DependencyHealth`` in
the resilience payload beside this one (``templates/languages/python/resilience/``).
Without it this module behaves exactly as before: no ``components`` field, and
readiness is your ``readiness`` callable alone. The binding is a PROTOCOL over a
plain dataclass, so this file needs no breaker library installed.

NOTE that ``/health`` answers 200 even when the aggregate is ``down`` — the
verdict is in the body. Only the two PROBES (``/health/live``, ``/health/ready``)
speak in status codes. An earlier revision of this template aliased ``/health``
to the readiness handler and answered 503, which the contract forbids and
``check-ops-conformance.zsh`` rejects (#1139, Python half).

This is an INTERNAL management surface: it binds a separate MANAGEMENT PORT
(default 9090), never the public app port, so ``/info``'s build data is
unreachable from outside without any per-endpoint auth. The network boundary
(NetworkPolicy + a Service that exposes only the app port, and the liveness/
readiness probe wiring) is the deployment layer's job (the composition repo).

Placement: drop this module into your package (e.g. ``src/<pkg>/ops_api.py``) and
run ``python -m <pkg>.ops_api`` as a lightweight ops sidecar, or mount
``OpsHandler`` on your existing server's management port. Declare the API majors
your service serves via ``served_majors`` — the /info lifecycle table is what
makes the epic #684 deprecation machinery observable.

Requires: opentelemetry-sdk, opentelemetry-exporter-prometheus, prometheus-client
(see requirements.txt beside this file).
"""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable, Literal, Protocol

from opentelemetry import metrics
from opentelemetry.exporter.prometheus import PrometheusMetricReader
from opentelemetry.sdk.metrics import MeterProvider
from prometheus_client import CONTENT_TYPE_LATEST, REGISTRY, generate_latest

Lifecycle = Literal["active", "deprecated"]

#: The /health aggregate, worst-first so ``_worse_of`` can compare two by index.
#: "ok" (never "up") is the exact spelling ops-api v1.0 shipped — renaming it would
#: break every v1.0 consumer, so v1.1 only ADDS "degraded" beside it.
STATUS_ORDER = ("ok", "degraded", "down")


@dataclass(frozen=True)
class ApiMajor:
    """One served API major and its lifecycle (mirrors the fragment's ApiMajor).

    A ``deprecated`` major MUST carry a ``sunset`` date (RFC 8594); an ``active``
    one MUST NOT need one. ``to_info`` enforces that invariant at serialization.
    """

    major: int
    lifecycle: Lifecycle = "active"
    sunset: str | None = None

    def to_info(self) -> dict[str, object]:
        if self.lifecycle == "deprecated" and not self.sunset:
            raise ValueError(
                f"deprecated major {self.major} needs a sunset date (RFC 8594)"
            )
        entry: dict[str, object] = {"major": self.major, "lifecycle": self.lifecycle}
        if self.sunset:
            entry["sunset"] = self.sunset
        return entry


@dataclass(frozen=True)
class Dependency:
    """One DIRECT dependency's health, as the ops-api v1.1 ``components`` map reports it.

    ``status``  up | degraded | down — read from the dependency's circuit breaker.
    ``kind``    hard | soft — the readiness hinge.
    ``breaker`` closed | open | half_open — the state the status was read from.
    ``since``   RFC 3339 timestamp of the last state change, so a dashboard can tell a
                blip from a sustained outage.
    """

    status: str
    kind: str
    breaker: str | None = None
    since: str | None = None

    def to_component(self) -> dict[str, object]:
        entry: dict[str, object] = {"status": self.status, "kind": self.kind}
        if self.breaker:
            entry["breaker"] = self.breaker
        if self.since:
            entry["since"] = self.since
        return entry


class DependencyHealthSource(Protocol):
    """Supplies the per-direct-dependency health that /health reports under ``components``.

    Deliberately a protocol over a plain dataclass rather than a dependency on a breaker
    library: this module stays importable by a service that has no outbound dependencies at
    all. The blessed implementation is ``DependencyHealth`` in the resilience payload
    (``templates/languages/python/resilience/``), which derives these entries PASSIVELY from
    circuit-breaker state — an open breaker IS a down dependency.

    DIRECT dependencies only. A service reports the one hop it calls itself and never
    transitively calls a downstream's /health (the health-check-storm anti-pattern).
    """

    def components(self) -> Mapping[str, Dependency]:
        """One entry per direct dependency, keyed by its stable name, in declaration order."""
        ...


@dataclass
class OpsConfig:
    """What the service reports on /info, and how the two health verdicts are decided.

    ``readiness`` is the NON-dependency half of the readiness answer — still starting up,
    draining during a graceful shutdown, an internal resource exhausted. The default is
    always-ready. The DEPENDENCY half comes from ``dependencies``: a declared ``hard``
    dependency being down also fails readiness, while a ``soft`` one never does. Liveness is
    deliberately NOT configurable: it reflects only that the process is serving, and must
    never check a dependency (that would turn a transient outage into a pod-restart storm).

    ``internal_status`` is the over-reporting hook the contract requires: the components set
    a FLOOR on the /health aggregate, never an equality, so a service impaired for a reason
    no dependency models (a backed-up work queue, a full disk) MUST report a MORE severe
    aggregate than its dependencies imply. Reporting a LESS severe one is a conformance
    failure.
    """

    version: str = field(default_factory=lambda: os.environ.get("BUILD_VERSION", "0.0.0"))
    git_sha: str = field(default_factory=lambda: os.environ.get("GIT_SHA", "unknown"))
    served_majors: tuple[ApiMajor, ...] = (ApiMajor(major=1, lifecycle="active"),)
    readiness: Callable[[], bool] = field(default=lambda: True)
    dependencies: DependencyHealthSource | None = None
    internal_status: Callable[[], str] = field(default=lambda: "ok")

    def info_payload(self) -> dict[str, object]:
        return {
            "build": {"version": self.version, "git_sha": self.git_sha},
            "api": [m.to_info() for m in self.served_majors],
        }

    def components(self) -> Mapping[str, Dependency]:
        """One snapshot of the dependency view, taken once per request.

        Both /health's aggregate and its components map are derived from the SAME snapshot,
        so a breaker that flips mid-request can never produce a body whose headline
        contradicts its own component list.
        """
        if self.dependencies is None:
            return {}
        return {name: _on_contract(d) for name, d in (self.dependencies.components() or {}).items()}

    def ready(self, components: Mapping[str, Dependency]) -> bool:
        """The readiness answer behind /health/ready.

        Among dependencies, only a declared HARD one being DOWN makes the service unready — a
        soft dependency down keeps the pod ready and serving degraded responses.
        Non-dependency reasons still apply and are checked first.
        """
        if not self.readiness():
            return False
        return not any(d.kind == "hard" and d.status == "down" for d in components.values())

    def aggregate(self, components: Mapping[str, Dependency]) -> str:
        """The aggregate served by /health: the worse of this service's own internal state and
        the FLOOR its dependencies impose — "down" if any HARD dependency is down, else
        "degraded" if ANY dependency is down or degraded, else "ok".

        Note the hard/degraded case: a HARD dependency that is merely half-open reads
        "degraded", not down, so it floors the aggregate at "degraded".
        """
        status = self.internal_status()
        if status not in STATUS_ORDER:
            # An off-contract value (a typo, "up" borrowed from the components vocabulary,
            # None, "") is normalized to the MOST severe status, never the least. Failing
            # toward severity keeps the coercion honest: read the other way, a mistyped
            # internal-status hook would make /health answer "ok" during exactly the
            # impairment the hook was written to report — the under-reporting the contract
            # forbids. "down" instead fails ops conformance loudly, and /health keeps
            # serving rather than raising out of the handler mid-outage.
            status = "down"
        for dependency in components.values():
            down = dependency.status == "down"
            if down and dependency.kind == "hard":
                status = _worse_of(status, "down")
            elif down or dependency.status == "degraded":
                status = _worse_of(status, "degraded")
        return status

    def health_payload(self, components: Mapping[str, Dependency]) -> dict[str, object]:
        """The /health body: the aggregate, plus ``components`` only when there are any.

        A service that declares no dependencies omits the field entirely and stays a valid
        ops-api v1.0 response.
        """
        payload: dict[str, object] = {"status": self.aggregate(components)}
        if components:
            payload["components"] = {name: d.to_component() for name, d in components.items()}
        return payload


def _worse_of(a: str, b: str) -> str:
    """Worst-wins comparison over STATUS_ORDER (ok < degraded < down)."""
    return a if STATUS_ORDER.index(a) >= STATUS_ORDER.index(b) else b


def _on_contract(dependency: Dependency) -> Dependency:
    """Force one component's ``status``/``kind`` onto the contract's vocabulary.

    ``DependencyHealthSource`` is a PROTOCOL, so a service may hand-write one — and this
    module ships two vocabularies that are easy to confuse: the aggregate spells healthy
    ``ok`` while a component spells it ``up``. A source that returns ``"ok"``, ``"Down"``
    or ``kind="Hard"`` would otherwise be read as healthy/soft by both ``ready`` and
    ``aggregate``, which compare against the literal contract spellings — so a hard
    dependency reported down in the wrong case would keep the pod ready and the aggregate
    ``ok``. That is the under-reporting the contract forbids, arriving silently.

    Unknown values are coerced to the MOST severe reading (``down``, ``hard``), never the
    least — the same fail-toward-severity rule ``aggregate`` applies to ``internal_status``.
    The blessed ``DependencyHealth`` can never trip this: it raises on an unknown breaker
    state and its kinds come from a parser that lower-cases them.
    """
    status = dependency.status if dependency.status in ("up", "degraded", "down") else "down"
    kind = dependency.kind if dependency.kind in ("hard", "soft") else "hard"
    if status == dependency.status and kind == dependency.kind:
        return dependency
    return Dependency(status=status, kind=kind, breaker=dependency.breaker, since=dependency.since)


def install_metrics() -> MeterProvider:
    """Wire the OTel SDK MeterProvider with the Prometheus reader.

    The reader registers a collector with prometheus_client's global REGISTRY, so
    ``/metrics`` exposes OTel-recorded metrics in Prometheus text format — the
    OTel SDK is the single instrumentation source, Prometheus is only the
    pull-compat exposition.
    """
    provider = MeterProvider(metric_readers=[PrometheusMetricReader()])
    metrics.set_meter_provider(provider)
    return provider


class OpsHandler(BaseHTTPRequestHandler):
    """Serves the three ops endpoints. Mount on any ``http.server`` server."""

    config: OpsConfig = OpsConfig()

    def _send(self, code: int, content_type: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code: int, payload: dict[str, object]) -> None:
        self._send(code, "application/json", json.dumps(payload).encode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler contract)
        route = self.path.split("?", 1)[0].rstrip("/") or "/"
        if route == "/info":
            self._json(200, self.config.info_payload())
        elif route == "/health/live":
            # Liveness: the process is serving this request, so it is alive.
            # Deliberately dependency-free — a failing liveness restarts the pod.
            self._json(200, {"status": "ok"})
        elif route == "/health/ready":
            # Readiness: can we serve traffic? A failing readiness sheds traffic without a
            # restart. 503 => not ready. This is a PROBE, so the verdict is in the status
            # code; among dependencies only a declared HARD one being down fails it.
            try:
                ready = self.config.ready(self.config.components())
            except Exception:  # noqa: BLE001 - see the /health branch below
                ready = False
            self._json(200 if ready else 503, {"status": "ok" if ready else "down"})
        elif route == "/health":
            # The human/dashboard-facing aggregate, plus per-direct-dependency `components`.
            # ALWAYS 200 while the process can answer, even when the aggregate is "down":
            # the verdict rides in the BODY. An operator reading this during an outage needs
            # the diagnosis, and a 503 here is an unreadable page exactly when it matters.
            # HTTP status codes are the two probes' vocabulary, which is why only they
            # document a 503 (#1139).
            #
            # THE CATCH IS THE CONTRACT, not defensive habit. A dependency source may raise
            # -- the blessed one does so BY DESIGN on an unrecognised breaker state, and a
            # hand-written one may do anything. Unhandled, that exception unwinds out of
            # do_GET, http.server closes the connection with no response at all, and the
            # conformance checker reports "/health: unreachable" instead of a diagnosis. So
            # answer 200 with the worst verdict: reporting "ok" here would be the
            # under-reporting the contract forbids, and readiness above fails closed for the
            # same reason.
            # SERIALIZE INSIDE THE GUARD. Catching only the source's own exception is
            # half the job: `components` carries source-provided values, and this module
            # coerces only `status`/`kind` -- so a hand-written source returning, say, a
            # datetime for `since` raises in json.dumps instead, one frame later and
            # outside a narrower try, closing the connection just the same.
            try:
                body = json.dumps(self.config.health_payload(self.config.components()))
            except Exception:  # noqa: BLE001 - any source failure means we cannot vouch for health
                body = json.dumps({"status": "down"})
            self._send(200, "application/json", body.encode("utf-8"))
        elif route == "/metrics":
            self._send(200, CONTENT_TYPE_LATEST, generate_latest(REGISTRY))
        else:
            self._json(404, {"error": "not found", "path": route})

    def log_message(self, *_args: object) -> None:  # silence default stderr logging
        return


def serve(host: str = "0.0.0.0", port: int = 9090, config: OpsConfig | None = None) -> None:  # noqa: S104
    """Run the ops surface on the MANAGEMENT port (default 9090 — never the public
    app port). Binds all interfaces so the kubelet's probes and the
    ops-conformance job can reach it; the network boundary is enforced by the
    deployment (NetworkPolicy + a Service that omits this port)."""
    install_metrics()
    if config is not None:
        OpsHandler.config = config
    ThreadingHTTPServer((host, port), OpsHandler).serve_forever()


if __name__ == "__main__":
    serve(port=int(os.environ.get("OPS_PORT", "9090")))
