/*
 * A worked six-mandate dependency client for NON-Spring Java (#1142, epic #964).
 *
 * The reference for how EVERY governed outbound call in this service should be
 * wired. Copy the shape, not the domain: pricing-api is an example SOFT dependency
 * (the catalogue still sells when pricing is unavailable -- it quotes the last
 * known price instead). A HARD dependency is wired identically; only the
 * `pricing-api=soft` line in resilience-dependencies.properties differs, and with
 * it what happens to /health/ready when its breaker opens.
 *
 * THE SIX MANDATES, and where each one lives:
 *   1. TIMEOUT              HttpClient.connectTimeout + HttpRequest.timeout, below
 *                           -- the ONLY mandate the catalog cannot impose for you,
 *                           because it does not own your socket
 *   2. CIRCUIT BREAKER      DependencyCatalog.call -> one breaker per dependency
 *   3. BOUNDED RETRY +
 *      JITTERED BACKOFF     DependencyCatalog.RETRY_CONFIG
 *   4. REGISTERED FALLBACK  the third argument to call(...), lastKnownPrice below
 *   5. BACKGROUND RECONNECT automaticTransitionFromOpenToHalfOpenEnabled, in the
 *                           catalog's breaker config
 *   6. STAY-STABLE          an open breaker fast-fails into the fallback; no
 *                           unbounded wait, no thread parked on a dead socket
 *
 * SO THE CLIENT'S OWN JOB IS SMALL: set the two timeouts, route the call through
 * catalog.call(...), and write a degraded path worth having. That is deliberate --
 * the mandates that can be centralized ARE centralized, so the thing a reviewer
 * has to check on each new client is a handful of lines.
 *
 * PLACEMENT: copy into your service's source set and set the package to match its
 * directory, e.g. src/main/java/com/acme/orders/pricing/PricingApiClient.java ->
 * package com.acme.orders.pricing; (this one does NOT have to sit in the .ops
 * package -- it only needs to import DependencyCatalog from there).
 */
package com.example.ops; // <-- CHANGE to match the directory you place this file in.

import java.io.IOException;
import java.io.UncheckedIOException;
import java.math.BigDecimal;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

/** Reads unit prices from the pricing service, degrading to the last known price. */
public final class PricingApiClient {

  /**
   * The declared dependency name. It is the key in resilience-dependencies.properties, the
   * name of the breaker, and the key /health reports this dependency under -- one string, so
   * the three can never drift apart.
   */
  public static final String DEPENDENCY = "pricing-api";

  /** A unit price for one stock-keeping unit. */
  public record PriceQuote(String sku, BigDecimal amount, String currency, boolean stale) {}

  private final DependencyCatalog catalog;
  private final HttpClient http;
  private final URI baseUrl;

  /**
   * The degraded path's data. A fallback must return something useful without touching the
   * dependency -- an in-process cache, a default, or a partial response. This one remembers
   * the last successful quote PER SKU and re-serves it marked {@code stale}, so callers can
   * tell a live price from a fallback one.
   *
   * <p>PER SKU MATTERS. A single-slot cache looks equivalent and is not: every fetch would
   * evict every other SKU, so during an outage the fallback would miss for all but the most
   * recently fetched one and serve the no-data default -- a price of zero -- for essentially
   * the whole catalogue. Bound it (an LRU, a Caffeine cache with a size limit) before you ship
   * a catalogue large enough for this map to matter; unbounded per-key caches are their own
   * outage.
   */
  private final ConcurrentMap<String, PriceQuote> lastKnownGood = new ConcurrentHashMap<>();

  public PricingApiClient(DependencyCatalog catalog, URI baseUrl) {
    // Fail at WIRING time if nobody declared this dependency. Without it the client would work
    // perfectly and be missing from /health -- a health surface that stays quiet through an
    // outage, which is the exact failure this payload exists to prevent.
    catalog.requireDeclared(DEPENDENCY);
    this.catalog = catalog;
    this.baseUrl = baseUrl;
    // MANDATE 1, half of it: a connect timeout. Without one, connecting to a black-holed host
    // blocks until the OS gives up -- minutes, on a default Linux SYN retry schedule.
    this.http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();
  }

  /**
   * Fetch the current unit price for a SKU, e.g. {@code ESP-1042-BLK}.
   *
   * <p>One call to {@link DependencyCatalog#call} is the whole protection: breaker, bounded
   * jittered retry, and the fallback, composed in the order that makes each of them work.
   *
   * @return the quote, or EMPTY when pricing is unavailable and nothing is cached for this SKU.
   *     Empty rather than a zero-priced quote on purpose: a degraded path owes the caller a
   *     usable answer or an honest absence, never a fabricated number they might bill on.
   */
  public Optional<PriceQuote> quote(String sku) {
    return catalog.call(
        DEPENDENCY, () -> Optional.of(fetch(sku)), cause -> lastKnownPrice(sku, cause));
  }

  /**
   * The raw outbound call. Everything it throws is a dependency failure the breaker records.
   *
   * <p>TWO THINGS HERE FAIL SILENTLY IF YOU DROP THEM:
   *
   * <p>1. {@code HttpRequest.timeout} is the other half of mandate 1. {@code connectTimeout}
   * only bounds establishing the connection; a dependency that accepts the socket and then
   * never answers -- the classic overloaded-service shape -- hangs forever without this, and
   * an unbounded wait is precisely what mandate 6 forbids. The breaker cannot save you: a call
   * that never returns never fails, so it never counts toward the failure rate and the breaker
   * stays closed while every caller thread piles up behind it.
   *
   * <p>2. {@code java.net.http} does NOT throw on a 4xx/5xx status -- unlike Spring's
   * RestClient, whose {@code retrieve()} throws by default. Without this explicit check a
   * broken dependency returns 503 to every call, the client happily parses the error body (or
   * throws a parse error attributed to the wrong cause), and the breaker never sees a failure
   * to record.
   */
  private PriceQuote fetch(String sku) {
    HttpRequest request =
        HttpRequest.newBuilder(priceUri(sku)).timeout(Duration.ofSeconds(3)).GET().build();
    HttpResponse<String> response;
    try {
      response = http.send(request, HttpResponse.BodyHandlers.ofString());
    } catch (IOException e) {
      throw new UncheckedIOException("pricing-api call failed for sku " + sku, e);
    } catch (InterruptedException e) {
      // Restore the flag before unwinding: swallowing it leaves the thread un-interruptible and
      // a graceful shutdown then hangs on exactly the dead dependency this class is about.
      Thread.currentThread().interrupt();
      // NotADependencyFailure, not a plain RuntimeException: an interrupt is OUR cancellation,
      // not the dependency's fault. As a retryable type it would be re-attempted -- and the
      // retry's backoff calls Thread.sleep, which on an already-interrupted thread throws at
      // once AND CLEARS the flag we just restored -- while each attempt counted toward the
      // breaker's failure rate, so draining a pod could open a healthy dependency's breaker.
      throw new DependencyCatalog.NotADependencyFailure("interrupted while calling pricing-api", e);
    }
    int status = response.statusCode();
    // java.net.http does NOT throw on 4xx/5xx (unlike Spring's RestClient), so this check is
    // what makes a broken dependency visible to the breaker at all.
    //
    // 4xx AND 5xx ARE NOT THE SAME EVENT, and conflating them is how a healthy dependency gets
    // reported down. A 4xx is a CALLER error -- an unknown SKU, a malformed request. It is
    // deterministic, so retrying it only burns backoff, and counting it toward the failure rate
    // means a burst of lookups for nonexistent SKUs (user-controlled traffic) can open the
    // breaker on a dependency that answered every request correctly. NotADependencyFailure is
    // ignored by both the retry and the breaker, so it goes straight to the fallback.
    if (status / 100 == 4) {
      throw new DependencyCatalog.NotADependencyFailure(
          "pricing-api answered HTTP " + status + " for sku " + sku + " (caller error)");
    }
    if (status / 100 != 2) {
      throw new IllegalStateException("pricing-api answered HTTP " + status + " for sku " + sku);
    }
    // The example endpoint answers a bare decimal, so this payload needs no JSON mapper and
    // stays about resilience. Your real client parses with whatever mapper the service already
    // uses -- that choice is orthogonal to the six mandates.
    PriceQuote quote = new PriceQuote(sku, new BigDecimal(response.body().strip()), "EUR", false);
    lastKnownGood.put(sku, quote);
    return quote;
  }

  /**
   * Build the request URI safely. Two traps, both of which turn a CALLER's input into a
   * reported dependency outage:
   *
   * <p>1. THE SKU MUST BE ENCODED. Interpolated raw, a space makes {@code URI} throw -- inside
   * the guarded supplier, so the breaker records it as a dependency failure -- and a {@code ?},
   * {@code #} or {@code ../} silently injects a query, a fragment or a different path.
   *
   * <p>2. RESOLVING AN ABSOLUTE PATH DISCARDS THE BASE PATH. {@code
   * URI("https://gw/pricing").resolve("/v1/prices/X")} is {@code https://gw/v1/prices/X}, not
   * {@code https://gw/pricing/v1/prices/X} -- so a service behind a gateway prefix silently
   * calls the wrong endpoint. Resolving a RELATIVE path against a base normalized to end in
   * {@code /} keeps the prefix.
   */
  private URI priceUri(String sku) {
    String base = baseUrl.toString();
    String normalized = base.endsWith("/") ? base : base + "/";
    return URI.create(normalized)
        .resolve("v1/prices/" + URLEncoder.encode(sku, StandardCharsets.UTF_8).replace("+", "%20"));
  }

  /**
   * The registered fallback (mandate 4).
   *
   * <p>It MUST NOT call the dependency, and MUST NOT rethrow -- either would defeat the
   * breaker it is protecting. Returning quickly is the point: this is what keeps the service
   * answering while pricing is down.
   *
   * <p>What it returns is business logic and yours to decide; that it EXISTS and is wired is
   * the org mandate.
   */
  private Optional<PriceQuote> lastKnownPrice(String sku, Throwable cause) {
    // A CALLER ERROR IS NOT AN OUTAGE, and the fallback sees both because call()'s catch
    // cannot tell them apart. Two things go wrong if this branch is missing. A SKU that was
    // priced before and now 404s -- delisted -- would be re-served its OLD price, when the
    // dependency just told us authoritatively that it no longer exists; and every bad-SKU
    // lookup would log a WARNING claiming pricing-api is unavailable, flooding the log with
    // false outage reports about a dependency that answered correctly. Report the honest
    // absence instead.
    //
    // It does NOT evict the cached entry, deliberately: an interrupt during a drain is also a
    // NotADependencyFailure, and throwing away a perfectly good price because the caller was
    // cancelled would trade one wrong answer for another. A delisted SKU's stale entry is
    // harmless here, because this branch never serves it.
    if (cause instanceof DependencyCatalog.NotADependencyFailure) {
      System.getLogger(PricingApiClient.class.getName())
          .log(System.Logger.Level.DEBUG, "no price for sku " + sku + ": " + cause.getMessage());
      return Optional.empty();
    }
    System.getLogger(PricingApiClient.class.getName())
        .log(
            System.Logger.Level.WARNING,
            "pricing-api unavailable for sku " + sku + ", serving last known price",
            cause);
    PriceQuote cached = lastKnownGood.get(sku);
    if (cached != null) {
      return Optional.of(new PriceQuote(sku, cached.amount(), cached.currency(), true));
    }
    // No cached price for THIS sku, so there is nothing honest to serve. An empty Optional is
    // the signal; a zero-priced quote would be a plausible-looking lie a caller could bill on.
    // Note it still RETURNS -- a fallback that rethrows defeats the breaker it is protecting.
    return Optional.empty();
  }
}
