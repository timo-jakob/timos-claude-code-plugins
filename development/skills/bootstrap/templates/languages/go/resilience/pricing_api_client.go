// A WORKED EXAMPLE of a dependency client under all six mandates (issue #1144).
//
// THIS IS NOT SERVICE CODE. It calls a `pricing-api` that does not exist, reading
// its base URL from PRICING_API_BASE_URL. Adapt it to a real dependency or delete
// it -- it is shipped to show the SHAPE, because the shape is what the review
// dimension checks for on a diff, and what the maintenance advisor (#968) will
// check on the back catalogue once it lands.
//
// What to copy from it, in order of how quietly each one fails if you skip it:
//
//  1. the client carries its OWN transport timeout (mandate 1). resilience.Call
//     cannot impose it -- it does not own your socket -- and in Go that timeout is
//     doing a second job: gobreaker has no slow-call detection, so YOUR TIMEOUT IS
//     THE SLOW-CALL THRESHOLD. Set it generously and a brownout passes unnoticed.
//  2. caller errors are wrapped with resilience.NotADependency, so a 404 the
//     request itself provoked never opens a breaker on a healthy dependency.
//  3. the fallback NEVER calls the dependency, and never fabricates a
//     money-shaped value it does not have.
//  4. every call goes through resilience.Call, which is what supplies the breaker,
//     the bounded jittered retry and the fast-fail.
package resilience

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	neturl "net/url"
	"os"
	"strings"
	"time"
)

// PricingAPIClient is a direct dependency guarded by the catalog.
type PricingAPIClient struct {
	catalog *Catalog
	baseURL string
	http    *http.Client
}

// DependencyName is the key this client claims in the declaration file. It must
// match a `<name>=hard|soft` line there, or NewPricingAPIClient fails at startup.
const DependencyName = "pricing-api"

// NewPricingAPIClient claims the dependency and builds a client with its own
// timeout.
//
// Claiming at CONSTRUCTION rather than at first call is deliberate: it turns "this
// dependency is guarded in code but missing from the declaration" into a startup
// failure, instead of a surprise on the first request after a deploy.
func NewPricingAPIClient(catalog *Catalog) (*PricingAPIClient, error) {
	if _, err := catalog.RequireDeclared(DependencyName); err != nil {
		return nil, err
	}
	// An unset base URL must fail HERE, not at call time. Left empty, the request
	// URL becomes "/prices/<sku>", http.NewRequestWithContext accepts it as a
	// valid relative URL, and the transport fails with "no Host in request URL" --
	// which this client would then report as a DEPENDENCY failure. A missing
	// environment variable would open the breaker and make /health blame a
	// dependency that was never called.
	// Validate the URL, not merely its emptiness. The commonest spelling of this
	// misconfiguration is a service name with no scheme
	// (pricing-api.svc.cluster.local:8080), which an emptiness check waves through
	// and the transport then rejects as "unsupported protocol scheme" -- on the
	// COUNTED arm, so the breaker opens and /health blames a dependency that was
	// never contacted, for a missing "http://".
	baseURL := os.Getenv("PRICING_API_BASE_URL")
	parsed, parseErr := neturl.Parse(baseURL)
	if parseErr != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return nil, fmt.Errorf(
			"pricing-api: PRICING_API_BASE_URL=%q is not an absolute http(s) URL (want e.g. "+
				"http://pricing-api:8080); a config error here would be reported as a dependency "+
				"outage rather than the config error it is", baseURL)
	}
	return &PricingAPIClient{
		catalog: catalog,
		baseURL: strings.TrimSuffix(baseURL, "/"),
		http: &http.Client{
			// MANDATE 1, and the slow-call threshold. Two seconds is the same
			// figure the Java and Spring siblings use for their slow-call bound,
			// chosen so a brownout trips the breaker rather than hiding behind a
			// generous deadline.
			Timeout: 2 * time.Second,
		},
	}, nil
}

// Price is whatever the dependency returns -- a placeholder for your real type.
type Price struct {
	SKU      string `json:"sku"`
	Cents    int64  `json:"cents"`
	Currency string `json:"currency"`
}

// Price fetches a price under all six mandates, degrading rather than failing.
func (c *PricingAPIClient) Price(ctx context.Context, sku string) (Price, error) {
	return Call(ctx, c.catalog, DependencyName,
		func(ctx context.Context) (Price, error) { return c.fetch(ctx, sku) },
		func(cause error) (Price, error) {
			// MANDATE 4, the registered fallback. It must NOT call the dependency
			// and must not block. WHAT it returns is your application's business
			// logic -- a cached price, a conservative default, an empty result
			// the caller can handle; THAT it exists is the org mandate.
			//
			// NOTE WHAT THIS DELIBERATELY DOES NOT DO: invent a price. Returning
			// Cents: 0 with a nil error would hand a caller a money-shaped value
			// they might bill on, and a marker field only helps a caller who
			// checks it. A degraded path owes the caller a usable answer or an
			// honest absence -- never a fabricated number. Serve a cached
			// last-known-good here if you have one.
			return Price{}, fmt.Errorf("pricing-api unavailable, no cached price for %q: %w", sku, cause)
		})
}

func (c *PricingAPIClient) fetch(ctx context.Context, sku string) (Price, error) {
	// ESCAPE the caller's input. Unescaped, a SKU containing "?" injects a query,
	// "/" walks to a different endpoint, and a space or control character makes the
	// request fail outright -- which the transport branch below would charge to the
	// breaker, so caller input would move a healthy dependency's health.
	url := fmt.Sprintf("%s/prices/%s", c.baseURL, neturl.PathEscape(sku))
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		// A malformed URL is our own bug, not the dependency failing -- so it
		// must not count against the breaker.
		return Price{}, NotADependency(err)
	}

	response, err := c.http.Do(request)
	if err != nil {
		// The CALLER went away -- a client disconnect, or a drain cancelling every
		// in-flight context. The dependency was never asked to do anything wrong,
		// so this must not count against its breaker.
		// ctx.Err() is the authority, the same rule the decode branch uses:
		// http.Client's own timeout wrapper can rewrite the returned cause, so
		// testing only the error would let a drain's cancellation reach the
		// counted arm.
		if errors.Is(err, context.Canceled) || errors.Is(ctx.Err(), context.Canceled) {
			return Price{}, NotADependency(err)
		}
		// Everything else IS a dependency failure: timeout (which, with no
		// slow-call detection in gobreaker, is also the brownout signal),
		// connection refused, DNS. These are the ones that should move the breaker.
		return Price{}, fmt.Errorf("pricing-api: %w", err)
	}
	defer func() { _ = response.Body.Close() }()

	switch {
	case response.StatusCode == http.StatusNotFound:
		// The caller asked for a SKU that does not exist. The dependency answered
		// correctly and promptly; it is not unwell. Counting this would let a
		// crawler hitting dead SKUs open the breaker and -- if pricing-api were
		// declared hard -- fail readiness for the whole pod.
		return Price{}, NotADependency(fmt.Errorf("pricing-api: no such sku %q", sku))
	case response.StatusCode >= 400 && response.StatusCode < 500:
		// The whole 4xx range is the caller's fault by definition, so classify it
		// as one rather than only the 404 you happened to think of.
		return Price{}, NotADependency(fmt.Errorf("pricing-api: status %d", response.StatusCode))
	case response.StatusCode >= 500:
		// 5xx is the dependency failing. Count it.
		return Price{}, fmt.Errorf("pricing-api: status %d", response.StatusCode)
	case response.StatusCode < 200 || response.StatusCode >= 300:
		// Everything else -- a 204 with no body, a 304, an unfollowed 3xx --
		// would otherwise fall through to the decoder and be reported as a
		// malformed body, i.e. charged to the breaker for a response that may be
		// perfectly correct. Make success explicit rather than residual.
		return Price{}, fmt.Errorf("pricing-api: unexpected status %d", response.StatusCode)
	}

	var price Price
	if err := json.NewDecoder(response.Body).Decode(&price); err != nil {
		// The CALLER went away mid-body. Do returns at the HEADERS, so most of a
		// request's cancellable lifetime is here -- and http.Client's own timeout
		// wrapper rewrites the cause, so ctx.Err() is the authoritative signal.
		// It distinguishes Canceled from DeadlineExceeded, so a real timeout still
		// counts as the brownout signal it is.
		if errors.Is(ctx.Err(), context.Canceled) {
			return Price{}, NotADependency(err)
		}
		// A body we cannot parse means the dependency is misbehaving, so this
		// counts -- unlike the 4xx cases above.
		return Price{}, fmt.Errorf("pricing-api: decoding response: %w", err)
	}
	return price, nil
}
