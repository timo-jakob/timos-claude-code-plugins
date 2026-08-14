/*
 * Canonical ops-api implementation for non-Spring Java services (issue #935, epic #682).
 *
 * The blessed Java realization of the org-standard ops surface defined by
 * contracts/ops/v2/openapi.yaml -- /info, /health, /health/live, /health/ready,
 * /metrics -- so a plain (non-Spring) Java service conforms to the same fragment
 * Spring services get via Actuator. It passes scripts/check-ops-conformance.zsh
 * unchanged.
 *
 * Instrumentation is OpenTelemetry ONLY (ARCHITECTURE.md policy): metrics come
 * from the OTel SDK SdkMeterProvider. OTLP push to a collector is the PRIMARY
 * pipeline -- wired here whenever the standard OTEL_EXPORTER_OTLP_ENDPOINT env
 * var is set (honoring OTEL_EXPORTER_OTLP_PROTOCOL = grpc | http/protobuf).
 * /metrics is the mandatory PULL-COMPAT surface, served by the OTel SDK's
 * Prometheus exporter (PrometheusHttpServer) -- a config wiring, not a second
 * metrics system.
 *
 * Why the /metrics reverse-proxy: unlike Python's PrometheusMetricReader (which
 * feeds a registry the app serves itself), OTel Java's Prometheus exporter ships
 * only as PrometheusHttpServer -- a MetricReader that runs its OWN embedded HTTP
 * server and cannot host extra handlers. To present ALL five ops endpoints on a
 * single management port (what check-ops-conformance.zsh is pointed at), we bind
 * PrometheusHttpServer to loopback on an internal port and have the management
 * server proxy GET /metrics to it. The OTel exporter still owns the exposition.
 *
 * DEPENDENCY HEALTH (ops-api v1.1, #1142 / epic #964): /health carries an optional
 * `components` map -- one entry per DIRECT dependency, read PASSIVELY from that
 * dependency's circuit-breaker state -- and a declared HARD dependency being down
 * also fails /health/ready. Wire it with OpsConfig.withDependencies(...); the
 * blessed source is DependencyHealth in the resilience payload beside this one
 * (templates/languages/java/resilience/). Without it this class behaves exactly as
 * before: no `components` field, and readiness is your BooleanSupplier alone. The
 * binding is an INTERFACE over plain records, so this file needs no breaker library
 * on the classpath.
 *
 * NOTE that /health answers 200 even when the aggregate is "down" -- the verdict is
 * in the body. Only the two PROBES (/health/live, /health/ready) speak in status
 * codes. An earlier revision of this template 503'd /health, which the contract
 * forbids and check-ops-conformance.zsh rejects (#1139, Java half).
 *
 * This is an INTERNAL management surface: it binds a separate MANAGEMENT PORT
 * (default 9090), never the public app port, so /info's build data is
 * unreachable from outside without any per-endpoint auth. The network boundary
 * (a NetworkPolicy + a Service that exposes only the app port, and the liveness/
 * readiness probe wiring) is the deployment layer's job (the composition repo).
 *
 * PLACEMENT: copy this file into your service's source set and set the package
 * to match its directory, e.g.
 *   src/main/java/com/acme/orders/ops/OpsApi.java  ->  package com.acme.orders.ops;
 * then fold the dependencies from build.gradle.kts (beside this file) into your
 * build, and call OpsApi.serve(...) from your service's startup with your real
 * OpsConfig. Declare the API majors your service serves via OpsConfig.servedMajors
 * -- the /info lifecycle table is what makes the epic #684 deprecation machinery
 * observable.
 *
 * Requires: opentelemetry-sdk, opentelemetry-exporter-prometheus,
 * opentelemetry-exporter-otlp (see build.gradle.kts beside this file).
 */
package com.example.ops; // <-- CHANGE to match the directory you place this file in.

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import io.opentelemetry.exporter.otlp.http.metrics.OtlpHttpMetricExporter;
import io.opentelemetry.exporter.otlp.metrics.OtlpGrpcMetricExporter;
import io.opentelemetry.exporter.prometheus.PrometheusHttpServer;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.metrics.SdkMeterProvider;
import io.opentelemetry.sdk.metrics.SdkMeterProviderBuilder;
import io.opentelemetry.sdk.metrics.export.MetricExporter;
import io.opentelemetry.sdk.metrics.export.PeriodicMetricReader;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.StringJoiner;
import java.util.concurrent.Executors;
import java.util.function.BooleanSupplier;
import java.util.function.Supplier;

/** The org-standard ops surface (/info, /health*, /metrics) for a non-Spring Java service. */
public final class OpsApi {

  /** A served API major's lifecycle state (mirrors the fragment's ApiMajor.lifecycle enum). */
  public enum Lifecycle {
    ACTIVE("active"),
    DEPRECATED("deprecated");

    private final String wire;

    Lifecycle(String wire) {
      this.wire = wire;
    }

    String wire() {
      return wire;
    }
  }

  /**
   * One served API major and its lifecycle (mirrors the fragment's ApiMajor). A DEPRECATED major
   * MUST carry a {@code sunset} date (RFC 8594); an ACTIVE one MUST NOT need one -- the constructor
   * enforces that invariant so a malformed lifecycle table can never reach /info.
   */
  public record ApiMajor(int major, Lifecycle lifecycle, String sunset) {
    public ApiMajor {
      if (major < 1) {
        throw new IllegalArgumentException("major must be an integer >= 1, got " + major);
      }
      Objects.requireNonNull(lifecycle, "lifecycle");
      if (lifecycle == Lifecycle.DEPRECATED && (sunset == null || sunset.isBlank())) {
        throw new IllegalArgumentException(
            "deprecated major " + major + " needs a sunset date (RFC 8594)");
      }
      if (lifecycle == Lifecycle.ACTIVE && sunset != null) {
        throw new IllegalArgumentException(
            "active major " + major + " must not carry a sunset date");
      }
    }

    /** An active major (no sunset). */
    public static ApiMajor active(int major) {
      return new ApiMajor(major, Lifecycle.ACTIVE, null);
    }

    /** A deprecated major with its RFC 8594 sunset date (ISO-8601, e.g. 2027-01-31). */
    public static ApiMajor deprecated(int major, String sunset) {
      return new ApiMajor(major, Lifecycle.DEPRECATED, sunset);
    }
  }

  /** The /health aggregate, worst-first so {@link #max} can compare two of them by ordinal. */
  public enum Status {
    OK("ok"),
    DEGRADED("degraded"),
    DOWN("down");

    private final String wire;

    Status(String wire) {
      this.wire = wire;
    }

    String wire() {
      return wire;
    }

    static Status max(Status a, Status b) {
      return a.ordinal() >= b.ordinal() ? a : b;
    }
  }

  /**
   * One DIRECT dependency's health, as the ops-api v1.1 {@code components} map reports it
   * (#1142, epic #964).
   *
   * @param status up | degraded | down -- read from the dependency's circuit breaker
   * @param kind hard | soft -- the readiness hinge
   * @param breaker closed | open | half_open -- the state the status was read from
   * @param since RFC 3339 timestamp of the last state change, so a dashboard can tell a blip
   *     from a sustained outage
   */
  public record Dependency(String status, String kind, String breaker, String since) {}

  /**
   * Supplies the per-direct-dependency health that /health reports under {@code components}.
   *
   * <p>Deliberately an interface over plain data rather than a dependency on a breaker library:
   * this class stays importable by a service that has no outbound dependencies at all. The
   * blessed implementation is {@code DependencyHealth} in the resilience payload
   * (templates/languages/java/resilience/), which derives these entries PASSIVELY from
   * resilience4j breaker state -- an open breaker IS a down dependency.
   *
   * <p>DIRECT dependencies only. A service reports the one hop it calls itself and never
   * transitively calls a downstream's /health (the health-check-storm anti-pattern).
   */
  @FunctionalInterface
  public interface DependencyHealthSource {
    /** One entry per direct dependency, keyed by its stable name, in declaration order. */
    Map<String, Dependency> components();
  }

  /**
   * What the service reports on /info, and how the two health verdicts are decided.
   *
   * <p>{@code readiness} is the NON-dependency half of the readiness answer -- still starting up,
   * draining during a graceful shutdown, an internal resource exhausted. The default is
   * always-ready. The DEPENDENCY half comes from {@code dependencies}: a declared HARD dependency
   * being down also fails readiness, while a SOFT one never does. Liveness is deliberately NOT
   * configurable: it reflects only that the process is serving, and must never check a dependency
   * (that would turn a transient outage into a pod-restart storm).
   *
   * <p>{@code internalStatus} is the over-reporting hook the contract requires: the components
   * set a FLOOR on the /health aggregate, never an equality, so a service impaired for a reason
   * no dependency models (a backed-up work queue, a full disk) MUST report a MORE severe
   * aggregate than its dependencies imply. Reporting a LESS severe one is a conformance failure.
   */
  public static final class OpsConfig {
    private final String version;
    private final String gitSha;
    private final List<ApiMajor> servedMajors;
    private final BooleanSupplier readiness;
    private final DependencyHealthSource dependencies;
    private final Supplier<Status> internalStatus;

    public OpsConfig(
        String version, String gitSha, List<ApiMajor> servedMajors, BooleanSupplier readiness) {
      this(version, gitSha, servedMajors, readiness, Map::of, () -> Status.OK);
    }

    private OpsConfig(
        String version,
        String gitSha,
        List<ApiMajor> servedMajors,
        BooleanSupplier readiness,
        DependencyHealthSource dependencies,
        Supplier<Status> internalStatus) {
      this.version = Objects.requireNonNull(version, "version");
      this.gitSha = Objects.requireNonNull(gitSha, "gitSha");
      this.servedMajors = List.copyOf(servedMajors); // null-checks + defensively copies
      this.readiness = Objects.requireNonNull(readiness, "readiness");
      this.dependencies = Objects.requireNonNull(dependencies, "dependencies");
      this.internalStatus = Objects.requireNonNull(internalStatus, "internalStatus");
    }

    /**
     * The default config: build metadata from the BUILD_VERSION / GIT_SHA env vars (as the CI build
     * sets them), a single active major 1, and always-ready. Override for your real service.
     */
    public static OpsConfig defaults() {
      return new OpsConfig(
          envOr("BUILD_VERSION", "0.0.0"),
          envOr("GIT_SHA", "unknown"),
          List.of(ApiMajor.active(1)),
          () -> true);
    }

    public OpsConfig withServedMajors(ApiMajor... majors) {
      return new OpsConfig(
          version, gitSha, List.of(majors), readiness, dependencies, internalStatus);
    }

    public OpsConfig withReadiness(BooleanSupplier readiness) {
      return new OpsConfig(
          version, gitSha, servedMajors, readiness, dependencies, internalStatus);
    }

    /**
     * Report per-direct-dependency health on /health, and let a HARD dependency being down fail
     * /health/ready (#1142). Wire the resilience payload's {@code DependencyHealth} here.
     */
    public OpsConfig withDependencies(DependencyHealthSource dependencies) {
      return new OpsConfig(
          version, gitSha, servedMajors, readiness, dependencies, internalStatus);
    }

    /** Raise the /health aggregate for an internal impairment no dependency models. */
    public OpsConfig withInternalStatus(Supplier<Status> internalStatus) {
      return new OpsConfig(
          version, gitSha, servedMajors, readiness, dependencies, internalStatus);
    }

    String infoJson() {
      StringBuilder api = new StringBuilder("[");
      for (int i = 0; i < servedMajors.size(); i++) {
        ApiMajor m = servedMajors.get(i);
        if (i > 0) {
          api.append(',');
        }
        api.append("{\"major\":").append(m.major());
        api.append(",\"lifecycle\":").append(jsonString(m.lifecycle().wire()));
        if (m.sunset() != null) {
          api.append(",\"sunset\":").append(jsonString(m.sunset()));
        }
        api.append('}');
      }
      api.append(']');
      return "{\"build\":{\"version\":"
          + jsonString(version)
          + ",\"git_sha\":"
          + jsonString(gitSha)
          + "},\"api\":"
          + api
          + "}";
    }

    /**
     * One snapshot of the dependency view, taken once per request. Both /health's aggregate and
     * its components map are derived from the SAME snapshot, so a breaker that flips mid-request
     * can never produce a body whose headline contradicts its own component list.
     */
    Map<String, Dependency> components() {
      Map<String, Dependency> snapshot = dependencies.components();
      return snapshot == null ? Map.of() : snapshot;
    }

    /**
     * The readiness answer behind /health/ready.
     *
     * <p>Among dependencies, only a declared HARD one being DOWN makes the service unready -- a
     * soft dependency down keeps the pod ready and serving degraded responses. Non-dependency
     * reasons still apply and are checked first.
     */
    boolean ready(Map<String, Dependency> components) {
      if (!readiness.getAsBoolean()) {
        return false;
      }
      return components.values().stream()
          .noneMatch(d -> "hard".equals(d.kind()) && "down".equals(d.status()));
    }

    /**
     * The aggregate served by /health: the worse of this service's own internal state and the
     * FLOOR its dependencies impose -- "down" if any HARD dependency is down, else "degraded" if
     * ANY dependency is down or degraded, else "ok".
     *
     * <p>Note the hard/degraded case: a HARD dependency that is merely half-open reads
     * "degraded", not down, so it floors the aggregate at "degraded".
     */
    Status aggregate(Map<String, Dependency> components) {
      Status status = internalStatus.get();
      if (status == null) {
        status = Status.OK;
      }
      for (Dependency d : components.values()) {
        boolean down = "down".equals(d.status());
        if (down && "hard".equals(d.kind())) {
          status = Status.max(status, Status.DOWN);
        } else if (down || "degraded".equals(d.status())) {
          status = Status.max(status, Status.DEGRADED);
        }
      }
      return status;
    }

    /**
     * The /health body: the aggregate, plus `components` only when there are any. A service that
     * declares no dependencies omits the field entirely and stays a valid ops-api v1.0 response.
     */
    String healthJson(Map<String, Dependency> components) {
      StringBuilder json =
          new StringBuilder("{\"status\":").append(jsonString(aggregate(components).wire()));
      appendComponents(json, components);
      return json.append('}').toString();
    }

    /**
     * The readiness 503 body: RFC 9457 problem details plus the {@code components} extension
     * member (ops-api v2, #1330).
     *
     * <p>RFC 9457's {@code status} is the HTTP code as an INTEGER, which collides head-on with the
     * health envelope's {@code "ok"}/{@code "down"} string -- so the health string is gone from the
     * 503 (503 already says "down") and the diagnosis rides in {@code components} instead.
     */
    String readinessProblemJson(Map<String, Dependency> components) {
      StringBuilder json = new StringBuilder("{\"type\":").append(jsonString(PROBLEM_TYPE_NOT_READY));
      json.append(",\"title\":").append(jsonString(PROBLEM_TITLE_NOT_READY));
      json.append(",\"status\":503");
      json.append(",\"detail\":").append(jsonString(readinessDetail(components)));
      appendComponents(json, components);
      return json.append('}').toString();
    }

    /**
     * Appends {@code ,"components":{...}} when there are any -- the ONE serializer both the
     * /health aggregate and the readiness problem use, so a shed pod and the dashboard cannot
     * disagree about a dependency's shape.
     */
    private static void appendComponents(StringBuilder json, Map<String, Dependency> components) {
      if (components.isEmpty()) {
        return;
      }
      json.append(",\"components\":{");
      boolean first = true;
      for (Map.Entry<String, Dependency> entry : components.entrySet()) {
        if (!first) {
          json.append(',');
        }
        first = false;
        Dependency d = entry.getValue();
        json.append(jsonString(entry.getKey())).append(":{");
        json.append("\"status\":").append(jsonString(d.status()));
        json.append(",\"kind\":").append(jsonString(d.kind()));
        if (d.breaker() != null) {
          json.append(",\"breaker\":").append(jsonString(d.breaker()));
        }
        if (d.since() != null) {
          json.append(",\"since\":").append(jsonString(d.since()));
        }
        json.append('}');
      }
      json.append('}');
    }
  }

  /**
   * RFC 9457 problem-type URNs (ops-api v2, #1330).
   *
   * <p>Host-free on purpose: a shipped service must not carry a documentation URL that rots when
   * the docs site moves.
   */
  static final String PROBLEM_TYPE_NOT_READY = "urn:problem-type:ops:not-ready";

  static final String PROBLEM_TYPE_NOT_ALIVE = "urn:problem-type:ops:not-alive";

  static final String PROBLEM_TITLE_NOT_READY = "Service Not Ready";

  /**
   * The two non-dependency unready reasons the contract names. A service that is unready for its
   * own reasons cannot tell us which, so it gets the start-up wording -- the overwhelmingly common
   * case, and the one an operator acts on the same way.
   */
  static final String DETAIL_STARTING_UP = "the service is starting up";

  static final String DETAIL_DRAINING = "the service is draining";

  /**
   * Builds the canonical {@code detail} sentence for a readiness 503.
   *
   * <p>The wording is FIXED, not free prose: check-ops-conformance.zsh and the acceptance lane both
   * assert it. Names are sorted LEXICOGRAPHICALLY so the string is deterministic regardless of the
   * order the breakers tripped in -- without the sort the same outage would produce different
   * bodies on different pods and no assertion could pin it.
   */
  static String readinessDetail(Map<String, Dependency> components) {
    // Literals rather than named constants, matching OpsConfig.ready, which spells the same hinge
    // `"hard".equals(d.kind()) && "down".equals(d.status())`. The two are the SAME predicate and
    // must stay in step: a 503 whose detail named a different set than the verdict used would be
    // worse than no detail at all.
    List<String> down = new ArrayList<>();
    for (Map.Entry<String, Dependency> entry : components.entrySet()) {
      Dependency d = entry.getValue();
      if ("hard".equals(d.kind()) && "down".equals(d.status())) {
        down.add(entry.getKey());
      }
    }
    if (down.isEmpty()) {
      return DETAIL_STARTING_UP;
    }
    Collections.sort(down);
    StringJoiner joined = new StringJoiner(", ");
    for (String name : down) {
      joined.add("'" + name + "'");
    }
    return down.size() == 1
        ? "hard dependency " + joined + " is down"
        : "hard dependencies " + joined + " are down";
  }

  private OpsApi() {}

  /**
   * Run the ops surface on the MANAGEMENT port (default 9090 -- never the public app port). Binds
   * all interfaces so the kubelet's probes and the ops-conformance job can reach it; the network
   * boundary is enforced by the deployment (NetworkPolicy + a Service that omits this port).
   */
  public static HttpServer serve(String host, int managementPort, OpsConfig config)
      throws IOException {
    // OTel SDK is the single instrumentation source. /metrics is served by the OTel Prometheus
    // exporter bound to loopback on an internal port; the management server proxies to it (see the
    // file header). OTLP push is the primary pipeline -- wired when its endpoint is configured.
    int prometheusPort = intEnvOr("OPS_PROMETHEUS_PORT", managementPort + 1);
    SdkMeterProvider meterProvider = installMetrics(prometheusPort);
    URI metricsUpstream = URI.create("http://127.0.0.1:" + prometheusPort + "/metrics");

    HttpServer server;
    try {
      server = HttpServer.create(new InetSocketAddress(host, managementPort), 0);
      // A dedicated executor so a slow /metrics proxy scrape never queues behind (or starves) the
      // liveness/readiness probes on the server's single dispatcher thread.
      server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
      server.createContext("/info", jsonHandler(200, config::infoJson));
      server.createContext("/health/live", jsonHandler(200, () -> "{\"status\":\"ok\"}"));
      server.createContext("/health/ready", readinessHandler(config));
      server.createContext("/health", healthHandler(config));
      server.createContext("/metrics", metricsProxy(metricsUpstream));
      server.start();
    } catch (IOException | RuntimeException e) {
      // Don't leak the loopback PrometheusHttpServer if the management port is already in use.
      meterProvider.close();
      throw e;
    }

    // Only after the surface is actually up: claim the OTel global (best-effort -- a service
    // already running the javaagent or SDK autoconfigure has one, and buildAndRegisterGlobal
    // would throw; keep the existing one, our meterProvider still backs /metrics), and wire
    // orderly shutdown so the loopback PrometheusHttpServer, OTLP reader and executor don't
    // linger past process exit.
    try {
      OpenTelemetrySdk.builder().setMeterProvider(meterProvider).buildAndRegisterGlobal();
    } catch (IllegalStateException alreadyRegistered) {
      // a global OpenTelemetry is already installed; leave it in place.
    }
    HttpServer started = server;
    Runtime.getRuntime()
        .addShutdownHook(
            new Thread(
                () -> {
                  started.stop(0);
                  meterProvider.close();
                }));
    return server;
  }

  /**
   * Wire the OTel SDK MeterProvider. The Prometheus exporter (loopback, internal port) serves the
   * pull-compat /metrics; when OTEL_EXPORTER_OTLP_ENDPOINT is set, an OTLP push reader is added as
   * the primary pipeline. The OTel SDK is the single instrumentation source either way.
   */
  private static SdkMeterProvider installMetrics(int prometheusPort) {
    SdkMeterProviderBuilder builder =
        SdkMeterProvider.builder()
            .registerMetricReader(
                PrometheusHttpServer.builder()
                    .setHost("127.0.0.1")
                    .setPort(prometheusPort)
                    .build());
    MetricExporter otlp = otlpExporterFromEnv();
    if (otlp != null) {
      builder.registerMetricReader(PeriodicMetricReader.create(otlp));
    }
    return builder.build();
  }

  /**
   * The OTLP push exporter (primary pipeline), built from the standard OTel env vars when an
   * endpoint is configured. Honors OTEL_EXPORTER_OTLP_PROTOCOL (grpc default, or http/protobuf) and
   * never aborts serve() on a malformed endpoint -- a bad value logs and skips the push reader,
   * leaving the pull-compat /metrics surface intact. Returns null when no endpoint is set.
   */
  private static MetricExporter otlpExporterFromEnv() {
    String endpoint = System.getenv("OTEL_EXPORTER_OTLP_ENDPOINT");
    if (endpoint == null || endpoint.isBlank()) {
      return null;
    }
    String protocol = envOr("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc").trim();
    try {
      return switch (protocol) {
        // gRPC takes OTEL_EXPORTER_OTLP_ENDPOINT (a base URL) verbatim.
        case "grpc" -> OtlpGrpcMetricExporter.builder().setEndpoint(endpoint).build();
        case "http/protobuf" -> {
          // The generic OTEL_EXPORTER_OTLP_ENDPOINT is a BASE url for HTTP; the exporter needs the
          // full signal URL, so append /v1/metrics (as SDK autoconfigure does) unless the operator
          // already gave a signal-specific URL. Without this, every push 404s at the collector
          // root.
          String base = endpoint.replaceAll("/+$", "");
          String httpEndpoint = base.endsWith("/v1/metrics") ? base : base + "/v1/metrics";
          yield OtlpHttpMetricExporter.builder().setEndpoint(httpEndpoint).build();
        }
        // An unsupported/typo'd protocol must be LOUD, never a silent gRPC fallback that pushes
        // into the void; skip the push reader and keep the pull-compat /metrics surface.
        default -> {
          System.err.println(
              "ops-api: unsupported OTEL_EXPORTER_OTLP_PROTOCOL '"
                  + protocol
                  + "' (want grpc | http/protobuf) -- OTLP push disabled");
          yield null;
        }
      };
    } catch (RuntimeException e) {
      System.err.println(
          "ops-api: ignoring OTLP push exporter -- invalid OTEL_EXPORTER_OTLP_ENDPOINT '"
              + endpoint
              + "' ("
              + e.getMessage()
              + ")");
      return null;
    }
  }

  // ---- handlers --------------------------------------------------------------

  private interface JsonBody {
    String get();
  }

  private static HttpHandler jsonHandler(int code, JsonBody body) {
    return exchange -> {
      if (!isGet(exchange)) {
        respond(exchange, 405, "application/json", "{\"error\":\"method not allowed\"}");
        return;
      }
      respond(exchange, code, "application/json", body.get());
    };
  }

  // /health/ready: 200 {"status":"ok"} when the readiness check AND every declared HARD
  // dependency pass, else 503 with an RFC 9457 problem
  // document on application/problem+json (type/title/integer status/detail, plus
  // the components extension member). Liveness never comes here -- it must stay
  // dependency-free. The two PROBES are where 503 belongs; /health is not one (see healthHandler).
  private static HttpHandler readinessHandler(OpsConfig config) {
    return exchange -> {
      if (!isGet(exchange)) {
        respond(exchange, 405, "application/json", "{\"error\":\"method not allowed\"}");
        return;
      }
      boolean ready;
      // Snapshot ONCE and reuse it for both the verdict and the problem body. Calling
      // components() again to build the body would re-enter the service's dependency source,
      // which can return a different map -- the 503 would then name a dependency the verdict
      // was not actually taken on.
      Map<String, Dependency> components = Map.of();
      try {
        components = config.components();
        ready = config.ready(components);
      } catch (RuntimeException e) {
        // A throwing dependency probe (timeout, SQLException wrapper, ...) degrades to the
        // contract's 503 -- never an aborted connection the checker misreads. The snapshot is
        // reset so a half-read map cannot reach the problem body.
        ready = false;
        components = Map.of();
      }
      if (ready) {
        respond(exchange, 200, "application/json", "{\"status\":\"ok\"}");
        return;
      }
      // ops-api v2 (#1330): an RFC 9457 problem document on application/problem+json. The media
      // type is part of the contract, not a detail -- org-problem-json-errors requires the 4xx/5xx
      // body to be BARE problem+json, so a correctly shaped body on application/json would still
      // be a conformance failure.
      String body;
      try {
        body = config.readinessProblemJson(components);
      } catch (RuntimeException e) {
        // Serializing reads source-provided values, so it can fail after the verdict is taken.
        // The fallback stays a VALID problem document rather than a health-shaped one.
        body =
            "{\"type\":\"" + PROBLEM_TYPE_NOT_READY + "\",\"title\":\"" + PROBLEM_TITLE_NOT_READY
                + "\",\"status\":503,\"detail\":\""
                + "the readiness problem document could not be serialized\"}";
      }
      respond(exchange, 503, "application/problem+json", body);
    };
  }

  // /health: the human/dashboard-facing aggregate, plus per-direct-dependency `components`
  // (ops-api v1.1, #1142). It answers 200 WHENEVER THE PROCESS CAN RESPOND AT ALL -- including
  // when the aggregate is "down". The verdict rides in the BODY: an operator reading this during
  // an outage needs the diagnosis, and a 503 here is an unreadable page exactly when it matters.
  // HTTP status codes are the two probes' vocabulary, which is why only they document a 503.
  private static HttpHandler healthHandler(OpsConfig config) {
    return exchange -> {
      if (!isGet(exchange)) {
        respond(exchange, 405, "application/json", "{\"error\":\"method not allowed\"}");
        return;
      }
      String body;
      try {
        body = config.healthJson(config.components());
      } catch (RuntimeException e) {
        // A throwing dependency-health source is itself a fault, and reporting "ok" (or an empty
        // 200) would be the under-reporting the contract forbids. Say "down" -- still a 200, so
        // the answer stays readable.
        body = "{\"status\":\"down\"}";
      }
      respond(exchange, 200, "application/json", body);
    };
  }

  // Reverse-proxy GET /metrics to the loopback PrometheusHttpServer, copying its status,
  // Content-Type (e.g. "text/plain; version=0.0.4") and body verbatim.
  //
  // java.net.http.HttpClient, NOT HttpURLConnection, and the reason is the executor above.
  // HttpURLConnection performs its blocking network I/O inside `synchronized` methods, which on
  // JDK 21 PINS the carrier thread for the whole read (JEP 491 only removes that in 24). The
  // virtual-thread scheduler's parallelism defaults to availableProcessors, so on a 1-CPU pod a
  // single slow scrape would block every other virtual thread -- including /health/live and
  // /health/ready, i.e. exactly the starvation the dedicated executor was added to prevent, with
  // a kubelet restart as the payoff. HttpClient parks the virtual thread instead of pinning it.
  private static HttpHandler metricsProxy(URI upstream) {
    HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
    return exchange -> {
      if (!isGet(exchange)) {
        respond(exchange, 405, "application/json", "{\"error\":\"method not allowed\"}");
        return;
      }
      boolean headersSent = false;
      try {
        HttpRequest.Builder request =
            HttpRequest.newBuilder(upstream).timeout(Duration.ofSeconds(5)).GET();
        String accept = exchange.getRequestHeaders().getFirst("Accept");
        if (accept != null) {
          request.header("Accept", accept);
        }
        HttpResponse<byte[]> response =
            client.send(request.build(), HttpResponse.BodyHandlers.ofByteArray());
        byte[] payload = response.body() == null ? new byte[0] : response.body();
        String contentType =
            response
                .headers()
                .firstValue("Content-Type")
                .orElse("text/plain; version=0.0.4; charset=utf-8");
        exchange.getResponseHeaders().set("Content-Type", contentType);
        exchange.sendResponseHeaders(response.statusCode(), payload.length == 0 ? -1 : payload.length);
        // Set only AFTER the headers are actually on the wire: flagging it before the call would
        // skip the 502 below for a failure that happened before anything was sent.
        headersSent = true;
        try (OutputStream out = exchange.getResponseBody()) {
          out.write(payload);
        }
      } catch (IOException e) {
        // Only a pre-commit failure can still send the 502 -- once headers are on the wire (client
        // gone mid-scrape) a second sendResponseHeaders would throw, so we let the connection drop.
        if (!headersSent) {
          respond(
              exchange, 502, "application/json", "{\"error\":\"metrics upstream unavailable\"}");
        }
      } catch (InterruptedException e) {
        // ORDER MATTERS, and the obvious order is wrong. The flag must be restored -- else a
        // graceful shutdown hangs on a scrape of a wedged exporter -- but restoring it FIRST
        // makes this 502 dead code: the httpserver writes through an interruptible
        // SocketChannel whose begin() checks the thread's interrupt status, so the first header
        // write throws ClosedByInterruptException. That is an IOException raised INSIDE the
        // InterruptedException arm, where the sibling catch does not apply, so it escapes the
        // handler and the server logs an unhandled-handler error on every drained scrape.
        // So: attempt the 502 first, restore the flag in a finally where it cannot be lost, and
        // swallow the write failure -- by then there is nobody left to tell.
        try {
          if (!headersSent) {
            try {
              respond(
                  exchange, 502, "application/json", "{\"error\":\"metrics upstream unavailable\"}");
            } catch (IOException ignored) {
              // client or channel already gone
            }
          }
        } finally {
          Thread.currentThread().interrupt();
        }
      } finally {
        // Idempotent, and the swallowed client-gone-mid-scrape path above reaches no body stream,
        // so without this those exchanges accumulate half-closed until the idle sweeper notices.
        exchange.close();
      }
    };
  }

  private static boolean isGet(HttpExchange exchange) {
    return "GET".equalsIgnoreCase(exchange.getRequestMethod());
  }

  private static void respond(HttpExchange exchange, int code, String contentType, String body)
      throws IOException {
    byte[] payload = body.getBytes(StandardCharsets.UTF_8);
    exchange.getResponseHeaders().set("Content-Type", contentType);
    exchange.sendResponseHeaders(code, payload.length);
    try (OutputStream out = exchange.getResponseBody()) {
      out.write(payload);
    }
  }

  // ---- small helpers ---------------------------------------------------------

  private static String envOr(String name, String fallback) {
    String v = System.getenv(name);
    return (v == null || v.isBlank()) ? fallback : v;
  }

  private static int intEnvOr(String name, int fallback) {
    String v = System.getenv(name);
    if (v == null || v.isBlank()) {
      return fallback;
    }
    try {
      return Integer.parseInt(v.trim());
    } catch (NumberFormatException e) {
      return fallback;
    }
  }

  // Minimal RFC 8259 JSON string escaping -- the payloads are tiny and controlled, so a full JSON
  // library is an unnecessary dependency (mirrors the Python template's stdlib-json posture).
  private static String jsonString(String s) {
    StringBuilder sb = new StringBuilder(s.length() + 2).append('"');
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      switch (c) {
        case '"' -> sb.append("\\\"");
        case '\\' -> sb.append("\\\\");
        case '\n' -> sb.append("\\n");
        case '\r' -> sb.append("\\r");
        case '\t' -> sb.append("\\t");
        default -> {
          if (c < 0x20) {
            sb.append(String.format("\\u%04x", (int) c));
          } else {
            sb.append(c);
          }
        }
      }
    }
    return sb.append('"').toString();
  }

  /**
   * Runs the ops surface with the default config on the management port (OPS_PORT, default 9090).
   * This is a TEMPLATE SMOKE-RUN of the shipped defaults (a single active major) -- it proves
   * nothing about your service. Verify your REAL service by calling serve(...) with your OpsConfig
   * from the service entrypoint, then running check-ops-conformance.zsh (see README).
   */
  public static void main(String[] args) throws IOException {
    serve("0.0.0.0", intEnvOr("OPS_PORT", 9090), OpsConfig.defaults());
  }
}
