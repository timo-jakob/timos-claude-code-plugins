package identity

import (
	"context"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// UnaryServerInterceptor is Middleware's token rule for the APPLICATION
// grpc.Server's unary RPCs: a call without a bearer token, or with one that
// fails Validate, is answered codes.Unauthenticated and never reaches the
// handler. A call that passes reaches the handler with its validated Claims in
// the context (ClaimsFrom).
//
// Register it on the application server only, never on the management server.
// There is no per-method exemption: every RPC on that server is validated, a
// grpc.health.v1 service registered there included. Probes use the ops
// payload's HTTP management port.
func UnaryServerInterceptor(v *Validator) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		ctx, err := authenticate(ctx, v)
		if err != nil {
			return nil, err
		}
		return handler(ctx, req)
	}
}

// StreamServerInterceptor is UnaryServerInterceptor's rule for streaming RPCs.
// A stream that passes reaches the handler through a wrapped ServerStream whose
// Context() carries the validated Claims.
func StreamServerInterceptor(v *Validator) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, _ *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		ctx, err := authenticate(ss.Context(), v)
		if err != nil {
			return err
		}
		return handler(srv, &claimsStream{ServerStream: ss, ctx: ctx})
	}
}

// claimsStream is a ServerStream whose Context() is the claims-bearing one.
type claimsStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s *claimsStream) Context() context.Context { return s.ctx }

// authenticate validates the call's bearer token and returns the context the
// handler runs with.
func authenticate(ctx context.Context, v *Validator) (context.Context, error) {
	raw, ok := incomingBearerToken(ctx)
	if !ok {
		return ctx, status.Error(codes.Unauthenticated, "unauthenticated")
	}
	claims, err := v.Validate(ctx, raw)
	if err != nil {
		// The cause is deliberately NOT echoed to the caller, exactly as
		// Middleware's 401: which check failed is a probing oracle.
		return ctx, status.Error(codes.Unauthenticated, "unauthenticated")
	}
	return withCallerToken(withClaims(ctx, claims), raw), nil
}

// incomingBearerToken reads the token from the incoming `authorization`
// metadata and nowhere else: no other metadata key, and no trusted identity
// metadata set by a proxy. More than one `authorization` value is rejected
// rather than guessing which one the caller meant.
func incomingBearerToken(ctx context.Context) (string, bool) {
	values := metadata.ValueFromIncomingContext(ctx, "authorization")
	if len(values) != 1 {
		return "", false
	}
	return parseBearer(values[0])
}
