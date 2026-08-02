/*
 * A worked six-mandate dependency client (#1141, epic #964).
 *
 * The reference for how EVERY governed outbound call in this service should be
 * wired. Copy the shape, not the domain: pricing-api is an example SOFT dependency
 * (the catalogue still sells when pricing is unavailable -- it quotes the last
 * known price instead). A HARD dependency is wired identically; only the
 * `kind: hard` declaration in application.yml differs, and with it what happens to
 * /health/ready when its breaker opens.
 *
 * THE SIX MANDATES, and where each one lives:
 *   1. TIMEOUT              spring.http.clients.{connect,read}-timeout (config)
 *   2. CIRCUIT BREAKER      @CircuitBreaker(name = "pricing-api")
 *   3. BOUNDED RETRY +
 *      JITTERED BACKOFF     @Retry(name = "pricing-api"), configured with
 *                           exponential backoff + randomized wait
 *   4. REGISTERED FALLBACK  fallbackMethod = "lastKnownPrice"
 *   5. BACKGROUND RECONNECT automatic-transition-from-open-to-half-open (config)
 *   6. STAY-STABLE          an open breaker fast-fails into the fallback; no
 *                           unbounded wait, no thread parked on a dead socket
 *
 * WHY fallbackMethod SITS ON @Retry AND NOT ON @CircuitBreaker. resilience4j's
 * default aspect order makes Retry the OUTERMOST aspect (retryAspectOrder
 * 2147483642 < circuitBreakerAspectOrder 2147483643; in Spring AOP a lower order
 * is the outer aspect). A fallback declared on @CircuitBreaker would therefore
 * convert the failure into a successful return BEFORE the Retry aspect ever sees
 * it -- the call would silently never be retried. On @Retry the fallback fires
 * only once the bounded retries are exhausted, which is what mandate 4 means.
 *
 * WHY THERE IS NO @TimeLimiter HERE. @TimeLimiter governs methods returning a
 * CompletionStage/Future; on a blocking call it is inert. Mandate 1 for a
 * synchronous client is the transport timeout, which is why
 * spring.http.clients.read-timeout is not optional (PLURAL `clients` -- the
 * singular Boot 3 spelling is deprecated in Boot 4 and binds nothing). The
 * resilience4j.timelimiter block in application-resilience.yml is there for the
 * async clients that do return CompletableFuture.
 *
 * PLACEMENT: copy into your service's source set and set the package to match its
 * directory, e.g. src/main/java/com/acme/orders/pricing/PricingApiClient.java ->
 * package com.acme.orders.pricing;
 */
package com.example.ops; // <-- CHANGE to match the directory you place this file in.

import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import io.github.resilience4j.retry.annotation.Retry;
import java.math.BigDecimal;
import java.util.concurrent.atomic.AtomicReference;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

/** Reads unit prices from the pricing service, degrading to the last known price. */
@Component
public class PricingApiClient {

  private static final Logger log = LoggerFactory.getLogger(PricingApiClient.class);

  /** A unit price for one stock-keeping unit. */
  public record PriceQuote(String sku, BigDecimal amount, String currency, boolean stale) {}

  private final RestClient http;

  /**
   * The degraded path's data. A fallback must return something useful without touching
   * the dependency -- an in-process cache, a default, or a partial response. This one
   * remembers the last successful quote and re-serves it marked {@code stale}, so callers
   * can tell a live price from a fallback one.
   */
  private final AtomicReference<PriceQuote> lastKnownGood = new AtomicReference<>();

  public PricingApiClient(
      RestClient.Builder builder, @Value("${pricing-api.base-url}") String baseUrl) {
    this.http = builder.baseUrl(baseUrl).build();
  }

  /**
   * Fetch the current unit price for a SKU, e.g. {@code ESP-1042-BLK}.
   *
   * <p>The two annotations are the whole protection: Retry bounds how often a blip is
   * re-attempted, and the breaker stops attempting at all once the dependency is
   * measurably failing.
   */
  @Retry(name = "pricing-api", fallbackMethod = "lastKnownPrice")
  @CircuitBreaker(name = "pricing-api")
  public PriceQuote quote(String sku) {
    PriceQuote quote =
        http.get().uri("/v1/prices/{sku}", sku).retrieve().body(PriceQuote.class);
    lastKnownGood.set(quote);
    return quote;
  }

  /**
   * The registered fallback: same parameters as {@link #quote(String)} plus the cause.
   *
   * <p>It MUST NOT call the dependency, and MUST NOT rethrow -- either would defeat the
   * breaker it is protecting. Returning quickly is the point: this is what keeps the
   * service answering while pricing is down.
   *
   * <p>What it returns is business logic and yours to decide; that it EXISTS and is wired
   * is the org mandate.
   */
  @SuppressWarnings("unused") // invoked reflectively by resilience4j
  private PriceQuote lastKnownPrice(String sku, Throwable cause) {
    log.warn(
        "pricing-api unavailable for sku={}, serving last known price: {}", sku, cause.toString());
    PriceQuote cached = lastKnownGood.get();
    if (cached != null && cached.sku().equals(sku)) {
      return new PriceQuote(sku, cached.amount(), cached.currency(), true);
    }
    return new PriceQuote(sku, BigDecimal.ZERO, "EUR", true);
  }
}
