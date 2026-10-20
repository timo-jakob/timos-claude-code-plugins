#!/usr/bin/env bats
#
# Structural tests for the canonical Go identity payload (#2861, realizing the
# identity position of #1186) — the in-process OIDC validation, claim extraction
# and authorization seam bootstrap places into internal/identity/.
#
# The Go toolchain is NOT in the test image (see tests/Dockerfile), so these are
# grep-based, exactly like tests/go-resilience-payload.bats: the payload's own
# behaviour tests (identity_test.go, carveout_test.go — httptest issuers serving
# discovery + JWKS, a key rotation, the ops carve-out) run under the bootstrapped
# repo's `go test`. What these pin is the security shape a careless edit would
# break silently, under that file's three rules:
#
#   1. ANCHOR EVERY NEEDLE TO CODE, NEVER TO PROSE — `flatten` strips comment
#      lines, and this payload's doc comments name every check they implement.
#   2. PIN A GUARD TOGETHER WITH ITS BODY, AS ONE NEEDLE.
#   3. NO NEEDLE MAY SPAN A SOURCE LINE.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ID="$REPO_ROOT/development/skills/bootstrap/templates/languages/go/identity"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
}

# go_func <file> <signature-prefix> — one top-level Go declaration, proven closed
# by a sentinel (see tests/go-resilience-payload.bats for why a shape check is
# not enough).
go_func() {
  local body
  body="$(awk -v sig="$2" '
    index($0, "func " sig) == 1 { inside = 1 }
    inside { print }
    inside && /^}$/ { print "//go_func:closed"; exit }
  ' "$1")"
  case "$body" in
    *"//go_func:closed") printf '%s' "${body%//go_func:closed}" ;;
    *) echo "go_func: 'func $2' not found in $1, or its block never closed" >&2; return 1 ;;
  esac
}

flatten() { printf '%s' "$1" | grep -v '^[[:space:]]*//' | tr -s ' \t\n' ' '; }

fn_flat() { local b; b="$(go_func "$ID/$1" "$2")" || return 1; flatten "$b"; }

# code_of <file> — the file with whole-line comments dropped, whitespace collapsed.
code_of() { [ -f "$1" ] || { echo "missing $1" >&2; return 1; }; flatten "$(cat "$1")"; }

# prod_code — every NON-test .go file of the payload, comments dropped. Guarded:
# an empty haystack would make every `lacks` below pass unconditionally.
prod_code() {
  local f out=""
  for f in identity.go claims.go middleware.go s2s.go; do
    out="$out $(code_of "$ID/$f")" || return 1
  done
  [ -n "${out// /}" ] || { echo "prod_code: empty haystack" >&2; return 1; }
  printf '%s' "$out"
}

@test "go identity payload files exist at the SKILL render paths" {
  [ -f "$ID/identity.go" ]
  [ -f "$ID/claims.go" ]
  [ -f "$ID/middleware.go" ]
  [ -f "$ID/identity_test.go" ]
  [ -f "$ID/carveout_test.go" ]
  [ -f "$ID/s2s.go" ]
  [ -f "$ID/s2s_test.go" ]
  [ -f "$ID/go.mod.deps" ]
  [ -f "$ID/README.md" ]
}

@test "go_func proves closure rather than inferring it (self-test)" {
  run ! go_func "$ID/identity.go" 'ThisDeclarationDoesNotExist('
}

@test "go identity files all declare package identity" {
  local f
  for f in identity.go claims.go middleware.go identity_test.go carveout_test.go s2s.go s2s_test.go; do
    grep -qE '^package identity$' "$ID/$f"
  done
}

@test "go identity go.mod.deps pins go-oidc/v3 and golang.org/x/oauth2, one require line each" {
  local deps; deps="$(grep -v '^//' "$ID/go.mod.deps")"
  contains "$deps" 'require github.com/coreos/go-oidc/v3 v3.'
  contains "$deps" 'require golang.org/x/oauth2 v0.'
  # one library per job: exactly these two require lines, and no require block
  [ "$(printf '%s\n' "$deps" | grep -c '^require ')" -eq 2 ]
  lacks "$deps" 'require ('
}

@test "go identity rejects an unlisted issuer BEFORE any verifier is built" {
  local fn; fn="$(fn_flat identity.go '(v *Validator) Validate(')"
  # the allowlist lookup, its rejection and only then the verifier — one needle,
  # so moving the build above the guard (a discovery request per unlisted iss) reds
  contains "$fn" 'entry, ok := v.issuers[iss] if !ok { return Claims{}, ErrIssuerNotListed } verifier, err := v.verifierFor(ctx, entry)'
}

@test "go identity pins each verifier's SupportedSigningAlgs to the issuer's configured algorithm" {
  local fn; fn="$(fn_flat identity.go '(v *Validator) discover(')"
  contains "$fn" 'SupportedSigningAlgs: []string{entry.issuer.Algorithm},'
  contains "$fn" 'ClientID: v.audience,'
  local nv; nv="$(fn_flat identity.go 'NewValidator(')"
  contains "$nv" 'if iss.Algorithm == "" { iss.Algorithm = DefaultAlgorithm }'
  contains "$(code_of "$ID/identity.go")" 'const DefaultAlgorithm = oidc.RS256'
}

@test "go identity admits no symmetric or none algorithm to the configurable set" {
  local code; code="$(code_of "$ID/identity.go")"
  contains "$code" 'var supportedAlgorithms = map[string]bool{'
  lacks "$code" 'oidc.HS'
  lacks "$code" '"HS'
  lacks "$code" '"none": true'
  local fn; fn="$(fn_flat identity.go '(c Config) validate(')"
  contains "$fn" 'if alg := iss.Algorithm; alg != "" && !supportedAlgorithms[alg] {'
}

@test "go identity builds verifiers lazily and does not cache a failed discovery" {
  local fn; fn="$(fn_flat identity.go '(v *Validator) verifierFor(')"
  contains "$fn" 'if entry.verifier != nil { verifier := entry.verifier entry.mu.Unlock() return verifier, nil }'
  local d; d="$(fn_flat identity.go '(v *Validator) discover(')"
  # a failure records the error and returns before the assignment, so it leaves the verifier nil
  contains "$d" 'if err != nil { entry.failErr = fmt.Errorf("%w: issuer discovery: %v", ErrInvalidToken, err) entry.failedAt = v.now() return } entry.failErr = nil entry.verifier = provider.VerifierContext(ctx,'
  # a background context, never the request's: the key set keeps it for refreshes
  contains "$d" 'ctx := oidc.ClientContext(context.Background(), v.httpClient)'
}

@test "go identity never holds the issuer lock across discovery, shares one discovery, and backs off a failure" {
  local fn; fn="$(fn_flat identity.go '(v *Validator) verifierFor(')"
  # the network call lives only in discover, which takes the lock AFTER it returns
  lacks "$fn" 'NewProvider('
  # the first lock is released on each early return, never deferred over the wait
  contains "$fn" 'error) { entry.mu.Lock() if entry.verifier != nil {'
  contains "$fn" 'done := entry.building entry.mu.Unlock() select {'
  local d; d="$(fn_flat identity.go '(v *Validator) discover(')"
  contains "$d" 'provider, err := oidc.NewProvider(ctx, entry.issuer.URL) entry.mu.Lock() defer entry.mu.Unlock() defer close(done) entry.building = nil'
  [ "$(printf '%s' "$d" | grep -o 'entry.mu.Lock()' | wc -l | tr -d ' ')" -eq 1 ]
  # inside the backoff the remembered failure answers without a new discovery
  contains "$fn" 'if entry.failErr != nil && v.now().Sub(entry.failedAt) < v.backoff { err := entry.failErr entry.mu.Unlock() return nil, err }'
  # at most one discovery per issuer at a time: only the first caller starts one
  contains "$fn" 'if entry.building == nil { entry.building = make(chan struct{}) go v.discover(entry, entry.building) } done := entry.building entry.mu.Unlock()'
  [ "$(printf '%s' "$(prod_code)" | grep -o 'go v.discover(' | wc -l | tr -d ' ')" -eq 1 ]
  # every waiter, the first included, gives up on its own request context
  contains "$fn" 'select { case <-done: case <-ctx.Done(): return nil, fmt.Errorf("%w: issuer discovery: %v", ErrInvalidToken, ctx.Err()) }'
  local nv; nv="$(fn_flat identity.go 'NewValidator(')"
  contains "$nv" 'backoff: discoveryBackoff, now: time.Now,'
  contains "$(code_of "$ID/identity.go")" 'const discoveryBackoff = 5 * time.Second'
}

@test "go identity has no validation-disabling switch and no trusted-header mode" {
  local code; code="$(prod_code)"
  # go-oidc's own escape hatches must never appear
  lacks "$code" 'InsecureSkipSignatureCheck'
  lacks "$code" 'SkipIssuerCheck'
  lacks "$code" 'SkipExpiryCheck'
  lacks "$code" 'SkipClientIDCheck'
  lacks "$code" 'InsecureIssuerURLContext'
  # the only request header read is Authorization
  contains "$code" 'r.Header.Get("Authorization")'
  [ "$(printf '%s' "$code" | grep -o 'Header.Get(' | wc -l | tr -d ' ')" -eq 1 ]
  # and no other request channel carries a token: no query, cookie, form or raw header read
  lacks "$code" 'URL.Query('
  lacks "$code" '.Cookie('
  lacks "$code" 'Header.Values('
  lacks "$code" 'Header['
  lacks "$code" 'FormValue('
  lacks "$code" 'os.LookupEnv('
  lacks "$code" 'os.Environ('
  # and the only environment read is the allowlist's own configuration
  [ "$(printf '%s' "$code" | grep -o 'os.Getenv("[A-Z_]*")' | sort -u | tr '\n' ' ')" = 'os.Getenv("OIDC_AUDIENCE") os.Getenv("OIDC_ISSUERS") os.Getenv("OIDC_ROLES_CLAIM") os.Getenv("OIDC_TENANT_CLAIM") ' ]
}

@test "go identity claim names default to Keycloak's and are configurable" {
  local code; code="$(code_of "$ID/identity.go")"
  contains "$code" 'DefaultTenantClaim = "organization"'
  contains "$code" 'DefaultRolesClaim = "realm_access.roles"'
  contains "$code" 'TenantClaim string'
  contains "$code" 'RolesClaim string'
  local fn; fn="$(fn_flat claims.go 'newClaimNames(')"
  contains "$fn" 'if tenant == "" { tenant = DefaultTenantClaim }'
  contains "$fn" 'if roles == "" { roles = DefaultRolesClaim }'
}

@test "go identity rejects a token asserting more than one tenant, and reads absent as no tenant" {
  local fn; fn="$(fn_flat claims.go 'tenantOf(')"
  contains "$fn" 'case nil: return "", false, nil'
  contains "$fn" 'case 0: return "", false, nil'
  contains "$fn" 'default: return "", false, errors.New("token asserts more than one tenant")'
}

@test "go identity RequireTenant compares for equality and rejects a tenant-less token" {
  local fn; fn="$(fn_flat claims.go 'RequireTenant(')"
  contains "$fn" 'if !ok || !claims.HasTenant { return ErrNoTenant } if claims.Tenant != requested { return ErrTenantMismatch } return nil'
}

@test "go identity claims reach a handler only through the context Middleware sets after validation" {
  local mw; mw="$(fn_flat middleware.go 'Middleware(')"
  contains "$mw" 'claims, err := v.Validate(r.Context(), raw) if err != nil { unauthorized(w, "invalid_token") return } ctx := withCallerToken(withClaims(r.Context(), claims), raw) next.ServeHTTP(w, r.WithContext(ctx))'
  contains "$mw" 'if !ok { unauthorized(w, "") return }'
  # the key is unexported, and withClaims is called nowhere else in production code
  contains "$(code_of "$ID/claims.go")" 'type claimsKey struct{}'
  [ "$(prod_code | grep -o 'withClaims(' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "go identity tests drive an httptest issuer serving discovery and JWKS, with a rotation" {
  local t; t="$(code_of "$ID/identity_test.go")"
  contains "$t" 'mux.HandleFunc("GET /.well-known/openid-configuration",'
  contains "$t" 'mux.HandleFunc("GET /jwks",'
  contains "$t" 'iss.server = httptest.NewServer('
  local test
  for test in TestUnlistedIssuerIsRejectedWithoutAnyRequest TestAlgNoneIsRejected \
    TestHS256SignedWithThePublicKeyIsRejected TestWrongAudienceIssuerKeyAndExpiryAreRejected \
    TestKeyRotationIsPickedUpWithoutARestart TestTenantClaimShapes TestClaimNamesAreConfigurable \
    TestRequestNamedTenantIsComparedToTheClaim TestMiddlewareRejectsMissingAndInvalidTokens \
    TestFailedDiscoveryIsRetriedNotCached TestFailedDiscoveryFailsFastInsideTheBackoff \
    TestConcurrentFirstTokensShareOneDiscovery TestWaiterGivesUpOnItsOwnContext; do
    contains "$t" "func $test(t *testing.T) {"
  done
}

@test "go identity carve-out test proves the ops paths by port: open on management, 401 on application" {
  local t; t="$(code_of "$ID/carveout_test.go")"
  contains "$t" 'var opsPaths = []string{"/info", "/health", "/health/live", "/health/ready", "/metrics"}'
  contains "$t" 'management, err := ops.NewHandler(ops.Config{}, metrics)'
  contains "$t" 'application := Middleware(newTestValidator(t, iss))(management)'
  contains "$t" 'if rec.Code != http.StatusUnauthorized {'
  # the payload's one placeholder, flagged so it is re-pointed on placement
  grep -qF 'ops "example.com/service/internal/ops" // <-- CHANGE THIS IMPORT' "$ID/carveout_test.go"
}

@test "go identity SKILL block renders every payload file, gated on the ops-api block" {
  local block
  block="$(awk '/^\*\*Go identity — in-process OIDC validation \(#2861\)\.\*\*/{f=1} f&&/^\*\*Node canonical implementation/{exit} f' "$SKILL")"
  [ -n "$block" ]
  contains "$block" 'The gate is **the Go ops-api block'"'"'s own'
  contains "$block" 'outcome, then whether the service has an HTTP application handler**.'
  contains "$block" 'the gate to give workers and message consumers that half is #2881:'
  # no net/http application handler skips; only a gRPC server owes the open #2867 line
  contains "$block" '- **The Go ops-api block installed, but no `net/http` handler serves application'
  contains "$block" 'routes** — a gRPC-only service, a message consumer, a worker → **skip this too**.'
  contains "$block" '- **The Go ops-api block installed and a `net/http` handler serves application'
  contains "$block" 'routes** → **install** per the render command below.'
  contains "$block" 'Whichever applies, a service that serves gRPC also records a Step-5 checklist'
  contains "$block" 'line: validate every gRPC call'"'"'s bearer token in a gRPC interceptor — #2867, not'
  contains "$block" 'server records no such line.'
  lacks "$block" 'exhaustive cases'
  contains "$block" 'internal/identity/'
  contains "$block" 'Never add a validation-disabling switch or a trusted-header'
  contains "$block" 'must be **empty or hold only an earlier copy'
  contains "$block" 'of this payload**; anything else there, another `package identity` included, means'
  contains "$block" 'a fresh directory, recorded in the Step-2 plan.'
  contains "$block" 'Fix it **before** `go mod tidy`.'
  contains "$block" 'Never place the `.go` files without the require.'
  contains "$block" 'so they go **only**'
  contains "$block" 'Carry Step-5 checklist items instead: (a) set `OIDC_ISSUERS` and `OIDC_AUDIENCE`'
  contains "$block" '(b) wrap'
  contains "$block" 'the **application** handler — never the management server — with'
  contains "$block" '(c) decide each tenant-naming route with'
  contains "$block" '(d) send each outbound service call through'
  local f
  for f in identity.go claims.go middleware.go identity_test.go carveout_test.go s2s.go s2s_test.go go.mod.deps README.md; do
    contains "$block" "languages/go/identity/$f"
  done
  # every file in the payload directory is rendered: a new file not added here
  # would never reach a bootstrapped repo
  local n; n="$(ls "$ID" | wc -l | tr -d ' ')"
  [ "$(printf '%s\n' "$block" | grep -c 'languages/go/identity/')" -eq "$n" ]
}

@test "go identity README documents local development against a dev issuer, never a bypass" {
  local r; r="$(cat "$ID/README.md")"
  contains "$r" 'There is **no trusted-header mode and no switch that disables validation**'
  contains "$r" 'OIDC_ISSUERS=http://localhost:8180/realms/dev'
  contains "$r" 'list it in your **local-development** environment only'
}

@test "go identity README states the placement order and the claims-only and by-port rules" {
  local r; r="$(cat "$ID/README.md")"
  contains "$r" 'or hold only an earlier copy of this payload; anything else there, another `package identity`'
  contains "$r" 'Fold `go.mod.deps`'"'"' `require` lines into that module'"'"'s `go.mod`, **then** `go mod tidy` from the'
  contains "$r" 'The same five paths mounted behind `Middleware` on the application port answer **401** like any'
  contains "$r" '`carveout_test.go` proves both halves against the real ops handler.'
  contains "$r" 'A handler reads the tenant and roles **only** from `ClaimsFrom(ctx)`, which only `Middleware`'
  contains "$r" 'When a request also *names* a tenant, `RequireTenant` compares it for equality and'
  contains "$r" 'rejects a mismatch, and rejects a request naming a tenant when the token carries none.'
  contains "$r" 'on that issuer'"'"'s first token, with `SupportedSigningAlgs` pinned to the issuer'"'"'s configured'
}

@test "go identity s2s: the caller token is set only by Middleware, read through CallerToken" {
  local code; code="$(code_of "$ID/s2s.go")"
  contains "$code" 'type callerTokenKey struct{}'
  contains "$code" 'func withCallerToken(ctx context.Context, raw string) context.Context {'
  contains "$code" 'func CallerToken(ctx context.Context) (string, bool) {'
  # the unexported setter is defined once and called once — by Middleware, after
  # Validate succeeded (pinned on the middleware body above)
  [ "$(prod_code | grep -o 'withCallerToken(' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "go identity s2s: the propagating transport overwrites Authorization and refuses without a token" {
  local fn; fn="$(fn_flat s2s.go '(t *PropagatingTransport) RoundTrip(')"
  contains "$fn" 'raw, ok := CallerToken(req.Context()) if !ok {'
  contains "$fn" 'return nil, ErrNoCallerToken }'
  contains "$fn" 'out := req.Clone(req.Context()) if redirectedAwayFromOrigin(req) { out.Header.Del("Authorization") } else { out.Header.Set("Authorization", "Bearer "+raw) }'
  lacks "$fn" 'Header.Get('
  # a redirect chain that cannot be walked back to the origin fails closed
  local rd; rd="$(fn_flat s2s.go 'redirectedAwayFromOrigin(req *http.Request) bool {')"
  contains "$rd" 'for first.Response != nil { if first.Response.Request == nil { return true } first = first.Response.Request }'
  contains "$rd" 'return first.URL.Host != req.URL.Host || first.URL.Scheme != req.URL.Scheme }'
  local cl; cl="$(fn_flat s2s.go '(s *ServiceAccount) Client(')"
  contains "$cl" 'if redirectedAwayFromOrigin(req) { return http.ErrUseLastResponse }'
}

@test "go identity s2s: service-account tokens are cached per tenant, the tenant requested only when passed" {
  local code; code="$(code_of "$ID/s2s.go")"
  contains "$code" 'DefaultTenantScopeTemplate = "organization:{tenant}"'
  contains "$code" '"golang.org/x/oauth2/clientcredentials"'
  local tts; tts="$(fn_flat s2s.go '(s *ServiceAccount) TenantTokenSource(')"
  contains "$tts" 'if tenant == "" || strings.ContainsFunc(tenant, unicode.IsSpace) { return nil, ErrInvalidTenant }'
  contains "$tts" 'src, ok := s.byTenant[tenant] if !ok {'
  contains "$tts" 'scope := strings.ReplaceAll(s.cfg.TenantScopeTemplate, "{tenant}", tenant)'
  local ts; ts="$(fn_flat s2s.go '(s *ServiceAccount) TokenSource(')"
  contains "$ts" 'if s.tenantless == nil { s.tenantless = s.newSource(nil) }'
  local ns; ns="$(fn_flat s2s.go '(s *ServiceAccount) newSource(')"
  contains "$ns" 'ctx := context.WithValue(context.Background(), oauth2.HTTPClient, s.httpClient)'
  contains "$ns" 'return cc.TokenSource(ctx)'
  contains "$ns" 'Scopes: append(append([]string{}, s.cfg.Scopes...), extra...),'
}

@test "go identity s2s tests prove both halves against httptest token and resource servers" {
  local t; t="$(code_of "$ID/s2s_test.go")"
  local test
  for test in TestPropagationForwardsTheValidatedTokenUnchanged TestPropagationWithoutAValidatedTokenSendsNothing \
    TestPropagationDoesNotModifyTheCallersRequest TestServiceAccountTokenIsCachedAndRefreshedOnExpiry \
    TestServiceAccountTokensAreIsolatedPerTenant TestServiceAccountScopeTemplateAndTenantValidation \
    TestNoTokenFollowsARedirectToAnotherHost; do
    contains "$t" "func $test(t *testing.T) {"
  done
  # propagation is driven through the real Middleware, the setter's only caller
  contains "$t" 'app := Middleware(newTestValidator(t, iss))(http.HandlerFunc('
  contains "$t" 'want := []string{"organization:acme", "organization:globex", ""}'
}

@test "go identity README documents that a service-account token carries a tenant only when acting for one" {
  local r; r="$(cat "$ID/README.md")"
  contains "$r" '**A service-account token carries a tenant only when the work is genuinely acting for one'
  contains "$r" 'call requests none. Tokens are cached per exact tenant string, with the tenant-less token in its own'
  contains "$r" 'An outbound call carries exactly one of two tokens, and neither half ever trusts a header (`s2s.go`).'
  contains "$r" 'whatever was there. With no validated token in the context it returns `ErrNoCallerToken` and sends'
  contains "$r" 'downstream service to that `aud` with a Keycloak audience mapper. Where that is unwanted, exchange'
  lacks "$r" 'queue consumer'
}
