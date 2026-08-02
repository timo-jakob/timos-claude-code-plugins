/*
 * The ops-api v1.1 health surface for Spring Boot (#1141, epic #964).
 *
 * Serves the three health endpoints of contracts/ops/v1/openapi.yaml -- /health,
 * /health/live and /health/ready -- with the exact bodies and status codes
 * scripts/check-ops-conformance.zsh asserts.
 *
 * WHY AN ACTUATOR @Endpoint AND NOT A @RestController. The ops surface binds a
 * separate internal management port, which Spring Boot serves from a CHILD
 * application context -- and that child context deliberately runs a MINIMAL MVC
 * stack: it registers a DispatcherServlet and a CompositeHandlerMapping that
 * merely collects the HandlerMapping beans present, with NO
 * RequestMappingHandlerMapping and no RouterFunctionMapping. A @RestController
 * placed there is therefore never mapped at all, and one placed in the MAIN
 * context is mapped on the PUBLIC app port -- leaking the dependency graph. An
 * @Endpoint has neither problem: it is declared in the main context (so its
 * collaborators inject normally) and Actuator's own endpoint handler mapping
 * serves it on the management port. It is also the only extension point Boot 4
 * still supports here -- @RestControllerEndpoint has been deprecated for removal
 * since Spring Boot 3.3.
 *
 * WHY THE ID IS `opshealth` AND NOT `health`. Actuator's own HealthEndpoint bean
 * exists whenever Actuator is on the classpath, and two endpoints sharing an id
 * fail endpoint discovery at startup. So this endpoint takes a distinct id and
 * application-resilience.yml maps it onto the contract's path with
 * `management.endpoints.web.path-mapping.opshealth: health`, while Actuator's own
 * health endpoint is simply left out of the exposure list.
 *
 * PLACEMENT: copy into your service's source set and set the package to match its
 * directory, e.g. src/main/java/com/acme/orders/ops/OpsHealthEndpoint.java ->
 * package com.acme.orders.ops;
 */
package com.example.ops; // <-- CHANGE to match the directory you place this file in.

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.List;
import java.util.Map;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.boot.actuate.endpoint.annotation.Selector;
import org.springframework.boot.actuate.endpoint.web.EndpointMediaTypes;
import org.springframework.boot.actuate.endpoint.web.WebEndpointResponse;
import org.springframework.boot.availability.ApplicationAvailability;
import org.springframework.boot.availability.LivenessState;
import org.springframework.context.annotation.Bean;
import org.springframework.stereotype.Component;

/** The org-standard ops health endpoints, served on the internal management port. */
@Component
@Endpoint(id = "opshealth")
public class OpsHealthEndpoint {

  /** The binary probe envelope: "ok" on a 200, "down" on a 503. */
  public record Health(String status) {}

  /**
   * The tri-state aggregate served by /health. {@code components} is omitted entirely
   * when the service declares no dependencies -- an ops-api v1.0 service stays valid.
   */
  @JsonInclude(JsonInclude.Include.NON_NULL)
  public record Aggregate(String status, Map<String, DependencyHealth.Component> components) {}

  private static final Health OK = new Health("ok");
  private static final Health DOWN = new Health("down");

  private final DependencyHealth health;
  private final ApplicationAvailability availability;

  public OpsHealthEndpoint(DependencyHealth health, ApplicationAvailability availability) {
    this.health = health;
    this.availability = availability;
  }

  /**
   * GET /health -- the human/dashboard-facing aggregate.
   *
   * <p>ALWAYS answers HTTP 200 while the process can respond at all -- the verdict is in
   * the body, not the status line. Returning the body directly (rather than a
   * {@link WebEndpointResponse}) is what guarantees that: there is no status to get
   * wrong. 503 is the two probes' vocabulary; a /health that 503s during an outage is
   * unreadable exactly when someone needs to read it.
   */
  @ReadOperation
  public Aggregate health() {
    Map<String, DependencyHealth.Component> components = health.components();
    return new Aggregate(health.aggregate(), components.isEmpty() ? null : components);
  }

  /**
   * GET /health/live and GET /health/ready -- the two Kubernetes probes.
   *
   * <p>The selector is the path segment after /health, so this one operation serves both
   * probes. Anything else 404s rather than silently answering as one of them.
   *
   * <p><b>live</b> asks whether the process is wedged and needs a restart, and is
   * DEPENDENCY-FREE by contract: a failing liveness makes the kubelet restart the pod, so
   * checking a dependency here would turn a transient outage into a restart storm.
   * Mandate 6 (stay-stable) is what keeps this answering while a dependency is down.
   *
   * <p><b>ready</b> asks whether this pod can accept traffic, and fails only for a
   * declared HARD dependency being down (or a non-dependency reason such as startup or
   * drain). A soft dependency down keeps the pod ready and degraded.
   */
  @ReadOperation
  public WebEndpointResponse<Health> probe(@Selector String probe) {
    return switch (probe) {
      case "live" -> respond(availability.getLivenessState() == LivenessState.CORRECT);
      case "ready" -> respond(health.ready());
      default -> new WebEndpointResponse<>(WebEndpointResponse.STATUS_NOT_FOUND);
    };
  }

  /**
   * Serve the ops endpoints as plain {@code application/json}, which is what
   * contracts/ops/v1/openapi.yaml declares.
   *
   * <p>Actuator's default produced type is
   * {@code application/vnd.spring-boot.actuator.v3+json}, and it is FIRST in the default
   * list -- so a client that accepts anything (curl, a probe, the conformance checker, a
   * spec-driven mock) is served the vendor type and not the media type the contract
   * names. Boot declares its own {@code EndpointMediaTypes} bean
   * {@code @ConditionalOnMissingBean}, so defining one here replaces it. This also brings
   * {@code /info} onto {@code application/json}; {@code /metrics} is unaffected, because
   * the Prometheus endpoint produces its own exposition types.
   */
  @Bean
  EndpointMediaTypes opsApiEndpointMediaTypes() {
    return new EndpointMediaTypes(List.of("application/json"), List.of("application/json"));
  }

  private static WebEndpointResponse<Health> respond(boolean healthy) {
    return healthy
        ? new WebEndpointResponse<>(OK, WebEndpointResponse.STATUS_OK)
        : new WebEndpointResponse<>(DOWN, WebEndpointResponse.STATUS_SERVICE_UNAVAILABLE);
  }
}
