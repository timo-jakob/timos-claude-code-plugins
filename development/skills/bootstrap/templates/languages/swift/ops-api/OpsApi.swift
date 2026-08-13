//  OpsApi.swift — the canonical Swift realization of the org-standard ops surface
//  (#937), the Swift sibling of the Python (#688), Java (#935), Go (#1192) and
//  Node (#936) payloads.
//
//  Serves the five endpoints of `contracts/ops/v1/openapi.yaml` — /info, /health,
//  /health/live, /health/ready, /metrics — from ONE swift-nio listener bound to a
//  separate MANAGEMENT port (default 9090, override with $OPS_PORT), never the
//  public app port. It passes `scripts/check-ops-conformance.zsh` unchanged.
//
//  Copy this file verbatim into your service as
//  `Sources/<ServiceTarget>/Ops/OpsApi.swift`. There are no placeholders to fill in.
//
//  DESIGN NOTES a reader will otherwise re-derive:
//
//    * No web framework. The HTTP layer is swift-nio directly, so this drops into
//      a Vapor service, a Hummingbird service, and a service with no framework
//      alike — the ops surface must never dictate the app's framework.
//    * ONE listener. /metrics is rendered into the same NIOAsyncChannel pipeline as
//      the JSON endpoints; there is no second bound port and no reverse-proxy hop.
//    * Fail fast on build metadata. $BUILD_VERSION and $GIT_SHA have NO fallback —
//      an unset one refuses startup by name rather than serving "unknown". A build
//      stamp that lies is worse than one that is absent, because /info is what the
//      #684 deprecation machinery and every incident triage read first.
//    * The dependency-health seam (ops-api v1.1) is an async, Sendable protocol over
//      a plain snapshot. This file imports NO circuit-breaker library and must never
//      grow one — the breaker-backed source is the resilience payload's job (#1146).

import Foundation
import Metrics
import NIOCore
import NIOHTTP1
import NIOPosix
import OTel
import Prometheus
import ServiceLifecycle

// MARK: - The /info lifecycle table

/// The lifecycle of one served API major, per the ops-api/v1 fragment.
public enum APILifecycle: String, Sendable, Codable {
    case active
    case deprecated
}

/// One entry of `/info`'s `api[]` table: a major this service actually serves.
///
/// The two halves of the sunset invariant are enforced at startup by
/// ``OpsConfig/validated()``: a `deprecated` major MUST carry a sunset date
/// (RFC 8594), and an `active` one MUST NOT. Only the first half is also caught
/// downstream by `check-ops-conformance.zsh`; for the second, this validation is
/// the only enforcement anywhere.
public struct APIMajor: Sendable, Codable {
    public var major: Int
    public var lifecycle: APILifecycle
    /// An RFC 8594 sunset date (`YYYY-MM-DD`). Required iff `lifecycle == .deprecated`.
    public var sunset: String?

    public init(major: Int, lifecycle: APILifecycle, sunset: String? = nil) {
        self.major = major
        self.lifecycle = lifecycle
        self.sunset = sunset
    }
}

// MARK: - Dependency health (ops-api v1.1)

/// The health of ONE dependency. Note the vocabulary: a component is
/// `up`/`degraded`/`down`, while the `/health` aggregate is `ok`/`degraded`/`down`.
/// The aggregate is spelled `ok` — never `up` — because that is what ops-api v1.0
/// shipped; v1.1 only added `degraded` beside it.
public enum ComponentStatus: String, Sendable, Codable {
    case up
    case degraded
    case down
}

/// Whether losing this dependency should shed traffic.
///
/// `hard` down ⇒ the aggregate is `down` AND `/health/ready` answers 503.
/// `soft` down ⇒ the aggregate is at least `degraded`, and readiness stays 200.
public enum DependencyKind: String, Sendable, Codable {
    case hard
    case soft
}

/// Circuit-breaker state, when a breaker backs this dependency.
///
/// The wire spelling of the half-open state is `half_open`, not `halfOpen`.
public enum BreakerState: String, Sendable, Codable {
    case closed
    case open
    case halfOpen = "half_open"
}

/// One entry of `/health`'s optional `components` map.
public struct Dependency: Sendable, Codable {
    public var status: ComponentStatus
    public var kind: DependencyKind
    public var breaker: BreakerState?
    /// An RFC 3339 timestamp: when this dependency entered its current state.
    public var since: String?

    public init(
        status: ComponentStatus,
        kind: DependencyKind,
        breaker: BreakerState? = nil,
        since: String? = nil
    ) {
        self.status = status
        self.kind = kind
        self.breaker = breaker
        self.since = since
    }
}

/// The ops-api v1.1 seam: where dependency health comes from.
///
/// Leaving ``OpsConfig/dependencies`` unset is legal and still conforms — `/health`
/// is then a byte-identical ops-api **v1.0** body with no `components` key at all,
/// and readiness is decided by ``OpsConfig/readiness`` alone.
///
/// The blessed implementation is the Swift resilience payload (#1146), which derives
/// these entries passively from circuit-breaker state. Implement it by hand in the
/// meantime if you like, but **return a freshly built dictionary every call**: handing
/// back a live, mutating registry map is a data race, and this protocol is `Sendable`
/// precisely so the compiler holds you to a snapshot.
public protocol DependencyHealthSource: Sendable {
    func components() async -> [String: Dependency]
}

/// The `/health` aggregate.
public enum AggregateStatus: String, Sendable, Codable {
    case ok
    case degraded
    case down

    /// Severity ordering, so "worst wins" is a total order rather than a chain of ifs.
    var severity: Int {
        switch self {
        case .ok: return 0
        case .degraded: return 1
        case .down: return 2
        }
    }

    static func worst(_ lhs: AggregateStatus, _ rhs: AggregateStatus) -> AggregateStatus {
        lhs.severity >= rhs.severity ? lhs : rhs
    }
}

// MARK: - Configuration

/// Why the ops surface refused to start. Every case names the thing to fix; none of
/// them is recoverable at runtime, which is the point — these are startup bugs, and
/// a service that serves a wrong `/info` is worse than one that refuses to boot.
public enum OpsConfigError: Error, CustomStringConvertible, Equatable {
    case missingEnvironment(String)
    case emptyServedMajors
    case invalidMajor(Int)
    case duplicateMajor(Int)
    case deprecatedMajorWithoutSunset(Int)
    case activeMajorWithSunset(Int)

    public var description: String {
        switch self {
        case .missingEnvironment(let name):
            return """
                ops-api: $\(name) is not set and has no fallback — /info must report a real \
                build, so the service refuses to start rather than serve a placeholder. \
                Supply it from the image build or the deployment environment.
                """
        case .emptyServedMajors:
            return """
                ops-api: servedMajors is empty — /info must advertise the majors this \
                service actually serves. Declare them explicitly; there is deliberately \
                no default, because a defaulted table advertises a major nobody agreed to.
                """
        case .invalidMajor(let major):
            return "ops-api: api major \(major) is invalid (must be an integer >= 1)"
        case .duplicateMajor(let major):
            return "ops-api: api major \(major) is declared more than once"
        case .deprecatedMajorWithoutSunset(let major):
            return """
                ops-api: api major \(major) is deprecated but declares no sunset date — \
                RFC 8594 requires one, and the #684 deprecation machinery reads it.
                """
        case .activeMajorWithSunset(let major):
            return """
                ops-api: api major \(major) is active but declares a sunset date — an \
                active major must not carry one, or clients will migrate off a major \
                that is not going anywhere.
                """
        }
    }
}

/// Everything the ops surface needs from the service that hosts it.
public struct OpsConfig: Sendable {
    /// The majors this service serves. REQUIRED — there is no default (see
    /// ``OpsConfigError/emptyServedMajors``).
    public var servedMajors: [APIMajor]

    /// The NON-dependency half of readiness — still starting up, draining during a
    /// graceful shutdown, an internal resource exhausted. Checked FIRST, before any
    /// dependency. Dependency-driven readiness comes from ``dependencies``.
    public var readiness: @Sendable () async -> Bool

    /// The over-reporting hook. Components set a FLOOR on the aggregate, never an
    /// equality, so a service impaired for a reason no dependency models (a backed-up
    /// queue, a full disk) can report a MORE severe aggregate. Reporting a LESS severe
    /// one is a conformance failure, and this cannot cause that.
    public var internalStatus: @Sendable () async -> AggregateStatus

    /// The ops-api v1.1 seam. `nil` (the default) serves a v1.0 body.
    public var dependencies: (any DependencyHealthSource)?

    /// Defaults to `$BUILD_VERSION`; refuses startup when neither is set.
    public var version: String?

    /// Defaults to `$GIT_SHA`; refuses startup when neither is set.
    public var gitSHA: String?

    public init(
        servedMajors: [APIMajor],
        readiness: @escaping @Sendable () async -> Bool = { true },
        internalStatus: @escaping @Sendable () async -> AggregateStatus = { .ok },
        dependencies: (any DependencyHealthSource)? = nil,
        version: String? = nil,
        gitSHA: String? = nil
    ) {
        self.servedMajors = servedMajors
        self.readiness = readiness
        self.internalStatus = internalStatus
        self.dependencies = dependencies
        self.version = version
        self.gitSHA = gitSHA
    }

    /// Resolve the build metadata and enforce both halves of the lifecycle-sunset
    /// invariant. Call this at startup — ``OpsApi/serve(config:metrics:host:port:)``
    /// does it for you, and refuses to bind if it throws.
    public func validated(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ResolvedOpsConfig {
        guard let version = firstNonEmpty(version, environment["BUILD_VERSION"]) else {
            throw OpsConfigError.missingEnvironment("BUILD_VERSION")
        }
        guard let gitSHA = firstNonEmpty(gitSHA, environment["GIT_SHA"]) else {
            throw OpsConfigError.missingEnvironment("GIT_SHA")
        }
        guard !servedMajors.isEmpty else { throw OpsConfigError.emptyServedMajors }

        var seen = Set<Int>()
        for entry in servedMajors {
            guard entry.major >= 1 else { throw OpsConfigError.invalidMajor(entry.major) }
            guard seen.insert(entry.major).inserted else {
                throw OpsConfigError.duplicateMajor(entry.major)
            }
            let sunset = firstNonEmpty(entry.sunset)
            switch entry.lifecycle {
            case .deprecated:
                guard sunset != nil else {
                    throw OpsConfigError.deprecatedMajorWithoutSunset(entry.major)
                }
            case .active:
                guard sunset == nil else {
                    throw OpsConfigError.activeMajorWithSunset(entry.major)
                }
            }
        }

        return ResolvedOpsConfig(
            version: version,
            gitSHA: gitSHA,
            servedMajors: servedMajors,
            readiness: readiness,
            internalStatus: internalStatus,
            dependencies: dependencies
        )
    }

    private func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }
}

/// An ``OpsConfig`` whose build metadata is resolved and whose lifecycle table has
/// been validated. Only ``OpsConfig/validated()`` can make one, so the handlers below
/// never carry an optional they would have to invent a value for.
public struct ResolvedOpsConfig: Sendable {
    public let version: String
    public let gitSHA: String
    public let servedMajors: [APIMajor]
    public let readiness: @Sendable () async -> Bool
    public let internalStatus: @Sendable () async -> AggregateStatus
    public let dependencies: (any DependencyHealthSource)?
}

// MARK: - Metrics

/// The process's metrics wiring: a Prometheus registry for the mandatory `/metrics`
/// pull surface, plus (when configured) swift-otel's OTLP push backend.
public struct OpsMetrics: Sendable {
    /// Rendered into `/metrics` by ``OpsApi``.
    public let registry: PrometheusCollectorRegistry
    /// swift-otel's background exporter service. `nil` when no OTLP endpoint is
    /// configured — run it alongside your app if non-nil (``OpsApi/serve`` does).
    public let otlpService: (any Service)?

    public init(registry: PrometheusCollectorRegistry, otlpService: (any Service)?) {
        self.registry = registry
        self.otlpService = otlpService
    }
}

extension OpsMetrics {
    /// Bootstrap the process-global `MetricsSystem` ONCE, with both backends behind
    /// swift-metrics' `MultiplexMetricsHandler`.
    ///
    /// This is the whole reason the payload takes two packages rather than one.
    /// swift-metrics allows exactly one `MetricsSystem.bootstrap` per process (a
    /// second is a fatal error), and swift-otel ships NO Prometheus exporter — so
    /// `OTel.bootstrap()`, which bootstraps the metrics system itself, would spend
    /// the one allowed call and leave `/metrics` with nothing to render. Instead we
    /// take swift-otel's factory WITHOUT its bootstrap, via `makeMetricsBackend()`,
    /// and multiplex it with swift-prometheus'. Your service then records through the
    /// ordinary swift-metrics API (`Counter`, `Gauge`, `Timer`) and every instrument
    /// lands in BOTH pipelines.
    ///
    /// Call this exactly once, before serving. Calling it twice traps, as it should.
    ///
    /// The OTLP half is wired only when an endpoint is configured
    /// (`OTEL_EXPORTER_OTLP_ENDPOINT` or `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`).
    /// Unconfigured is the normal local/CI case, not an error: wiring it anyway would
    /// dial localhost every export interval and log a failure each time.
    public static func bootstrap(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> OpsMetrics {
        let registry = PrometheusCollectorRegistry()
        let prometheusFactory = PrometheusMetricsFactory(registry: registry)

        guard hasOTLPEndpoint(in: environment) else {
            MetricsSystem.bootstrap(prometheusFactory)
            return OpsMetrics(registry: registry, otlpService: nil)
        }

        let otel = try OTel.makeMetricsBackend()
        MetricsSystem.bootstrap(
            MultiplexMetricsHandler(factories: [prometheusFactory, otel.factory])
        )
        return OpsMetrics(registry: registry, otlpService: otel.service)
    }

    static func hasOTLPEndpoint(in environment: [String: String]) -> Bool {
        for key in ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "OTEL_EXPORTER_OTLP_ENDPOINT"] {
            if let value = environment[key],
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
        }
        return false
    }
}

// MARK: - Wire shapes

/// `/info`'s body. The `git_sha` wire key is snake_case; the checker reads it by name.
struct InfoBody: Encodable {
    struct Build: Encodable {
        let version: String
        let gitSHA: String

        enum CodingKeys: String, CodingKey {
            case version
            case gitSHA = "git_sha"
        }
    }

    let build: Build
    let api: [APIMajor]
}

/// `/health`'s body. `components` is absent — not null, not empty — when no
/// ``DependencyHealthSource`` is wired, which is what keeps the v1.0 body byte-identical.
struct HealthBody: Encodable {
    let status: AggregateStatus
    let components: [String: Dependency]?
}

/// The binary probe bodies (`/health/live`, `/health/ready`).
struct ProbeBody: Encodable {
    let status: AggregateStatus
}

/// One rendered HTTP response.
struct OpsResponse: Sendable {
    let status: HTTPResponseStatus
    let contentType: String
    let body: [UInt8]

    static func json(_ status: HTTPResponseStatus, _ bytes: [UInt8]) -> OpsResponse {
        OpsResponse(status: status, contentType: "application/json; charset=utf-8", body: bytes)
    }
}

// MARK: - The router

/// Answers the five ops paths. Pure with respect to the network: it takes a method
/// and a path and returns bytes, so every branch below is unit-testable without a socket.
public struct OpsRouter: Sendable {
    let config: ResolvedOpsConfig
    let registry: PrometheusCollectorRegistry

    public init(config: ResolvedOpsConfig, registry: PrometheusCollectorRegistry) {
        self.config = config
        self.registry = registry
    }

    func respond(method: HTTPMethod, uri: String) async -> OpsResponse {
        let path = Self.normalize(uri)
        guard method == .GET || method == .HEAD else {
            return errorResponse(.methodNotAllowed, "method \(method) is not allowed on \(path)")
        }
        switch path {
        case "/info": return await info()
        case "/health": return await health()
        case "/health/live": return live()
        case "/health/ready": return await ready()
        case "/metrics": return metrics()
        default:
            return errorResponse(.notFound, "no ops endpoint at \(path)")
        }
    }

    /// Strip the query string, then collapse a single trailing slash so `/health/`
    /// reaches the same handler as `/health`. Percent-encoded paths are deliberately
    /// NOT decoded: `/health%2Flive` is a different path, not a sneaky `/health/live`.
    static func normalize(_ uri: String) -> String {
        var path = uri
        if let queryStart = path.firstIndex(of: "?") {
            path = String(path[path.startIndex..<queryStart])
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? "/" : path
    }

    // ---- /info

    func info() async -> OpsResponse {
        let body = InfoBody(
            build: .init(version: config.version, gitSHA: config.gitSHA),
            api: config.servedMajors
        )
        return encode(body, status: .ok)
    }

    // ---- /health, /health/live, /health/ready

    /// `/health` ALWAYS answers 200 — the verdict is in the body. An operator reading
    /// this during an outage needs the diagnosis, and a 503 here is an unreadable page
    /// exactly when it matters most. The probes below are where a status code decides.
    func health() async -> OpsResponse {
        let components = await config.dependencies?.components()
        let aggregate = await aggregateStatus(components: components)
        return encode(HealthBody(status: aggregate, components: components), status: .ok)
    }

    /// Liveness is process-only and NEVER a function of a dependency. Making it one is
    /// the pod-restart-storm anti-pattern: a shared dependency blips, every replica
    /// fails liveness at once, and the orchestrator restarts a fleet that was healthy.
    func live() -> OpsResponse {
        encode(ProbeBody(status: .ok), status: .ok)
    }

    /// Readiness is a probe: the verdict is the STATUS CODE. 503 sheds traffic without
    /// a restart. A HARD dependency down fails it; a SOFT one never does.
    func ready() async -> OpsResponse {
        guard await config.readiness() else {
            return encode(ProbeBody(status: .down), status: .serviceUnavailable)
        }
        let components = await config.dependencies?.components()
        if let components, components.values.contains(where: { $0.kind == .hard && $0.status == .down }) {
            return encode(ProbeBody(status: .down), status: .serviceUnavailable)
        }
        return encode(ProbeBody(status: .ok), status: .ok)
    }

    /// The FLOOR the components put under the aggregate:
    ///   * any HARD dependency `down`            → `down`
    ///   * any dependency `down` or `degraded`   → at least `degraded`
    ///   * otherwise                             → `ok`
    ///
    /// Note the middle branch is deliberately kind-agnostic: a HARD dependency merely
    /// half-open (`degraded`) floors the aggregate at `degraded`, NOT `down` — only a
    /// hard dependency fully down forces `down`.
    ///
    /// It is a floor, not an equality, so ``ResolvedOpsConfig/internalStatus`` can only
    /// ever raise it. Under-reporting — a hard dependency down while the aggregate still
    /// claims to be serving — is the one thing that can never be legitimate, and the
    /// worst-wins combination below makes it unreachable.
    func aggregateStatus(components: [String: Dependency]?) async -> AggregateStatus {
        var floor = AggregateStatus.ok
        for dependency in components?.values ?? [:].values {
            if dependency.kind == .hard && dependency.status == .down {
                floor = .down
            } else if dependency.status == .down || dependency.status == .degraded {
                floor = .worst(floor, .degraded)
            }
        }
        return .worst(floor, await config.internalStatus())
    }

    // ---- /metrics

    /// Rendered from the same registry the multiplexed swift-metrics backend writes
    /// into, on THIS listener — one bound port, no second server, no proxy hop.
    func metrics() -> OpsResponse {
        var buffer = [UInt8]()
        registry.emit(into: &buffer)
        return OpsResponse(
            status: .ok,
            contentType: "text/plain; version=0.0.4; charset=utf-8",
            body: buffer
        )
    }

    // ---- encoding

    /// Encoding a fixed, non-generic shape cannot realistically fail, but `encode`
    /// throws, so the fallback names the endpoint instead of dropping the connection —
    /// an ops surface that dies silently is worse than one that reports its own bug.
    func encode<T: Encodable>(_ value: T, status: HTTPResponseStatus) -> OpsResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            return .json(status, Array(try encoder.encode(value)))
        } catch {
            return errorResponse(.internalServerError, "ops-api could not encode its own response")
        }
    }

    func errorResponse(_ status: HTTPResponseStatus, _ message: String) -> OpsResponse {
        let escaped = message.replacingOccurrences(of: "\"", with: "'")
        return .json(status, Array(#"{"error":"\#(escaped)"}"#.utf8))
    }
}

// MARK: - The server

public enum OpsApi {
    /// The management port the surface binds by default. Overridden by `$OPS_PORT`.
    public static let defaultPort = 9090

    /// At most this many ops connections are served concurrently. Probes and scrapes
    /// are a handful of short requests; the bound exists so a stuck peer cannot grow
    /// the task group without limit.
    static let maxConcurrentConnections = 32

    public static func resolvedPort(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment["OPS_PORT"], let port = Int(raw), (1...65535).contains(port)
        else {
            return defaultPort
        }
        return port
    }

    /// Validate the config, bind the management port, and serve until the task is
    /// cancelled. Runs swift-otel's exporter service alongside when one is configured.
    ///
    /// Throws before binding when the config is invalid — that is the fail-fast
    /// contract: a service whose `/info` would lie never reaches the listener.
    public static func serve(
        config: OpsConfig,
        metrics: OpsMetrics,
        host: String = "0.0.0.0",
        port: Int? = nil
    ) async throws {
        let resolved = try config.validated()
        let router = OpsRouter(config: resolved, registry: metrics.registry)
        let boundPort = port ?? resolvedPort()

        try await withThrowingTaskGroup(of: Void.self) { group in
            if let otlpService = metrics.otlpService {
                group.addTask { try await otlpService.run() }
            }
            group.addTask { try await runListener(router: router, host: host, port: boundPort) }
            try await group.next()
            group.cancelAll()
        }
    }

    static func runListener(router: OpsRouter, host: String, port: Int) async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                        wrappingChannelSynchronously: channel
                    )
                }
            }

        try await server.executeThenClose { inbound in
            try await withThrowingTaskGroup(of: Void.self) { connections in
                var running = 0
                for try await connection in inbound {
                    if running >= maxConcurrentConnections {
                        _ = try? await connections.next()
                        running -= 1
                    }
                    connections.addTask { await serve(connection: connection, router: router) }
                    running += 1
                }
            }
        }
    }

    /// One connection. Every failure here is a dead peer, not a service fault, so it is
    /// swallowed: letting it escape would tear down the whole listener and take the
    /// probes with it.
    static func serve(
        connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
        router: OpsRouter
    ) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                for try await part in inbound {
                    switch part {
                    case .head(let requestHead):
                        head = requestHead
                    case .body:
                        break  // ops endpoints take no request body; drain and ignore.
                    case .end:
                        guard let requestHead = head else { break }
                        head = nil
                        let response = await router.respond(
                            method: requestHead.method,
                            uri: requestHead.uri
                        )
                        try await write(
                            response,
                            to: outbound,
                            version: requestHead.version,
                            includeBody: requestHead.method != .HEAD
                        )
                    }
                }
            }
        } catch {
            // The peer went away mid-exchange. Nothing to report it to.
        }
    }

    static func write(
        _ response: OpsResponse,
        to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        version: HTTPVersion,
        includeBody: Bool
    ) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: response.contentType)
        headers.add(name: "content-length", value: String(response.body.count))
        // The ops surface is internal and must never be cached by an intermediary:
        // a cached /health/ready is a probe answering for a service it never asked.
        headers.add(name: "cache-control", value: "no-store")
        let head = HTTPResponseHead(version: version, status: response.status, headers: headers)

        var parts: [HTTPServerResponsePart] = [.head(head)]
        if includeBody && !response.body.isEmpty {
            var buffer = ByteBufferAllocator().buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            parts.append(.body(.byteBuffer(buffer)))
        }
        parts.append(.end(nil))
        try await outbound.write(contentsOf: parts)
    }
}
