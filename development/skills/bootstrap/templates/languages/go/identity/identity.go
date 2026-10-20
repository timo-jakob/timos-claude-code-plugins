// Package identity is the canonical in-process OIDC validation payload for Go
// services (#2861, realizing the identity position of #1186 -- ARCHITECTURE.md,
// "Identity and authorization -- OIDC at the edge, claims as the only input").
//
// The service validates and authorizes; a gateway may validate first, but never
// instead. So every request to the APPLICATION handler carries a bearer access
// token that this package verifies here, in the service:
//
//   - the token's `iss` must be in a configured, environment-scoped ALLOWLIST of
//     issuers. The token chooses AMONG the listed issuers and never introduces
//     one: an unlisted `iss` is rejected before any discovery or JWKS request is
//     made. Fetching keys from whatever issuer a token names would accept any
//     token from anyone who serves a JWKS document -- not weaker validation, none.
//   - the signature is verified against that issuer's published keys with the
//     issuer's CONFIGURED expected algorithm (default RS256). The token's own
//     `alg` header never picks the algorithm, so `alg: none` and HS256-with-the-
//     public-key confusion are rejected rather than negotiated.
//   - `iss`, `aud` and `exp` are checked by go-oidc's verifier.
//
// Issuer-awareness: one verifier per allowlisted issuer, built LAZILY on that
// issuer's first token (discovery + JWKS), so a tenant served from a dedicated
// issuer needs a config entry, not a code change -- and an issuer that is down
// at startup does not stop the service from booting. go-oidc's remote key set
// re-fetches the JWKS when a token is signed by a key it has not seen, so a key
// rotation is picked up without a restart.
//
// There is NO trusted-header mode and NO switch that disables validation -- not
// for local development, not for service-to-service calls. Local development
// lists a dev issuer in a LOCAL-development allowlist only (README.md). A flag
// that turns validation off is a code path in the shipped binary, and "off in
// development" is one misread environment variable away from "off".
//
// The ops surface is outside the token rule only because it is served on the
// separate MANAGEMENT port by the ops payload (internal/ops). Wrap ONLY the
// application handler with Middleware, and register the gRPC server
// interceptors ONLY on the application grpc.Server -- never the management
// server.
//
// PLACEMENT: every file of this payload goes into internal/identity/ (package
// identity) of the module that builds the service binary, and go.mod.deps is
// folded into that module's go.mod. See README.md.
package identity

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

// DefaultAlgorithm is the expected signing algorithm of an issuer whose config
// names none. Keycloak signs access tokens with RS256 by default.
const DefaultAlgorithm = oidc.RS256

// Default claim names follow Keycloak's conventions: Keycloak Organizations emits
// the tenant as `organization`, and realm roles live under `realm_access.roles`.
const (
	DefaultTenantClaim = "organization"
	DefaultRolesClaim  = "realm_access.roles"
)

// Issuer is one allowlisted issuer.
type Issuer struct {
	// URL is the issuer identifier, exactly as the token's `iss` carries it and
	// as the issuer's discovery document declares it.
	URL string
	// Algorithm is the one signing algorithm this issuer's tokens are verified
	// with. Empty means DefaultAlgorithm.
	Algorithm string
}

// Config configures a Validator.
type Config struct {
	// Issuers is the environment-scoped allowlist. A deployed environment lists
	// only its own provider; a dev issuer belongs only in a LOCAL-development
	// allowlist. Required: an empty allowlist would reject every token, which is
	// a misconfiguration worth failing at startup rather than at the first call.
	Issuers []Issuer
	// Audience is the `aud` value this service accepts -- its own client id.
	// Required.
	Audience string
	// TenantClaim names the claim the tenant is read from. Empty means
	// DefaultTenantClaim.
	TenantClaim string
	// RolesClaim is the dot-separated path to the roles array. Empty means
	// DefaultRolesClaim.
	RolesClaim string
	// HTTPClient makes the discovery and JWKS requests. nil means a client with
	// a 10s timeout: an unbounded fetch would hang every request behind it.
	HTTPClient *http.Client
}

// ConfigFromEnv reads the Config from the environment, which is where the
// environment-scoped allowlist belongs:
//
//	OIDC_ISSUERS       comma-separated issuer URLs, each optionally `=ALG`
//	                   (e.g. "https://keycloak.prod.example/realms/platform=RS256")
//	OIDC_AUDIENCE      the service's client id
//	OIDC_TENANT_CLAIM  optional, default "organization"
//	OIDC_ROLES_CLAIM   optional, default "realm_access.roles"
//
// It returns an error for a missing allowlist or audience rather than a Config
// that rejects everything.
func ConfigFromEnv() (Config, error) {
	cfg := Config{
		Audience:    strings.TrimSpace(os.Getenv("OIDC_AUDIENCE")),
		TenantClaim: strings.TrimSpace(os.Getenv("OIDC_TENANT_CLAIM")),
		RolesClaim:  strings.TrimSpace(os.Getenv("OIDC_ROLES_CLAIM")),
	}
	for _, entry := range strings.Split(os.Getenv("OIDC_ISSUERS"), ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		iss := Issuer{URL: entry}
		// An issuer identifier carries no query component (OIDC Discovery 1.0,
		// section 2), so any '=' in an entry introduces its algorithm.
		if i := strings.LastIndex(entry, "="); i > 0 {
			iss = Issuer{URL: entry[:i], Algorithm: entry[i+1:]}
		}
		cfg.Issuers = append(cfg.Issuers, iss)
	}
	if err := cfg.validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// supportedAlgorithms is the closed set an issuer may be configured with. HS*
// is deliberately absent: a symmetric key would have to be shared with every
// service that validates, and the public JWKS cannot carry it.
var supportedAlgorithms = map[string]bool{
	oidc.RS256: true, oidc.RS384: true, oidc.RS512: true,
	oidc.ES256: true, oidc.ES384: true, oidc.ES512: true,
	oidc.PS256: true, oidc.PS384: true, oidc.PS512: true,
	oidc.EdDSA: true,
}

func (c Config) validate() error {
	if len(c.Issuers) == 0 {
		return errors.New("identity: no issuers configured (set OIDC_ISSUERS)")
	}
	if c.Audience == "" {
		return errors.New("identity: no audience configured (set OIDC_AUDIENCE)")
	}
	seen := make(map[string]bool, len(c.Issuers))
	for _, iss := range c.Issuers {
		if iss.URL == "" {
			return errors.New("identity: an issuer has an empty URL")
		}
		if seen[iss.URL] {
			return fmt.Errorf("identity: issuer %q is listed twice", iss.URL)
		}
		seen[iss.URL] = true
		if alg := iss.Algorithm; alg != "" && !supportedAlgorithms[alg] {
			return fmt.Errorf("identity: issuer %q has unsupported algorithm %q", iss.URL, alg)
		}
	}
	return nil
}

// Errors a Validate call can return, for a caller that wants to tell them apart.
// Middleware answers every one of them with the same 401, and the gRPC server
// interceptors with the same codes.Unauthenticated.
var (
	ErrNoToken         = errors.New("identity: no bearer token")
	ErrMalformedToken  = errors.New("identity: malformed token")
	ErrIssuerNotListed = errors.New("identity: token issuer is not in the allowlist")
	ErrInvalidToken    = errors.New("identity: token failed verification")
	ErrInvalidClaims   = errors.New("identity: token claims are invalid")
)

// discoveryBackoff is how long a failed discovery is remembered. Inside it, a
// token for that issuer fails fast with the remembered error instead of every
// request starting -- and waiting on -- another fetch from an issuer that is
// down. After it, the next token retries, so a recovered issuer needs no restart.
const discoveryBackoff = 5 * time.Second

// issuerEntry holds one allowlisted issuer's verifier, built on first use. mu
// guards the fields only; it is never held across a network call.
type issuerEntry struct {
	issuer   Issuer
	mu       sync.Mutex
	verifier *oidc.IDTokenVerifier
	building chan struct{} // non-nil while a discovery runs; closed when it ends
	failErr  error         // the last discovery's error, nil after a success
	failedAt time.Time     // when failErr was recorded
}

// Validator verifies access tokens against the allowlist. Safe for concurrent use.
type Validator struct {
	audience   string
	claims     claimNames
	httpClient *http.Client
	issuers    map[string]*issuerEntry
	backoff    time.Duration    // discoveryBackoff; shortened only by tests
	now        func() time.Time // time.Now; replaced only by tests
}

// NewValidator returns a Validator for cfg. It makes no network request: each
// issuer's discovery and JWKS fetch happen on that issuer's first token.
func NewValidator(cfg Config) (*Validator, error) {
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	client := cfg.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	v := &Validator{
		audience:   cfg.Audience,
		claims:     newClaimNames(cfg.TenantClaim, cfg.RolesClaim),
		httpClient: client,
		issuers:    make(map[string]*issuerEntry, len(cfg.Issuers)),
		backoff:    discoveryBackoff,
		now:        time.Now,
	}
	for _, iss := range cfg.Issuers {
		if iss.Algorithm == "" {
			iss.Algorithm = DefaultAlgorithm
		}
		v.issuers[iss.URL] = &issuerEntry{issuer: iss}
	}
	return v, nil
}

// Issuers returns the allowlisted issuer URLs, sorted -- for a startup log line.
func (v *Validator) Issuers() []string {
	out := make([]string, 0, len(v.issuers))
	for url := range v.issuers {
		out = append(out, url)
	}
	sort.Strings(out)
	return out
}

// Validate verifies raw and returns its validated claims.
func (v *Validator) Validate(ctx context.Context, raw string) (Claims, error) {
	if raw == "" {
		return Claims{}, ErrNoToken
	}
	iss, err := unverifiedIssuer(raw)
	if err != nil {
		return Claims{}, err
	}
	// The allowlist guard comes BEFORE any verifier is built, so an unlisted
	// issuer never causes a discovery or JWKS request.
	entry, ok := v.issuers[iss]
	if !ok {
		return Claims{}, ErrIssuerNotListed
	}
	verifier, err := v.verifierFor(ctx, entry)
	if err != nil {
		return Claims{}, err
	}
	token, err := verifier.Verify(ctx, raw)
	if err != nil {
		return Claims{}, fmt.Errorf("%w: %v", ErrInvalidToken, err)
	}
	var payload map[string]any
	if err := token.Claims(&payload); err != nil {
		return Claims{}, fmt.Errorf("%w: %v", ErrInvalidClaims, err)
	}
	claims, err := v.claims.extract(payload)
	if err != nil {
		return Claims{}, err
	}
	claims.Subject = token.Subject
	claims.Issuer = token.Issuer
	return claims, nil
}

// verifierFor returns entry's verifier, starting its discovery on first use.
// Concurrent first tokens for one issuer share ONE discovery: the first starts
// it, every caller waits on the same channel -- or on its own request context,
// so a slow issuer never holds a request past its deadline. A failed discovery
// is remembered for v.backoff and then retried, never cached for good.
func (v *Validator) verifierFor(ctx context.Context, entry *issuerEntry) (*oidc.IDTokenVerifier, error) {
	entry.mu.Lock()
	if entry.verifier != nil {
		verifier := entry.verifier
		entry.mu.Unlock()
		return verifier, nil
	}
	if entry.failErr != nil && v.now().Sub(entry.failedAt) < v.backoff {
		err := entry.failErr
		entry.mu.Unlock()
		return nil, err
	}
	if entry.building == nil {
		entry.building = make(chan struct{})
		go v.discover(entry, entry.building)
	}
	done := entry.building
	entry.mu.Unlock()
	select {
	case <-done:
	case <-ctx.Done():
		return nil, fmt.Errorf("%w: issuer discovery: %v", ErrInvalidToken, ctx.Err())
	}
	entry.mu.Lock()
	defer entry.mu.Unlock()
	if entry.verifier != nil {
		return entry.verifier, nil
	}
	return nil, entry.failErr
}

// discover runs one discovery for entry WITHOUT holding entry.mu, then records
// its outcome and closes done. It is bounded by v.httpClient's timeout.
func (v *Validator) discover(entry *issuerEntry, done chan struct{}) {
	// A background context carrying only the HTTP client: go-oidc keeps this
	// context for the key set's later JWKS refreshes, so it must not be a
	// request context that is cancelled when the first request ends.
	ctx := oidc.ClientContext(context.Background(), v.httpClient)
	provider, err := oidc.NewProvider(ctx, entry.issuer.URL)
	entry.mu.Lock()
	defer entry.mu.Unlock()
	defer close(done)
	entry.building = nil
	if err != nil {
		entry.failErr = fmt.Errorf("%w: issuer discovery: %v", ErrInvalidToken, err)
		entry.failedAt = v.now()
		return
	}
	entry.failErr = nil
	entry.verifier = provider.VerifierContext(ctx, &oidc.Config{
		ClientID:             v.audience,
		SupportedSigningAlgs: []string{entry.issuer.Algorithm},
	})
}

// unverifiedIssuer reads `iss` from the token's payload WITHOUT verifying it.
// It is used only to choose among the allowlisted issuers; the chosen issuer's
// verifier then checks the signature and `iss` itself.
func unverifiedIssuer(raw string) (string, error) {
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return "", ErrMalformedToken
	}
	body, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", ErrMalformedToken
	}
	var claims struct {
		Issuer string `json:"iss"`
	}
	if err := json.Unmarshal(body, &claims); err != nil || claims.Issuer == "" {
		return "", ErrMalformedToken
	}
	return claims.Issuer, nil
}
