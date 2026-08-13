/**
 * The canonical ops-api implementation for Node services (issue #936, epic #682
 * -- the ops-surface programme the Python #688, Java #935 and Go #1192 payloads
 * belong to, not the JS-plugin foundation epic #729 that filed it).
 *
 * The blessed Node realization of the org-standard ops surface defined by
 * contracts/ops/v2/openapi.yaml -- /info, /health, /health/live, /health/ready,
 * /metrics -- so a Node service conforms to the same fragment Spring services get
 * via Actuator. It passes scripts/check-ops-conformance.zsh unchanged.
 *
 * NO WEB FRAMEWORK. The HTTP layer is `node:http` and nothing else: this module
 * must be droppable into an Express service, a Fastify service and a service with
 * no framework at all, so it imports none of them. Its only runtime dependencies
 * are OpenTelemetry packages.
 *
 * Instrumentation is OpenTelemetry ONLY (ARCHITECTURE.md policy): metrics come
 * from the OTel SDK MeterProvider. OTLP push to a collector is the PRIMARY
 * pipeline -- wired by installMetrics whenever the standard
 * OTEL_EXPORTER_OTLP_ENDPOINT env var is set (honouring OTEL_EXPORTER_OTLP_PROTOCOL
 * = grpc | http/protobuf). Both variables have a signal-specific twin,
 * OTEL_EXPORTER_OTLP_METRICS_ENDPOINT / _METRICS_PROTOCOL, which takes precedence.
 * /metrics is the mandatory PULL-COMPAT surface, served by the OTel SDK's
 * Prometheus exporter -- a config wiring, not a second metrics system.
 *
 * ONE LISTENER. The Prometheus exporter is constructed with
 * `preventServerStart: true` and its own `getMetricsRequestHandler` is mounted on
 * the management server, so all five endpoints share a single `node:http` server.
 * This is the Go payload's single-mux shape, deliberately NOT the Java one, whose
 * exporter runs its own embedded server and forced a /metrics reverse-proxy hop.
 * Constructing the exporter WITHOUT that flag binds a second port (9464 by
 * default) behind your back -- a silent second listener on a management surface.
 *
 * DEPENDENCY HEALTH (ops-api v1.1, #965 / epic #964): /health carries an optional
 * `components` map -- one entry per DIRECT dependency, read PASSIVELY from that
 * dependency's circuit-breaker state -- and a declared HARD dependency being down
 * also fails /health/ready. Wire it with OpsConfig.dependencies; the blessed source
 * is the Node resilience payload (#1145), which derives these entries PASSIVELY
 * from `opossum` breaker state. Leave OpsConfig.dependencies unset and this module
 * behaves exactly as ops-api v1.0: no `components` field, and readiness is your
 * OpsConfig.readiness alone. The binding is an INTERFACE over plain objects, so
 * this module needs no breaker library on its import path -- and must never grow
 * one. The import direction is one-way and load-bearing: the resilience payload
 * imports this module, never the reverse.
 *
 * NOTE that /health answers 200 even when the aggregate is "down" -- the verdict is
 * in the body. Only the two PROBES (/health/live, /health/ready) speak in status
 * codes. The Java and Python payloads shipped this wrong and had to be fixed (#1139);
 * the conformance checker has always rejected it, but a healthy service conforms
 * either way, so the divergence only surfaces during an outage.
 *
 * This is an INTERNAL management surface: bind it to a separate MANAGEMENT PORT
 * (default 9090, override $OPS_PORT), never the public app port, so /info's build
 * data is unreachable from outside without any per-endpoint auth. The network
 * boundary (a NetworkPolicy + a Service that exposes only the app port, and the
 * liveness/readiness probe wiring) is the deployment layer's job (the composition
 * repo).
 *
 * PLACEMENT: copy this file into your service as `src/ops/opsApi.ts`, fold the
 * dependencies from package.json.deps into your package.json, and `await
 * serve(config)` from your startup with your real OpsConfig. Declare the API
 * majors your service serves via OpsConfig.servedMajors -- the /info lifecycle
 * table is what makes the epic #684 deprecation machinery observable.
 *
 * $GIT_SHA IS REQUIRED AND HAS NO FALLBACK. Node has no equivalent of the VCS
 * revision the Go toolchain stamps into a binary, so there is nothing truthful to
 * fall back to -- and a confidently-wrong commit in the ops surface is worse than
 * a service that refuses to boot. An unset $GIT_SHA (with no OpsConfig.gitSha) is
 * a STARTUP error naming the variable; a placeholder is never served. Plumb it in
 * at build time (a Docker `ARG GIT_SHA` / `ENV GIT_SHA`, or the deployment's env).
 */

import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { metrics } from "@opentelemetry/api";
import { OTLPMetricExporter as OTLPGrpcMetricExporter } from "@opentelemetry/exporter-metrics-otlp-grpc";
import { OTLPMetricExporter as OTLPProtoMetricExporter } from "@opentelemetry/exporter-metrics-otlp-proto";
import { PrometheusExporter } from "@opentelemetry/exporter-prometheus";
import {
  MeterProvider,
  PeriodicExportingMetricReader,
  type MetricReader,
  type PushMetricExporter,
} from "@opentelemetry/sdk-metrics";

/**
 * DEFAULT_PORT is the management port the ops surface binds by default. It is
 * deliberately NOT the public app port: /info's build data must be unreachable
 * from outside without per-endpoint auth.
 */
export const DEFAULT_PORT = 9090;

/** Lifecycle values for a served API major (contracts/ops/v2/openapi.yaml). */
export const LIFECYCLE_ACTIVE = "active";
export const LIFECYCLE_DEPRECATED = "deprecated";

/**
 * Aggregate statuses served on /health.
 *
 * The healthy aggregate is spelled "ok", NEVER "up" -- that is the exact spelling
 * ops-api v1.0 shipped, and renaming it would break every v1.0 consumer. v1.1 only
 * ADDED "degraded" beside it. The components map uses a different vocabulary
 * (below); confusing the two is the single easiest way to under-report health.
 */
export const STATUS_OK = "ok";
export const STATUS_DEGRADED = "degraded";
export const STATUS_DOWN = "down";

/**
 * Per-dependency statuses served in the /health components map. Healthy is "up"
 * here -- see the note on STATUS_OK.
 */
export const COMPONENT_UP = "up";
export const COMPONENT_DEGRADED = "degraded";
export const COMPONENT_DOWN = "down";

/**
 * Circuit-breaker states a component may report. The mapping to a component
 * status is exact: closed = up, half_open = degraded, open = down.
 */
export const BREAKER_CLOSED = "closed";
export const BREAKER_OPEN = "open";
export const BREAKER_HALF_OPEN = "half_open";

/**
 * Dependency kinds -- the readiness hinge. A hard dependency down fails
 * /health/ready (Kubernetes sheds traffic); a soft one never does.
 */
export const KIND_HARD = "hard";
export const KIND_SOFT = "soft";

export type Lifecycle = typeof LIFECYCLE_ACTIVE | typeof LIFECYCLE_DEPRECATED;
export type AggregateStatus = typeof STATUS_OK | typeof STATUS_DEGRADED | typeof STATUS_DOWN;
export type ComponentStatus = typeof COMPONENT_UP | typeof COMPONENT_DEGRADED | typeof COMPONENT_DOWN;
export type BreakerState = typeof BREAKER_CLOSED | typeof BREAKER_OPEN | typeof BREAKER_HALF_OPEN;
export type DependencyKind = typeof KIND_HARD | typeof KIND_SOFT;

/**
 * RFC 9457 problem-type URNs (ops-api v2, #1330).
 *
 * Host-free on purpose: a shipped service must not carry a documentation URL
 * that rots when the docs site moves.
 */
export const PROBLEM_TYPE_NOT_READY = "urn:problem-type:ops:not-ready";
export const PROBLEM_TYPE_NOT_ALIVE = "urn:problem-type:ops:not-alive";

const PROBLEM_TITLE_NOT_READY = "Service Not Ready";

/**
 * The two non-dependency unready reasons the contract names. A service that is
 * unready for its own reasons cannot tell us which, so it gets the start-up
 * wording -- the overwhelmingly common case, and the one an operator acts on the
 * same way.
 */
export const DETAIL_STARTING_UP = "the service is starting up";
export const DETAIL_DRAINING = "the service is draining";

/**
 * readinessDetail builds the canonical `detail` sentence.
 *
 * The wording is FIXED, not free prose: check-ops-conformance.zsh and the
 * acceptance lane both assert it. Names are sorted LEXICOGRAPHICALLY so the
 * string is deterministic regardless of the order the breakers tripped in --
 * without the sort the same outage would produce different bodies on different
 * pods and no assertion could pin it.
 */
function readinessDetail(components: Record<string, Dependency> | undefined): string {
  const down = Object.entries(components ?? {})
    .filter(([, d]) => d.kind === KIND_HARD && d.status === COMPONENT_DOWN)
    .map(([name]) => name)
    .sort();
  if (down.length === 0) {
    return DETAIL_STARTING_UP;
  }
  const quoted = down.map((name) => `'${name}'`);
  return quoted.length === 1
    ? `hard dependency ${quoted[0]} is down`
    : `hard dependencies ${quoted.join(", ")} are down`;
}

/** statusRank orders the aggregate worst-last, so worseOf can compare two by rank. */
const STATUS_RANK: Record<AggregateStatus, number> = {
  [STATUS_OK]: 0,
  [STATUS_DEGRADED]: 1,
  [STATUS_DOWN]: 2,
};

/**
 * ApiMajor is one served API major and its lifecycle (mirrors the fragment's
 * ApiMajor schema).
 *
 * A deprecated major MUST carry a sunset date (RFC 8594) and an active one MUST
 * NOT -- validateConfig enforces both directions at STARTUP, when createOpsHandler
 * calls it. Only the first direction is also checked downstream by the conformance
 * job, so the second is validateConfig's alone.
 */
export interface ApiMajor {
  major: number;
  lifecycle: Lifecycle;
  sunset?: string;
}

/**
 * Dependency is one DIRECT dependency's health, as the ops-api v1.1 components
 * map reports it.
 *
 *   status   up | degraded | down -- read from the dependency's circuit breaker.
 *   kind     hard | soft -- the readiness hinge.
 *   breaker  closed | open | half_open -- the state the status was read from.
 *   since    RFC 3339 timestamp of the last state change, so a dashboard can tell
 *            a blip from a sustained outage.
 *
 * breaker and since are optional; absent values are omitted from the JSON rather
 * than serialized as "", which the checker would reject as a non-member of the
 * breaker enum.
 */
export interface Dependency {
  status: ComponentStatus;
  kind: DependencyKind;
  breaker?: BreakerState;
  since?: string;
}

/**
 * DependencyHealthSource supplies the per-direct-dependency health that /health
 * reports under `components`.
 *
 * Deliberately an interface over plain objects rather than a dependency on a
 * breaker library: this module stays importable by a service that has no outbound
 * dependencies at all, and the ops surface never grows a breaker on its import
 * path. The blessed implementation is the Node resilience payload (#1145), which
 * derives these entries PASSIVELY from circuit-breaker state -- an open breaker IS
 * a down dependency. Implementing it by hand is the escape hatch, not the default;
 * leaving OpsConfig.dependencies unset keeps a conforming v1.0.
 *
 * DIRECT dependencies only. A service reports the one hop it calls itself and
 * never transitively calls a downstream's /health (the health-check-storm
 * anti-pattern).
 */
export interface DependencyHealthSource {
  /**
   * components returns one entry per direct dependency, keyed by its stable name.
   * Returning undefined is legal and means "no dependencies to report".
   *
   * RETURN A FRESHLY BUILT OBJECT. Node is single-threaded, so unlike the Go
   * sibling there is no concurrent-map hazard here -- but /health serializes what
   * you return, so handing back your own live registry lets any later mutation of
   * it be observed as a health report you never intended, and lets this module's
   * normalization pass be mistaken for a copy of yours. Build the snapshot.
   */
  components(): Record<string, Dependency> | undefined;
}

/**
 * OpsConfig is what the service reports on /info, and how the two health verdicts
 * are decided.
 *
 * readiness is the NON-dependency half of the readiness answer -- still starting
 * up, draining during a graceful shutdown, an internal resource exhausted. The
 * default (unset) is always-ready. The DEPENDENCY half comes from dependencies: a
 * declared hard dependency being down also fails readiness, while a soft one never
 * does. Liveness is deliberately NOT configurable: it reflects only that the
 * process is serving, and must never check a dependency (that would turn a
 * transient outage into a pod-restart storm).
 *
 * internalStatus is the over-reporting hook the contract requires: the components
 * set a FLOOR on the /health aggregate, never an equality, so a service impaired
 * for a reason no dependency models (a backed-up work queue, a full disk) MUST
 * report a MORE severe aggregate than its dependencies imply. Reporting a LESS
 * severe one is a conformance failure.
 */
export interface OpsConfig {
  /**
   * version is /info's build.version. Unset falls back to $BUILD_VERSION, then the
   * service's own package.json version -- never empty, which the checker rejects.
   */
  version?: string;
  /**
   * gitSha is /info's build.git_sha. Unset falls back to $GIT_SHA and NOWHERE
   * ELSE: with neither set, startup fails naming the variable. See the module doc.
   */
  gitSha?: string;
  /** servedMajors is the /info lifecycle table. Empty defaults to a single active major 1. */
  servedMajors?: ApiMajor[];
  /** readiness is the non-dependency half of /health/ready. Unset = always ready. */
  readiness?: () => boolean;
  /**
   * dependencies supplies the v1.1 components map. Unset = ops-api v1.0
   * behaviour: no components field, readiness is readiness alone.
   */
  dependencies?: DependencyHealthSource;
  /** internalStatus is the over-reporting hook. Unset = STATUS_OK. */
  internalStatus?: () => AggregateStatus;
}

/** The `node:http` request handler shape every route in this module speaks. */
export type OpsRequestHandler = (req: IncomingMessage, res: ServerResponse) => void;

/** A config with every default applied, so the handlers never re-derive one. */
interface ResolvedConfig {
  version: string;
  gitSha: string;
  servedMajors: ApiMajor[];
  readiness: () => boolean;
  dependencies?: DependencyHealthSource;
  internalStatus: () => AggregateStatus;
}

/**
 * validateConfig throws unless the config can serve a conforming /info.
 *
 * Called by createOpsHandler, so a misdeclared major fails at STARTUP. For three
 * of the five rules below (major < 1, an invalid lifecycle, deprecated-without-
 * sunset) that is merely EARLIER than the conformance job. For the other two -- a
 * DUPLICATE major, and an ACTIVE major carrying a sunset -- it is the only
 * enforcement anywhere: the checker inspects neither.
 */
export function validateConfig(config: OpsConfig): void {
  const seen = new Set<number>();
  for (const m of config.servedMajors ?? []) {
    if (!Number.isInteger(m.major) || m.major < 1) {
      throw new Error(`ops: api major ${String(m.major)} is invalid (want an integer >= 1)`);
    }
    if (seen.has(m.major)) {
      throw new Error(`ops: api major ${String(m.major)} is declared twice`);
    }
    seen.add(m.major);
    if (m.lifecycle === LIFECYCLE_DEPRECATED) {
      if (m.sunset === undefined || m.sunset === "") {
        throw new Error(`ops: deprecated major ${String(m.major)} needs a sunset date (RFC 8594)`);
      }
    } else if (m.lifecycle === LIFECYCLE_ACTIVE) {
      // An active major must not carry a sunset date: a sunset is the promise
      // that a major is going away, and advertising one on a major that is not
      // deprecated tells consumers to migrate off a version nobody is retiring.
      if (m.sunset !== undefined && m.sunset !== "") {
        throw new Error(`ops: active major ${String(m.major)} must not carry a sunset date`);
      }
    } else {
      throw new Error(
        `ops: major ${String(m.major)} has an invalid lifecycle "${String(m.lifecycle)}" ` +
          `(want "${LIFECYCLE_ACTIVE}" or "${LIFECYCLE_DEPRECATED}")`,
      );
    }
  }
}

/**
 * resolveConfig applies the defaults and COPIES servedMajors.
 *
 * The copy is not ceremony: the caller keeps a reference to the array it passed,
 * and a later push/edit through that reference would otherwise change what /info
 * serves -- after validateConfig has already approved it.
 */
function resolveConfig(config: OpsConfig): ResolvedConfig {
  const servedMajors: ApiMajor[] =
    config.servedMajors !== undefined && config.servedMajors.length > 0
      ? config.servedMajors.map((m) => ({ ...m }))
      : [{ major: 1, lifecycle: LIFECYCLE_ACTIVE }];
  return {
    version: resolveVersion(config.version),
    gitSha: resolveGitSha(config.gitSha),
    servedMajors,
    readiness: config.readiness ?? (() => true),
    dependencies: config.dependencies,
    internalStatus: config.internalStatus ?? (() => STATUS_OK),
  };
}

/**
 * componentsSnapshot takes ONE snapshot of the dependency view per request.
 *
 * Both /health's aggregate and its components map are derived from the SAME
 * snapshot, so a breaker that flips mid-request can never produce a body whose
 * headline contradicts its own component list.
 */
function componentsSnapshot(cfg: ResolvedConfig): Record<string, Dependency> | undefined {
  if (cfg.dependencies === undefined) {
    return undefined;
  }
  const raw = cfg.dependencies.components();
  if (raw === undefined || raw === null) {
    return undefined;
  }
  const entries = Object.entries(raw);
  if (entries.length === 0) {
    return undefined;
  }
  const out: Record<string, Dependency> = {};
  for (const [name, d] of entries) {
    out[name] = onContract(d);
  }
  return out;
}

/**
 * isReady is the readiness answer behind /health/ready.
 *
 * Among dependencies, only a declared HARD one being DOWN makes the service
 * unready -- a soft dependency down keeps the pod ready and serving degraded
 * responses. Non-dependency reasons still apply and are checked first.
 */
function isReady(cfg: ResolvedConfig, components: Record<string, Dependency> | undefined): boolean {
  if (!cfg.readiness()) {
    return false;
  }
  for (const d of Object.values(components ?? {})) {
    if (d.kind === KIND_HARD && d.status === COMPONENT_DOWN) {
      return false;
    }
  }
  return true;
}

/**
 * aggregate is the status served by /health: the worse of this service's own
 * internal state and the FLOOR its dependencies impose -- "down" if any HARD
 * dependency is down, else "degraded" if ANY dependency is down or degraded, else
 * "ok".
 *
 * Note the hard/degraded case: a HARD dependency that is merely half-open reads
 * "degraded", not down, so it floors the aggregate at "degraded" rather than
 * "down". Only a hard dependency that is fully down forces "down".
 */
function aggregate(cfg: ResolvedConfig, components: Record<string, Dependency> | undefined): AggregateStatus {
  // An off-contract value (a typo, "up" borrowed from the components vocabulary,
  // "") is normalized to the MOST severe status, never the least. Failing toward
  // severity keeps the coercion honest: read the other way, a mistyped
  // internal-status hook would make /health answer "ok" during exactly the
  // impairment the hook was written to report -- the under-reporting the contract
  // forbids. "down" instead fails ops conformance loudly.
  const declared: unknown = cfg.internalStatus();
  let status: AggregateStatus = isAggregateStatus(declared) ? declared : STATUS_DOWN;
  for (const d of Object.values(components ?? {})) {
    // ORDER IS THE CONTRACT. This is a first-match chain: exchanging the two arms
    // makes a fully-down HARD dependency match the second one and floor the
    // aggregate at "degraded" instead of "down" -- the marquee contract inverted,
    // in the under-reporting direction.
    if (d.status === COMPONENT_DOWN && d.kind === KIND_HARD) {
      status = worseOf(status, STATUS_DOWN);
    } else if (d.status === COMPONENT_DOWN || d.status === COMPONENT_DEGRADED) {
      status = worseOf(status, STATUS_DEGRADED);
    }
  }
  return status;
}

/** worseOf is a worst-wins comparison over STATUS_RANK (ok < degraded < down). */
function worseOf(a: AggregateStatus, b: AggregateStatus): AggregateStatus {
  return STATUS_RANK[a] >= STATUS_RANK[b] ? a : b;
}

function isAggregateStatus(value: unknown): value is AggregateStatus {
  return value === STATUS_OK || value === STATUS_DEGRADED || value === STATUS_DOWN;
}

/**
 * onContract forces one component's status/kind onto the contract's vocabulary.
 *
 * DependencyHealthSource is an INTERFACE, so a service may hand-write one -- and
 * TypeScript's types are erased at runtime, so nothing stops a JS caller (or a
 * value parsed from JSON) from supplying "ok", "Down" or kind "Hard". Read
 * literally by isReady and aggregate, which compare against the contract
 * spellings, a hard dependency reported down in the wrong case would keep the pod
 * ready and the aggregate "ok". That is the under-reporting the contract forbids,
 * arriving silently.
 *
 * Unknown values are coerced to the MOST severe reading (down, hard), never the
 * least -- the same fail-toward-severity rule aggregate applies to internalStatus.
 * An off-contract breaker is DROPPED rather than coerced: it is descriptive, and a
 * present-but-invalid one fails conformance while an absent one is legal. A
 * non-string `since` is dropped for a second reason too: it is the only free-form
 * field here, so it is the only way a source could smuggle in a value
 * (a BigInt, a circular object) that JSON.stringify throws on mid-response.
 */
function onContract(raw: unknown): Dependency {
  const d: Partial<Record<keyof Dependency, unknown>> =
    typeof raw === "object" && raw !== null ? (raw as Partial<Record<keyof Dependency, unknown>>) : {};
  const status: ComponentStatus =
    d.status === COMPONENT_UP || d.status === COMPONENT_DEGRADED || d.status === COMPONENT_DOWN
      ? d.status
      : COMPONENT_DOWN;
  const kind: DependencyKind = d.kind === KIND_HARD || d.kind === KIND_SOFT ? d.kind : KIND_HARD;
  const out: Dependency = { status, kind };
  if (d.breaker === BREAKER_CLOSED || d.breaker === BREAKER_OPEN || d.breaker === BREAKER_HALF_OPEN) {
    out.breaker = d.breaker;
  }
  if (typeof d.since === "string" && d.since !== "") {
    out.since = d.since;
  }
  return out;
}

// ---- payloads --------------------------------------------------------------

interface InfoBody {
  build: { version: string; git_sha: string };
  api: ApiMajor[];
}

interface HealthBody {
  status: AggregateStatus;
  /**
   * Omitted entirely when there are no dependencies, keeping the response a valid
   * ops-api v1.0 body. `components: {}` would NOT be -- it announces a v1.1 body
   * that then reports nothing.
   */
  components?: Record<string, Dependency>;
}

// ---- handler ---------------------------------------------------------------

/**
 * createOpsHandler returns the five-endpoint ops surface as one `node:http`
 * request handler.
 *
 * metricsHandler serves /metrics and is what installMetrics returns; it is
 * REQUIRED, because /metrics is a mandatory part of the contract -- omitting it is
 * a startup error rather than a 404 the ops-conformance job discovers later.
 *
 * Most services call `serve`, which does both. Use createOpsHandler directly to
 * mount the surface on a management server you already run.
 */
export function createOpsHandler(config: OpsConfig, metricsHandler: OpsRequestHandler): OpsRequestHandler {
  validateConfig(config);
  if (typeof metricsHandler !== "function") {
    throw new Error("ops: metricsHandler is required (/metrics is part of the ops contract)");
  }
  const cfg = resolveConfig(config);

  return (req: IncomingMessage, res: ServerResponse): void => {
    // GET and HEAD only -- the two methods a probe, a scraper and the conformance
    // checker use. Anything else is a mistake worth naming: a management surface
    // that silently 404s a POST reads as "wrong path" rather than "wrong method".
    if (req.method !== "GET" && req.method !== "HEAD") {
      res.setHeader("Allow", "GET, HEAD");
      writeJson(req, res, 405, {
        error: "method not allowed",
        method: req.method ?? "",
      });
      return;
    }

    const path = normalizePath(pathOf(req.url));

    switch (path) {
      case "/info":
        writeJson(req, res, 200, {
          build: { version: cfg.version, git_sha: cfg.gitSha },
          api: cfg.servedMajors,
        } satisfies InfoBody);
        return;

      // Liveness: the process is serving this request, so it is alive.
      // Deliberately dependency-free -- a failing liveness restarts the pod, so
      // making it a function of a dependency turns a transient outage into a
      // restart storm.
      case "/health/live":
        writeJson(req, res, 200, { status: STATUS_OK });
        return;

      // Readiness: can we serve traffic? A failing readiness sheds traffic without
      // a restart. 503 => not ready. This is a PROBE, so the verdict rides in the
      // STATUS CODE; among dependencies only a declared HARD one being down fails
      // it.
      //
      // THE TRY/CATCH IS THE CONTRACT, not defensive habit: DependencyHealthSource
      // is an interface a service may implement by hand, and an exception from it
      // would otherwise escape into `node:http`, which destroys the socket with no
      // response -- the checker then reports "/health/ready: unreachable" instead
      // of a verdict. Readiness fails CLOSED: if we cannot read dependency health
      // we cannot vouch for being able to serve, and shedding traffic is the safe
      // direction.
      case "/health/ready": {
        let ready = false;
        // Snapshot ONCE and reuse it for both the verdict and the problem body.
        // Calling componentsSnapshot again to build the body would re-enter the
        // service's DependencyHealthSource, which can return a different map --
        // the 503 would then name a dependency the verdict was not taken on.
        let components: Record<string, Dependency> | undefined;
        try {
          components = componentsSnapshot(cfg);
          ready = isReady(cfg, components);
        } catch {
          ready = false;
          // Leave components undefined so the 503 falls back to the
          // non-dependency wording rather than naming a half-read map.
          components = undefined;
        }
        if (ready) {
          writeJson(req, res, 200, { status: STATUS_OK });
          return;
        }
        // ops-api v2: RFC 9457 problem details, not {"status":"down"}. The health
        // string is gone from the 503 -- 503 already says "down" -- and the
        // diagnosis rides in `components` instead.
        writeProblemJson(req, res, 503, {
          type: PROBLEM_TYPE_NOT_READY,
          title: PROBLEM_TITLE_NOT_READY,
          status: 503,
          detail: readinessDetail(components),
          ...(components === undefined ? {} : { components }),
        });
        return;
      }

      // The human/dashboard-facing aggregate, plus per-direct-dependency
      // components. ALWAYS 200 while the process can answer, even when the
      // aggregate is "down": the verdict rides in the BODY. An operator reading
      // this during an outage needs the diagnosis, and a 503 here is an unreadable
      // page exactly when it matters. HTTP status codes are the two probes'
      // vocabulary, which is why only they document a 503 (#1139).
      //
      // Same fail-closed try/catch as readiness, for the same reason: reporting
      // "ok" from the catch would be the under-reporting the contract forbids.
      case "/health": {
        let body: HealthBody = { status: STATUS_DOWN };
        try {
          const components = componentsSnapshot(cfg);
          body = { status: aggregate(cfg, components), ...(components !== undefined ? { components } : {}) };
        } catch {
          body = { status: STATUS_DOWN };
        }
        writeJson(req, res, 200, body);
        return;
      }

      case "/metrics":
        metricsHandler(req, res);
        return;

      // Anything else on the management port is a mistake worth naming, not a
      // blank 404 page.
      default:
        writeJson(req, res, 404, { error: "not found", path });
        return;
    }
  };
}

/**
 * pathOf extracts the RAW path from a request target, dropping the query string.
 *
 * Deliberately NOT decoded. An encoded slash is part of its segment, not a
 * separator, so "/health%2F" is the one-segment path "health/" and must 404 --
 * decoding first would route it to /health and make %2F mean one thing here and
 * another everywhere else. Comparing the raw string gives that for free.
 */
function pathOf(url: string | undefined): string {
  const target = url ?? "/";
  const q = target.indexOf("?");
  return q === -1 ? target : target.slice(0, q);
}

/**
 * normalizePath strips trailing slashes before dispatch, so "/health/" reaches the
 * same route as "/health".
 *
 * Without this a probe or a hand-rolled curl with a trailing slash gets a 404 from
 * an otherwise conforming service. "/" itself is preserved.
 */
function normalizePath(path: string): string {
  if (path.length > 1 && path.endsWith("/")) {
    const trimmed = path.replace(/\/+$/, "");
    return trimmed === "" ? "/" : trimmed;
  }
  return path;
}

/**
 * writeJson is the single writer for every ops response.
 *
 * ORDER is the contract: the status code and headers must be set BEFORE the body
 * is written, or Node emits the default 200 and the readiness 503 silently
 * disappears. A HEAD request gets the headers and no body -- `node:http` does not
 * suppress it for us the way Go's net/http does.
 */
function writeJson(req: IncomingMessage, res: ServerResponse, code: number, payload: unknown): void {
  let body: string;
  let status = code;
  try {
    body = JSON.stringify(payload);
  } catch {
    // Unreachable for every payload this module builds; a hand-written
    // DependencyHealthSource is the only way in, and onContract already drops the
    // non-string values that could get here. Answering with a hand-built body
    // rather than a naked 500 keeps even this branch a valid JSON status response.
    body = '{"status":"down"}';
    status = 500;
  }
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Content-Length", Buffer.byteLength(body));
  if (req.method === "HEAD") {
    res.end();
    return;
  }
  res.end(body);
}

/**
 * writeProblemJson writes an RFC 9457 document on application/problem+json.
 *
 * Separate from writeJson because the media type is part of the contract, not a
 * detail: org-problem-json-errors requires the 4xx/5xx body to be BARE
 * problem+json, so answering the readiness 503 on application/json would be a
 * conformance failure even with a correctly shaped body. Same header-before-body
 * ordering rule as writeJson, for the same reason.
 */
function writeProblemJson(
  req: IncomingMessage,
  res: ServerResponse,
  code: number,
  payload: unknown,
): void {
  let body: string;
  let status = code;
  try {
    body = JSON.stringify(payload);
  } catch {
    // Unreachable, but the fallback stays a VALID problem document rather than
    // borrowing writeJson's health-shaped one -- a 500 here would otherwise
    // answer a problem+json content type with a {"status":"down"} body.
    body = JSON.stringify({
      type: PROBLEM_TYPE_NOT_READY,
      title: PROBLEM_TITLE_NOT_READY,
      status: 500,
      detail: "the readiness problem document could not be serialized",
    });
    status = 500;
  }
  res.statusCode = status;
  res.setHeader("Content-Type", "application/problem+json");
  res.setHeader("Content-Length", Buffer.byteLength(body));
  if (req.method === "HEAD") {
    res.end();
    return;
  }
  res.end(body);
}

// ---- metrics ---------------------------------------------------------------

/** What installMetrics returns: the provider to shut down, and the /metrics route. */
export interface OpsMetrics {
  provider: MeterProvider;
  metricsHandler: OpsRequestHandler;
}

/**
 * installMetrics wires the OTel SDK MeterProvider and returns it together with the
 * handler that serves /metrics.
 *
 * OpenTelemetry is the SINGLE instrumentation source. Two readers hang off one
 * provider:
 *
 *   - the Prometheus exporter, constructed with `preventServerStart: true` so it
 *     binds NO port of its own, and mounted on the management server through its
 *     getMetricsRequestHandler -- the mandatory pull-compat surface, so conformance
 *     and smoke checks need no collector;
 *   - an OTLP periodic reader, the PRIMARY pipeline, wired only when
 *     OTEL_EXPORTER_OTLP_ENDPOINT (or OTEL_EXPORTER_OTLP_METRICS_ENDPOINT) is set.
 *     OTEL_EXPORTER_OTLP_PROTOCOL picks grpc (the default when unset) or
 *     http/protobuf, and OTEL_EXPORTER_OTLP_METRICS_PROTOCOL overrides it; any
 *     other value is a startup error, never a silent fallback. The exporters read
 *     the rest of the standard OTEL_* env vars themselves.
 *
 * The returned provider is the caller's to shut down -- `serve` does it. Setting
 * it as the GLOBAL meter provider is what makes it useful: without that call every
 * `metrics.getMeter(...)` instrument a service records goes to a no-op and
 * /metrics is empty -- silently useless yet still conforming.
 */
export function installMetrics(): OpsMetrics {
  const pullExporter = new PrometheusExporter({ preventServerStart: true });
  const readers: MetricReader[] = [pullExporter];

  const pushExporter = newOtlpExporter();
  if (pushExporter !== undefined) {
    readers.push(new PeriodicExportingMetricReader({ exporter: pushExporter }));
  }

  const provider = new MeterProvider({ readers });
  metrics.setGlobalMeterProvider(provider);

  return {
    provider,
    metricsHandler: (req, res) => {
      pullExporter.getMetricsRequestHandler(req, res);
    },
  };
}

/**
 * newOtlpExporter builds the OTLP push exporter, or returns undefined when no
 * collector endpoint is configured.
 *
 * Absence of an endpoint is the NORMAL local/CI case and must not be an error: the
 * exporters would otherwise dial localhost and log a connection failure every
 * export interval. /metrics still works without a collector, which is exactly why
 * the pull surface is mandatory rather than optional.
 *
 * OTEL_EXPORTER_OTLP_METRICS_ENDPOINT is checked too, because a service may push
 * only metrics to a different collector than its traces -- reading just the
 * general variable would silently ignore that configuration. The protocol reads
 * the same pair: OTEL_EXPORTER_OTLP_METRICS_PROTOCOL wins over
 * OTEL_EXPORTER_OTLP_PROTOCOL, per the OTel spec's signal-specific precedence.
 *
 * The accepted protocols are exactly grpc (the spec's default when unset) and
 * http/protobuf. An unrecognised value is a LOUD error rather than a silent
 * fallback -- including "http/json", which the JS SDK's metrics exporters do not
 * implement: routing it to the protobuf exporter would hand a JSON-expecting
 * collector protobuf and fail every export interval while the operator believes
 * the config was accepted.
 */
function newOtlpExporter(): PushMetricExporter | undefined {
  const endpoint = process.env.OTEL_EXPORTER_OTLP_METRICS_ENDPOINT ?? process.env.OTEL_EXPORTER_OTLP_ENDPOINT;
  if (endpoint === undefined || endpoint === "") {
    return undefined;
  }
  const protocol = process.env.OTEL_EXPORTER_OTLP_METRICS_PROTOCOL ?? process.env.OTEL_EXPORTER_OTLP_PROTOCOL ?? "";
  switch (protocol) {
    case "http/protobuf":
      return new OTLPProtoMetricExporter();
    case "":
    case "grpc":
      // grpc is the spec's default when the variable is unset.
      return new OTLPGrpcMetricExporter();
    default:
      throw new Error(`ops: unsupported OTLP protocol "${protocol}" (want grpc or http/protobuf)`);
  }
}

// ---- server ----------------------------------------------------------------

/** A running ops surface: the server, its meter provider, and one way to stop both. */
export interface OpsServer {
  server: Server;
  provider: MeterProvider;
  /** Drains in-flight requests, then flushes and shuts down the meter provider. */
  close(): Promise<void>;
}

/**
 * serve installs metrics and runs the ops surface on the MANAGEMENT port.
 *
 * It resolves once the server is LISTENING, so a port clash rejects here rather
 * than surfacing as an unhandled 'error' event later. It binds all interfaces so
 * the kubelet's probes and the ops-conformance job can reach it; the network
 * boundary is enforced by the deployment (a NetworkPolicy + a Service that omits
 * this port).
 */
export async function serve(config: OpsConfig, port: number = defaultPort()): Promise<OpsServer> {
  const { provider, metricsHandler } = installMetrics();
  let handler: OpsRequestHandler;
  try {
    handler = createOpsHandler(config, metricsHandler);
  } catch (err) {
    // The provider is already running two readers; leaking it would keep an OTLP
    // export timer alive in a process that is about to report a startup failure.
    await provider.shutdown();
    throw err;
  }

  const server = createServer(handler);
  // Explicit bounds: an unbounded management server is a Slowloris target, and the
  // probes it answers must never be starved by a stuck connection. requestTimeout
  // must exceed headersTimeout, or Node warns and raises it for you.
  server.headersTimeout = 5_000;
  server.requestTimeout = 10_000;
  server.keepAliveTimeout = 60_000;

  await new Promise<void>((resolve, reject) => {
    const onError = (err: Error): void => {
      server.removeListener("listening", onListening);
      reject(err);
    };
    const onListening = (): void => {
      server.removeListener("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(port);
  }).catch(async (err: unknown) => {
    await provider.shutdown();
    throw err;
  });

  return {
    server,
    provider,
    close: async (): Promise<void> => {
      await new Promise<void>((resolve, reject) => {
        server.close((err) => {
          if (err) {
            reject(err);
            return;
          }
          resolve();
        });
        // Explicitly drop the IDLE keep-alive connections a probe or a Prometheus
        // scraper leaves behind, rather than relying on close() to do it.
        //
        // On current Node this is belt-and-braces: server.close() was measured
        // (Node 26) to release idle keep-alive sockets by itself, so removing this
        // line changes nothing observable. It is kept because the guarantee it
        // makes explicit is the one that matters at shutdown — on a runtime where
        // close() waits out every existing connection, an idle socket lingers for
        // the full keepAliveTimeout (60s, above) and a rolling update sits in
        // "terminating" for a minute after its last real request. Stating the
        // intent in code costs nothing and does not depend on which Node the
        // adopter runs. In-flight requests are unaffected either way: only
        // connections with no active request are closed.
        server.closeIdleConnections();
      });
      // Best-effort flush on the way out, AFTER the drain: shutting the provider
      // down first would leave the still-serving /metrics route reading a dead
      // reader for the length of the drain.
      await provider.shutdown();
    },
  };
}

/**
 * defaultPort is the management port to serve on: $OPS_PORT, else DEFAULT_PORT.
 *
 * A malformed $OPS_PORT is a startup error rather than a silent fall back to 9090:
 * an operator who set it meant to move the surface, and quietly ignoring the value
 * puts the ops endpoints on a port nothing is scraping.
 */
export function defaultPort(): number {
  const raw = process.env.OPS_PORT;
  if (raw === undefined || raw === "") {
    return DEFAULT_PORT;
  }
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`ops: OPS_PORT "${raw}" is not a valid port (want an integer 0-65535)`);
  }
  return port;
}

// ---- build metadata --------------------------------------------------------

/**
 * resolveVersion resolves /info's build.version: the explicit config value, else
 * $BUILD_VERSION, else the service's own package.json version, else "0.0.0". Never
 * empty -- the conformance checker requires a non-empty string.
 *
 * The package.json fallback is truthful in a way a placeholder would not be: it IS
 * the service's declared version. That is why version has a fallback chain and
 * git_sha (below) has none.
 */
function resolveVersion(configured: string | undefined): string {
  if (configured !== undefined && configured !== "") {
    return configured;
  }
  const fromEnv = process.env.BUILD_VERSION;
  if (fromEnv !== undefined && fromEnv !== "") {
    return fromEnv;
  }
  return readPackageVersion() ?? "0.0.0";
}

/**
 * resolveGitSha resolves /info's build.git_sha: the explicit config value, else
 * $GIT_SHA, else THROW.
 *
 * There is deliberately no third option. Node has no equivalent of the VCS
 * revision the Go toolchain stamps into a binary, so every candidate placeholder
 * ("unknown", the version, an empty string) is either a lie or a conformance
 * failure -- and a confidently-wrong commit in the ops surface sends an operator
 * to the wrong diff during an incident. Failing at startup names the missing
 * variable while someone is still watching the deploy.
 */
function resolveGitSha(configured: string | undefined): string {
  if (configured !== undefined && configured !== "") {
    return configured;
  }
  const fromEnv = process.env.GIT_SHA;
  if (fromEnv !== undefined && fromEnv !== "") {
    return fromEnv;
  }
  throw new Error(
    "ops: GIT_SHA is not set and OpsConfig.gitSha was not supplied -- /info's " +
      "build.git_sha has no truthful fallback in Node, so the ops surface refuses " +
      "to serve a placeholder. Set the GIT_SHA environment variable at build or " +
      "deploy time.",
  );
}

/**
 * readPackageVersion walks up from this module's own directory for the nearest
 * package.json carrying a non-empty version string.
 *
 * Walking rather than reading a fixed relative path is what makes the fallback
 * survive placement: this file may sit at src/ops/ in the source tree and dist/ops/
 * once compiled, and in a monorepo the nearest package.json is the SERVICE's, which
 * is the one whose version /info should report.
 */
function readPackageVersion(): string | undefined {
  let dir = dirname(fileURLToPath(import.meta.url));
  // Bounded so a placement outside any package cannot walk the whole filesystem.
  for (let depth = 0; depth < 16; depth += 1) {
    const version = readVersionField(join(dir, "package.json"));
    if (version !== undefined) {
      return version;
    }
    const parent = dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }
  return undefined;
}

function readVersionField(file: string): string | undefined {
  try {
    const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
    if (typeof parsed === "object" && parsed !== null) {
      const version: unknown = (parsed as { version?: unknown }).version;
      if (typeof version === "string" && version !== "") {
        return version;
      }
    }
    return undefined;
  } catch {
    // Missing, unreadable or malformed: keep walking rather than failing. A
    // service with no readable package.json still gets "0.0.0", which conforms.
    return undefined;
  }
}
