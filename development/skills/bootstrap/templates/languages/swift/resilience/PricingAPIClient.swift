//  PricingAPIClient.swift — a WORKED EXAMPLE of a dependency client under all six
//  mandates (#1146).
//
//  THIS IS NOT SERVICE CODE. It calls a `pricing-api` that does not exist, reading its
//  base URL from $PRICING_API_BASE_URL. Adapt it to a real dependency or delete it — it
//  is shipped to show the SHAPE, because the shape is what the resilience review
//  dimension checks for on a diff.
//
//  What to copy from it, in order of how quietly each one fails if you skip it:
//
//   1. caller errors are wrapped in `NotADependencyFailure`, so a 404 the request
//      itself provoked never opens a breaker on a healthy dependency;
//   2. the fallback NEVER calls the dependency, and never fabricates a money-shaped
//      value it does not have;
//   3. the initializer CLAIMS its dependency (`requireDeclared`), so an undeclared one
//      is a startup failure rather than a surprise on the first request;
//   4. every call goes through `catalog.call`, which supplies the per-call timeout, the
//      breaker, the bounded jittered retry and the fast-fail.

import Foundation

#if canImport(FoundationNetworking)
    // URLSession lives here on Linux; on Apple platforms it is part of Foundation.
    import FoundationNetworking
#endif

/// What the dependency returns — a placeholder for your real type.
public struct Price: Sendable, Codable, Equatable {
    public var sku: String
    public var cents: Int64
    public var currency: String
}

/// Why a price could not be served. The fallback's honest absence.
public struct PriceUnavailable: Error, Sendable, CustomStringConvertible {
    public let sku: String
    public let cause: any Error
    public var description: String { "pricing-api unavailable, no cached price for \"\(sku)\": \(cause)" }
}

/// A direct dependency guarded by the catalog.
public struct PricingAPIClient: Sendable {
    /// The key this client claims in the declaration. It must match a
    /// `<name>=hard|soft` line there, or the initializer fails at startup.
    public static let dependencyName = "pricing-api"

    let catalog: DependencyCatalog
    let baseURL: URL
    let session: URLSession

    /// Claims the dependency and validates the base URL — both at CONSTRUCTION.
    ///
    /// An unset or scheme-less base URL must fail HERE, not at call time: left to the
    /// transport it fails on the COUNTED arm, so a missing `http://` would open the
    /// breaker and make `/health` blame a dependency that was never contacted.
    public init(
        catalog: DependencyCatalog,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared
    ) async throws {
        try await catalog.requireDeclared(Self.dependencyName)
        let raw = environment["PRICING_API_BASE_URL"] ?? ""
        guard let url = URL(string: raw), url.scheme == "http" || url.scheme == "https",
            url.host != nil
        else {
            throw ConfigurationError(
                message: """
                    pricing-api: PRICING_API_BASE_URL="\(raw)" is not an absolute http(s) URL \
                    (want e.g. http://pricing-api:8080); a config error here would be reported \
                    as a dependency outage rather than the config error it is
                    """)
        }
        self.catalog = catalog
        self.baseURL = url
        self.session = session
    }

    /// Fetch a price under all six mandates, degrading rather than failing.
    public func price(sku: String) async throws -> Price {
        try await catalog.call(
            Self.dependencyName,
            operation: { try await fetch(sku: sku) },
            fallback: { cause in
                // MANDATE 4, the registered fallback. It must NOT call the dependency and
                // must not block. WHAT it returns is your application's business logic — a
                // cached price, a conservative default, an empty result the caller can
                // handle; THAT it exists is the org mandate.
                //
                // NOTE WHAT THIS DELIBERATELY DOES NOT DO: invent a price. `cents: 0` would
                // hand a caller a money-shaped value they might bill on. A degraded path
                // owes the caller a usable answer or an honest absence — never a
                // fabricated number. Serve a cached last-known-good here if you have one.
                throw PriceUnavailable(sku: sku, cause: cause)
            })
    }

    func fetch(sku: String) async throws -> Price {
        // ESCAPE the caller's input: unescaped, a SKU containing "?" injects a query and
        // "/" walks to another endpoint — and a request that fails for that reason would
        // be charged to the breaker, so caller input would move a dependency's health.
        guard
            let escaped = sku.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "?"])),
            let url = URL(string: "\(baseURL.absoluteString.trimmingSuffix("/"))/prices/\(escaped)")
        else {
            throw NotADependencyFailure(ConfigurationError(message: "pricing-api: cannot build a URL for sku \"\(sku)\""))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Transport errors (refused, DNS, reset) propagate as COUNTED failures. A
        // cancelled caller surfaces here as URLError(.cancelled) and is excluded by the
        // catalog, which asks `Task.isCancelled` rather than trusting the error's type.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DependencyProtocolError(message: "pricing-api: not an HTTP response")
        }

        switch http.statusCode {
        case 404:
            // The caller asked for a SKU that does not exist. The dependency answered
            // correctly and promptly; counting this would let a crawler on dead SKUs open
            // the breaker — and, were pricing-api declared hard, fail readiness.
            throw NotADependencyFailure(ConfigurationError(message: "pricing-api: no such sku \"\(sku)\""))
        case 400..<500:
            // The whole 4xx range is the caller's fault by definition.
            throw NotADependencyFailure(DependencyProtocolError(message: "pricing-api: status \(http.statusCode)"))
        case 500...:
            // 5xx is the dependency failing. Count it.
            throw DependencyProtocolError(message: "pricing-api: status \(http.statusCode)")
        case 200..<300:
            break
        default:
            // A 1xx or an unfollowed 3xx would otherwise reach the decoder and be
            // reported as a malformed body. Make success explicit, not residual.
            throw DependencyProtocolError(message: "pricing-api: unexpected status \(http.statusCode)")
        }

        // A body we cannot parse means the dependency is misbehaving: this counts.
        return try JSONDecoder().decode(Price.self, from: data)
    }
}

/// A local misconfiguration — never the dependency's fault.
public struct ConfigurationError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// The dependency answered, but not in a shape we can use.
public struct DependencyProtocolError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
