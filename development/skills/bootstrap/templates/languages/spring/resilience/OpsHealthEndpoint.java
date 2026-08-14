/*
 * The ops-api v1.1 health surface for Spring Boot (#1141, epic #964).
 *
 * Serves the three health endpoints of contracts/ops/v2/openapi.yaml -- /health,
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
import java.util.stream.Collectors;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.boot.actuate.endpoint.annotation.Selector;
import org.springframework.boot.actuate.endpoint.web.EndpointMediaTypes;
import org.springframework.boot.actuate.endpoint.web.WebEndpointResponse;
import org.springframework.boot.availability.ApplicationAvailability;
import org.springframework.boot.availability.LivenessState;
import org.springframework.context.annotation.Bean;
import org.springframework.stereotype.Component;
import org.springframework.util.MimeType;

/** The org-standard ops health endpoints, served on the internal management port. */
@Component
@Endpoint(id = "opshealth")
public class OpsHealthEndpoint {

  /**
   * The 200 envelope for the two probes. In ops-api v2 only "ok" is ever served —
   * a probe that would have answered "down" answers 503 with an RFC 9457 problem
   * document instead (see {@link Problem} / {@link ReadinessProblem}).
   */
  public record Health(String status) {}

  /**
   * The tri-state aggregate served by /health. {@code components} is omitted entirely
   * when the service declares no dependencies -- an ops-api v1.0 service stays valid.
   */
  @JsonInclude(JsonInclude.Include.NON_NULL)
  public record Aggregate(String status, Map<String, DependencyHealth.Component> components) {}

  /**
   * RFC 9457 problem details (ops-api v2, #1330) -- the liveness 503 body, and the base
   * shape.
   *
   * <p>DELIBERATELY FLAT: {@link ReadinessProblem} repeats these four members rather than
   * composing with {@code allOf}, mirroring the contract's own schemas. See
   * contracts/ops/v2/openapi.yaml for why the composition breaks the org lint rule.
   *
   * <p>An explicit record rather than Spring's {@code ProblemDetail}: that type defaults
   * {@code type} to {@code about:blank} and carries an {@code instance} member the other
   * five payloads do not emit, so it would have to be overridden into this shape anyway.
   */
  public record Problem(String type, String title, int status, String detail) {}

  /** The readiness 503 body: the four members plus the {@code components} extension member. */
  @JsonInclude(JsonInclude.Include.NON_NULL)
  public record ReadinessProblem(
      String type,
      String title,
      int status,
      String detail,
      Map<String, DependencyHealth.Component> components) {}

  /**
   * Problem-type URNs. Host-free on purpose: a shipped service must not carry a
   * documentation URL that rots when the docs site moves.
   */
  static final String PROBLEM_TYPE_NOT_READY = "urn:problem-type:ops:not-ready";

  static final String PROBLEM_TYPE_NOT_ALIVE = "urn:problem-type:ops:not-alive";

  /**
   * The non-dependency unready reasons the contract names, and the liveness wording. A
   * service that is unready for its own reasons cannot tell us which, so it gets the
   * start-up wording -- the overwhelmingly common case, and the one an operator acts on
   * the same way.
   */
  static final String DETAIL_STARTING_UP = "the service is starting up";

  static final String DETAIL_DRAINING = "the service is draining";

  static final String DETAIL_NOT_ALIVE = "the process is not alive and should be restarted";

  private static final MimeType PROBLEM_JSON = MimeType.valueOf("application/problem+json");

  private static final Health OK = new Health("ok");

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
  public WebEndpointResponse<?> probe(@Selector String probe) {
    return switch (probe) {
      case "live" ->
          availability.getLivenessState() == LivenessState.CORRECT
              ? new WebEndpointResponse<>(OK, WebEndpointResponse.STATUS_OK)
              // Liveness is dependency-free BY CONTRACT, so this problem document
              // carries NO extension members -- a components map here would be a lie.
              // Spring is the ONE payload that can actually answer this: the other five
              // are unconditionally 200 on /health/live, because a process that can
              // answer HTTP is alive. Here LivenessState can be BROKEN independently.
              : problem(new Problem(PROBLEM_TYPE_NOT_ALIVE, "Service Not Alive", 503, DETAIL_NOT_ALIVE));
      case "ready" -> readyResponse();
      default -> new WebEndpointResponse<>(WebEndpointResponse.STATUS_NOT_FOUND);
    };
  }

  /**
   * The readiness answer: 200 with the health envelope, or a 503 RFC 9457 problem document
   * carrying the {@code components} extension member (ops-api v2, #1330).
   *
   * <p>The components are read ONCE here and handed to the body. {@link DependencyHealth#ready()}
   * reads them again internally, which is unavoidable without widening that API -- but the
   * BODY at least describes a single snapshot, so the detail and the map cannot disagree
   * with each other.
   */
  private WebEndpointResponse<?> readyResponse() {
    Map<String, DependencyHealth.Component> components = health.components();
    if (health.ready()) {
      return new WebEndpointResponse<>(OK, WebEndpointResponse.STATUS_OK);
    }
    return problem(
        new ReadinessProblem(
            PROBLEM_TYPE_NOT_READY,
            "Service Not Ready",
            503,
            readinessDetail(components),
            components.isEmpty() ? null : components));
  }

  /**
   * Serve the ops endpoints as plain {@code application/json}, which is what
   * contracts/ops/v2/openapi.yaml declares.
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

  /**
   * Wraps an RFC 9457 document in a 503 carrying {@code application/problem+json}.
   *
   * <p>NO SERVLET FILTER IS NEEDED, and none should be added. {@link WebEndpointResponse}
   * takes a {@link MimeType} alongside the status, and Actuator's MVC adapter
   * ({@code AbstractWebMvcEndpointHandlerMapping$ServletWebOperationAdapter#handleResult})
   * turns a non-null one into {@code ResponseEntity.contentType(...)}. Spring MVC then
   * SHORT-CIRCUITS content negotiation on a concrete preset content type -- before it
   * consults the producible types -- so the {@code produces} condition derived from
   * {@link #opsApiEndpointMediaTypes()} governs Accept MATCHING only, never what is
   * written. Jackson's converter already supports {@code application/*+json}.
   *
   * <p>Do NOT widen {@link #opsApiEndpointMediaTypes()} to include problem+json to make
   * this work: that list is the PRODUCED set for the whole ops surface, so widening it
   * would change the negotiated type for {@code /info} and {@code /health} as a side
   * effect. The per-response type is the narrow tool for a per-response problem.
   */
  private static WebEndpointResponse<?> problem(Object body) {
    return new WebEndpointResponse<>(
        body, WebEndpointResponse.STATUS_SERVICE_UNAVAILABLE, PROBLEM_JSON);
  }

  /**
   * Builds the canonical {@code detail} sentence for a readiness 503.
   *
   * <p>The wording is FIXED, not free prose: check-ops-conformance.zsh and the acceptance
   * lane both assert it. Names are sorted LEXICOGRAPHICALLY so the string is deterministic
   * regardless of the order the breakers tripped in.
   *
   * <p>The hinge is spelled exactly as {@link DependencyHealth#ready()} spells it. The two
   * are the SAME predicate: a 503 whose detail named a different set than the verdict used
   * would be worse than no detail at all.
   */
  static String readinessDetail(Map<String, DependencyHealth.Component> components) {
    List<String> down =
        components.entrySet().stream()
            .filter(e -> "hard".equals(e.getValue().kind()) && "down".equals(e.getValue().status()))
            .map(Map.Entry::getKey)
            .sorted()
            .toList();
    if (down.isEmpty()) {
      // No hard dependency is down, so readiness failed for a non-dependency reason:
      // Spring's own ReadinessState is not ACCEPTING_TRAFFIC (starting up, or draining).
      return DETAIL_STARTING_UP;
    }
    String joined = down.stream().map(name -> "'" + name + "'").collect(Collectors.joining(", "));
    return down.size() == 1
        ? "hard dependency " + joined + " is down"
        : "hard dependencies " + joined + " are down";
  }
}
