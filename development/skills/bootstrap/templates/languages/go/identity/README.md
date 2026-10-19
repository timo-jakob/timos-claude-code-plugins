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

## The blessed library: `coreos/go-oidc/v3`

One library, no alternative and no switch. It does discovery, the caching and rotating JWKS key
set, and `iss`/`aud`/`exp` verification with configured algorithms. `go.mod.deps` beside this file
carries its require line.

## Placement

1. Copy every file of this payload into **`internal/identity/`** of the module that builds the
   service binary — the same module the ops-api payload went into. The directory must be empty
   or hold only an earlier copy of this payload; anything else there, another `package identity`
   included, means a fresh directory.
2. In `carveout_test.go`, re-point the one flagged import
   `ops "example.com/service/internal/ops"` (`<-- CHANGE THIS IMPORT`) at your module path plus the
   directory `opsapi.go` landed in.
3. Fold `go.mod.deps`' `require` line into that module's `go.mod`, **then** `go mod tidy` from the
   module directory. Tidy before the files are placed strips the line and exits 0.

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
can populate, after validation. No code path reads either from a header, a path parameter or a
body field. When a request also *names* a tenant, `RequireTenant` compares it for equality and
rejects a mismatch, and rejects a request naming a tenant when the token carries none. Keycloak
Organizations may emit `organization` as an array of aliases or, with attributes mapped, as an
object keyed by alias; both are read. An absent or empty claim means the token carries no tenant.

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
