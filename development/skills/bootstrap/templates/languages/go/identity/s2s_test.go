package identity

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// resourceServer records the Authorization header of every request it gets.
type resourceServer struct {
	server   *httptest.Server
	mu       sync.Mutex
	auth     []string
	requests atomic.Int64
}

func newResourceServer(t *testing.T) *resourceServer {
	t.Helper()
	rs := &resourceServer{}
	rs.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rs.requests.Add(1)
		rs.mu.Lock()
		rs.auth = append(rs.auth, r.Header.Get("Authorization"))
		rs.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(rs.server.Close)
	return rs
}

func (rs *resourceServer) lastAuth() string {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if len(rs.auth) == 0 {
		return ""
	}
	return rs.auth[len(rs.auth)-1]
}

// tokenServer is an in-process client-credentials token endpoint. It records the
// scope of every token request and issues tokens with the lifetimes in expiries,
// one per request, repeating the last one.
type tokenServer struct {
	server   *httptest.Server
	mu       sync.Mutex
	scopes   []string
	expiries []int
}

func newTokenServer(t *testing.T, expiries ...int) *tokenServer {
	t.Helper()
	if len(expiries) == 0 {
		expiries = []int{3600}
	}
	ts := &tokenServer{expiries: expiries}
	ts.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil || r.PostForm.Get("grant_type") != "client_credentials" {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		ts.mu.Lock()
		n := len(ts.scopes)
		ts.scopes = append(ts.scopes, r.PostForm.Get("scope"))
		exp := ts.expiries[min(n, len(ts.expiries)-1)]
		ts.mu.Unlock()
		writeTestJSON(w, map[string]any{
			"access_token": fmt.Sprintf("sa-token-%d", n+1),
			"token_type":   "Bearer",
			"expires_in":   exp,
		})
	}))
	t.Cleanup(ts.server.Close)
	return ts
}

func (ts *tokenServer) fetched() []string {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	return append([]string{}, ts.scopes...)
}

func newTestServiceAccount(t *testing.T, ts *tokenServer) *ServiceAccount {
	t.Helper()
	sa, err := NewServiceAccount(ServiceAccountConfig{
		TokenURL: ts.server.URL, ClientID: "billing-nightly", ClientSecret: "s3cret",
	})
	if err != nil {
		t.Fatal(err)
	}
	return sa
}

// TestPropagationForwardsTheValidatedTokenUnchanged drives a real inbound request
// through Middleware, whose setter is the only writer of the caller token.
func TestPropagationForwardsTheValidatedTokenUnchanged(t *testing.T) {
	iss := newTestIssuer(t)
	orders := newResourceServer(t)
	client := &http.Client{Transport: &PropagatingTransport{}}
	var outboundErr error
	app := Middleware(newTestValidator(t, iss))(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		req, _ := http.NewRequestWithContext(r.Context(), http.MethodGet, orders.server.URL+"/orders", nil)
		req.Header.Set("Authorization", "Bearer forged-by-the-handler")
		resp, err := client.Do(req)
		if err != nil {
			outboundErr = err
			return
		}
		_ = resp.Body.Close()
	}))
	raw := iss.sign(t, iss.claimsFor(nil))
	in := httptest.NewRequest(http.MethodGet, "/tenants/acme/orders", nil)
	in.Header.Set("Authorization", "Bearer "+raw)
	app.ServeHTTP(httptest.NewRecorder(), in)
	if outboundErr != nil {
		t.Fatalf("outbound call failed: %v", outboundErr)
	}
	// Unchanged, and the pre-set outbound header was overwritten.
	if got := orders.lastAuth(); got != "Bearer "+raw {
		t.Fatalf("outbound Authorization = %q, want the inbound validated token", got)
	}
}

func TestPropagationWithoutAValidatedTokenSendsNothing(t *testing.T) {
	orders := newResourceServer(t)
	client := &http.Client{Transport: &PropagatingTransport{}}
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, orders.server.URL, nil)
	// A header on the inbound side, or a value set by hand, is never a caller token.
	req.Header.Set("Authorization", "Bearer self-asserted")
	_, err := client.Do(req)
	if !errors.Is(err, ErrNoCallerToken) {
		t.Fatalf("err = %v, want ErrNoCallerToken", err)
	}
	if n := orders.requests.Load(); n != 0 {
		t.Fatalf("resource server got %d requests, want 0", n)
	}
}

func TestPropagationDoesNotModifyTheCallersRequest(t *testing.T) {
	orders := newResourceServer(t)
	ctx := withCallerToken(context.Background(), "validated-token")
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, orders.server.URL, nil)
	req.Header.Set("Authorization", "Bearer original")
	resp, err := (&PropagatingTransport{}).RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if got := req.Header.Get("Authorization"); got != "Bearer original" {
		t.Fatalf("the caller's request was modified: %q", got)
	}
	if got := orders.lastAuth(); got != "Bearer validated-token" {
		t.Fatalf("outbound Authorization = %q", got)
	}
}

func TestServiceAccountTokenIsCachedAndRefreshedOnExpiry(t *testing.T) {
	// The first token is already inside oauth2's expiry window (5s < its 10s
	// delta), so the second call must refresh; the second token lasts an hour,
	// so the third call is served from the cache.
	ts := newTokenServer(t, 5, 3600)
	src := newTestServiceAccount(t, ts).TokenSource()
	want := []string{"sa-token-1", "sa-token-2", "sa-token-2"}
	for i, w := range want {
		tok, err := src.Token()
		if err != nil {
			t.Fatal(err)
		}
		if tok.AccessToken != w {
			t.Fatalf("call %d: token %q, want %q", i+1, tok.AccessToken, w)
		}
	}
	if n := len(ts.fetched()); n != 2 {
		t.Fatalf("token endpoint hit %d times, want 2", n)
	}
}

func TestServiceAccountTokensAreIsolatedPerTenant(t *testing.T) {
	ts := newTokenServer(t)
	sa := newTestServiceAccount(t, ts)
	token := func(tenant string) string {
		t.Helper()
		src := sa.TokenSource()
		if tenant != "" {
			var err error
			if src, err = sa.TenantTokenSource(tenant); err != nil {
				t.Fatal(err)
			}
		}
		tok, err := src.Token()
		if err != nil {
			t.Fatal(err)
		}
		return tok.AccessToken
	}
	acme, globex, none := token("acme"), token("globex"), token("")
	if acme == globex || acme == none || globex == none {
		t.Fatalf("tokens shared across tenants: acme=%s globex=%s tenant-less=%s", acme, globex, none)
	}
	if again := token("acme"); again != acme {
		t.Fatalf("repeat tenant-A call got %s, want the cached %s", again, acme)
	}
	got := ts.fetched()
	want := []string{"organization:acme", "organization:globex", ""}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("token requests' scopes = %q, want %q (the repeat call served from cache)", got, want)
	}
}

func TestServiceAccountScopeTemplateAndTenantValidation(t *testing.T) {
	ts := newTokenServer(t)
	sa, err := NewServiceAccount(ServiceAccountConfig{
		TokenURL: ts.server.URL, ClientID: "billing-nightly",
		Scopes: []string{"billing.write"}, TenantScopeTemplate: "tenant/{tenant}",
	})
	if err != nil {
		t.Fatal(err)
	}
	src, err := sa.TenantTokenSource("acme")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := src.Token(); err != nil {
		t.Fatal(err)
	}
	if got := ts.fetched(); len(got) != 1 || got[0] != "billing.write tenant/acme" {
		t.Fatalf("scope = %q, want the template applied beside the base scopes", got)
	}
	for _, bad := range []string{"", "acme openid", "acme\tadmin"} {
		if _, err := sa.TenantTokenSource(bad); !errors.Is(err, ErrInvalidTenant) {
			t.Errorf("tenant %q: err = %v, want ErrInvalidTenant", bad, err)
		}
	}
	for name, cfg := range map[string]ServiceAccountConfig{
		"no token url":          {ClientID: "c"},
		"no client id":          {TokenURL: ts.server.URL},
		"template without slot": {TokenURL: ts.server.URL, ClientID: "c", TenantScopeTemplate: "organization"},
	} {
		if _, err := NewServiceAccount(cfg); err == nil {
			t.Errorf("%s: NewServiceAccount accepted it", name)
		}
	}
}

func TestServiceAccountClientSendsItsToken(t *testing.T) {
	ts := newTokenServer(t)
	billing := newResourceServer(t)
	sa := newTestServiceAccount(t, ts)
	src, err := sa.TenantTokenSource("acme")
	if err != nil {
		t.Fatal(err)
	}
	resp, err := sa.Client(src).Get(billing.server.URL)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if got := billing.lastAuth(); got != "Bearer sa-token-1" {
		t.Fatalf("Authorization = %q, want the service-account token", got)
	}
}

// roundTripFunc adapts a function to http.RoundTripper.
type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// TestNoTokenFollowsARedirectToAnotherHost: a downstream answering 302 to a
// second host must not hand either token to it.
func TestNoTokenFollowsARedirectToAnotherHost(t *testing.T) {
	elsewhere := newResourceServer(t)
	redirector := httptest.NewServer(http.RedirectHandler(elsewhere.server.URL, http.StatusFound))
	t.Cleanup(redirector.Close)

	ctx := withCallerToken(context.Background(), "validated-token")
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, redirector.URL, nil)
	resp, err := (&http.Client{Transport: &PropagatingTransport{}}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if n, got := elsewhere.requests.Load(), elsewhere.lastAuth(); n != 1 || got != "" {
		t.Fatalf("propagation: redirect target got %d requests, Authorization %q; want 1, none", n, got)
	}

	// A Base that leaves resp.Request unset breaks the walk back to the
	// origin; the hop must still go out without the token.
	stripping := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		resp, err := http.DefaultTransport.RoundTrip(r)
		if resp != nil {
			resp.Request = nil
		}
		return resp, err
	})
	req, _ = http.NewRequestWithContext(ctx, http.MethodGet, redirector.URL, nil)
	resp, err = (&http.Client{Transport: &PropagatingTransport{Base: stripping}}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if n, got := elsewhere.requests.Load(), elsewhere.lastAuth(); n != 2 || got != "" {
		t.Fatalf("stripping Base: redirect target got %d requests, Authorization %q; want 2, none", n, got)
	}

	sa := newTestServiceAccount(t, newTokenServer(t))
	resp, err = sa.Client(sa.TokenSource()).Get(redirector.URL)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusFound || elsewhere.requests.Load() != 2 {
		t.Fatalf("service account: status %d, redirect target requests %d; want 302 and none followed",
			resp.StatusCode, elsewhere.requests.Load())
	}

	// A same-host https-to-http downgrade leaves the origin too: the token
	// would otherwise cross the wire in cleartext.
	downgrade := httptest.NewRequest(http.MethodGet, "http://orders.internal/x/", nil)
	downgrade.Response = &http.Response{Request: httptest.NewRequest(http.MethodGet, "https://orders.internal/x", nil)}
	if !redirectedAwayFromOrigin(downgrade) {
		t.Fatal("an https-to-http redirect on the same host must count as leaving the origin")
	}
}
