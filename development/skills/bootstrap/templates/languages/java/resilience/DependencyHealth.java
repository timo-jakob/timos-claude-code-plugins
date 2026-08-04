/*
 * Passive dependency health, read from circuit-breaker state, for NON-Spring Java
 * (#1142, epic #964).
 *
 * The unifying idea of the org resilience policy: THE CIRCUIT BREAKER KEEPS YOU
 * SERVING; THE DEPENDENCY-HEALTH SURFACE TELLS YOU WHAT'S DEGRADED. An open
 * breaker IS a down dependency, so health is read from the breaker rather than
 * measured by a second mechanism.
 *
 * PASSIVE means exactly that: this class never calls a dependency, never runs a
 * scheduled probe, and NEVER transitively calls a downstream's /health (the
 * health-check-storm anti-pattern, where one slow leaf hangs every ancestor's
 * health check). Real request traffic -- or the breaker's own background
 * half-open probe -- has already moved the state; reading it costs nothing and
 * generates no traffic.
 *
 * WHERE THE AGGREGATE AND THE READINESS RULE LIVE: not here. This class maps
 * breaker state to the per-dependency `components` entries and stops there; OpsApi
 * derives the aggregate floor and the readiness answer from those entries. The
 * Spring payload keeps all three together because its endpoint class is
 * Spring-specific anyway, but here the split earns something concrete -- OpsApi
 * stays free of any resilience4j import, so a service that has no dependencies to
 * break can serve the ops surface without this payload on its classpath at all.
 *
 * PLACEMENT: copy into your service's source set, BESIDE OpsApi.java (it
 * implements OpsApi.DependencyHealthSource and returns OpsApi.Dependency records),
 * and set the package to match the directory, e.g.
 * src/main/java/com/acme/orders/ops/DependencyHealth.java -> package
 * com.acme.orders.ops;
 */
package com.example.ops; // <-- CHANGE to match the directory you place this file in.

import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import java.time.Clock;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Derives the ops-api v1.1 {@code components} map from resilience4j breaker state.
 *
 * <p>The mapping from breaker state to dependency status is exact and defined by the
 * contract: closed = {@code up}, half-open = {@code degraded} (being re-probed), open =
 * {@code down}.
 */
public final class DependencyHealth implements OpsApi.DependencyHealthSource {

  private final DependencyCatalog catalog;
  private final Clock clock;

  /** Dependency name -> when it last changed breaker state. */
  private final Map<String, Instant> since = new ConcurrentHashMap<>();

  public DependencyHealth(DependencyCatalog catalog) {
    this(catalog, Clock.systemUTC());
  }

  /** The Clock is injectable so a test can assert on {@code since} without sleeping. */
  public DependencyHealth(DependencyCatalog catalog, Clock clock) {
    this.catalog = catalog;
    this.clock = clock;
    Instant startedAt = now();
    catalog
        .dependencies()
        .keySet()
        .forEach(
            name -> {
              since.put(name, startedAt);
              // The catalog created every declared breaker eagerly, so this neither creates one
              // nor can it miss one -- it only attaches the listener that keeps `since` honest.
              catalog
                  .breakers()
                  .circuitBreaker(name)
                  .getEventPublisher()
                  .onStateTransition(event -> since.put(name, now()));
            });
  }

  /**
   * The ops-api {@code components} map: one entry per DIRECT dependency, in declaration
   * order. Empty when the service declares none, in which case OpsApi omits the field
   * entirely and the response stays valid ops-api v1.0.
   */
  @Override
  public Map<String, OpsApi.Dependency> components() {
    Map<String, OpsApi.Dependency> out = new LinkedHashMap<>();
    catalog
        .dependencies()
        .forEach(
            (name, kind) -> {
              CircuitBreaker.State state = catalog.breakers().circuitBreaker(name).getState();
              out.put(
                  name,
                  new OpsApi.Dependency(
                      statusOf(state),
                      kind.wire(),
                      breakerOf(state),
                      rfc3339(since.getOrDefault(name, now()))));
            });
    return out;
  }

  /**
   * Breaker state -> dependency status.
   *
   * <p>FORCED_OPEN is an operator-forced open breaker: calls are being rejected, so the
   * dependency is unusable and reports {@code down} exactly like a naturally open one.
   * DISABLED and METRICS_ONLY mean the breaker is not rejecting anything, so it has no
   * failure verdict to report and the dependency reads {@code up}.
   */
  private static String statusOf(CircuitBreaker.State state) {
    return switch (state) {
      case OPEN, FORCED_OPEN -> "down";
      case HALF_OPEN -> "degraded";
      case CLOSED, DISABLED, METRICS_ONLY -> "up";
    };
  }

  /**
   * Breaker state -> the contract's three-value {@code breaker} field. resilience4j has six
   * states; the contract names the three that describe what is happening to calls, so the
   * non-enforcing states project onto {@code closed} and FORCED_OPEN onto {@code open}.
   */
  private static String breakerOf(CircuitBreaker.State state) {
    return switch (state) {
      case OPEN, FORCED_OPEN -> "open";
      case HALF_OPEN -> "half_open";
      case CLOSED, DISABLED, METRICS_ONLY -> "closed";
    };
  }

  private Instant now() {
    return clock.instant().truncatedTo(ChronoUnit.MILLIS);
  }

  private static String rfc3339(Instant instant) {
    return instant.truncatedTo(ChronoUnit.MILLIS).toString();
  }
}
