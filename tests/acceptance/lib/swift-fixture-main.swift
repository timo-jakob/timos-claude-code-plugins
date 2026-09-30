// The fixture SERVICE the Swift resilience acceptance cases (#1146) run against.
//
// It is the adopter's half of the contract and nothing more: it compiles the shipped
// ops-api and resilience payloads into ONE target (Ops/ and Resilience/ beside this
// file, exactly the bootstrapped layout) and wires them the way the resilience
// README tells a service to. Every verdict the cases assert — the components map,
// the aggregate floor, the readiness hinge, the fast-fail — therefore comes from the
// templates, not from here.
//
// What IS here is the world around the service: a fake `pricing-api` upstream that
// counts the requests it receives (so a case can prove a call never left the
// process), a simulated `orders-db`, and an app port that serves one endpoint
// through the worked-example client.
//
//   $SCENARIO        all-up | soft-down | hard-down — which breaker to trip at startup
//   $OPS_PORT        the management port (read by OpsApi itself)
//   $APP_PORT        the app port: GET /prices/<sku>, GET /upstream-hits, GET /orders-db-calls
//   $PRICING_PORT    the fake upstream's port
//   $BREAKER_OPEN_MS the breakers' open duration, so a case can watch half-open arrive
//
// The data is the story's own use_case: version 1.4.2, commit 9e11997, a deprecated
// major 1 sunsetting 2027-01-31 beside an active major 2, and the direct dependencies
// `orders-db` (hard) and `pricing-api` (soft).

import Foundation
import NIOCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import NIOHTTP1
import NIOPosix

let env = ProcessInfo.processInfo.environment
let scenario = env["SCENARIO"] ?? "all-up"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("swift ops fixture: \(message)\n".utf8))
    exit(1)
}

func port(_ name: String) -> Int {
    guard let raw = env[name], let value = Int(raw) else { fail("$\(name) is required") }
    return value
}

// MARK: - A minimal HTTP listener for the app port and the fake upstream

/// Whole milliseconds in a duration, for the x-elapsed-ms header the fast-fail case reads.
func millis(_ d: Duration) -> Int64 {
    d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
}

typealias Handler = @Sendable (String) async -> (HTTPResponseStatus, [(String, String)], String)

func serveHTTP(port: Int, handler: @escaping Handler) async throws {
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .bind(host: "0.0.0.0", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                    wrappingChannelSynchronously: channel)
            }
        }
    try await server.executeThenClose { inbound in
        // Not the discarding group: that needs macOS 14, above the payload's floor.
        // A fixture's connection count is small, so the retained results are harmless.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for try await connection in inbound {
                group.addTask {
                    try? await connection.executeThenClose { requests, responses in
                        var uri = "/"
                        for try await part in requests {
                            switch part {
                            case .head(let head): uri = head.uri
                            case .body: break
                            case .end:
                                let (status, headers, body) = await handler(uri)
                                var h = HTTPHeaders(headers)
                                h.add(name: "content-type", value: "application/json")
                                h.add(name: "content-length", value: String(body.utf8.count))
                                try await responses.write(
                                    .head(HTTPResponseHead(version: .http1_1, status: status, headers: h)))
                                try await responses.write(.body(.byteBuffer(ByteBuffer(string: body))))
                                try await responses.write(.end(nil))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - The world around the service

/// Counts what reached a dependency. An actor, so the count is exact under load.
actor Tally {
    private(set) var value = 0
    func bump() { value += 1 }
}

let upstreamHits = Tally()
let ordersDBCalls = Tally()

/// The fake pricing-api. In every scenario but all-up it answers 503 — the dependency
/// failing — so the worked-example client charges its breaker for real.
let upstreamFailing = scenario != "all-up"
let upstreamHandler: Handler = { uri in
    await upstreamHits.bump()
    if upstreamFailing { return (.serviceUnavailable, [], #"{"error":"pricing backend down"}"#) }
    let sku = uri.split(separator: "/").last.map(String.init) ?? "unknown"
    return (.ok, [], #"{"sku":"\#(sku)","cents":1299,"currency":"NZD"}"#)
}

struct OrdersDBDown: Error {}

/// A simulated orders-db client, shaped like the worked example: it CLAIMS its
/// dependency at construction and routes every call through the catalog.
struct OrdersDBClient: Sendable {
    let catalog: DependencyCatalog
    let failing: Bool

    init(catalog: DependencyCatalog, failing: Bool) async throws {
        try await catalog.requireDeclared("orders-db")
        self.catalog = catalog
        self.failing = failing
    }

    func ping() async throws -> Bool {
        try await catalog.call(
            "orders-db",
            operation: {
                await ordersDBCalls.bump()
                if failing { throw OrdersDBDown() }
                return true
            },
            fallback: { _ in false })
    }
}

// MARK: - Startup, exactly as the resilience README wires it

let openMs = Int(env["BREAKER_OPEN_MS"] ?? "") ?? 10_000
let catalog: DependencyCatalog
do {
    catalog = try DependencyCatalog.load(
        breakerConfiguration: BreakerConfiguration(openDuration: .milliseconds(openMs)))
} catch {
    fail("\(error)")
}

// Each client claims its dependency — only the ones the declaration in force names,
// so the empty-declaration case builds none.
var pricing: PricingAPIClient?
var ordersDB: OrdersDBClient?
do {
    if catalog.dependencies["pricing-api"] != nil {
        pricing = try await PricingAPIClient(
            catalog: catalog,
            environment: ["PRICING_API_BASE_URL": "http://127.0.0.1:\(port("PRICING_PORT"))"])
    }
    if catalog.dependencies["orders-db"] != nil {
        ordersDB = try await OrdersDBClient(catalog: catalog, failing: scenario == "hard-down")
    }
    // AFTER every client is built: refuses a declared dependency nobody guards.
    try await catalog.requireAllDeclaredGuarded()
} catch {
    fail("\(error)")
}

let pricingClient = pricing
let ordersClient = ordersDB

try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await serveHTTP(port: port("PRICING_PORT"), handler: upstreamHandler) }

    // Trip the scenario's breaker with REAL failing calls, before serving.
    switch scenario {
    case "soft-down":
        guard let client = pricingClient, let breaker = catalog.breaker(for: "pricing-api") else {
            fail("soft-down needs pricing-api declared")
        }
        // Wait until the fake upstream ANSWERS, rather than for a fixed time: tripping
        // against a listener that is not bound yet fails on connection-refused, which
        // trips the breaker without the upstream ever counting a hit.
        let probe = URL(string: "http://127.0.0.1:\(port("PRICING_PORT"))/ready")!
        var bound = false
        for _ in 0..<100 where !bound {
            bound = (try? await URLSession.shared.data(from: probe)) != nil
            if !bound { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard bound else { fail("the fake pricing-api upstream never answered") }
        var tries = 0
        while await breaker.state != .open, tries < 20 {
            _ = try? await client.price(sku: "sku-1234")
            tries += 1
        }
        guard await breaker.state == .open else { fail("soft-down: pricing-api never tripped") }
    case "hard-down":
        guard let client = ordersClient, let breaker = catalog.breaker(for: "orders-db") else {
            fail("hard-down needs orders-db declared")
        }
        var tries = 0
        while await breaker.state != .open, tries < 20 {
            _ = try await client.ping()
            tries += 1
        }
        guard await breaker.state == .open else { fail("hard-down: orders-db never tripped") }
    case "all-up":
        break
    default:
        fail("unknown SCENARIO \"\(scenario)\"")
    }

    group.addTask {
        try await serveHTTP(port: port("APP_PORT")) { uri in
            switch uri {
            case "/upstream-hits":
                return (.ok, [], #"{"hits":\#(await upstreamHits.value)}"#)
            case "/orders-db-calls":
                return (.ok, [], #"{"calls":\#(await ordersDBCalls.value)}"#)
            case let path where path.hasPrefix("/prices/"):
                guard let client = pricingClient else { return (.notFound, [], #"{"error":"no pricing-api"}"#) }
                let sku = String(path.dropFirst("/prices/".count))
                let clock = ContinuousClock()
                let started = clock.now
                do {
                    let price = try await client.price(sku: sku)
                    let ms = millis(clock.now - started)
                    return (.ok, [("x-elapsed-ms", String(ms))], #"{"cents":\#(price.cents)}"#)
                } catch {
                    let ms = millis(clock.now - started)
                    let message = "\(error)".replacingOccurrences(of: "\"", with: "'")
                    return (.serviceUnavailable, [("x-elapsed-ms", String(ms))], #"{"error":"\#(message)"}"#)
                }
            default:
                return (.notFound, [], #"{"error":"no such path"}"#)
            }
        }
    }

    let metrics = try OpsMetrics.bootstrap()
    group.addTask {
        try await OpsApi.serve(
            config: OpsConfig(
                servedMajors: [
                    APIMajor(major: 1, lifecycle: .deprecated, sunset: "2027-01-31"),
                    APIMajor(major: 2, lifecycle: .active),
                ],
                dependencies: DependencyHealth.seam(for: catalog)
            ),
            metrics: metrics,
            host: "0.0.0.0"
        )
    }
    print("swift ops fixture listening scenario=\(scenario)")
    try await group.next()
    group.cancelAll()
}
