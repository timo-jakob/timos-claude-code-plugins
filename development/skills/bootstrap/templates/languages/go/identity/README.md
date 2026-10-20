# Canonical in-process OIDC validation (Go) — #2861

The blessed Go realization of the family's identity position (ARCHITECTURE.md, *Identity and
authorization — OIDC at the edge, claims as the only input*, #1186): **the service validates and
authorizes; a gateway may validate first, but never instead.** Every request to the application
handler carries a bearer access token that this package verifies inside the service, and the
tenant and roles a handler authorizes from come only out of that verified token.

## What a token must pass

| check | how | rejected when |
| --- | --- | --- |
| Issuer allowlist | the token's unverified `iss` selects an entry of `Config.Issuers` | `iss` is not listed — **before** any discovery or JWKS request |
| Signature | go-oidc, against the listed issuer's JWKS | the signature fails, or the algorithm is not the issuer's configured one (`alg: none`, HS256 signed with the public key) |
| `iss`, `aud`, `exp` | go-oidc's verifier, `aud` against `Config.Audience` | any one does not check out |
| Tenant claim | `organization` (configurable) | it holds **more than one** entry — a token asserts exactly one active tenant |
| Roles claim | `realm_access.roles` (configurable dot path) | it is present but not an array of strings |

The allowlist guard is the whole safety of issuer-awareness: the token chooses *among* the
listed issuers and never introduces one. Each listed issuer gets its own verifier, built lazily
on that issuer's first token, with `SupportedSigningAlgs` pinned to the issuer's configured
algorithm (default `RS256`). go-oidc's remote key set re-fetches the JWKS when a token carries a
key it has not seen, so a **key rotation is picked up without a restart**. Concurrent first tokens
for one issuer share one discovery, and each waits no longer than its own request's context. A
failed discovery is remembered for a 5-second backoff, inside which that issuer's tokens fail
fast with 401, and is retried after it, so an issuer outage neither queues requests nor needs a
restart once the issuer is back.

## The blessed libraries: `coreos/go-oidc/v3` and `golang.org/x/oauth2`

One library per job, no alternative and no switch. go-oidc does discovery, the caching and
rotating JWKS key set, and `iss`/`aud`/`exp` verification with configured algorithms;
`golang.org/x/oauth2/clientcredentials` is the service-account token source. `go.mod.deps` beside
this file carries both require lines.

## Placement

1. Copy every file of this payload into **`internal/identity/`** of the module that builds the
   service binary — the same module the ops-api payload went into. The directory must be empty
   or hold only an earlier copy of this payload; anything else there, another `package identity`
   included, means a fresh directory. `interceptor.go` and `interceptor_test.go` are placed only
   for a service that runs an application `grpc.Server`.
2. In `carveout_test.go`, re-point the one flagged import
   `ops "example.com/service/internal/ops"` (`<-- CHANGE THIS IMPORT`) at your module path plus the
   directory `opsapi.go` landed in.
3. Fold `go.mod.deps`' `require` lines into that module's `go.mod`, **then** `go mod tidy` from the
   module directory. Tidy before the files are placed strips the lines and exits 0.

## Wiring

```go
cfg, err := identity.ConfigFromEnv()
if err != nil {
    log.Fatal(err) // no allowlist or no audience: refuse to start, never run unvalidated
}
validator, err := identity.NewValidator(cfg)
if err != nil {
    log.Fatal(err)
}

app := http.NewServeMux()
app.HandleFunc("GET /tenants/{tenant}/orders", func(w http.ResponseWriter, r *http.Request) {
    // The path names a tenant: compare it, never trust it.
    if err := identity.RequireTenant(r.Context(), r.PathValue("tenant")); err != nil {
        identity.Forbidden(w)
        return
    }
    claims, _ := identity.ClaimsFrom(r.Context())
    if !claims.HasRole("orders-reader") {
        identity.Forbidden(w)
        return
    }
    // ... serve claims.Tenant's orders
})

// The token rule wraps the APPLICATION handler only.
go func() { _ = ops.Serve(ctx, ops.DefaultAddr(), opsCfg) }() // management port: no token rule
server := &http.Server{Addr: ":8080", Handler: identity.Middleware(validator)(app), ReadHeaderTimeout: 5 * time.Second}
```

### gRPC: the same rule as server interceptors

A service that serves its application API over gRPC registers `interceptor.go`'s two interceptors
on its **application** `grpc.Server`. They read the token from the incoming `authorization`
metadata and nowhere else, call the same `Validator`, and hand the handler the same claims, so
`ClaimsFrom`, `HasRole` and `RequireTenant` work unchanged. A missing, malformed or invalid token, or
more than one `authorization` value, is answered `codes.Unauthenticated` with the message
`unauthenticated` and never reaches the handler; the cause is not echoed.

```go
grpcServer := grpc.NewServer(
    grpc.ChainUnaryInterceptor(identity.UnaryServerInterceptor(validator)),
    grpc.ChainStreamInterceptor(identity.StreamServerInterceptor(validator)),
)
ordersv1.RegisterOrderServiceServer(grpcServer, &orderService{})

func (s *orderService) ListOrders(
    ctx context.Context, req *ordersv1.ListOrdersRequest,
) (*ordersv1.ListOrdersResponse, error) {
    // The request names a tenant: compare it, never trust it.
    if err := identity.RequireTenant(ctx, req.GetTenant()); err != nil {
        return nil, status.Error(codes.PermissionDenied, "permission denied")
    }
    claims, _ := identity.ClaimsFrom(ctx)
    if !claims.HasRole("orders-reader") {
        return nil, status.Error(codes.PermissionDenied, "permission denied")
    }
    // ... list claims.Tenant's orders
}
```

**There is no per-method exemption.** The interceptors validate every RPC on the application
`grpc.Server`, a `grpc.health.v1` service registered there included. The management port stays
HTTP and unvalidated, served by the ops payload, and probes use it; never register the
interceptors on it, and never carve a method out of the application server instead.

The environment carries the allowlist:

| variable | example |
| --- | --- |
| `OIDC_ISSUERS` | `https://keycloak.prod.example/realms/platform=RS256` (comma-separated, `=ALG` optional) |
| `OIDC_AUDIENCE` | `orders-service` |
| `OIDC_TENANT_CLAIM` | optional, default `organization` |
| `OIDC_ROLES_CLAIM` | optional, default `realm_access.roles` |

## The ops surface is exempt by PORT, not by path

`/info`, `/health`, `/health/live`, `/health/ready` and `/metrics` answer without a token because
the ops payload serves them on the separate **management port**, which `Middleware` never wraps.
The same five paths mounted behind `Middleware` on the application port answer **401** like any
other endpoint. `carveout_test.go` proves both halves against the real ops handler.

## Tenant and roles are claims, never request input

A handler reads the tenant and roles **only** from `ClaimsFrom(ctx)`, which only `Middleware`
and the gRPC server interceptors can populate, after validation. No code path reads either from
a header, a path parameter or a body field.
When a request also *names* a tenant, `RequireTenant` compares it for equality and
rejects a mismatch, and rejects a request naming a tenant when the token carries none. Keycloak
Organizations may emit `organization` as an array of aliases or, with attributes mapped, as an
object keyed by alias; both are read. An absent or empty claim means the token carries no tenant.

## Service-to-service calls: the caller's token or the service's own

An outbound HTTP call carries exactly one of two tokens, and neither half ever trusts a header (`s2s.go`).
Neither token leaves the host and scheme called: on a redirect to another host or scheme,
propagation sends no token and `ServiceAccount.Client` returns the 3xx unfollowed.

The receiving service runs this payload too, so it accepts a token only when the token's `aud`
names that service's own `OIDC_AUDIENCE`. The propagated token carries the audience the caller's
token was issued with, and a service-account token the audience its client is issued. Add every
downstream service to that `aud` with a Keycloak audience mapper. Where that is unwanted, exchange
the token for one scoped to the downstream (RFC 8693 token exchange). Never widen a downstream's
`OIDC_AUDIENCE` to accept a token issued for another service.

**On behalf of a user — propagate.** A handler calling another service for the user it is serving
forwards that user's validated token. `Middleware` (or a gRPC server interceptor) stores it after
validation, `CallerToken(ctx)` reads it back, and `PropagatingTransport` sets it as the outbound
`Authorization` header,
overwriting whatever was there. With no validated token in the context it returns `ErrNoCallerToken` and sends
nothing. Build the outbound request with the inbound request's context:

```go
orders := &http.Client{Transport: &identity.PropagatingTransport{}, Timeout: 10 * time.Second}
req, _ := http.NewRequestWithContext(r.Context(), http.MethodGet, ordersURL+"/orders", nil)
resp, err := orders.Do(req)
```

**Background and system work — the service account.** A scheduled job or any other work in this
service that no user asked for uses the service's own client-credentials token:

```go
sa, err := identity.NewServiceAccount(identity.ServiceAccountConfig{
    TokenURL:     "https://keycloak.prod.example/realms/platform/protocol/openid-connect/token",
    ClientID:     "billing-nightly",
    ClientSecret: secretFromMountedFile, // never from source
})
src, err := sa.TenantTokenSource("acme") // acting for tenant acme: requests scope organization:acme
resp, err := sa.Client(src).Get(billingURL + "/invoices")
system := sa.TokenSource() // acting for no tenant: requests no organization scope
```

**A service-account token carries a tenant only when the work is genuinely acting for one
tenant.** A job that claims a tenant it is not acting for is indistinguishable, downstream, from a
compromised one. So the tenant is requested per call, through `TenantScopeTemplate` (default
`organization:{tenant}`, matching the `organization` claim this payload reads), and a tenant-less
call requests none. Tokens are cached per exact tenant string, with the tenant-less token in its own
entry, so a token fetched for one tenant is never served to another tenant or to a tenant-less call.
Each is refreshed only when it expires. A tenant that is empty or contains whitespace is refused with
`ErrInvalidTenant`, because scopes are space-separated and such a tenant would request scopes nobody
asked for.

## Local development: a dev issuer, never a bypass

There is **no trusted-header mode and no switch that disables validation**. Run a local Keycloak
(or any OIDC issuer) and list it in your **local-development** environment only:

```sh
OIDC_ISSUERS=http://localhost:8180/realms/dev OIDC_AUDIENCE=orders-service go run ./cmd/service
```

Mint a token from that realm and send it as `Authorization: Bearer …`. Every deployed environment
— a shared development or test cluster included — lists only its own provider. An allowlist that
admits a dev issuer anywhere deployed is a bypass switch in another form, and one no code review
will find.
