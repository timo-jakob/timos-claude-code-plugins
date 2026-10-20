package identity

import (
	"context"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

var listOrders = &grpc.UnaryServerInfo{FullMethod: "/orders.v1.OrderService/ListOrders"}

// incoming is the context a gRPC server hands an interceptor for a call that
// carries md (key, value pairs).
func incoming(md ...string) context.Context {
	return metadata.NewIncomingContext(context.Background(), metadata.Pairs(md...))
}

// listOrdersHandler is an application handler whose request names a tenant: it
// authorizes only from the validated claims.
func listOrdersHandler(ctx context.Context, req any) (any, error) {
	if err := RequireTenant(ctx, req.(string)); err != nil {
		return nil, status.Error(codes.PermissionDenied, "permission denied")
	}
	claims, _ := ClaimsFrom(ctx)
	if !claims.HasRole("orders-reader") {
		return nil, status.Error(codes.PermissionDenied, "permission denied")
	}
	return claims, nil
}

func wantUnauthenticated(t *testing.T, name string, err error) {
	t.Helper()
	st, ok := status.FromError(err)
	if !ok || st.Code() != codes.Unauthenticated || st.Message() != "unauthenticated" {
		t.Errorf("%s: err = %v, want codes.Unauthenticated %q", name, err, "unauthenticated")
	}
}

func TestUnaryInterceptorPassesValidatedClaimsToTheHandler(t *testing.T) {
	iss := newTestIssuer(t)
	intercept := UnaryServerInterceptor(newTestValidator(t, iss))
	raw := iss.sign(t, iss.claimsFor(nil))
	resp, err := intercept(incoming("authorization", "bearer "+raw), "acme", listOrders, listOrdersHandler)
	if err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	claims := resp.(Claims)
	if !claims.HasTenant || claims.Tenant != "acme" || !claims.HasRole("orders-reader") {
		t.Errorf("claims = %+v, want tenant acme with role orders-reader", claims)
	}
}

func TestUnaryInterceptorStoresTheCallerToken(t *testing.T) {
	iss := newTestIssuer(t)
	intercept := UnaryServerInterceptor(newTestValidator(t, iss))
	raw := iss.sign(t, iss.claimsFor(nil))
	var got string
	_, err := intercept(incoming("authorization", "Bearer "+raw), nil, listOrders, func(ctx context.Context, _ any) (any, error) {
		got, _ = CallerToken(ctx)
		return nil, nil
	})
	if err != nil || got != raw {
		t.Errorf("CallerToken = %q (err %v), want the validated token", got, err)
	}
}

func TestUnaryInterceptorRejectsMissingAndInvalidTokens(t *testing.T) {
	iss := newTestIssuer(t)
	unlisted := newTestIssuer(t)
	intercept := UnaryServerInterceptor(newTestValidator(t, iss))
	valid := iss.sign(t, iss.claimsFor(nil))
	cases := map[string]context.Context{
		"no metadata":      context.Background(),
		"no authorization": incoming("x-tenant-id", "acme"),
		"basic scheme":     incoming("authorization", "Basic dXNlcjpwYXNz"),
		"empty bearer":     incoming("authorization", "Bearer "),
		"multi-valued":     incoming("authorization", "Bearer "+valid, "authorization", "Bearer "+valid),
		"garbage token":    incoming("authorization", "Bearer not.a.token"),
		"expired": incoming("authorization", "Bearer "+iss.sign(t, iss.claimsFor(map[string]any{
			"exp": time.Now().Add(-time.Minute).Unix(),
		}))),
		"wrong issuer": incoming("authorization", "Bearer "+unlisted.sign(t, unlisted.claimsFor(nil))),
		"wrong aud": incoming("authorization", "Bearer "+iss.sign(t, iss.claimsFor(map[string]any{
			"aud": "billing-service",
		}))),
	}
	for name, ctx := range cases {
		called := false
		_, err := intercept(ctx, "acme", listOrders, func(context.Context, any) (any, error) {
			called = true
			return nil, nil
		})
		wantUnauthenticated(t, name, err)
		if called {
			t.Errorf("%s: handler invoked for a rejected call", name)
		}
	}
	if n := unlisted.requests.Load(); n != 0 {
		t.Errorf("an unlisted issuer's token caused %d requests to it, want 0", n)
	}
}

func TestUnaryHandlerMapsATenantMismatchToPermissionDenied(t *testing.T) {
	iss := newTestIssuer(t)
	intercept := UnaryServerInterceptor(newTestValidator(t, iss))
	ctx := incoming("authorization", "Bearer "+iss.sign(t, iss.claimsFor(nil)))
	_, err := intercept(ctx, "globex", listOrders, listOrdersHandler)
	if status.Code(err) != codes.PermissionDenied {
		t.Errorf("tenant globex with an acme token: err = %v, want codes.PermissionDenied", err)
	}
}

// testStream is a ServerStream that only answers Context().
type testStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s *testStream) Context() context.Context { return s.ctx }

var watchOrders = &grpc.StreamServerInfo{FullMethod: "/orders.v1.OrderService/WatchOrders", IsServerStream: true}

func TestStreamInterceptorWrapsTheStreamWithValidatedClaims(t *testing.T) {
	iss := newTestIssuer(t)
	intercept := StreamServerInterceptor(newTestValidator(t, iss))
	ss := &testStream{ctx: incoming("authorization", "Bearer "+iss.sign(t, iss.claimsFor(nil)))}
	var claims Claims
	var ok bool
	err := intercept(nil, ss, watchOrders, func(_ any, stream grpc.ServerStream) error {
		claims, ok = ClaimsFrom(stream.Context())
		return RequireTenant(stream.Context(), "acme")
	})
	if err != nil {
		t.Fatalf("valid stream rejected: %v", err)
	}
	if !ok || claims.Tenant != "acme" || !claims.HasRole("orders-reader") {
		t.Errorf("stream claims = %+v (ok %v), want tenant acme with role orders-reader", claims, ok)
	}
}

func TestStreamInterceptorRejectsBeforeTheHandlerRuns(t *testing.T) {
	iss := newTestIssuer(t)
	intercept := StreamServerInterceptor(newTestValidator(t, iss))
	for name, ctx := range map[string]context.Context{
		"no authorization": context.Background(),
		"wrong aud": incoming("authorization", "Bearer "+iss.sign(t, iss.claimsFor(map[string]any{
			"aud": "billing-service",
		}))),
	} {
		called := false
		err := intercept(nil, &testStream{ctx: ctx}, watchOrders, func(any, grpc.ServerStream) error {
			called = true
			return nil
		})
		wantUnauthenticated(t, name, err)
		if called {
			t.Errorf("%s: stream handler invoked for a rejected stream", name)
		}
	}
}
