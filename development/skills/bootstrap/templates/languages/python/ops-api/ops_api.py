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

Placement: drop this module into your package (e.g. ``src/<pkg>/ops_api.py``) and
run ``python -m <pkg>.ops_api`` as a lightweight ops sidecar, or mount
``OpsHandler`` on your existing server. Declare the API majors your service
serves via ``served_majors`` — the /info lifecycle table is what makes the epic
#684 deprecation machinery observable.

Requires: opentelemetry-sdk, opentelemetry-exporter-prometheus, prometheus-client
(see requirements.txt beside this file).
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Literal

from opentelemetry import metrics
from opentelemetry.exporter.prometheus import PrometheusMetricReader
from opentelemetry.sdk.metrics import MeterProvider
from prometheus_client import CONTENT_TYPE_LATEST, REGISTRY, generate_latest

Lifecycle = Literal["active", "deprecated"]


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


@dataclass
class OpsConfig:
    """What the service reports on /info. Build fields default to env stamps."""

    version: str = field(default_factory=lambda: os.environ.get("BUILD_VERSION", "0.0.0"))
    git_sha: str = field(default_factory=lambda: os.environ.get("GIT_SHA", "unknown"))
    served_majors: tuple[ApiMajor, ...] = (ApiMajor(major=1, lifecycle="active"),)

    def info_payload(self) -> dict[str, object]:
        return {
            "build": {"version": self.version, "git_sha": self.git_sha},
            "api": [m.to_info() for m in self.served_majors],
        }


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
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/info":
            self._json(200, self.config.info_payload())
        elif path == "/health":
            self._json(200, {"status": "ok"})
        elif path == "/metrics":
            self._send(200, CONTENT_TYPE_LATEST, generate_latest(REGISTRY))
        else:
            self._json(404, {"error": "not found", "path": path})

    def log_message(self, *_args: object) -> None:  # silence default stderr logging
        return


def serve(host: str = "0.0.0.0", port: int = 8080, config: OpsConfig | None = None) -> None:  # noqa: S104
    """Run the ops surface. Binds all interfaces so the container health probe
    and the ops-conformance job can reach it."""
    install_metrics()
    if config is not None:
        OpsHandler.config = config
    ThreadingHTTPServer((host, port), OpsHandler).serve_forever()


if __name__ == "__main__":
    serve(port=int(os.environ.get("OPS_PORT", "8080")))
