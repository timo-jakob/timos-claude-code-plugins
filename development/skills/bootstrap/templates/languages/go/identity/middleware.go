package identity

import (
	"net/http"
	"strings"
)

// Middleware returns the token rule for the APPLICATION handler: a request
// without a bearer token, or with one that fails Validate, is answered 401 and
// never reaches next. A request that passes reaches next with its validated
// Claims in the context (ClaimsFrom).
//
// Wrap ONLY the application handler. The five ops paths are exempt because the
// ops payload serves them on the separate management port -- the port is the
// condition, not the path -- so the same paths mounted behind this middleware on
// the application port answer 401 like any other endpoint.
//
// The token is read from the Authorization header and nowhere else: no query
// parameter, no cookie, and no trusted identity header set by a proxy.
func Middleware(v *Validator) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw, ok := bearerToken(r)
			if !ok {
				unauthorized(w, "")
				return
			}
			claims, err := v.Validate(r.Context(), raw)
			if err != nil {
				// The cause is deliberately NOT echoed to the caller: telling an
				// attacker which check failed (issuer, signature, audience) is a
				// probing oracle. Log it server-side if you need it.
				unauthorized(w, "invalid_token")
				return
			}
			ctx := withCallerToken(withClaims(r.Context(), claims), raw)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// bearerToken extracts an RFC 6750 bearer token from the Authorization header.
func bearerToken(r *http.Request) (string, bool) {
	return parseBearer(r.Header.Get("Authorization"))
}

// parseBearer reads a `Bearer <token>` credential. The scheme is
// case-insensitive. The gRPC interceptors share it, so both surfaces accept
// exactly the same credentials.
func parseBearer(credential string) (string, bool) {
	scheme, token, ok := strings.Cut(credential, " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token = strings.TrimSpace(token)
	return token, token != ""
}

// unauthorized answers 401 with the RFC 6750 challenge.
func unauthorized(w http.ResponseWriter, errCode string) {
	challenge := `Bearer`
	if errCode != "" {
		challenge = `Bearer error="` + errCode + `"`
	}
	w.Header().Set("WWW-Authenticate", challenge)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
}

// Forbidden answers 403 for an authorization decision a handler made from the
// claims -- RequireTenant's errors, or a missing role.
func Forbidden(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusForbidden)
	_, _ = w.Write([]byte(`{"error":"forbidden"}`))
}
