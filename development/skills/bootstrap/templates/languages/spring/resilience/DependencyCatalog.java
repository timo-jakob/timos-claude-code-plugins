/*
 * The hard/soft dependency declaration (#1141, epic #964).
 *
 * This is the readiness hinge of the org resilience policy: each DIRECT
 * dependency is declared `hard` (nothing works without it, so its loss fails
 * /health/ready and Kubernetes sheds traffic) or `soft` (degraded operation is
 * possible, so its loss never fails readiness -- the breaker opens, the pod stays
 * ready, and /health reports it degraded).
 *
 * Declaring it in configuration rather than in code is deliberate: hard-vs-soft is
 * an operational judgement that can change without a code change (a cache that was
 * optional becomes load-bearing), and a reviewer can audit the whole dependency
 * set by reading one block of application.yml.
 *
 * PLACEMENT: copy into your service's source set and set the package to match its
 * directory, e.g. src/main/java/com/acme/orders/ops/DependencyCatalog.java ->
 * package com.acme.orders.ops;
 */
package com.example.ops; // <-- CHANGE to match the directory you place this file in.

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * The service's declared direct dependencies, bound from {@code resilience.dependencies}.
 *
 * <p>DIRECT dependencies only. A service reports the one hop it calls itself and never
 * transitively calls a downstream's {@code /health} -- that is the health-check-storm
 * anti-pattern, where one slow leaf hangs every ancestor's health check.
 */
@Component
@ConfigurationProperties(prefix = "resilience")
public class DependencyCatalog {

  /** How a dependency's loss affects readiness. */
  public enum Kind {
    /** Nothing works without it: its loss fails /health/ready. */
    HARD,
    /** Degraded operation is possible: its loss never fails readiness. */
    SOFT
  }

  /**
   * One declared dependency.
   *
   * @param kind hard or soft -- the readiness hinge
   * @param breaker the resilience4j CircuitBreaker instance name; when null, the
   *     dependency's own name is used (the normal case -- name them the same)
   */
  public record Dependency(Kind kind, String breaker) {}

  private Map<String, Dependency> dependencies = new LinkedHashMap<>();

  public Map<String, Dependency> getDependencies() {
    return dependencies;
  }

  public void setDependencies(Map<String, Dependency> dependencies) {
    this.dependencies = (dependencies == null) ? new LinkedHashMap<>() : dependencies;
  }

  /**
   * The declared dependencies keyed by name, in declaration order, with each
   * breaker name resolved (defaulting to the dependency name).
   */
  public Map<String, Dependency> resolved() {
    Map<String, Dependency> out = new LinkedHashMap<>();
    dependencies.forEach(
        (name, dep) -> {
          String breaker = (dep.breaker() == null || dep.breaker().isBlank()) ? name : dep.breaker();
          out.put(name, new Dependency(dep.kind(), breaker));
        });
    return Collections.unmodifiableMap(out);
  }
}
