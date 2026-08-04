/*
 * The hard/soft declaration and the six-mandate call wrapper, for NON-Spring Java
 * (#1142, epic #964).
 *
 * This class is the whole resilience scaffolding: it owns the declared direct
 * dependencies, the circuit breaker and retry that protect each one, and the
 * `call` wrapper every governed outbound call goes through. DependencyHealth
 * reads the breakers it creates; nothing else has to know they exist.
 *
 * WHY THE DECLARATION LIVES IN A FILE AND NOT IN CODE: hard-vs-soft is an
 * OPERATIONAL judgement that changes without the code changing (a cache that was
 * optional becomes load-bearing), and a reviewer can audit the whole dependency
 * set by reading one short file. Spring services declare the same thing under
 * `resilience.dependencies` in application.yml; this is the plain-Java spelling of
 * it, with no configuration framework required.
 *
 * PLACEMENT: copy into your service's source set and set the package to match its
 * directory, e.g. src/main/java/com/acme/orders/ops/DependencyCatalog.java ->
 * package com.acme.orders.ops;
 */
package com.example.ops; // <-- CHANGE to match the directory you place this file in.

import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.core.IntervalFunction;
import io.github.resilience4j.retry.Retry;
import io.github.resilience4j.retry.RetryConfig;
import io.github.resilience4j.retry.RetryRegistry;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Function;
import java.util.function.Supplier;

/**
 * The service's declared direct dependencies, each with the circuit breaker and retry that
 * protect it.
 *
 * <p>DIRECT dependencies only. A service reports the one hop it calls itself and never
 * transitively calls a downstream's {@code /health} -- that is the health-check-storm
 * anti-pattern, where one slow leaf hangs every ancestor's health check.
 */
public final class DependencyCatalog {

  /** The declaration file read from the classpath when no explicit path is given. */
  public static final String DEFAULT_RESOURCE = "resilience-dependencies.properties";

  /** Env var pointing at a declaration file on disk (a mounted ConfigMap, typically). */
  public static final String FILE_ENV = "OPS_DEPENDENCIES_FILE";

  /**
   * Thrown by a guarded call for something that is NOT the dependency's fault -- a caller
   * mistake (a malformed argument, a 4xx for a resource that legitimately does not exist), or
   * a local cancellation such as an interrupt during shutdown.
   *
   * <p>It is ignored by BOTH the retry and the breaker, which is the whole point. Without such
   * a type every exception a call throws is a dependency failure, so a burst of user-driven
   * 404s -- or a drain that interrupts in-flight work -- opens the breaker on a dependency
   * that never failed; {@code /health} then reports it {@code down}, and if it is declared
   * {@code hard}, readiness sheds all traffic from a perfectly healthy pod.
   *
   * <p>Retrying these is equally wrong: they cannot succeed on repeat, so the attempts only
   * burn the backoff schedule. An interrupt is worse still -- the retry's backoff sleeps, and
   * {@link Thread#sleep} on a thread whose interrupt flag is set throws immediately AND CLEARS
   * that flag, silently discarding the cancellation.
   */
  public static final class NotADependencyFailure extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public NotADependencyFailure(String message) {
      super(message);
    }

    public NotADependencyFailure(String message, Throwable cause) {
      super(message, cause);
    }
  }

  /** How a dependency's loss affects readiness. */
  public enum Kind {
    /** Nothing works without it: its loss fails /health/ready. */
    HARD,
    /** Degraded operation is possible: its loss never fails readiness. */
    SOFT;

    static Kind parse(String raw, String name) {
      return switch (raw.trim().toLowerCase(Locale.ROOT)) {
        case "hard" -> HARD;
        case "soft" -> SOFT;
        default ->
            throw new IllegalArgumentException(
                "dependency '" + name + "' has kind '" + raw + "' (want hard|soft)");
      };
    }

    /** The contract's lower-case spelling, as the /health components map reports it. */
    public String wire() {
      return name().toLowerCase(Locale.ROOT);
    }
  }

  /**
   * The blessed breaker settings. Every dependency gets its OWN CircuitBreaker instance from
   * this one config -- one breaker per dependency is mandate 2, and it is also what makes the
   * ops-api {@code components} map meaningful (a shared breaker could only ever report one
   * verdict for everything behind it).
   *
   * <p>{@code automaticTransitionFromOpenToHalfOpenEnabled} is MANDATE 5, background
   * reconnect: without it a breaker leaves OPEN only when a call arrives after the wait
   * duration, so a dependency that lost all its traffic while down stays reported down until
   * something happens to call it. With it, the breaker schedules its own transition to
   * HALF_OPEN and recovery is visible on /health with no traffic and no deploy. It needs no
   * scheduler of your own -- the circuitbreaker module runs one internally.
   *
   * <p>THE SLOW-CALL THRESHOLDS ARE NOT OPTIONAL, and their absence is invisible. A dependency
   * in the classic brownout -- accepting connections and answering in 2.9s, never erroring --
   * produces a 0% failure rate, so a breaker without them never opens: every request blocks
   * for the full retry schedule, the registered fallback never fires, and /health reports the
   * dependency {@code up} for the entire event. resilience4j's default threshold is 60s, which
   * a sane transport timeout guarantees is never reached, so the default is effectively "off".
   * KEEP THIS BELOW YOUR CLIENT'S PER-REQUEST TIMEOUT (2s here vs the worked client's 3s), or
   * the transport gives up before a call is ever recorded as slow. This mirrors the Spring
   * payload's slow-call-duration-threshold / slow-call-rate-threshold.
   */
  public static final CircuitBreakerConfig BREAKER_CONFIG =
      CircuitBreakerConfig.custom()
          .slidingWindowType(CircuitBreakerConfig.SlidingWindowType.COUNT_BASED)
          .slidingWindowSize(20)
          .minimumNumberOfCalls(10)
          .failureRateThreshold(50f)
          .slowCallDurationThreshold(Duration.ofSeconds(2))
          .slowCallRateThreshold(100f)
          .waitDurationInOpenState(Duration.ofSeconds(10))
          .permittedNumberOfCallsInHalfOpenState(3)
          .automaticTransitionFromOpenToHalfOpenEnabled(true)
          .ignoreExceptions(CallNotPermittedException.class, NotADependencyFailure.class)
          .build();

  /**
   * The blessed retry settings -- MANDATE 3, bounded retry with jittered backoff.
   *
   * <p>BOUNDED: {@code maxAttempts(3)} is the whole call budget (one try plus two retries),
   * not three retries. JITTERED: {@code ofExponentialRandomBackoff} multiplies the interval by
   * 2 each attempt and randomizes it by +/-50%, so a dependency coming back up is not hit by
   * every client's retry at the same instant -- the thundering herd that turns a recovery into
   * a second outage.
   *
   * <p>The interval is CAPPED at 2s. At the shipped {@code maxAttempts(3)} the waits are only
   * ~200ms and ~400ms so the cap never binds today -- it is here because this is a template
   * adopters tune, and raising attempts to 6 without a ceiling silently parks a request thread
   * on a ~6.4s final wait. The Spring payload caps it the same way
   * ({@code exponential-max-wait-duration}).
   *
   * <p>{@code ignoreExceptions} is load-bearing and its absence fails SILENTLY. Retry is the
   * OUTER decorator (see {@link #call}), so without {@link CallNotPermittedException} an open
   * breaker's instant rejection is itself retried -- burning the full backoff schedule on a
   * dependency already known to be down, which is exactly the parked-caller behaviour mandate
   * 6 forbids. {@link NotADependencyFailure} is ignored for the mirror reason: a caller error
   * or a cancellation cannot succeed on repeat, and retrying an interrupt actively destroys
   * the interrupt flag (see that type's javadoc).
   */
  public static final RetryConfig RETRY_CONFIG =
      RetryConfig.custom()
          .maxAttempts(3)
          .intervalFunction(
              IntervalFunction.ofExponentialRandomBackoff(
                  Duration.ofMillis(200), 2.0d, 0.5d, Duration.ofSeconds(2)))
          .ignoreExceptions(CallNotPermittedException.class, NotADependencyFailure.class)
          .build();

  private final Map<String, Kind> dependencies;
  private final CircuitBreakerRegistry breakers;
  private final RetryRegistry retries;

  /** Dependencies some client has claimed via {@link #requireDeclared}. */
  private final Set<String> guarded = ConcurrentHashMap.newKeySet();

  private DependencyCatalog(
      Map<String, Kind> dependencies, CircuitBreakerConfig breakerConfig, RetryConfig retryConfig) {
    this.dependencies = Collections.unmodifiableMap(new LinkedHashMap<>(dependencies));
    this.breakers = CircuitBreakerRegistry.of(breakerConfig);
    this.retries = RetryRegistry.of(retryConfig);
    // Create every declared dependency's breaker and retry EAGERLY. The registries are
    // lazy-by-name, so without this a dependency that has not been called yet would have no
    // breaker for DependencyHealth to read and would be missing from /health entirely --
    // under-reporting the contract forbids, and at the worst possible moment (startup, when
    // an operator is watching).
    this.dependencies
        .keySet()
        .forEach(
            name -> {
              breakers.circuitBreaker(name);
              retries.retry(name);
            });
  }

  /**
   * Load the declaration from {@code $OPS_DEPENDENCIES_FILE} when that is set, else from the
   * classpath resource {@value #DEFAULT_RESOURCE}, else empty.
   *
   * <p>An EMPTY catalog is legitimate, not an error: a service with no direct dependencies
   * omits the {@code components} map entirely and stays a valid ops-api v1.0 responder. What
   * is NOT legitimate is having dependencies and not declaring them, which nothing here can
   * detect -- that gap is the review dimension's and the maintenance advisor's to close.
   *
   * @throws UncheckedIOException if a declaration file is named but cannot be read -- a
   *     mistyped mount path must not degrade silently into "no dependencies", which would
   *     produce a health surface that reports nothing wrong during a total outage
   */
  public static DependencyCatalog load() {
    String file = System.getenv(FILE_ENV);
    if (file != null && !file.isBlank()) {
      Path path = Path.of(file.trim());
      try {
        return new DependencyCatalog(
            parse(Files.readAllLines(path, StandardCharsets.UTF_8)), BREAKER_CONFIG, RETRY_CONFIG);
      } catch (IOException e) {
        throw new UncheckedIOException(
            "cannot read the dependency declaration named by " + FILE_ENV + " (" + path + ")", e);
      }
    }
    try (InputStream in =
        DependencyCatalog.class.getClassLoader().getResourceAsStream(DEFAULT_RESOURCE)) {
      if (in == null) {
        return new DependencyCatalog(Map.of(), BREAKER_CONFIG, RETRY_CONFIG);
      }
      return new DependencyCatalog(
          parse(List.of(new String(in.readAllBytes(), StandardCharsets.UTF_8).split("\\R", -1))),
          BREAKER_CONFIG,
          RETRY_CONFIG);
    } catch (IOException e) {
      throw new UncheckedIOException("cannot read classpath " + DEFAULT_RESOURCE, e);
    }
  }

  /** Declare the dependencies directly. The seam tests and small services use. */
  public static DependencyCatalog of(Map<String, Kind> dependencies) {
    return new DependencyCatalog(dependencies, BREAKER_CONFIG, RETRY_CONFIG);
  }

  /**
   * Declare the dependencies with your own breaker/retry settings.
   *
   * <p>The seam for the one thing the blessed defaults cannot decide for you: WHICH EXCEPTIONS
   * ARE NOT DEPENDENCY FAILURES. {@link NotADependencyFailure} covers it when your own code
   * throws, but a third-party client that throws its own type for a 404 needs that type in
   * {@code ignoreExceptions} too -- and without this overload the only way to add it would be
   * to edit the shipped template. Start from {@link #BREAKER_CONFIG} / {@link #RETRY_CONFIG}
   * with {@code .from(...)} so you inherit the blessed values and change only what you mean to.
   *
   * <p>ONE TRAP, AND IT IS SILENT: {@code ignoreExceptions(Class...)} ASSIGNS the list, it does
   * not append to it. {@code RetryConfig.from(RETRY_CONFIG).ignoreExceptions(TheirNotFound.class)}
   * therefore DROPS {@link CallNotPermittedException} and {@link NotADependencyFailure}, which
   * re-creates both round-one defects at once -- an open breaker's rejection retried through the
   * whole backoff schedule, and an interrupt retried into a cleared interrupt flag. Always
   * re-list every type you still want ignored:
   *
   * <pre>
   *   RetryConfig.from(DependencyCatalog.RETRY_CONFIG)
   *       .ignoreExceptions(CallNotPermittedException.class,
   *           DependencyCatalog.NotADependencyFailure.class, TheirNotFound.class)
   *       .build()
   * </pre>
   *
   * <p>And do it for BOTH configs: widening only the breaker's list stops the caller error
   * counting toward the failure rate but still burns the full retry schedule on every one.
   */
  public static DependencyCatalog of(
      Map<String, Kind> dependencies, CircuitBreakerConfig breakerConfig, RetryConfig retryConfig) {
    return new DependencyCatalog(dependencies, breakerConfig, retryConfig);
  }

  /**
   * Parse {@code <name>=hard|soft} lines, preserving declaration order.
   *
   * <p>Hand-parsed rather than handed to {@link java.util.Properties}, for two reasons that
   * both show up in the health surface: Properties is a Hashtable, so the declaration order a
   * human wrote -- the order /health reports dependencies in -- is lost; and its stream form
   * decodes ISO-8859-1, which mangles a non-ASCII dependency name into a key that then matches
   * nothing.
   */
  private static Map<String, Kind> parse(List<String> lines) {
    Map<String, Kind> out = new LinkedHashMap<>();
    for (String raw : lines) {
      String line = raw.strip();
      if (line.isEmpty() || line.startsWith("#")) {
        continue;
      }
      int eq = line.indexOf('=');
      if (eq < 1) {
        throw new IllegalArgumentException(
            "malformed dependency declaration '" + line + "' (want <name>=hard|soft)");
      }
      String name = line.substring(0, eq).strip();
      out.put(name, Kind.parse(line.substring(eq + 1), name));
    }
    return out;
  }

  /** The declared dependencies, in declaration order. */
  public Map<String, Kind> dependencies() {
    return dependencies;
  }

  /** The registry DependencyHealth reads. One breaker per declared dependency. */
  public CircuitBreakerRegistry breakers() {
    return breakers;
  }

  /**
   * Assert that {@code name} is declared, and return it.
   *
   * <p>Call this from a dependency client's CONSTRUCTOR. A client that guards a dependency
   * nobody declared would work perfectly and be invisible on /health -- the under-reporting
   * the contract forbids -- and {@link #call} alone would only catch it on the first request.
   * Failing at wiring time turns that into a boot failure an operator sees immediately.
   */
  public String requireDeclared(String name) {
    if (!dependencies.containsKey(name)) {
      throw new IllegalStateException(
          "dependency '"
              + name
              + "' is guarded in code but not declared. Add '"
              + name
              + "=hard' or '"
              + name
              + "=soft' to "
              + DEFAULT_RESOURCE
              + ", so /health reports it.");
    }
    guarded.add(name);
    return name;
  }

  /**
   * Assert that every DECLARED dependency has a client guarding it -- the mirror of {@link
   * #requireDeclared}, and just as load-bearing. Call it from startup AFTER every dependency
   * client is constructed.
   *
   * <p>Without it the two guards only cover one direction. A name declared in the properties
   * file but wired to no client still gets a breaker (created eagerly so it can never be
   * missing from {@code components}), and that breaker stays CLOSED forever because nothing
   * ever calls through it -- so {@code /health} reports the dependency {@code up}
   * unconditionally, straight through a total outage, and a {@code hard} one never sheds
   * traffic either. That is exactly the under-reporting the contract forbids, and it is the
   * default outcome for anyone who adopts the shipped declaration verbatim. The Spring payload
   * catches the same class of mistake at startup from the other side; this is the plain-Java
   * equivalent.
   *
   * @throws IllegalStateException naming every declared dependency no client claimed
   */
  public void requireAllDeclaredGuarded() {
    List<String> unguarded =
        dependencies.keySet().stream().filter(name -> !guarded.contains(name)).toList();
    if (!unguarded.isEmpty()) {
      throw new IllegalStateException(
          "declared but not guarded by any client: "
              + String.join(", ", unguarded)
              + ". Their breakers can never leave CLOSED, so /health would report them 'up'"
              + " during an outage. Wire a client through call(...) for each, or remove them"
              + " from "
              + DEFAULT_RESOURCE
              + ".");
    }
  }

  /**
   * Run an outbound call under all six mandates and fall back if it fails.
   *
   * <p>THE DECORATION ORDER IS THE POINT, and it is the same nesting Spring's aspect order
   * produces, spelled out rather than configured:
   *
   * <pre>
   *   fallback( retry( breaker( call ) ) )
   * </pre>
   *
   * <p>The breaker is INNERMOST, so it observes each individual attempt and its failure-rate
   * window counts attempts rather than whole call sequences. Retry wraps it, so a transient
   * blip is re-attempted with jittered backoff. The fallback is OUTERMOST, so it fires only
   * once the bounded retries are exhausted -- a fallback inside the retry would convert the
   * first failure into a success and the call would never be retried, which is the same trap
   * the Spring payload avoids by putting {@code fallbackMethod} on {@code @Retry}.
   *
   * <p>Only {@link RuntimeException} is caught: an {@link Error} is not a dependency failure
   * and must not be swallowed by a fallback. {@link CallNotPermittedException} (the open
   * breaker's rejection) arrives here immediately, un-retried -- mandate 6.
   *
   * @param name the declared dependency this call goes to
   * @param call the actual outbound call -- it MUST carry its own transport timeout (mandate
   *     1); nothing here can impose one on a socket it does not own. FOR HTTP that is the
   *     client's connect timeout plus a per-request timeout. FOR JDBC it is NOT the pool's
   *     {@code connectionTimeout}, which bounds only ACQUIRING a connection: a query already on
   *     the wire when the database stalls is unbounded, so set the driver's {@code
   *     socketTimeout} (or {@code Statement.setQueryTimeout} / JPA's {@code
   *     jakarta.persistence.query.timeout}) as well. Either way keep it ABOVE {@link
   *     #BREAKER_CONFIG}'s 2s slow-call threshold, so a brownout is recorded as slow before the
   *     transport gives up -- an unbounded call never returns, so it never fails, so the breaker
   *     never opens and /health reports the dependency {@code up} for the whole event
   * @param fallback the degraded path (mandate 4). It MUST NOT call the dependency and MUST
   *     NOT rethrow -- either defeats the breaker it is protecting. WHAT it returns is your
   *     business logic; THAT it exists is the org mandate.
   */
  public <T> T call(String name, Supplier<T> call, Function<Throwable, T> fallback) {
    String dependency = requireDeclared(name);
    CircuitBreaker breaker = breakers.circuitBreaker(dependency);
    Retry retry = retries.retry(dependency);
    Supplier<T> guarded = Retry.decorateSupplier(retry, CircuitBreaker.decorateSupplier(breaker, call));
    try {
      return guarded.get();
    } catch (RuntimeException failure) {
      return fallback.apply(failure);
    }
  }
}
