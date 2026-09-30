//  DependencyHealth.swift — passive dependency health, read from circuit-breaker
//  state, for Swift services (#1146, epic #964).
//
//  The unifying idea of the org resilience policy: THE CIRCUIT BREAKER KEEPS YOU
//  SERVING; THE DEPENDENCY-HEALTH SURFACE TELLS YOU WHAT'S DEGRADED. An open breaker
//  IS a down dependency, so health is READ from the breaker rather than measured by a
//  second mechanism.
//
//  PASSIVE means exactly that: this file never calls a dependency, never runs a
//  scheduled probe, and NEVER transitively calls a downstream's /health (the
//  health-check-storm anti-pattern, where one slow leaf hangs every ancestor's health
//  check). Real request traffic — or the breaker's own half-open probe — has already
//  moved the state; reading it costs one actor hop per dependency and generates no
//  traffic. The breaker computes open -> half-open from elapsed time on read, so a
//  recovering dependency becomes visible on /health even with no traffic at all.
//
//  WHERE THE AGGREGATE AND THE READINESS RULE LIVE: not here. This file maps breaker
//  state to the per-dependency `components` entries and stops. `OpsApi.swift` derives
//  the aggregate floor and the readiness answer from them — which is what lets the ops
//  surface stay free of any breaker, as its own header promises.

import Foundation

#if canImport(Ops)
    import Ops
#endif

/// Derives the ops-api v1.1 `components` map from the catalog's breakers.
///
/// Conforms, unchanged, to the `DependencyHealthSource` seam `OpsApi.swift` ships: if
/// that contract ever changes shape, this conformance fails the build rather than
/// letting `/health` quietly lose its components map.
public struct DependencyHealth: DependencyHealthSource {
    let catalog: DependencyCatalog

    public init(catalog: DependencyCatalog) {
        self.catalog = catalog
    }

    /// The value to hand `OpsConfig.dependencies`: this source, or `nil` when the
    /// catalog declares nothing.
    ///
    /// Use THIS rather than the initializer when wiring the seam. An empty catalog
    /// behind a non-nil source would make `/health` serve `"components":{}` — a v1.1
    /// body announcing dependency health and then reporting none — where an unset slot
    /// serves the byte-identical ops-api v1.0 body with no `components` key at all.
    public static func seam(for catalog: DependencyCatalog) -> (any DependencyHealthSource)? {
        catalog.dependencies.isEmpty ? nil : DependencyHealth(catalog: catalog)
    }

    /// One entry per DIRECT dependency, built into a FRESH dictionary on every call.
    ///
    /// `/health` and `/health/ready` both read what comes back, and the seam is `Sendable`
    /// precisely so a live registry can never be handed out. Each breaker is read in ONE
    /// actor hop (`snapshot()`), so an entry's `breaker` and `since` always describe the
    /// same moment — and `since` is the breaker's own transition stamp, set on every
    /// state change and never on a read that changed nothing.
    public func components() async -> [String: Dependency] {
        var out: [String: Dependency] = [:]
        for (name, kind) in catalog.dependencies {
            guard let breaker = catalog.breaker(for: name) else {
                // Unreachable by construction — the catalog creates a breaker for every
                // declared dependency. If it ever became reachable, report the dependency
                // DOWN rather than omitting it: silently dropping a declared dependency is
                // exactly the under-reporting the two startup guards exist to refuse.
                out[name] = Dependency(
                    status: .down, kind: kind, breaker: .open, since: Self.rfc3339(Date()))
                continue
            }
            let snapshot = await breaker.snapshot()
            out[name] = Dependency(
                status: Self.status(of: snapshot.state),
                kind: kind,
                breaker: snapshot.state,
                since: Self.rfc3339(snapshot.since)
            )
        }
        return out
    }

    /// Breaker state → the contract's component status: closed = up, half-open =
    /// degraded (being re-probed), open = down.
    ///
    /// A component is healthy as `up`; the `/health` AGGREGATE spells healthy `ok`. The
    /// ops enums make the wrong spelling a compile error rather than a silent all-clear.
    /// The switch is exhaustive with no `default`, so a fourth breaker state is a compile
    /// error here rather than a guess.
    static func status(of state: BreakerState) -> ComponentStatus {
        switch state {
        case .closed: return .up
        case .halfOpen: return .degraded
        case .open: return .down
        }
    }

    /// RFC 3339 in UTC, whole seconds — the shape every sibling payload serves.
    static func rfc3339(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
