/**
 * Passive dependency health, read from circuit-breaker state, for Node services
 * (issue #1145, epic #964).
 *
 * The unifying idea of the org resilience policy: THE CIRCUIT BREAKER KEEPS YOU
 * SERVING; THE DEPENDENCY-HEALTH SURFACE TELLS YOU WHAT'S DEGRADED. An open breaker
 * IS a down dependency, so health is READ from the breaker rather than measured by a
 * second mechanism.
 *
 * PASSIVE means exactly that: this file never calls a dependency, never runs a
 * scheduled probe, and NEVER transitively calls a downstream's /health (the
 * health-check-storm anti-pattern, where one slow leaf hangs every ancestor's health
 * check). Real request traffic -- or the breaker's own half-open probe -- has already
 * moved the state; reading it costs nothing and generates no traffic. opossum moves
 * an open breaker to half-open on its own timer, so a recovering dependency becomes
 * visible on /health even while the service receives no traffic at all.
 *
 * WHERE THE AGGREGATE AND THE READINESS RULE LIVE: not here. This file maps breaker
 * state to the per-dependency `components` entries and stops. The ops module derives
 * the aggregate floor and the readiness answer from those entries -- which is what
 * lets it stay free of any breaker import, as its own doc comment promises.
 */

// <-- CHANGE THIS IMPORT if the ops-api payload is not at src/ops/opsApi.ts beside
// this directory. It is the one path in this payload that depends on placement.
// A TYPE-ONLY import on purpose: it is erased at compile time, so this module never
// loads the ops module (or its OpenTelemetry graph) at runtime -- the dependency
// runs one way, resilience onto ops, and only as a contract.
import type { Dependency, DependencyHealthSource } from "../ops/opsApi.js";

import type { Breaker, DependencyCatalog } from "./dependencyCatalog.js";

/** The contract's three breaker spellings. */
type BreakerState = "closed" | "open" | "half_open";

/**
 * DependencyHealth derives the ops-api v1.1 `components` map from opossum state.
 *
 * `implements DependencyHealthSource` is the compile-time proof that this satisfies
 * the seam the ops module ships: if the ops-api contract ever changes shape, the
 * build fails rather than /health quietly losing its components map.
 */
export class DependencyHealth implements DependencyHealthSource {
  readonly #catalog: DependencyCatalog;
  readonly #now: () => Date;
  // When each dependency last changed breaker state, so a dashboard can tell a blip
  // from a sustained outage.
  readonly #since = new Map<string, Date>();

  /**
   * Wires the health view onto a catalog.
   *
   * Construct it BEFORE the breakers see traffic: the listeners that keep `since`
   * honest are attached here. A breaker that transitioned earlier still reports the
   * right STATUS -- that is read live -- but its `since` would be the construction
   * time rather than the transition.
   *
   * `now` is injectable so a test can assert on `since` without sleeping.
   */
  constructor(catalog: DependencyCatalog, now: () => Date = () => new Date()) {
    this.#catalog = catalog;
    this.#now = now;
    const startedAt = now();
    for (const name of catalog.dependencies().keys()) {
      this.#since.set(name, startedAt);
      const breaker = catalog.breaker(name);
      if (breaker === undefined) {
        continue;
      }
      // All three transitions. opossum emits each synchronously from the call that
      // moved the breaker, or from its own reset timer for open -> half-open.
      const stamp = (): void => {
        this.#since.set(name, this.#now());
      };
      breaker.on("open", stamp);
      breaker.on("halfOpen", stamp);
      breaker.on("close", stamp);
    }
  }

  /**
   * The ops-api `components` map: one entry per DIRECT dependency.
   *
   * A FRESHLY BUILT object every call, as the seam requires: /health serializes what
   * comes back, so handing out a live registry would let a later mutation be observed
   * as a health report nobody intended.
   *
   * A service that declares no dependencies gets `{}`, and the ops module then omits
   * the field entirely, leaving the response a valid ops-api v1.0 body.
   */
  components(): Record<string, Dependency> {
    const out: Record<string, Dependency> = {};
    for (const [name, kind] of this.#catalog.dependencies()) {
      const since = rfc3339(this.#since.get(name) ?? this.#now());
      const breaker = this.#catalog.breaker(name);
      if (breaker === undefined) {
        // Unreachable by construction -- the catalog creates a breaker for every
        // declared dependency. If it ever became reachable, report the dependency
        // DOWN rather than omitting it: silently dropping a declared dependency is
        // exactly the under-reporting the two startup guards exist to refuse.
        out[name] = { status: "down", kind, breaker: "open", since };
        continue;
      }
      const state = breakerStateOf(breaker);
      out[name] = { status: statusOf(state), kind, breaker: state, since };
    }
    return out;
  }
}

/**
 * Reads opossum's state onto the contract's three values.
 *
 * opossum also has a SHUTDOWN state (and a disabled flag), neither of which is one
 * of the contract's. A breaker in either is not evidence of health -- a shut-down
 * breaker rejects every call -- so it fails toward severity and reports open.
 */
export function breakerStateOf(breaker: Breaker): BreakerState {
  if (breaker.closed && breaker.enabled) {
    return "closed";
  }
  if (breaker.halfOpen) {
    return "half_open";
  }
  return "open";
}

/**
 * Maps breaker state to the contract's dependency status.
 *
 * Note the two vocabularies the ops module warns about: a COMPONENT is healthy as
 * "up", while the /health AGGREGATE spells healthy "ok". Returning "ok" here would be
 * coerced to "down" by the ops module's fail-toward-severity rule.
 */
export function statusOf(state: BreakerState): Dependency["status"] {
  switch (state) {
    case "closed":
      return "up";
    case "half_open":
      return "degraded";
    case "open":
      return "down";
  }
}

/** RFC 3339 at second precision, the spelling every sibling payload serves. */
function rfc3339(at: Date): string {
  return at.toISOString().replace(/\.\d{3}Z$/, "Z");
}
