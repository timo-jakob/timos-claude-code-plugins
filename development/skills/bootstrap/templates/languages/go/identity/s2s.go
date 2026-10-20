package identity

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/clientcredentials"
)

// Service-to-service calls carry one of exactly two tokens (#2862, the
// service-to-service clause of #1186), and neither ever trusts a header:
//
//   - work done ON BEHALF OF A USER forwards that user's validated token, through
//     PropagatingTransport;
//   - background and system work uses the service's own client-credentials
//     token, through ServiceAccount. That token carries a tenant only when the
//     call is genuinely acting for one tenant -- a background job that claims a
//     tenant it is not acting for is indistinguishable, downstream, from a
//     compromised one.

// callerTokenKey is unexported, so only this package can put a caller token in a
// context: a value under it was set by Middleware after successful validation.
type callerTokenKey struct{}

// withCallerToken stores the validated inbound token. Only Middleware calls it,
// and only after Validate succeeded.
func withCallerToken(ctx context.Context, raw string) context.Context {
	return context.WithValue(ctx, callerTokenKey{}, raw)
}

// CallerToken returns the inbound caller's validated bearer token, as Middleware
// stored it for this request.
func CallerToken(ctx context.Context) (string, bool) {
	raw, ok := ctx.Value(callerTokenKey{}).(string)
	return raw, ok && raw != ""
}

// ErrNoCallerToken is returned by PropagatingTransport for a request whose
// context holds no validated caller token. Nothing is sent.
var ErrNoCallerToken = errors.New("identity: no validated caller token in the request context")

// PropagatingTransport forwards the inbound caller's validated token on an
// outbound request made on that user's behalf. It sets the Authorization header
// to CallerToken(req.Context()), overwriting any Authorization header already
// on the request, and refuses -- sending nothing -- when the context holds no
// validated token. Build the outbound request with the inbound request's
// context (http.NewRequestWithContext(r.Context(), …)).
type PropagatingTransport struct {
	// Base performs the request. nil means http.DefaultTransport.
	Base http.RoundTripper
}

// RoundTrip implements http.RoundTripper.
func (t *PropagatingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	raw, ok := CallerToken(req.Context())
	if !ok {
		if req.Body != nil {
			_ = req.Body.Close() // a RoundTripper must close the body, even on error
		}
		return nil, ErrNoCallerToken
	}
	// A RoundTripper must not modify the request it was given.
	out := req.Clone(req.Context())
	if redirectedAwayFromOrigin(req) {
		// net/http dropped the token for this hop; re-adding it would hand the
		// caller's token to whatever host the downstream redirected to.
		out.Header.Del("Authorization")
	} else {
		out.Header.Set("Authorization", "Bearer "+raw)
	}
	base := t.Base
	if base == nil {
		base = http.DefaultTransport
	}
	return base.RoundTrip(out)
}

// redirectedAwayFromOrigin reports whether req is a redirect hop to a host or
// scheme other than the one the call was made to. A token is only ever sent to
// that host over that scheme, so an https-to-http downgrade never carries it. A
// hop whose chain does not lead back to the original request (a Base transport
// that leaves resp.Request unset) counts as leaving it: the check fails closed.
func redirectedAwayFromOrigin(req *http.Request) bool {
	first := req
	for first.Response != nil {
		if first.Response.Request == nil {
			return true
		}
		first = first.Response.Request
	}
	return first.URL.Host != req.URL.Host || first.URL.Scheme != req.URL.Scheme
}

// DefaultTenantScopeTemplate requests a tenant through Keycloak Organizations'
// scope, matching the `organization` claim Validator reads the tenant from.
const DefaultTenantScopeTemplate = "organization:{tenant}"

// ServiceAccountConfig configures a ServiceAccount.
type ServiceAccountConfig struct {
	// TokenURL is the issuer's token endpoint. Required.
	TokenURL string
	// ClientID and ClientSecret are the service account's credentials. Read
	// them from a mounted secret, never from source. ClientID is required.
	ClientID     string
	ClientSecret string
	// Scopes are requested on every token, tenant-scoped or not.
	Scopes []string
	// TenantScopeTemplate is the scope that requests a tenant; "{tenant}" is
	// replaced with the tenant. Empty means DefaultTenantScopeTemplate.
	TenantScopeTemplate string
	// HTTPClient calls the token endpoint. nil means a client with a 10s
	// timeout: an unbounded token fetch would hang every call behind it.
	HTTPClient *http.Client
}

// ServiceAccount hands out client-credentials tokens for background and system
// work. Tokens are cached PER TENANT -- one token source per exact tenant
// string, plus a separate tenant-less one -- so a token fetched for one tenant
// is never served to another tenant or to a tenant-less call. Each cached token
// is refreshed only when it expires. Safe for concurrent use.
//
// The cache grows with the number of distinct tenants this service acts for,
// which is bounded by the tenants that exist.
type ServiceAccount struct {
	cfg        ServiceAccountConfig
	httpClient *http.Client

	mu         sync.Mutex
	tenantless oauth2.TokenSource
	byTenant   map[string]oauth2.TokenSource
}

// NewServiceAccount returns a ServiceAccount for cfg. It makes no request.
func NewServiceAccount(cfg ServiceAccountConfig) (*ServiceAccount, error) {
	if cfg.TokenURL == "" {
		return nil, errors.New("identity: service account needs a TokenURL")
	}
	if cfg.ClientID == "" {
		return nil, errors.New("identity: service account needs a ClientID")
	}
	if cfg.TenantScopeTemplate == "" {
		cfg.TenantScopeTemplate = DefaultTenantScopeTemplate
	}
	if !strings.Contains(cfg.TenantScopeTemplate, "{tenant}") {
		return nil, errors.New("identity: TenantScopeTemplate must contain {tenant}")
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	return &ServiceAccount{cfg: cfg, httpClient: client, byTenant: map[string]oauth2.TokenSource{}}, nil
}

// ErrInvalidTenant is returned for an empty tenant, or one containing
// whitespace: scopes are space-separated, so such a tenant would request scopes
// nobody asked for.
var ErrInvalidTenant = errors.New("identity: tenant must be non-empty and contain no whitespace")

// TokenSource returns the tenant-less token source, for system work that acts
// for no tenant. Its tokens request no organization scope.
func (s *ServiceAccount) TokenSource() oauth2.TokenSource {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.tenantless == nil {
		s.tenantless = s.newSource(nil)
	}
	return s.tenantless
}

// TenantTokenSource returns the token source for work genuinely acting for
// tenant. Its tokens request that tenant through TenantScopeTemplate.
func (s *ServiceAccount) TenantTokenSource(tenant string) (oauth2.TokenSource, error) {
	if tenant == "" || strings.ContainsFunc(tenant, unicode.IsSpace) {
		return nil, ErrInvalidTenant
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	src, ok := s.byTenant[tenant]
	if !ok {
		scope := strings.ReplaceAll(s.cfg.TenantScopeTemplate, "{tenant}", tenant)
		src = s.newSource([]string{scope})
		s.byTenant[tenant] = src
	}
	return src, nil
}

// Client returns an HTTP client that sends src's token on every request, for
// calling another service with a service-account token. It never follows a
// redirect to another host or scheme -- oauth2.Transport would re-add the token
// on that hop -- and returns the 3xx response instead.
func (s *ServiceAccount) Client(src oauth2.TokenSource) *http.Client {
	return &http.Client{
		Transport: &oauth2.Transport{Source: src},
		Timeout:   30 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if redirectedAwayFromOrigin(req) {
				return http.ErrUseLastResponse
			}
			if len(via) >= 10 {
				return errors.New("identity: stopped after 10 redirects")
			}
			return nil
		},
	}
}

// newSource builds a caching token source; the caller holds s.mu. The context
// carries only the HTTP client and is never a request's, so a cancelled request
// cannot break the source's later refreshes.
func (s *ServiceAccount) newSource(extra []string) oauth2.TokenSource {
	cc := clientcredentials.Config{
		ClientID:     s.cfg.ClientID,
		ClientSecret: s.cfg.ClientSecret,
		TokenURL:     s.cfg.TokenURL,
		Scopes:       append(append([]string{}, s.cfg.Scopes...), extra...),
	}
	ctx := context.WithValue(context.Background(), oauth2.HTTPClient, s.httpClient)
	return cc.TokenSource(ctx) // a ReuseTokenSource: cached until the token expires
}
