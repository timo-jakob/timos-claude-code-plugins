package identity

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

// Claims is the validated identity of a request. It is the ONLY input a handler
// authorizes from: the tenant and roles here come from a verified token, never
// from a header, a path parameter or a body field. A value the request itself
// names -- a tenant in the path, say -- is a request for data, compared against
// these claims by RequireTenant and rejected on mismatch, never trusted.
type Claims struct {
	// Subject is the token's `sub`.
	Subject string
	// Issuer is the allowlisted issuer that signed the token.
	Issuer string
	// Tenant is the token's one active tenant. Meaningful only when HasTenant.
	Tenant string
	// HasTenant is false for a token that carries no tenant claim -- a
	// service-account token doing tenant-less background work, for instance.
	HasTenant bool
	// Roles are the token's roles, in token order.
	Roles []string
}

// HasRole reports whether the claims carry role.
func (c Claims) HasRole(role string) bool {
	for _, r := range c.Roles {
		if r == role {
			return true
		}
	}
	return false
}

// Authorization errors. Both mean 403 Forbidden: the caller is authenticated,
// but not for this tenant.
var (
	ErrNoTenant       = errors.New("identity: token carries no tenant, but the request names one")
	ErrTenantMismatch = errors.New("identity: request names a tenant the token does not assert")
)

// RequireTenant is the authorization seam for a request that NAMES a tenant
// (e.g. the {tenant} segment of /tenants/{tenant}/orders). It compares the named
// tenant with the token's for EQUALITY -- a token asserts exactly one active
// tenant, so this is never set membership -- and rejects a mismatch rather than
// silently serving the token's tenant instead. A token with no tenant claim is
// rejected too: a caller that must act for a tenant obtains a token asserting it.
func RequireTenant(ctx context.Context, requested string) error {
	claims, ok := ClaimsFrom(ctx)
	if !ok || !claims.HasTenant {
		return ErrNoTenant
	}
	if claims.Tenant != requested {
		return ErrTenantMismatch
	}
	return nil
}

// claimsKey is unexported, so only this package can put Claims in a context:
// a value under it was set by Middleware after successful validation.
type claimsKey struct{}

// ClaimsFrom returns the validated claims Middleware stored for this request.
func ClaimsFrom(ctx context.Context) (Claims, bool) {
	claims, ok := ctx.Value(claimsKey{}).(Claims)
	return claims, ok
}

func withClaims(ctx context.Context, claims Claims) context.Context {
	return context.WithValue(ctx, claimsKey{}, claims)
}

// claimNames are the configured claim locations.
type claimNames struct {
	tenant string
	roles  []string // the roles path, split at '.'
}

func newClaimNames(tenant, roles string) claimNames {
	if tenant == "" {
		tenant = DefaultTenantClaim
	}
	if roles == "" {
		roles = DefaultRolesClaim
	}
	return claimNames{tenant: tenant, roles: strings.Split(roles, ".")}
}

// extract reads the tenant and roles out of a verified token's payload.
func (n claimNames) extract(payload map[string]any) (Claims, error) {
	var claims Claims
	tenant, has, err := tenantOf(payload[n.tenant])
	if err != nil {
		return Claims{}, fmt.Errorf("%w: %s: %v", ErrInvalidClaims, n.tenant, err)
	}
	claims.Tenant, claims.HasTenant = tenant, has
	roles, err := rolesOf(lookup(payload, n.roles))
	if err != nil {
		return Claims{}, fmt.Errorf("%w: %s: %v", ErrInvalidClaims, strings.Join(n.roles, "."), err)
	}
	claims.Roles = roles
	return claims, nil
}

// tenantOf reads the tenant claim. Keycloak Organizations emits it as an array
// of organization aliases -- or, with organization attributes mapped, as an
// object keyed by alias -- so both shapes are read, plus a bare string.
//
// A token asserts EXACTLY ONE active tenant: more than one entry makes the token
// invalid, because picking one would be guessing which tenant the caller meant.
// An absent claim, or an empty one, means the token carries no tenant.
func tenantOf(value any) (string, bool, error) {
	var entries []string
	switch v := value.(type) {
	case nil:
		return "", false, nil
	case string:
		entries = []string{v}
	case []any:
		for _, e := range v {
			s, ok := e.(string)
			if !ok {
				return "", false, errors.New("tenant entry is not a string")
			}
			entries = append(entries, s)
		}
	case map[string]any:
		for k := range v {
			entries = append(entries, k)
		}
	default:
		return "", false, errors.New("tenant claim has an unsupported shape")
	}
	switch len(entries) {
	case 0:
		return "", false, nil
	case 1:
		if entries[0] == "" {
			return "", false, errors.New("tenant entry is empty")
		}
		return entries[0], true, nil
	default:
		return "", false, errors.New("token asserts more than one tenant")
	}
}

// lookup walks a dot-separated claim path through nested objects; nil when any
// segment is missing.
func lookup(payload map[string]any, path []string) any {
	var cur any = payload
	for _, seg := range path {
		obj, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = obj[seg]
	}
	return cur
}

// rolesOf reads the roles array. Absent means no roles; any other shape than an
// array of strings is an invalid token, not an empty role set.
func rolesOf(value any) ([]string, error) {
	if value == nil {
		return nil, nil
	}
	list, ok := value.([]any)
	if !ok {
		return nil, errors.New("roles claim is not an array")
	}
	roles := make([]string, 0, len(list))
	for _, e := range list {
		s, ok := e.(string)
		if !ok {
			return nil, errors.New("role entry is not a string")
		}
		roles = append(roles, s)
	}
	return roles, nil
}
