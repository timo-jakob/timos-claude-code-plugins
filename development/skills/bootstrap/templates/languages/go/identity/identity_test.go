package identity

import (
	"context"
	"crypto"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// testIssuer is an in-process OIDC issuer: it serves a discovery document and a
// JWKS, counts every request, and can rotate its signing key.
type testIssuer struct {
	server      *httptest.Server
	requests    atomic.Int64
	discoveries atomic.Int64                  // discovery-document requests only
	failing     atomic.Bool                   // answer 500 to everything while set
	hold        atomic.Pointer[chan struct{}] // discovery blocks until it is closed

	mu  sync.Mutex
	key *rsa.PrivateKey
	kid string
}

func newTestIssuer(t *testing.T) *testIssuer {
	t.Helper()
	iss := &testIssuer{}
	iss.rotate(t)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		if h := iss.hold.Load(); h != nil {
			<-*h
		}
		writeTestJSON(w, map[string]any{
			"issuer":                                iss.url(),
			"jwks_uri":                              iss.url() + "/jwks",
			"id_token_signing_alg_values_supported": []string{"RS256"},
		})
	})
	mux.HandleFunc("GET /jwks", func(w http.ResponseWriter, _ *http.Request) {
		iss.mu.Lock()
		pub := iss.key.PublicKey
		kid := iss.kid
		iss.mu.Unlock()
		writeTestJSON(w, map[string]any{"keys": []map[string]string{{
			"kty": "RSA", "use": "sig", "alg": "RS256", "kid": kid,
			"n": b64(pub.N.Bytes()), "e": b64(big.NewInt(int64(pub.E)).Bytes()),
		}}})
	})
	iss.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		iss.requests.Add(1)
		if r.URL.Path == "/.well-known/openid-configuration" {
			iss.discoveries.Add(1)
		}
		if iss.failing.Load() {
			http.Error(w, "down", http.StatusInternalServerError)
			return
		}
		mux.ServeHTTP(w, r)
	}))
	t.Cleanup(iss.server.Close)
	return iss
}

func (i *testIssuer) url() string { return i.server.URL }

// stallDiscovery makes discovery block until the returned release is called.
// release also runs at cleanup, before the server closes, so no test leaves a
// discovery hanging.
func (i *testIssuer) stallDiscovery(t *testing.T) (release func()) {
	t.Helper()
	ch := make(chan struct{})
	i.hold.Store(&ch)
	var once sync.Once
	release = func() { once.Do(func() { close(ch) }) }
	t.Cleanup(release)
	return release
}

// testClock is a frozen Validator clock: only advance moves it, so a test's
// margins never depend on how fast the runner is.
type testClock struct {
	base   time.Time
	offset atomic.Int64
}

func (c *testClock) now() time.Time { return c.base.Add(time.Duration(c.offset.Load())) }

func (c *testClock) advance(d time.Duration) { c.offset.Add(int64(d)) }

func withTestClock(v *Validator) *testClock {
	c := &testClock{base: time.Now()}
	v.now = c.now
	return c
}

// rotate replaces the signing key; the JWKS serves only the new one from now on.
func (i *testIssuer) rotate(t *testing.T) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	i.key = key
	i.kid = "kid-" + b64(key.N.Bytes()[:6])
}

// sign issues an RS256 token with this issuer's current key.
func (i *testIssuer) sign(t *testing.T, claims map[string]any) string {
	t.Helper()
	i.mu.Lock()
	key, kid := i.key, i.kid
	i.mu.Unlock()
	return signRS256(t, key, kid, claims)
}

// claimsFor are valid claims for this issuer: the shape the use case sketches.
func (i *testIssuer) claimsFor(overrides map[string]any) map[string]any {
	c := map[string]any{
		"iss":          i.url(),
		"sub":          "user-4711",
		"aud":          "orders-service",
		"exp":          time.Now().Add(5 * time.Minute).Unix(),
		"iat":          time.Now().Unix(),
		"organization": []string{"acme"},
		"realm_access": map[string]any{"roles": []string{"orders-reader"}},
	}
	for k, v := range overrides {
		if v == nil {
			delete(c, k)
			continue
		}
		c[k] = v
	}
	return c
}

func signRS256(t *testing.T, key *rsa.PrivateKey, kid string, claims map[string]any) string {
	t.Helper()
	input := segment(t, map[string]any{"alg": "RS256", "typ": "JWT", "kid": kid}) + "." + segment(t, claims)
	digest := sha256.Sum256([]byte(input))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return input + "." + b64(sig)
}

func segment(t *testing.T, v any) string {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b64(raw)
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func writeTestJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func newTestValidator(t *testing.T, issuers ...*testIssuer) *Validator {
	t.Helper()
	cfg := Config{Audience: "orders-service"}
	for _, iss := range issuers {
		cfg.Issuers = append(cfg.Issuers, Issuer{URL: iss.url()})
	}
	v, err := NewValidator(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestValidTokenYieldsTenantAndRoles(t *testing.T) {
	iss := newTestIssuer(t)
	v := newTestValidator(t, iss)
	claims, err := v.Validate(context.Background(), iss.sign(t, iss.claimsFor(nil)))
	if err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	if !claims.HasTenant || claims.Tenant != "acme" {
		t.Fatalf("tenant = %q (has %v), want acme", claims.Tenant, claims.HasTenant)
	}
	if !claims.HasRole("orders-reader") || claims.Subject != "user-4711" || claims.Issuer != iss.url() {
		t.Fatalf("unexpected claims %+v", claims)
	}
}

func TestUnlistedIssuerIsRejectedWithoutAnyRequest(t *testing.T) {
	listed := newTestIssuer(t)
	unlisted := newTestIssuer(t)
	v := newTestValidator(t, listed)
	_, err := v.Validate(context.Background(), unlisted.sign(t, unlisted.claimsFor(nil)))
	if !errors.Is(err, ErrIssuerNotListed) {
		t.Fatalf("err = %v, want ErrIssuerNotListed", err)
	}
	if n := unlisted.requests.Load() + listed.requests.Load(); n != 0 {
		t.Fatalf("an unlisted issuer caused %d discovery/JWKS requests, want 0", n)
	}
}

func TestAlgNoneIsRejected(t *testing.T) {
	iss := newTestIssuer(t)
	v := newTestValidator(t, iss)
	raw := segment(t, map[string]any{"alg": "none", "typ": "JWT"}) + "." + segment(t, iss.claimsFor(nil)) + "."
	if _, err := v.Validate(context.Background(), raw); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("alg none: err = %v, want ErrInvalidToken", err)
	}
}

func TestHS256SignedWithThePublicKeyIsRejected(t *testing.T) {
	iss := newTestIssuer(t)
	v := newTestValidator(t, iss)
	iss.mu.Lock()
	pub, err := x509.MarshalPKIXPublicKey(&iss.key.PublicKey)
	kid := iss.kid
	iss.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	input := segment(t, map[string]any{"alg": "HS256", "typ": "JWT", "kid": kid}) + "." + segment(t, iss.claimsFor(nil))
	mac := hmac.New(sha256.New, pub)
	mac.Write([]byte(input))
	raw := input + "." + b64(mac.Sum(nil))
	if _, err := v.Validate(context.Background(), raw); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("HS256 confusion: err = %v, want ErrInvalidToken", err)
	}
}

func TestWrongAudienceIssuerKeyAndExpiryAreRejected(t *testing.T) {
	iss := newTestIssuer(t)
	other := newTestIssuer(t)
	v := newTestValidator(t, iss, other)
	cases := map[string]string{
		"wrong aud": iss.sign(t, iss.claimsFor(map[string]any{"aud": "billing-service"})),
		"expired":   iss.sign(t, iss.claimsFor(map[string]any{"exp": time.Now().Add(-time.Minute).Unix()})),
		// Claims a listed issuer, but is signed by another listed issuer's key.
		"iss of one issuer, key of another": other.sign(t, iss.claimsFor(nil)),
	}
	for name, raw := range cases {
		if _, err := v.Validate(context.Background(), raw); !errors.Is(err, ErrInvalidToken) {
			t.Errorf("%s: err = %v, want ErrInvalidToken", name, err)
		}
	}
}

func TestKeyRotationIsPickedUpWithoutARestart(t *testing.T) {
	iss := newTestIssuer(t)
	v := newTestValidator(t, iss)
	if _, err := v.Validate(context.Background(), iss.sign(t, iss.claimsFor(nil))); err != nil {
		t.Fatalf("before rotation: %v", err)
	}
	iss.rotate(t)
	// The same Validator -- no restart -- must accept a token signed by the new
	// key, which it can only do by re-fetching the JWKS.
	if _, err := v.Validate(context.Background(), iss.sign(t, iss.claimsFor(nil))); err != nil {
		t.Fatalf("after rotation: %v", err)
	}
}

func TestFailedDiscoveryIsRetriedNotCached(t *testing.T) {
	iss := newTestIssuer(t)
	v := newTestValidator(t, iss)
	clock := withTestClock(v)
	iss.failing.Store(true)
	if _, err := v.Validate(context.Background(), iss.sign(t, iss.claimsFor(nil))); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("issuer down: err = %v, want ErrInvalidToken", err)
	}
	iss.failing.Store(false)
	clock.advance(v.backoff)
	if _, err := v.Validate(context.Background(), iss.sign(t, iss.claimsFor(nil))); err != nil {
		t.Fatalf("issuer back up, backoff over: %v", err)
	}
}

func TestFailedDiscoveryFailsFastInsideTheBackoff(t *testing.T) {
	iss := newTestIssuer(t)
	v := newTestValidator(t, iss)
	clock := withTestClock(v)
	iss.failing.Store(true)
	raw := iss.sign(t, iss.claimsFor(nil))
	if _, err := v.Validate(context.Background(), raw); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("issuer down: err = %v, want ErrInvalidToken", err)
	}
	// Inside the backoff the remembered failure answers, with no new request --
	// even though the issuer has recovered in the meantime.
	iss.failing.Store(false)
	clock.advance(v.backoff - time.Millisecond)
	for range 5 {
		if _, err := v.Validate(context.Background(), raw); !errors.Is(err, ErrInvalidToken) {
			t.Fatalf("inside the backoff: err = %v, want ErrInvalidToken", err)
		}
	}
	if n := iss.discoveries.Load(); n != 1 {
		t.Fatalf("%d discovery requests inside the backoff, want 1", n)
	}
	clock.advance(time.Millisecond)
	if _, err := v.Validate(context.Background(), raw); err != nil {
		t.Fatalf("backoff over: %v", err)
	}
	if n := iss.discoveries.Load(); n != 2 {
		t.Fatalf("%d discovery requests after the backoff, want 2", n)
	}
}

func TestConcurrentFirstTokensShareOneDiscovery(t *testing.T) {
	iss := newTestIssuer(t)
	v := newTestValidator(t, iss)
	release := iss.stallDiscovery(t)
	raw := iss.sign(t, iss.claimsFor(nil))
	const callers = 8
	errs := make(chan error, callers)
	for range callers {
		go func() {
			_, err := v.Validate(context.Background(), raw)
			errs <- err
		}()
	}
	// Give every caller time to reach the stalled discovery before it answers.
	time.Sleep(100 * time.Millisecond)
	release()
	for range callers {
		if err := <-errs; err != nil {
			t.Errorf("concurrent first token: %v", err)
		}
	}
	if n := iss.discoveries.Load(); n != 1 {
		t.Fatalf("%d discovery requests for %d concurrent first tokens, want 1", n, callers)
	}
}

func TestWaiterGivesUpOnItsOwnContext(t *testing.T) {
	iss := newTestIssuer(t)
	v := newTestValidator(t, iss)
	iss.stallDiscovery(t)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := v.Validate(ctx, iss.sign(t, iss.claimsFor(nil))); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("stalled issuer: err = %v, want ErrInvalidToken", err)
	}
	if waited := time.Since(start); waited > 2*time.Second {
		t.Fatalf("waited %v on a stalled discovery, want about the request's 50ms deadline", waited)
	}
}

func TestTenantClaimShapes(t *testing.T) {
	iss := newTestIssuer(t)
	v := newTestValidator(t, iss)
	cases := []struct {
		name       string
		org        any
		wantTenant string
		wantHas    bool
		wantErr    error
	}{
		{"single entry", []string{"acme"}, "acme", true, nil},
		{"object keyed by alias", map[string]any{"acme": map[string]any{}}, "acme", true, nil},
		{"multiple entries", []string{"acme", "globex"}, "", false, ErrInvalidClaims},
		{"absent", nil, "", false, nil},
	}
	for _, tc := range cases {
		claims, err := v.Validate(context.Background(), iss.sign(t, iss.claimsFor(map[string]any{"organization": tc.org})))
		if tc.wantErr != nil {
			if !errors.Is(err, tc.wantErr) {
				t.Errorf("%s: err = %v, want %v", tc.name, err, tc.wantErr)
			}
			continue
		}
		if err != nil || claims.Tenant != tc.wantTenant || claims.HasTenant != tc.wantHas {
			t.Errorf("%s: claims %+v err %v, want tenant %q has %v", tc.name, claims, err, tc.wantTenant, tc.wantHas)
		}
	}
}

func TestClaimNamesAreConfigurable(t *testing.T) {
	iss := newTestIssuer(t)
	v, err := NewValidator(Config{
		Issuers:     []Issuer{{URL: iss.url()}},
		Audience:    "orders-service",
		TenantClaim: "tenant_id",
		RolesClaim:  "resource_access.orders-service.roles",
	})
	if err != nil {
		t.Fatal(err)
	}
	raw := iss.sign(t, iss.claimsFor(map[string]any{
		"organization":    []string{"not-the-tenant", "ignored"},
		"tenant_id":       "acme",
		"resource_access": map[string]any{"orders-service": map[string]any{"roles": []string{"orders-admin"}}},
	}))
	claims, err := v.Validate(context.Background(), raw)
	if err != nil {
		t.Fatalf("custom claim names: %v", err)
	}
	if claims.Tenant != "acme" || !claims.HasRole("orders-admin") || claims.HasRole("orders-reader") {
		t.Fatalf("unexpected claims %+v", claims)
	}
}

// ordersApp is an application handler whose route names a tenant.
func ordersApp() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /tenants/{tenant}/orders", func(w http.ResponseWriter, r *http.Request) {
		if err := RequireTenant(r.Context(), r.PathValue("tenant")); err != nil {
			Forbidden(w)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	return mux
}

func TestRequestNamedTenantIsComparedToTheClaim(t *testing.T) {
	iss := newTestIssuer(t)
	app := Middleware(newTestValidator(t, iss))(ordersApp())
	acme := iss.sign(t, iss.claimsFor(nil))
	tenantless := iss.sign(t, iss.claimsFor(map[string]any{"organization": nil}))
	cases := []struct {
		name, path, token string
		want              int
	}{
		{"matching tenant", "/tenants/acme/orders", acme, http.StatusOK},
		{"other tenant", "/tenants/globex/orders", acme, http.StatusForbidden},
		{"token without tenant", "/tenants/acme/orders", tenantless, http.StatusForbidden},
	}
	for _, tc := range cases {
		req := httptest.NewRequest(http.MethodGet, tc.path, nil)
		req.Header.Set("Authorization", "Bearer "+tc.token)
		rec := httptest.NewRecorder()
		app.ServeHTTP(rec, req)
		if rec.Code != tc.want {
			t.Errorf("%s: status %d, want %d", tc.name, rec.Code, tc.want)
		}
	}
}

func TestRequireTenantErrors(t *testing.T) {
	ctx := withClaims(context.Background(), Claims{Tenant: "acme", HasTenant: true})
	if err := RequireTenant(ctx, "globex"); !errors.Is(err, ErrTenantMismatch) {
		t.Errorf("mismatch: err = %v", err)
	}
	if err := RequireTenant(withClaims(context.Background(), Claims{}), "acme"); !errors.Is(err, ErrNoTenant) {
		t.Errorf("no tenant claim: err = %v", err)
	}
	if err := RequireTenant(context.Background(), "acme"); !errors.Is(err, ErrNoTenant) {
		t.Errorf("no claims at all: err = %v", err)
	}
}

func TestMiddlewareRejectsMissingAndInvalidTokens(t *testing.T) {
	iss := newTestIssuer(t)
	app := Middleware(newTestValidator(t, iss))(ordersApp())
	for name, header := range map[string]string{
		"no header":     "",
		"basic scheme":  "Basic dXNlcjpwYXNz",
		"garbage token": "Bearer not.a.token",
		"wrong aud":     "Bearer " + iss.sign(t, iss.claimsFor(map[string]any{"aud": "billing-service"})),
	} {
		req := httptest.NewRequest(http.MethodGet, "/tenants/acme/orders", nil)
		if header != "" {
			req.Header.Set("Authorization", header)
		}
		// A trusted-identity header must change nothing.
		req.Header.Set("X-Tenant-Id", "acme")
		rec := httptest.NewRecorder()
		app.ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized || !strings.HasPrefix(rec.Header().Get("WWW-Authenticate"), "Bearer") {
			t.Errorf("%s: status %d challenge %q, want 401 Bearer", name, rec.Code, rec.Header().Get("WWW-Authenticate"))
		}
	}
}

func TestConfigFromEnv(t *testing.T) {
	t.Setenv("OIDC_ISSUERS", "https://keycloak.prod.example/realms/platform=RS256, https://keycloak.prod.example/realms/acme")
	t.Setenv("OIDC_AUDIENCE", "orders-service")
	cfg, err := ConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	want := []Issuer{
		{URL: "https://keycloak.prod.example/realms/platform", Algorithm: "RS256"},
		{URL: "https://keycloak.prod.example/realms/acme"},
	}
	if len(cfg.Issuers) != 2 || cfg.Issuers[0] != want[0] || cfg.Issuers[1] != want[1] || cfg.Audience != "orders-service" {
		t.Fatalf("cfg = %+v", cfg)
	}
}

func TestConfigRejectsWhatWouldBeABypass(t *testing.T) {
	cases := map[string]Config{
		"no issuers":       {Audience: "orders-service"},
		"no audience":      {Issuers: []Issuer{{URL: "https://keycloak.prod.example/realms/platform"}}},
		"symmetric alg":    {Audience: "a", Issuers: []Issuer{{URL: "https://i.example", Algorithm: "HS256"}}},
		"alg none":         {Audience: "a", Issuers: []Issuer{{URL: "https://i.example", Algorithm: "none"}}},
		"duplicate issuer": {Audience: "a", Issuers: []Issuer{{URL: "https://i.example"}, {URL: "https://i.example"}}},
	}
	for name, cfg := range cases {
		if _, err := NewValidator(cfg); err == nil {
			t.Errorf("%s: NewValidator accepted it", name)
		}
	}
}
