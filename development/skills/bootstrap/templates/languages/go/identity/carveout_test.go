package identity

import (
	"net/http"
	"net/http/httptest"
	"testing"

	ops "example.com/service/internal/ops" // <-- CHANGE THIS IMPORT to your module path + the ops package's directory
)

// opsPaths are the five ops-surface paths (#688).
var opsPaths = []string{"/info", "/health", "/health/live", "/health/ready", "/metrics"}

// TestOpsCarveOutIsThePortNotThePath proves the carve-out the identity position
// states: the ops paths answer without a token on the MANAGEMENT server, which
// Middleware never wraps, and the SAME paths mounted on the application handler
// answer 401 without a token like any other endpoint.
func TestOpsCarveOutIsThePortNotThePath(t *testing.T) {
	metrics := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	management, err := ops.NewHandler(ops.Config{}, metrics)
	if err != nil {
		t.Fatal(err)
	}
	iss := newTestIssuer(t)
	application := Middleware(newTestValidator(t, iss))(management)

	for _, path := range opsPaths {
		rec := httptest.NewRecorder()
		management.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("management %s without a token: status %d, want 200", path, rec.Code)
		}

		rec = httptest.NewRecorder()
		application.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("application %s without a token: status %d, want 401", path, rec.Code)
		}
	}
	if n := iss.requests.Load(); n != 0 {
		t.Errorf("token-less requests caused %d issuer requests, want 0", n)
	}
}
