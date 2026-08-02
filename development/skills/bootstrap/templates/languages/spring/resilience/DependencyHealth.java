/*
 * Passive dependency health, read from circuit-breaker state (#1141, epic #964).
 *
 * The unifying idea of the org resilience policy: THE CIRCUIT BREAKER KEEPS YOU
 * SERVING; THE DEPENDENCY-HEALTH SURFACE TELLS YOU WHAT'S DEGRADED. An open
 * breaker IS a down dependency, so health is read from the breaker rather than
 * measured by a second mechanism.
 *
 * PASSIVE means exactly that: this class never calls a dependency, never runs a
 * scheduled probe, and NEVER transitively calls a downstream's /health (the
 * health-check-storm anti-pattern, where one slow leaf hangs every ancestor's
 * health check). Real request traffic -- or the breaker's own half-open probe --
 * has already moved the state; reading it costs nothing and generates no traffic.
 *
 * PLACEMENT: copy into your service's source set and set the package to match its
 * directory, e.g. src/main/java/com/acme/orders/ops/DependencyHealth.java ->
 * package com.acme.orders.ops;
 */
package com.example.ops; // <-- CHANGE to match the directory you place this file in.

import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import java.time.Clock;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.availability.ApplicationAvailability;
import org.springframework.boot.availability.ReadinessState;
import org.springframework.stereotype.Component;

/**
 * Derives the ops-api v1.1 dependency-health view from resilience4j breaker state.
 *
 * <p>The mapping from breaker state to dependency status is exact and defined by the
 * contract: closed = {@code up}, half-open = {@code degraded} (being re-probed), open =
 * {@code down}.
 *
 * <p>An ordinary component of the MAIN application context: it serves no HTTP itself, so
 * scanning it here is safe, and OpsHealthEndpoint (the Actuator endpoint that does serve
 * it, on the management port) injects it normally.
 */
@Component
public class DependencyHealth {

  /**
   * One direct dependency's health, serialized as an ops-api {@code DependencyHealth}.
   *
   * @param status up | degraded | down -- read from the breaker
   * @param kind hard | soft -- the declared readiness hinge
   * @param breaker closed | open | half_open -- the state the status was read from
   * @param since RFC 3339 timestamp of the last state change, so a dashboard can tell a
   *     blip from a sustained outage
   */
  public record Component(String status, String kind, String breaker, String since) {}

  private final CircuitBreakerRegistry registry;
  private final DependencyCatalog catalog;
  private final ApplicationAvailability availability;
  private final Clock clock;

  /** Dependency name -> when it last changed breaker state. */
  private final Map<String, Instant> since = new ConcurrentHashMap<>();

  /**
   * The Clock is taken from the context when the service defines one and defaults to
   * {@link Clock#systemUTC()} otherwise, so this never competes with an application's own
   * Clock bean while staying injectable in tests.
   */
  public DependencyHealth(
      CircuitBreakerRegistry registry,
      DependencyCatalog catalog,
      ApplicationAvailability availability,
      ObjectProvider<Clock> clock) {
    this.registry = registry;
    this.catalog = catalog;
    this.availability = availability;
    this.clock = clock.getIfAvailable(Clock::systemUTC);
    subscribe();
  }

  /**
   * Bind each declared dependency to its breaker and start tracking state changes.
   *
   * <p>A declared dependency with no breaker is a HARD startup failure, not a warning.
   * Mandate 2 says every governed outbound call has a breaker; without one this class
   * would have nothing to read and would report the dependency as {@code up}
   * unconditionally -- precisely the under-reporting the ops-api contract forbids. Fail
   * loudly at boot instead of serving a health surface that lies during an outage.
   */
  private void subscribe() {
    Instant startedAt = now();
    catalog
        .resolved()
        .forEach(
            (name, dep) -> {
              CircuitBreaker breaker =
                  registry
                      .find(dep.breaker())
                      .orElseThrow(
                          () ->
                              new IllegalStateException(
                                  "Dependency '"
                                      + name
                                      + "' is declared under resilience.dependencies but has no"
                                      + " resilience4j circuit breaker named '"
                                      + dep.breaker()
                                      + "'. Declare it under"
                                      + " resilience4j.circuitbreaker.instances, or drop the"
                                      + " dependency declaration."));
              since.put(name, startedAt);
              breaker.getEventPublisher().onStateTransition(event -> since.put(name, now()));
            });
  }

  /**
   * The ops-api {@code components} map: one entry per DIRECT dependency, in declaration
   * order. Empty when the service declares no dependencies, in which case the caller
   * omits the field entirely.
   */
  public Map<String, Component> components() {
    Map<String, Component> out = new LinkedHashMap<>();
    catalog
        .resolved()
        .forEach(
            (name, dep) -> {
              CircuitBreaker.State state = registry.circuitBreaker(dep.breaker()).getState();
              out.put(
                  name,
                  new Component(
                      statusOf(state),
                      dep.kind().name().toLowerCase(java.util.Locale.ROOT),
                      breakerOf(state),
                      rfc3339(since.getOrDefault(name, now()))));
            });
    return out;
  }

  /**
   * The aggregate served by {@code /health}.
   *
   * <p>The components set a FLOOR, not an equality: {@code down} if any HARD dependency
   * is down, else {@code degraded} if ANY dependency (hard or soft) is down or degraded,
   * else {@code ok}. Note the hard/degraded case -- a hard dependency that is merely
   * half-open is {@code degraded}, not down.
   *
   * <p>Over-reporting is legal and expected: a service that is impaired for an internal
   * reason no dependency models (a backed-up work queue, a full disk) MUST report a MORE
   * severe aggregate than this. Add that here; never report a LESS severe one.
   */
  public String aggregate() {
    String floor = "ok";
    for (Map.Entry<String, Component> entry : components().entrySet()) {
      Component component = entry.getValue();
      boolean down = "down".equals(component.status());
      if (down && "hard".equals(component.kind())) {
        return "down";
      }
      if (down || "degraded".equals(component.status())) {
        floor = "degraded";
      }
    }
    return floor;
  }

  /**
   * The readiness answer behind {@code /health/ready}.
   *
   * <p>Among dependencies, only a declared HARD one being down makes the service unready
   * -- a soft dependency down keeps the pod ready and serving degraded responses. That
   * single rule resolves the tension between naive readiness (shed traffic on any
   * dependency loss) and resilience (stay up and degrade).
   *
   * <p>Non-dependency reasons are unaffected and still apply: a service still starting
   * up, or draining during a graceful shutdown, is unready even with every dependency
   * healthy. That state comes from Spring's own {@link ReadinessState}.
   */
  public boolean ready() {
    if (availability.getReadinessState() != ReadinessState.ACCEPTING_TRAFFIC) {
      return false;
    }
    return components().values().stream()
        .noneMatch(c -> "hard".equals(c.kind()) && "down".equals(c.status()));
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
   * Breaker state -> the contract's three-value {@code breaker} field. resilience4j has
   * six states; the contract names the three that describe what is happening to calls, so
   * the non-enforcing states project onto {@code closed} and FORCED_OPEN onto {@code
   * open}.
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
