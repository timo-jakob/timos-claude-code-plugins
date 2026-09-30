//  DependencyCatalog.swift — the hard/soft dependency declaration, one circuit breaker
//  per declared dependency, and the six-mandate call wrapper for Swift services
//  (#1146, epic #964). The Swift sibling of the Spring (#1141), Java (#1142),
//  Python (#1143) and Go (#1144) payloads.
//
//  Every outbound dependency call gets a timeout, a circuit breaker, bounded retry
//  with jittered backoff, a registered fallback, background reconnect and
//  stay-stable fast-fail. The breaker is the payload-owned `CircuitBreaker` actor
//  below, deliberately NOT a third-party library: README.md, "Why a payload-owned
//  actor breaker", records the fit-check every candidate failed.
//
//  It EXTENDS the ops-api payload rather than standing alone: DependencyHealth.swift
//  conforms to the `DependencyHealthSource` seam `OpsApi.swift` already ships, and
//  this file reads the ops vocabulary (`DependencyKind`, `BreakerState`) from it.
//  The dependency direction is one-way and load-bearing — resilience depends on ops,
//  never the reverse — which is what keeps `OpsApi.swift` free of any breaker, as its
//  own header promises.
//
//  PLACEMENT: copy this file, DependencyHealth.swift and (optionally)
//  PricingAPIClient.swift into `Sources/<ServiceTarget>/Resilience/`, in the SAME
//  target as `Ops/OpsApi.swift`. There are no placeholders. The conditional import
//  below is what lets the same files also compile when `Ops` is a separate target.

import Foundation

#if canImport(Ops)
    import Ops
#endif

// MARK: - The declaration

/// The COMPILED-IN default declaration: `resilience-dependencies.properties`, verbatim.
///
/// Swift has no `//go:embed`, and the resource-bundle route (`Bundle.module`) needs a
/// `resources:` line in `targets:` plus a Dockerfile that copies the `.resources`
/// bundle into the runtime stage — miss either and the declaration is simply absent
/// in the image, so every pod dies at startup. A string literal travels inside the
/// binary on every platform with no manifest edit, which is the whole requirement.
///
/// THIS LITERAL AND `resilience-dependencies.properties` ARE ONE FILE IN TWO PLACES.
/// Edit them together: the literal is what the binary carries, the `.properties` file
/// is the same declaration in the shape an operator mounts as a ConfigMap through
/// `$OPS_DEPENDENCIES_FILE`. Changing it is a rebuild, not a restart.
public let bundledDependencyDeclaration = #"""
    # Hard/soft dependency declaration for the Swift resilience payload (#1146).
    #
    # One `<name>=hard|soft` line per DIRECT dependency -- the ones this service calls
    # itself. Never list a transitive dependency: each service reports one hop, and the
    # observability layer assembles the graph. (A service that called a downstream's
    # /health to fold it into its own would be the health-check-storm anti-pattern,
    # where one slow leaf hangs every ancestor's health check.)
    #
    # hard  Nothing works without it. Its loss FAILS /health/ready, so Kubernetes sheds
    #       traffic -- correct, because the pod genuinely cannot serve.
    # soft  Degraded operation is possible. Its loss NEVER fails readiness: the breaker
    #       opens, the service serves degraded responses, it reconnects in the
    #       background, and /health reports it down while the pod stays ready.
    #
    # Choosing wrong is the expensive mistake in both directions. A cache marked hard
    # sheds all traffic the moment it blips; a database marked soft keeps the pod in
    # rotation while every request fails.
    #
    # FULL-LINE `#` COMMENTS ONLY. A trailing `orders-db=hard # primary` makes the kind
    # literally "hard # primary" -- the parser rejects it at startup rather than
    # guessing, because a misparsed kind decides whether an outage sheds traffic.
    #
    # THIS FILE IS COMPILED INTO THE BINARY: DependencyCatalog.swift carries it,
    # verbatim, as `bundledDependencyDeclaration`. Swift has no //go:embed, so EDIT
    # BOTH TOGETHER -- and editing it is a REBUILD, NOT A RESTART. The copy compiled
    # into the binary is what makes it reach the runtime at all: a declaration read
    # from the working directory would simply not be there in the container image.
    #
    # $OPS_DEPENDENCIES_FILE overrides it at runtime for a mounted ConfigMap, and an
    # override that cannot be read fails startup rather than silently falling back to
    # the compiled copy -- a typo'd path must not boot the pod with the wrong
    # readiness hinge.
    #
    # No duplicate names: a repeated line is rejected at startup, because last-wins
    # could quietly downgrade a hard dependency to soft and disarm the hinge.
    #
    # REPLACE THE TWO EXAMPLES BELOW WITH YOUR REAL DEPENDENCIES. Left verbatim they
    # fail startup on requireAllDeclaredGuarded() (nothing guards them) -- and if you
    # skip that call, /health cheerfully reports two dependencies you do not have as `up`.

    orders-db=hard
    pricing-api=soft

    """#

/// Why the catalog refused to start. Every case is a startup bug and names the thing
/// to fix; none is recoverable at runtime, which is the point.
public enum DependencyDeclarationError: Error, CustomStringConvertible, Equatable {
    case unreadableOverride(path: String, reason: String)
    case malformedLine(origin: String, line: Int, text: String)
    case duplicate(origin: String, line: Int, name: String, previous: DependencyKind, now: String)
    case unknownKind(origin: String, line: Int, name: String, kind: String)
    case undeclared(name: String, origin: String)
    case unguarded(names: [String], origin: String)

    public var description: String {
        switch self {
        case .unreadableOverride(let path, let reason):
            return """
                resilience: $\(DependencyCatalog.declarationFileEnv) is set to "\(path)" but it \
                cannot be read (\(reason)); refusing to fall back to the compiled-in declaration
                """
        case .malformedLine(let origin, let line, let text):
            return "\(origin):\(line): expected `<name>=hard|soft`, got \"\(text)\""
        case .duplicate(let origin, let line, let name, let previous, let now):
            return """
                \(origin):\(line): dependency "\(name)" is declared twice (\(previous.rawValue), \
                then "\(now)"); one line per dependency
                """
        case .unknownKind(let origin, let line, let name, let kind):
            return """
                \(origin):\(line): dependency "\(name)" has kind "\(kind)" (want hard|soft; note \
                that only FULL-LINE `#` comments are supported, so a trailing comment lands here)
                """
        case .undeclared(let name, let origin):
            return """
                resilience: dependency "\(name)" is guarded in code but not declared in \(origin) \
                (add "\(name)=hard|soft")
                """
        case .unguarded(let names, let origin):
            return """
                resilience: \(origin) declares \(names), but no client claimed them -- their \
                breakers can never leave closed, so /health would report them up during an \
                outage; either call requireDeclared from the client's initializer or remove \
                them from the declaration
                """
        }
    }
}

/// Parse `<name>=hard|soft` lines.
///
/// FULL-LINE `#` COMMENTS ONLY — a trailing `orders-db=hard # primary` would make the
/// kind literally `hard # primary`, which is neither. Rather than silently guessing,
/// that is an error: a misparsed kind decides whether an outage sheds traffic.
public func parseDependencyDeclaration(
    _ content: String, origin: String
) throws(DependencyDeclarationError) -> [String: DependencyKind] {
    var out: [String: DependencyKind] = [:]
    // Split on EVERY newline form, not on "\n": Swift reads "\r\n" as ONE Character,
    // which never equals "\n", so a CRLF file (a ConfigMap saved on Windows) would parse
    // as a single line — and one that starts with `#` would declare nothing at all.
    // `omittingEmptySubsequences: false` keeps blank lines, so the reported line number
    // is the one an operator sees in their editor. A BOM is not whitespace, so it is
    // dropped explicitly or the first name would parse as "\u{FEFF}orders-db".
    let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for (index, raw) in lines.enumerated() {
        let line = index + 1
        var text = String(raw)
        if index == 0 && text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.hasPrefix("#") { continue }
        guard let equals = text.firstIndex(of: "=") else {
            throw .malformedLine(origin: origin, line: line, text: text)
        }
        let name = text[..<equals].trimmingCharacters(in: .whitespaces)
        let value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if name.isEmpty { throw .malformedLine(origin: origin, line: line, text: text) }
        // A duplicate is checked BEFORE the kind, so `a=hard` + `a=maybe` reports the
        // duplicate rather than making the operator fix the kind and meet the duplicate
        // on the next boot. Last-wins is the one malformation a silent parser would
        // swallow, and it DISARMS THE READINESS HINGE: a ConfigMap assembled from two
        // sources can quietly downgrade a hard dependency to soft.
        if let previous = out[name] {
            throw .duplicate(origin: origin, line: line, name: name, previous: previous, now: value)
        }
        switch value.lowercased() {
        case "hard": out[name] = .hard
        case "soft": out[name] = .soft
        default: throw .unknownKind(origin: origin, line: line, name: name, kind: value)
        }
    }
    return out
}

// MARK: - The breaker

/// The blessed per-dependency breaker configuration.
///
/// At PARITY with the Java, Python and Go siblings where the figures overlap, so
/// recovery becomes visible on `/health` at the same moment across the fleet.
public struct BreakerConfiguration: Sendable {
    /// Trip at this share of failures among the counted calls in the window.
    public var failureRateThreshold: Double
    /// Never trip on fewer counted calls than this. Without a floor, the first
    /// failure after a reset is a 100% failure rate on a sample of one.
    public var minimumVolume: Int
    /// The COUNT-based sliding window: the last N counted outcomes. Count-based rather
    /// than time-based on purpose — a time window that resets its counters (gobreaker's
    /// `Interval`) means a dependency called fewer than `minimumVolume` times per
    /// interval can never trip, and `/health` reports it up through a total outage.
    public var windowSize: Int
    /// MANDATE 5, background reconnect: open → half-open after this long.
    public var openDuration: Duration
    /// How many probe calls half-open admits; that many successes close the breaker.
    public var halfOpenPermits: Int

    public init(
        failureRateThreshold: Double = 0.5,
        minimumVolume: Int = 10,
        windowSize: Int = 20,
        openDuration: Duration = .seconds(10),
        halfOpenPermits: Int = 3
    ) {
        self.failureRateThreshold = failureRateThreshold
        self.minimumVolume = minimumVolume
        self.windowSize = windowSize
        self.openDuration = openDuration
        self.halfOpenPermits = halfOpenPermits
    }
}

/// An open breaker's rejection — the dependency is already known to be down.
/// MANDATE 6: it arrives immediately, is never retried, and goes to the fallback.
public struct CallNotPermitted: Error, Sendable, CustomStringConvertible {
    public let dependency: String
    public var description: String { "resilience: \(dependency)'s circuit breaker is open" }
}

/// A call that outlived its per-call timeout. It COUNTS against the breaker: a slow
/// dependency is a sick one, and this is how a brownout opens the breaker.
public struct DependencyTimeout: Error, Sendable, CustomStringConvertible {
    public let dependency: String
    public let after: Duration
    public var description: String { "resilience: \(dependency) did not answer within \(after)" }
}

/// Marks an error that must NOT count against a dependency's breaker: a caller error
/// (a 4xx the request itself provoked). Thirty user-driven 404s must not open a breaker
/// on a healthy dependency and — if it is declared hard — start failing readiness.
public struct NotADependencyFailure: Error, Sendable, CustomStringConvertible {
    public let underlying: any Error
    public init(_ underlying: any Error) { self.underlying = underlying }
    public var description: String { "not a dependency failure: \(underlying)" }
}

/// What one admitted call turned out to be, from the breaker's point of view.
public enum CallOutcome: Sendable {
    case success
    case failure
    /// Neither success nor failure: a caller error or a cancelled caller.
    case ignored
}

/// A point-in-time reading of one breaker, taken in a single actor hop so the state
/// and its timestamp can never describe two different moments.
public struct BreakerSnapshot: Sendable {
    public let state: BreakerState
    /// When the breaker entered `state`.
    public let since: Date
}

/// The payload-owned circuit breaker: an `actor`, one instance per dependency.
///
/// The guarded call NEVER runs on this actor. `acquire()` and `record(_:for:)` are the
/// only isolated steps, each a few comparisons, so concurrent callers of one dependency
/// run their calls in parallel — the property that got `pybreaker` rejected in #1143,
/// where a lock held across the call serialized every caller.
public actor CircuitBreaker {
    /// Admission ticket from ``acquire()``. The generation is what lets ``record(_:for:)``
    /// discard an outcome from a phase that has already ended — a call admitted while
    /// closed must not count as a half-open probe when it lands after the breaker tripped.
    public struct Permit: Sendable {
        let generation: UInt64
    }

    enum Phase {
        case closed
        case open(until: ContinuousClock.Instant)
        case halfOpen(inFlight: Int, successes: Int)
    }

    public nonisolated let name: String
    public nonisolated let configuration: BreakerConfiguration
    private let clock = ContinuousClock()
    private var phase: Phase = .closed
    private var generation: UInt64 = 0
    private var changedAt = Date()
    /// Counted outcomes in the closed phase, `true` = failure, oldest first.
    private var window: [Bool] = []

    public init(name: String, configuration: BreakerConfiguration = BreakerConfiguration()) {
        self.name = name
        self.configuration = configuration
    }

    /// The state, advanced for elapsed time FIRST.
    ///
    /// MANDATE 5's visibility: open → half-open is computed from the clock on READ, so a
    /// recovering dependency shows as `half_open` on the next `/health` scrape even while
    /// the service receives no traffic at all — no scheduler, no timer, no probe.
    public var state: BreakerState { snapshot().state }

    public func snapshot() -> BreakerSnapshot {
        advance()
        switch phase {
        case .closed: return BreakerSnapshot(state: .closed, since: changedAt)
        case .open: return BreakerSnapshot(state: .open, since: changedAt)
        case .halfOpen: return BreakerSnapshot(state: .halfOpen, since: changedAt)
        }
    }

    /// Admit one call, or reject it at once. Never suspends, never waits for a slot.
    public func acquire() throws(CallNotPermitted) -> Permit {
        advance()
        switch phase {
        case .closed:
            return Permit(generation: generation)
        case .open:
            throw CallNotPermitted(dependency: name)
        case .halfOpen(let inFlight, let successes):
            guard inFlight + successes < configuration.halfOpenPermits else {
                throw CallNotPermitted(dependency: name)
            }
            phase = .halfOpen(inFlight: inFlight + 1, successes: successes)
            return Permit(generation: generation)
        }
    }

    /// Record what an admitted call turned out to be.
    public func record(_ outcome: CallOutcome, for permit: Permit) {
        guard permit.generation == generation else { return }
        switch phase {
        case .closed:
            guard outcome != .ignored else { return }
            window.append(outcome == .failure)
            if window.count > configuration.windowSize { window.removeFirst() }
            let failures = window.filter { $0 }.count
            if window.count >= configuration.minimumVolume,
                Double(failures) / Double(window.count) >= configuration.failureRateThreshold
            {
                trip()
            }
        case .open:
            return
        case .halfOpen(let inFlight, let successes):
            switch outcome {
            case .failure:
                // One failed probe re-opens: the dependency is not back yet.
                trip()
            case .success:
                if successes + 1 >= configuration.halfOpenPermits {
                    transition(to: .closed)
                } else {
                    phase = .halfOpen(inFlight: inFlight - 1, successes: successes + 1)
                }
            case .ignored:
                // The permit is handed back without a verdict.
                phase = .halfOpen(inFlight: inFlight - 1, successes: successes)
            }
        }
    }

    private func trip() {
        transition(to: .open(until: clock.now.advanced(by: configuration.openDuration)))
    }

    private func advance() {
        if case .open(let until) = phase, clock.now >= until {
            transition(to: .halfOpen(inFlight: 0, successes: 0))
        }
    }

    /// Every state change goes through here, so `since` is stamped on EACH transition
    /// and never on a read that changed nothing.
    private func transition(to next: Phase) {
        phase = next
        generation &+= 1
        changedAt = Date()
        window.removeAll()
    }
}

// MARK: - The catalog

/// The declared dependencies, one breaker per dependency, and the call wrapper.
///
/// One breaker PER DEPENDENCY is mandate 2, and it is also what makes the `/health`
/// components map meaningful: the breaker is the unit the surface reports, so sharing
/// one across two dependencies would report them as a single fused component.
public final class DependencyCatalog: Sendable {
    /// The file name of the declaration's ConfigMap twin.
    public static let declarationFile = "resilience-dependencies.properties"
    /// Points at a declaration to read INSTEAD of the compiled-in one.
    public static let declarationFileEnv = "OPS_DEPENDENCIES_FILE"

    /// MANDATE 1: every call is cut off after this long, and the cut-off COUNTS.
    public static let defaultCallTimeout: Duration = .seconds(2)
    /// MANDATE 3: the FIRST call plus two retries — the same 3 the siblings use.
    public static let maxAttempts = 3
    /// The first backoff, doubled per attempt.
    public static let retryBaseDelay: Duration = .milliseconds(100)
    /// The cap on the exponential growth.
    public static let retryMaxDelay: Duration = .seconds(2)

    public let dependencies: [String: DependencyKind]
    /// Where the declaration came from, so a startup failure names the real file.
    public let origin: String
    /// Created EAGERLY for every declared dependency and never written afterwards, so
    /// reads need no lock — and ``requireAllDeclaredGuarded()`` can tell "declared but
    /// nobody guards it" from "not declared", which a lazily-populated map could not.
    private let breakers: [String: CircuitBreaker]
    private let claims = ClaimRegistry()

    /// Build from an explicit declaration — the seam a test uses, and the escape hatch
    /// for a service that keeps its declaration elsewhere.
    public init(
        dependencies: [String: DependencyKind],
        origin: String = "the declaration passed to DependencyCatalog(dependencies:)",
        breakerConfiguration: BreakerConfiguration = BreakerConfiguration()
    ) {
        self.dependencies = dependencies
        self.origin = origin
        var breakers: [String: CircuitBreaker] = [:]
        for name in dependencies.keys {
            breakers[name] = CircuitBreaker(name: name, configuration: breakerConfiguration)
        }
        self.breakers = breakers
    }

    /// Build from the declaration in force: the file `$OPS_DEPENDENCIES_FILE` names when
    /// it is set, otherwise the compiled-in ``bundledDependencyDeclaration``.
    ///
    /// There is deliberately no working-directory tier. It would be present in local dev
    /// and absent in the container image, so a mistake would surface only after deploy.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        breakerConfiguration: BreakerConfiguration = BreakerConfiguration()
    ) throws(DependencyDeclarationError) -> DependencyCatalog {
        var source = bundledDependencyDeclaration
        var origin = "the compiled-in \(declarationFile)"
        if let path = environment[declarationFileEnv], !path.isEmpty {
            // An unreadable override fails LOUDLY rather than silently falling back: a
            // typo'd ConfigMap path would otherwise boot the pod with the wrong hinge.
            do {
                source = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw .unreadableOverride(path: path, reason: "\(error)")
            }
            origin = path
        }
        let declared = try parseDependencyDeclaration(source, origin: origin)
        return DependencyCatalog(
            dependencies: declared, origin: origin, breakerConfiguration: breakerConfiguration)
    }

    /// The breaker for a declared dependency, or `nil` when it is not declared.
    public func breaker(for name: String) -> CircuitBreaker? { breakers[name] }

    /// Refuse a dependency that code guards but the declaration never named.
    ///
    /// CALL IT FROM EACH DEPENDENCY CLIENT'S INITIALIZER. It is the only writer of the
    /// guarded set, so a service whose clients never claim their dependencies reaches
    /// ``requireAllDeclaredGuarded()`` with an empty set, which then refuses every
    /// declared dependency and the pod never boots. Claiming at construction also turns
    /// "guarded in code but missing from the declaration" into a startup failure.
    @discardableResult
    public func requireDeclared(_ name: String) async throws(DependencyDeclarationError) -> String {
        guard dependencies[name] != nil else { throw .undeclared(name: name, origin: origin) }
        await claims.claim(name)
        return name
    }

    /// Refuse a dependency the declaration names but no client guards. Call it ONCE at
    /// startup, AFTER every client is built.
    ///
    /// An unguarded dependency's breaker never sees a call, so it can never leave
    /// `closed` — and `/health` would swear the dependency is up through a total outage.
    public func requireAllDeclaredGuarded() async throws(DependencyDeclarationError) {
        let claimed = await claims.claimed
        let unguarded = dependencies.keys.filter { !claimed.contains($0) }.sorted()
        guard unguarded.isEmpty else { throw .unguarded(names: unguarded, origin: origin) }
    }

    /// Run an outbound call under all six mandates, and fall back when it fails.
    ///
    ///     let price = try await catalog.call("pricing-api",
    ///         operation: { try await client.fetch(sku) },
    ///         fallback: { cause in try cachedPrice(sku, cause) })
    ///
    /// The operation MUST honour Task cancellation (URLSession, AsyncHTTPClient and NIO
    /// all do): the timeout is enforced by cancelling it, and a call that ignores
    /// cancellation holds its caller until it returns on its own.
    public func call<T: Sendable>(
        _ name: String,
        timeout: Duration = DependencyCatalog.defaultCallTimeout,
        operation: @escaping @Sendable () async throws -> T,
        fallback: @escaping @Sendable (any Error) async throws -> T
    ) async throws -> T {
        try await requireDeclared(name)
        guard let breaker = breakers[name] else {
            throw DependencyDeclarationError.undeclared(name: name, origin: origin)
        }
        // The caller already went away before anything was attempted, so the dependency
        // was never contacted — charging it would let caller-side overload open a
        // HEALTHY dependency's breaker.
        if Task.isCancelled { return try await fallback(CancellationError()) }

        var lastError: any Error = CancellationError()
        for attempt in 1...max(Self.maxAttempts, 1) {
            let permit: CircuitBreaker.Permit
            do {
                permit = try await breaker.acquire()
            } catch {
                // MANDATE 6: an open breaker's rejection is never retried.
                lastError = error
                break
            }
            do {
                let value = try await Self.withTimeout(timeout, dependency: name, operation)
                await breaker.record(.success, for: permit)
                return value
            } catch {
                await breaker.record(Self.outcome(of: error), for: permit)
                lastError = error
            }
            if !Self.retryable(lastError) || attempt == Self.maxAttempts { break }
            do {
                try await Task.sleep(for: Self.backoff(attempt: attempt))
            } catch {
                // Cancelled mid-backoff: a drain must not be held up by a retry sleeping
                // on a dependency that is already gone. The dependency's own error is
                // kept — it is what caused the degradation.
                break
            }
        }
        // MANDATE 4: the fallback. That one is WIRED is the org mandate; what it
        // returns is your application's business logic.
        return try await fallback(lastError)
    }

    /// How an error counts against the breaker.
    ///
    /// `Task.isCancelled` is the authority for a cancelled CALLER, not the error's type:
    /// URLSession reports its own cancellation as `URLError(.cancelled)`, and a drain
    /// cancelling every in-flight task must not open a healthy dependency's breaker.
    /// A ``DependencyTimeout`` is NOT a cancelled caller — the caller is still there —
    /// so a brownout counts.
    static func outcome(of error: any Error) -> CallOutcome {
        if error is NotADependencyFailure { return .ignored }
        if Task.isCancelled { return .ignored }
        return .failure
    }

    /// Whether another attempt could possibly help. Every `false` is a mandate:
    /// an open breaker is already known down (6); a caller's own error reproduces
    /// exactly (and counts nothing); a cancelled caller has spent its budget.
    static func retryable(_ error: any Error) -> Bool {
        if Task.isCancelled { return false }
        if error is CallNotPermitted { return false }
        if error is NotADependencyFailure { return false }
        return true
    }

    /// Exponential, capped, FULL-jittered: a uniform draw over `[0, delay]`. Equal jitter
    /// still leaves the fleet retrying inside one narrow window — the synchronized
    /// stampede the backoff exists to break.
    static func backoff(attempt: Int) -> Duration {
        let shift = min(max(attempt - 1, 0), 20)
        let grown = retryBaseDelay * (1 << shift)
        let delay = grown < retryMaxDelay ? grown : retryMaxDelay
        return delay * Double.random(in: 0...1)
    }

    /// MANDATE 1: race the operation against the clock, and cancel the loser.
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        dependency: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DependencyTimeout(dependency: dependency, after: timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

/// The guarded set. An actor rather than a lock, because the platform floor predates
/// `Synchronization.Mutex` and an `@unchecked Sendable` box is a promise the compiler
/// cannot check.
actor ClaimRegistry {
    private(set) var claimed: Set<String> = []
    func claim(_ name: String) { claimed.insert(name) }
}
