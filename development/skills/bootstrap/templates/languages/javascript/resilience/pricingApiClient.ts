/**
 * A WORKED EXAMPLE of a dependency client under all six mandates (issue #1145).
 *
 * THIS IS NOT SERVICE CODE. It calls a `pricing-api` that does not exist, reading
 * its base URL from PRICING_API_BASE_URL. Adapt it to a real dependency or delete it
 * -- it is shipped to show the SHAPE, because the shape is what the review dimension
 * checks for on a diff.
 *
 * What to copy from it, in order of how quietly each one fails if you skip it:
 *
 *  1. the action passes the catalog's AbortSignal to fetch (mandate 1). The catalog
 *     owns the timeout, but only the action owns the socket; ignore the signal and a
 *     timed-out request keeps its connection until the dependency answers.
 *  2. caller errors are wrapped with notADependency, so a 404 the request itself
 *     provoked never opens a breaker on a healthy dependency.
 *  3. the fallback RESOLVES -- it never calls the dependency, never fabricates a
 *     money-shaped value it does not have, and never rejects. An outage that ends in
 *     a rejection nobody awaits is an unhandled rejection, which terminates a Node
 *     process by default.
 *  4. every call goes through catalog.call, which supplies the breaker, the bounded
 *     jittered retry and the fast-fail.
 */

import { type CallOptions, type DependencyCatalog, notADependency } from "./dependencyCatalog.js";

/**
 * The key this client claims in the declaration file. It must match a
 * `<name>=hard|soft` line there, or the constructor fails at startup.
 */
export const DEPENDENCY_NAME = "pricing-api";

/** Whatever the dependency returns -- a placeholder for your real type. */
export interface Price {
  sku: string;
  cents: number;
  currency: string;
}

/**
 * A price, or an honest absence. The union is the point: TypeScript will not let a
 * caller read `price` without first checking `available`, so a degraded answer
 * cannot be billed on by accident.
 */
export type PriceResult = { available: true; price: Price } | { available: false; cause: unknown };

/** A direct dependency guarded by the catalog. */
export class PricingApiClient {
  readonly #catalog: DependencyCatalog;
  readonly #baseUrl: string;

  /**
   * Claims the dependency and validates the configuration.
   *
   * Claiming at CONSTRUCTION rather than at first call is deliberate: it turns "this
   * dependency is guarded in code but missing from the declaration" into a startup
   * failure, instead of a surprise on the first request after a deploy.
   */
  constructor(catalog: DependencyCatalog, baseUrl: string | undefined = process.env.PRICING_API_BASE_URL) {
    catalog.requireDeclared(DEPENDENCY_NAME);
    // Validate the URL, not merely its presence, and HERE rather than at call time.
    // The commonest spelling of this misconfiguration is a service name with no
    // scheme (pricing-api.svc.cluster.local:8080), which fetch rejects as an invalid
    // URL -- on the COUNTED arm, so the breaker would open and /health would blame a
    // dependency that was never contacted, for a missing "http://".
    let parsed: URL | undefined;
    try {
      parsed = new URL(baseUrl ?? "");
    } catch {
      parsed = undefined;
    }
    if (parsed === undefined || (parsed.protocol !== "http:" && parsed.protocol !== "https:") || parsed.host === "") {
      throw new Error(
        `pricing-api: PRICING_API_BASE_URL="${baseUrl ?? ""}" is not an absolute http(s) URL (want e.g. ` +
          "http://pricing-api:8080); a config error here would be reported as a dependency outage rather " +
          "than the config error it is",
      );
    }
    this.#catalog = catalog;
    this.#baseUrl = parsed.href.replace(/\/+$/, "");
  }

  /** Fetches a price under all six mandates, degrading rather than failing. */
  async price(sku: string, options: CallOptions = {}): Promise<PriceResult> {
    return this.#catalog.call<PriceResult>(
      DEPENDENCY_NAME,
      async (signal) => ({ available: true, price: await this.#fetch(sku, signal) }),
      // MANDATE 4, the registered fallback. It must NOT call the dependency and must
      // not block. WHAT it returns is your application's business logic -- a cached
      // last-known-good price, an empty result the caller can handle; THAT it exists
      // is the org mandate. It deliberately does not invent a price.
      (cause) => ({ available: false, cause }),
      options,
    );
  }

  async #fetch(sku: string, signal: AbortSignal): Promise<Price> {
    // ENCODE the caller's input. Unencoded, a SKU containing "?" injects a query and
    // "/" walks to a different endpoint -- and the resulting failure would be charged
    // to the breaker, so caller input would move a healthy dependency's health.
    const url = `${this.#baseUrl}/prices/${encodeURIComponent(sku)}`;

    // A transport failure -- refused, reset, DNS, the attempt's own timeout -- IS a
    // dependency failure and propagates to be counted. A caller who went away is
    // re-classified by the catalog, which is the one place that can tell the two
    // aborts apart.
    const response = await fetch(url, { signal, headers: { accept: "application/json" } });

    if (response.status < 200 || response.status >= 300) {
      // Release the connection: an unread body pins the socket in undici's pool, and
      // enough of them starve every later call to this dependency.
      await discard(response);
      if (response.status === 404) {
        // The caller asked for a SKU that does not exist. The dependency answered
        // correctly and promptly; counting this would let a crawler hitting dead SKUs
        // open the breaker and -- if pricing-api were declared hard -- fail readiness
        // for the whole pod.
        throw notADependency(new Error(`pricing-api: no such sku "${sku}"`));
      }
      if (response.status >= 400 && response.status < 500) {
        // The whole 4xx range is the caller's fault by definition, so classify it as
        // one rather than only the 404 you happened to think of.
        throw notADependency(new Error(`pricing-api: status ${response.status}`));
      }
      // 5xx is the dependency failing, and so is anything else that is not a success
      // -- a 304, an unfollowed 3xx. Count it.
      throw new Error(`pricing-api: status ${response.status}`);
    }

    // A body we cannot parse, or one of the wrong shape, means the dependency is
    // misbehaving, so both count -- unlike the 4xx cases above.
    let body: unknown;
    try {
      body = await response.json();
    } catch (err) {
      throw new Error("pricing-api: decoding response", { cause: err });
    }
    if (!isPrice(body)) {
      throw new Error("pricing-api: response is not a price");
    }
    return body;
  }
}

function isPrice(value: unknown): value is Price {
  if (typeof value !== "object" || value === null) {
    return false;
  }
  const v = value as Record<string, unknown>;
  return typeof v.sku === "string" && Number.isInteger(v.cents) && typeof v.currency === "string";
}

async function discard(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // Nothing to recover: the body is being thrown away either way.
  }
}
