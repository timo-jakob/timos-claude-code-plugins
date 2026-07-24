/*
 * Canonical ops-api implementation for non-Spring Java services (issue #935, epic #682).
 *
 * The blessed Java realization of the org-standard ops surface defined by
 * contracts/ops/v1/openapi.yaml -- /info, /health, /health/live, /health/ready,
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
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.Executors;
import java.util.function.BooleanSupplier;

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

  /**
   * What the service reports on /info and how readiness is decided.
   *
   * <p>{@code readiness} is the dependency check behind /health/ready (and the /health
   * aggregate) -- the default is always-ready; plug your datastore/downstream check here. Liveness
   * is deliberately NOT configurable: it reflects only that the process is serving, and must never
   * check a dependency (that would turn a transient outage into a pod-restart storm).
   */
  public static final class OpsConfig {
    private final String version;
    private final String gitSha;
    private final List<ApiMajor> servedMajors;
    private final BooleanSupplier readiness;

    public OpsConfig(
        String version, String gitSha, List<ApiMajor> servedMajors, BooleanSupplier readiness) {
      this.version = Objects.requireNonNull(version, "version");
      this.gitSha = Objects.requireNonNull(gitSha, "gitSha");
      this.servedMajors = List.copyOf(servedMajors); // null-checks + defensively copies
      this.readiness = Objects.requireNonNull(readiness, "readiness");
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
      return new OpsConfig(version, gitSha, List.of(majors), readiness);
    }

    public OpsConfig withReadiness(BooleanSupplier readiness) {
      return new OpsConfig(version, gitSha, servedMajors, readiness);
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

    boolean ready() {
      return readiness.getAsBoolean();
    }
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
      server.createContext("/health", readinessHandler(config));
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

  // /health and /health/ready: 200 {"status":"ok"} when the dependency check passes, else 503
  // {"status":"down"}. Liveness never comes here -- it must stay dependency-free.
  private static HttpHandler readinessHandler(OpsConfig config) {
    return exchange -> {
      if (!isGet(exchange)) {
        respond(exchange, 405, "application/json", "{\"error\":\"method not allowed\"}");
        return;
      }
      boolean ready;
      try {
        ready = config.ready();
      } catch (RuntimeException e) {
        // A throwing dependency probe (timeout, SQLException wrapper, ...) degrades to the
        // contract's 503 {"status":"down"} -- never an aborted connection the checker misreads.
        ready = false;
      }
      respond(
          exchange,
          ready ? 200 : 503,
          "application/json",
          ready ? "{\"status\":\"ok\"}" : "{\"status\":\"down\"}");
    };
  }

  // Reverse-proxy GET /metrics to the loopback PrometheusHttpServer, copying its status,
  // Content-Type (e.g. "text/plain; version=0.0.4") and body verbatim.
  private static HttpHandler metricsProxy(URI upstream) {
    return exchange -> {
      if (!isGet(exchange)) {
        respond(exchange, 405, "application/json", "{\"error\":\"method not allowed\"}");
        return;
      }
      HttpURLConnection conn = null;
      boolean headersSent = false;
      try {
        conn = (HttpURLConnection) upstream.toURL().openConnection();
        conn.setRequestMethod("GET");
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(5000);
        String accept = exchange.getRequestHeaders().getFirst("Accept");
        if (accept != null) {
          conn.setRequestProperty("Accept", accept);
        }
        int status = conn.getResponseCode();
        InputStream in = status < 400 ? conn.getInputStream() : conn.getErrorStream();
        byte[] payload = in == null ? new byte[0] : in.readAllBytes();
        String contentType = conn.getContentType();
        if (contentType == null) {
          contentType = "text/plain; version=0.0.4; charset=utf-8";
        }
        exchange.getResponseHeaders().set("Content-Type", contentType);
        headersSent = true;
        exchange.sendResponseHeaders(status, payload.length == 0 ? -1 : payload.length);
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
      } finally {
        if (conn != null) {
          conn.disconnect();
        }
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
