// Package ops is the canonical ops-api implementation for Go services
// (issue #1192, epic #682 -- the ops-surface programme the Java #935 and Python
// #688 payloads belong to, not the Go-plugin foundation epic #868 that filed it).
//
// The blessed Go realization of the org-standard ops surface defined by
// contracts/ops/v2/openapi.yaml -- /info, /health, /health/live, /health/ready,
// /metrics -- so a Go service conforms to the same fragment Spring services get
// via Actuator. It passes scripts/check-ops-conformance.zsh unchanged.
//
// Instrumentation is OpenTelemetry ONLY (ARCHITECTURE.md policy): metrics come
// from the OTel SDK MeterProvider. OTLP push to a collector is the PRIMARY
// pipeline -- wired by InstallMetrics whenever the standard
// OTEL_EXPORTER_OTLP_ENDPOINT env var is set (honoring OTEL_EXPORTER_OTLP_PROTOCOL
// = grpc | http/protobuf). Both variables have a signal-specific twin,
// OTEL_EXPORTER_OTLP_METRICS_ENDPOINT / _METRICS_PROTOCOL, which takes precedence.
// /metrics is the mandatory PULL-COMPAT surface, served
// by the OTel SDK's Prometheus exporter -- a config wiring, not a second metrics
// system. Unlike OTel Java (whose Prometheus exporter runs its own embedded
// server, forcing the Java payload to reverse-proxy /metrics), the Go exporter
// registers into a prometheus.Registry that promhttp serves as an ordinary
// http.Handler -- so all five endpoints share one mux with no proxy hop.
//
// DEPENDENCY HEALTH (ops-api v1.1, #965 / epic #964): /health carries an optional
// `components` map -- one entry per DIRECT dependency, read PASSIVELY from that
// dependency's circuit-breaker state -- and a declared HARD dependency being down
// also fails /health/ready. Wire it with Config.Dependencies; the blessed source is
// DependencyHealth in the resilience payload beside this one
// (templates/languages/go/resilience/, #1144), which derives these entries
// PASSIVELY from sony/gobreaker state. Leave Config.Dependencies unset and this
// package behaves exactly as ops-api v1.0: no `components` field, and readiness is
// your Config.Readiness alone. The binding is an INTERFACE over a plain struct, so this
// package needs no breaker library on its import path -- and must never grow one.
//
// NOTE that /health answers 200 even when the aggregate is "down" -- the verdict is
// in the body. Only the two PROBES (/health/live, /health/ready) speak in status
// codes. The Java and Python payloads shipped this wrong and had to be fixed (#1139);
// the conformance checker has always rejected it, but a healthy service conforms
// either way, so the divergence only surfaces during an outage.
//
// This is an INTERNAL management surface: bind it to a separate MANAGEMENT PORT
// (default 9090), never the public app port, so /info's build data is unreachable
// from outside without any per-endpoint auth. The network boundary (a
// NetworkPolicy + a Service that exposes only the app port, and the liveness/
// readiness probe wiring) is the deployment layer's job (the composition repo).
//
// PLACEMENT: copy this file into your service (e.g. internal/ops/opsapi.go), fold
// the requires from go.mod.deps beside it into your go.mod, and call ops.Serve
// from your startup with your real Config. Declare the API majors your service
// serves via Config.ServedMajors -- the /info lifecycle table is what makes the
// epic #684 deprecation machinery observable.
//
// YOUR go.mod MUST DECLARE go 1.22 OR NEWER. The routes below are http.ServeMux
// METHOD PATTERNS ("GET /health"), and the standard library gates that grammar on
// the MODULE's go directive rather than on the installed toolchain -- so a module
// still saying `go 1.21` parses them as host-prefixed patterns under even the
// newest Go, matches nothing, and answers 404 on every ops endpoint with no build
// error and no warning. There is no runtime check that can catch this from in
// here: by the time this code runs, the mux has already accepted the patterns.
package ops

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"runtime/debug"
	"sort"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	otelprom "go.opentelemetry.io/otel/exporters/prometheus"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
)

// DefaultPort is the management port the ops surface binds by default. It is
// deliberately NOT the public app port: /info's build data must be unreachable
// from outside without per-endpoint auth.
const DefaultPort = 9090

// Lifecycle values for a served API major (contracts/ops/v2/openapi.yaml).
const (
	LifecycleActive     = "active"
	LifecycleDeprecated = "deprecated"
)

// Aggregate statuses served on /health.
//
// The healthy aggregate is spelled "ok", NEVER "up" -- that is the exact spelling
// ops-api v1.0 shipped, and renaming it would break every v1.0 consumer. v1.1 only
// ADDED "degraded" beside it. The components map uses a different vocabulary
// (below); confusing the two is the single easiest way to under-report health.
const (
	StatusOK       = "ok"
	StatusDegraded = "degraded"
	StatusDown     = "down"
)

// Per-dependency statuses served in the /health components map. Healthy is "up"
// here -- see the note on StatusOK.
const (
	ComponentUp       = "up"
	ComponentDegraded = "degraded"
	ComponentDown     = "down"
)

// Circuit-breaker states a component may report. The mapping to a component
// status is exact: closed = up, half_open = degraded, open = down.
const (
	BreakerClosed   = "closed"
	BreakerOpen     = "open"
	BreakerHalfOpen = "half_open"
)

// Dependency kinds -- the readiness hinge. A hard dependency down fails
// /health/ready (Kubernetes sheds traffic); a soft one never does.
const (
	KindHard = "hard"
	KindSoft = "soft"
)

// statusRank orders the aggregate worst-last, so worseOf can compare two by rank.
var statusRank = map[string]int{StatusOK: 0, StatusDegraded: 1, StatusDown: 2}

// APIMajor is one served API major and its lifecycle (mirrors the fragment's
// ApiMajor schema).
//
// A deprecated major MUST carry a sunset date (RFC 8594) and an active one MUST
// NOT -- Config.Validate enforces both directions at STARTUP, when NewHandler
// calls it. Go has no construction hook, so a malformed literal is silent until
// then (the Java sibling really does validate in its record constructor; do not
// carry that phrasing over). Only the first direction is also checked downstream,
// so the second is Validate's alone -- see the note on Validate.
type APIMajor struct {
	Major     int    `json:"major"`
	Lifecycle string `json:"lifecycle"`
	Sunset    string `json:"sunset,omitempty"`
}

// Dependency is one DIRECT dependency's health, as the ops-api v1.1 components
// map reports it.
//
//	Status   up | degraded | down -- read from the dependency's circuit breaker.
//	Kind     hard | soft -- the readiness hinge.
//	Breaker  closed | open | half_open -- the state the status was read from.
//	Since    RFC 3339 timestamp of the last state change, so a dashboard can tell
//	         a blip from a sustained outage.
//
// Breaker and Since are optional; empty values are omitted from the JSON rather
// than serialized as "", which the checker would reject as a non-member of the
// breaker enum.
type Dependency struct {
	Status  string `json:"status"`
	Kind    string `json:"kind"`
	Breaker string `json:"breaker,omitempty"`
	Since   string `json:"since,omitempty"`
}

// DependencyHealthSource supplies the per-direct-dependency health that /health
// reports under `components`.
//
// Deliberately an interface over a plain struct rather than a dependency on a
// breaker library: this package stays importable by a service that has no outbound
// dependencies at all, and the ops surface never grows a breaker on its import
// path. The blessed implementation is DependencyHealth in the resilience payload
// (#1144), which derives these entries PASSIVELY from circuit-breaker state -- an
// open breaker IS a down dependency. Implementing it by hand is the escape hatch,
// not the default; leaving Config.Dependencies unset keeps a conforming v1.0.
//
// DIRECT dependencies only. A service reports the one hop it calls itself and
// never transitively calls a downstream's /health (the health-check-storm
// anti-pattern).
type DependencyHealthSource interface {
	// Components returns one entry per direct dependency, keyed by its stable
	// name. Returning nil is legal and means "no dependencies to report".
	//
	// IT MUST RETURN A FRESHLY BUILT MAP -- a snapshot -- never the source's own
	// live map. /health and /health/ready both RANGE over what you return, and a
	// map another goroutine writes while this one reads is a concurrent map
	// read/write: Go makes that a runtime FATAL error, not a panic, so the
	// recover guards on both health paths cannot catch it and the whole process
	// dies mid-scrape. That is precisely the outage-time crash mandate 6 forbids,
	// arriving through the one door the guards do not cover. If your breaker
	// registry keeps a map, copy it under your own lock before returning.
	Components() map[string]Dependency
}

// Config is what the service reports on /info, and how the two health verdicts are
// decided.
//
// Readiness is the NON-dependency half of the readiness answer -- still starting
// up, draining during a graceful shutdown, an internal resource exhausted. The
// default (nil) is always-ready. The DEPENDENCY half comes from Dependencies: a
// declared hard dependency being down also fails readiness, while a soft one never
// does. Liveness is deliberately NOT configurable: it reflects only that the
// process is serving, and must never check a dependency (that would turn a
// transient outage into a pod-restart storm).
//
// InternalStatus is the over-reporting hook the contract requires: the components
// set a FLOOR on the /health aggregate, never an equality, so a service impaired
// for a reason no dependency models (a backed-up work queue, a full disk) MUST
// report a MORE severe aggregate than its dependencies imply. Reporting a LESS
// severe one is a conformance failure.
type Config struct {
	// Version is /info's build.version. Empty falls back to $BUILD_VERSION, then
	// the main module's version, then "0.0.0" -- never empty, which the checker
	// rejects.
	Version string
	// GitSHA is /info's build.git_sha. Empty falls back to $GIT_SHA, then the
	// VCS revision the Go toolchain stamps into the binary, then "unknown".
	GitSHA string
	// ServedMajors is the /info lifecycle table. Empty defaults to a single
	// active major 1.
	ServedMajors []APIMajor
	// Readiness is the non-dependency half of /health/ready. nil = always ready.
	Readiness func() bool
	// Dependencies supplies the v1.1 components map. nil = ops-api v1.0
	// behaviour: no components field, readiness is Readiness alone.
	Dependencies DependencyHealthSource
	// InternalStatus is the over-reporting hook. nil = StatusOK.
	InternalStatus func() string
}

// Validate reports whether the config can serve a conforming /info.
//
// Called by NewHandler, so a misdeclared major fails at STARTUP -- the one place a
// Go service can still catch it cheaply. For three of the five rules below
// (major < 1, an invalid lifecycle, deprecated-without-sunset) that is merely
// EARLIER than the conformance job. For the other two -- a DUPLICATE major, and
// an ACTIVE major carrying a sunset -- it is the only enforcement anywhere: the
// checker inspects neither, so removing those arms buys no downstream safety net.
func (c Config) Validate() error {
	seen := make(map[int]bool, len(c.ServedMajors))
	for _, m := range c.ServedMajors {
		if m.Major < 1 {
			return fmt.Errorf("ops: api major %d is invalid (want an integer >= 1)", m.Major)
		}
		if seen[m.Major] {
			return fmt.Errorf("ops: api major %d is declared twice", m.Major)
		}
		seen[m.Major] = true
		switch m.Lifecycle {
		case LifecycleDeprecated:
			if m.Sunset == "" {
				return fmt.Errorf("ops: deprecated major %d needs a sunset date (RFC 8594)", m.Major)
			}
		case LifecycleActive:
			// An active major must not carry a sunset date: a sunset is the
			// promise that a major is going away, and advertising one on a major
			// that is not deprecated tells consumers to migrate off a version
			// nobody is retiring.
			if m.Sunset != "" {
				return fmt.Errorf("ops: active major %d must not carry a sunset date", m.Major)
			}
		default:
			return fmt.Errorf("ops: major %d has an invalid lifecycle %q (want %q or %q)",
				m.Major, m.Lifecycle, LifecycleActive, LifecycleDeprecated)
		}
	}
	return nil
}

// resolved returns the config with defaults applied and ServedMajors copied.
//
// The copy is not ceremony: the caller keeps a reference to the slice it passed,
// and a later append/edit through that reference would otherwise change what /info
// serves -- after Validate has already approved it.
func (c Config) resolved() Config {
	out := c
	if out.Version == "" {
		out.Version = defaultVersion()
	}
	if out.GitSHA == "" {
		out.GitSHA = defaultGitSHA()
	}
	if len(out.ServedMajors) == 0 {
		out.ServedMajors = []APIMajor{{Major: 1, Lifecycle: LifecycleActive}}
	} else {
		out.ServedMajors = append([]APIMajor(nil), out.ServedMajors...)
	}
	if out.Readiness == nil {
		out.Readiness = func() bool { return true }
	}
	if out.InternalStatus == nil {
		out.InternalStatus = func() string { return StatusOK }
	}
	return out
}

// components takes ONE snapshot of the dependency view per request.
//
// Both /health's aggregate and its components map are derived from the SAME
// snapshot, so a breaker that flips mid-request can never produce a body whose
// headline contradicts its own component list.
func (c Config) components() map[string]Dependency {
	if c.Dependencies == nil {
		return nil
	}
	raw := c.Dependencies.Components()
	if len(raw) == 0 {
		return nil
	}
	out := make(map[string]Dependency, len(raw))
	for name, d := range raw {
		out[name] = onContract(d)
	}
	return out
}

// ready is the readiness answer behind /health/ready.
//
// Among dependencies, only a declared HARD one being DOWN makes the service
// unready -- a soft dependency down keeps the pod ready and serving degraded
// responses. Non-dependency reasons still apply and are checked first.
func (c Config) ready(components map[string]Dependency) bool {
	if !c.Readiness() {
		return false
	}
	for _, d := range components {
		if d.Kind == KindHard && d.Status == ComponentDown {
			return false
		}
	}
	return true
}

// aggregate is the status served by /health: the worse of this service's own
// internal state and the FLOOR its dependencies impose -- "down" if any HARD
// dependency is down, else "degraded" if ANY dependency is down or degraded, else
// "ok".
//
// Note the hard/degraded case: a HARD dependency that is merely half-open reads
// "degraded", not down, so it floors the aggregate at "degraded" rather than
// "down". Only a hard dependency that is fully down forces "down".
func (c Config) aggregate(components map[string]Dependency) string {
	status := c.InternalStatus()
	if _, ok := statusRank[status]; !ok {
		// An off-contract value (a typo, "up" borrowed from the components
		// vocabulary, "") is normalized to the MOST severe status, never the
		// least. Failing toward severity keeps the coercion honest: read the
		// other way, a mistyped internal-status hook would make /health answer
		// "ok" during exactly the impairment the hook was written to report --
		// the under-reporting the contract forbids. "down" instead fails ops
		// conformance loudly, and /health keeps serving rather than panicking
		// out of the handler mid-outage.
		status = StatusDown
	}
	for _, d := range components {
		switch {
		case d.Status == ComponentDown && d.Kind == KindHard:
			status = worseOf(status, StatusDown)
		case d.Status == ComponentDown || d.Status == ComponentDegraded:
			status = worseOf(status, StatusDegraded)
		}
	}
	return status
}

// worseOf is a worst-wins comparison over statusRank (ok < degraded < down).
func worseOf(a, b string) string {
	if statusRank[a] >= statusRank[b] {
		return a
	}
	return b
}

// onContract forces one component's Status/Kind onto the contract's vocabulary.
//
// DependencyHealthSource is an INTERFACE, so a service may hand-write one -- and
// this package ships two vocabularies that are easy to confuse: the aggregate
// spells healthy "ok" while a component spells it "up". A source returning "ok",
// "Down" or Kind "Hard" would otherwise be read as healthy/soft by both ready and
// aggregate, which compare against the literal contract spellings -- so a hard
// dependency reported down in the wrong case would keep the pod ready and the
// aggregate "ok". That is the under-reporting the contract forbids, arriving
// silently.
//
// Unknown values are coerced to the MOST severe reading (down, hard), never the
// least -- the same fail-toward-severity rule aggregate applies to InternalStatus.
// An off-contract Breaker is dropped rather than coerced: it is descriptive, and a
// present-but-invalid one fails conformance while an absent one is legal.
func onContract(d Dependency) Dependency {
	switch d.Status {
	case ComponentUp, ComponentDegraded, ComponentDown:
	default:
		d.Status = ComponentDown
	}
	switch d.Kind {
	case KindHard, KindSoft:
	default:
		d.Kind = KindHard
	}
	switch d.Breaker {
	case "", BreakerClosed, BreakerOpen, BreakerHalfOpen:
	default:
		d.Breaker = ""
	}
	return d
}

// ---- payloads --------------------------------------------------------------

type buildBlock struct {
	Version string `json:"version"`
	GitSHA  string `json:"git_sha"`
}

type infoBody struct {
	Build buildBlock `json:"build"`
	API   []APIMajor `json:"api"`
}

type healthBody struct {
	Status string `json:"status"`
	// Omitted entirely when there are no dependencies, keeping the response a
	// valid ops-api v1.0 body.
	Components map[string]Dependency `json:"components,omitempty"`
}

type statusBody struct {
	Status string `json:"status"`
}

// ---- RFC 9457 problem details (ops-api v2, #1330) ---------------------------

// Problem-type URNs. Host-free on purpose: a shipped service must not carry a
// documentation URL that rots when the docs site moves.
const (
	ProblemTypeNotReady = "urn:problem-type:ops:not-ready"
	ProblemTypeNotAlive = "urn:problem-type:ops:not-alive"

	problemTitleNotReady = "Service Not Ready"

	// The two non-dependency unready reasons the contract names. A service that
	// is unready for its own reasons (Config.Readiness returning false) cannot
	// tell us which, so it gets the start-up wording -- the overwhelmingly
	// common case, and the one an operator acts on the same way.
	//
	// DetailDraining is a HOOK, not something this package emits: a service that
	// distinguishes draining from starting up in its own Readiness hook can use
	// it, and the contract documents the wording so every service that does
	// spells it the same way.
	DetailStartingUp = "the service is starting up"
	DetailDraining   = "the service is draining"

	// The liveness problem's title and detail. EXPORTED even though this package
	// never emits them: Go liveness is unconditionally 200 (a process answering
	// HTTP is alive), so these exist for a service that adds its own liveness
	// gate. Unexported they would be unused identifiers, and bootstrap's own
	// .golangci.yml enables `unused` -- so a service copying this file verbatim,
	// exactly as the header instructs, would go red on lint.
	ProblemTitleNotAlive = "Service Not Alive"
	DetailNotAlive       = "the process is not alive and should be restarted"
)

// problemBody is the liveness/base RFC 9457 document: the four required members
// and nothing else.
//
// The struct is flat rather than embedded in readinessProblemBody for the same
// reason the CONTRACT's schemas are flat -- see contracts/ops/v2/openapi.yaml.
// Embedding would serialize identically here, but keeping the two shapes
// visibly parallel to the schema is what lets a reader check one against the
// other without holding Go's embedding rules in their head.
type problemBody struct {
	Type   string `json:"type"`
	Title  string `json:"title"`
	Status int    `json:"status"`
	Detail string `json:"detail"`
}

// readinessProblemBody is the readiness 503: the four members plus the
// `components` extension member, byte-identical to the map /health serves.
type readinessProblemBody struct {
	Type   string `json:"type"`
	Title  string `json:"title"`
	Status int    `json:"status"`
	Detail string `json:"detail"`
	// Omitted ONLY when the service declares no dependencies at all -- never as a
	// function of which half of readiness failed. A 503 raised for a non-dependency
	// reason still carries the full map: the snapshot is taken BEFORE the gate.
	Components map[string]Dependency `json:"components,omitempty"`
}

// readinessDetail builds the canonical `detail` sentence.
//
// The wording is FIXED, not free prose: check-ops-conformance.zsh and the
// acceptance lane both assert it. Names are sorted LEXICOGRAPHICALLY so the
// string is deterministic regardless of the order the breakers tripped in --
// without the sort, the same outage would produce different bodies on different
// pods and no assertion could pin it.
func readinessDetail(components map[string]Dependency) string {
	var down []string
	for name, d := range components {
		if d.Kind == KindHard && d.Status == ComponentDown {
			down = append(down, name)
		}
	}
	if len(down) == 0 {
		// No hard dependency is down, so readiness failed for a non-dependency
		// reason: the service's own Readiness hook said no.
		return DetailStartingUp
	}
	sort.Strings(down)
	quoted := make([]string, len(down))
	for i, name := range down {
		quoted[i] = "'" + name + "'"
	}
	if len(quoted) == 1 {
		return "hard dependency " + quoted[0] + " is down"
	}
	return "hard dependencies " + strings.Join(quoted, ", ") + " are down"
}

// ---- handler ---------------------------------------------------------------

// NewHandler returns the five-endpoint ops surface.
//
// metricsHandler serves /metrics and is what InstallMetrics returns; it is
// REQUIRED, because /metrics is a mandatory part of the contract -- passing nil is
// a startup error rather than a 404 the ops-conformance job discovers later.
//
// Most services call Serve, which does both. Use NewHandler directly to mount the
// surface on a management server you already run.
func NewHandler(cfg Config, metricsHandler http.Handler) (http.Handler, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if metricsHandler == nil {
		return nil, errors.New("ops: metricsHandler is required (/metrics is part of the ops contract)")
	}
	c := cfg.resolved()

	mux := http.NewServeMux()

	mux.HandleFunc("GET /info", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, infoBody{
			Build: buildBlock{Version: c.Version, GitSHA: c.GitSHA},
			API:   c.ServedMajors,
		})
	})

	// Liveness: the process is serving this request, so it is alive. Deliberately
	// dependency-free -- a failing liveness restarts the pod, so making it a
	// function of a dependency turns a transient outage into a restart storm.
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, statusBody{Status: StatusOK})
	})

	// Readiness: can we serve traffic? A failing readiness sheds traffic without a
	// restart. 503 => not ready. This is a PROBE, so the verdict rides in the
	// STATUS CODE; among dependencies only a declared HARD one being down fails it.
	mux.HandleFunc("GET /health/ready", func(w http.ResponseWriter, _ *http.Request) {
		ready := false
		// Read the components ONCE and reuse them for both the verdict and the
		// problem body. Calling c.components() a second time to build the body
		// would re-enter the service's DependencyHealthSource, which can return
		// a different map -- the 503 would then name a dependency the verdict
		// was not actually taken on.
		var components map[string]Dependency
		// See the /health branch for why the recover IS the contract. Readiness
		// fails CLOSED: if we cannot read dependency health we cannot vouch for
		// being able to serve, and shedding traffic is the safe direction. A
		// panic leaves components nil, so the 503 falls back to the
		// non-dependency wording rather than naming a half-read map.
		func() {
			defer func() {
				if r := recover(); r != nil {
					ready = false
					components = nil
				}
			}()
			components = c.components()
			ready = c.ready(components)
		}()
		if ready {
			writeJSON(w, http.StatusOK, statusBody{Status: StatusOK})
			return
		}
		// ops-api v2: RFC 9457 problem details, not {"status":"down"}. The
		// health string is gone from the 503 -- 503 already says "down" -- and
		// the diagnosis rides in `components` instead.
		writeProblemJSON(w, http.StatusServiceUnavailable, readinessProblemBody{
			Type:       ProblemTypeNotReady,
			Title:      problemTitleNotReady,
			Status:     http.StatusServiceUnavailable,
			Detail:     readinessDetail(components),
			Components: components,
		})
	})

	// The human/dashboard-facing aggregate, plus per-direct-dependency components.
	// ALWAYS 200 while the process can answer, even when the aggregate is "down":
	// the verdict rides in the BODY. An operator reading this during an outage
	// needs the diagnosis, and a 503 here is an unreadable page exactly when it
	// matters. HTTP status codes are the two probes' vocabulary, which is why only
	// they document a 503 (#1139).
	//
	// THE RECOVER IS THE CONTRACT, not defensive habit. DependencyHealthSource is
	// an interface a service may implement by hand, and a panic in it (a nil map,
	// a nil pointer inside a breaker registry) would otherwise unwind out of the
	// handler; net/http recovers it, closes the connection WITHOUT a response, and
	// the conformance checker reports "/health: unreachable" instead of a
	// diagnosis. So answer 200 with the worst verdict: reporting "ok" here would
	// be the under-reporting the contract forbids.
	//
	// Note there is no serialization-failure branch, unlike the Python sibling:
	// every field a source can populate is a string on a fixed struct, so
	// json.Marshal here cannot fail. Go's type system removed that failure mode
	// rather than the guard being forgotten.
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		body := healthBody{Status: StatusDown}
		func() {
			defer func() {
				if r := recover(); r != nil {
					body = healthBody{Status: StatusDown}
				}
			}()
			components := c.components()
			body = healthBody{Status: c.aggregate(components), Components: components}
		}()
		writeJSON(w, http.StatusOK, body)
	})

	mux.Handle("GET /metrics", metricsHandler)

	// Anything else on the management port is a mistake worth naming, not a blank
	// 404 page.
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusNotFound, map[string]string{
			"error": "not found",
			"path":  r.URL.Path,
		})
	})

	return normalizePath(mux), nil
}

// normalizePath strips a trailing slash before dispatch.
//
// http.ServeMux's exact patterns ("GET /health") do not match "/health/", and its
// built-in redirect only runs the other way (a registered subtree "/health/"
// redirecting "/health" onto it). Without this, a probe or a hand-rolled curl with
// a trailing slash gets a 404 from an otherwise conforming service.
//
// A request carrying PERCENT-ENCODED path material (RawPath non-empty) is passed
// through untouched. An encoded slash is part of its segment, not a separator, so
// "/health%2F" is the one-segment path "health/" and rightly 404s -- rewriting it
// would make %2F mean one thing with a trailing slash and another without.
func normalizePath(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.RawPath != "" {
			next.ServeHTTP(w, r)
			return
		}
		if p := r.URL.Path; len(p) > 1 && strings.HasSuffix(p, "/") {
			trimmed := strings.TrimRight(p, "/")
			if trimmed == "" {
				trimmed = "/"
			}
			// Each request is this handler chain's own value, so retargeting it
			// in place is safe -- but the URL is a pointer shared with the
			// original, so copy it rather than mutating the caller's.
			r2 := *r
			u := *r.URL
			u.Path = trimmed
			r2.URL = &u
			next.ServeHTTP(w, &r2)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, payload any) {
	body, err := json.Marshal(payload)
	if err != nil {
		// Unreachable for every payload this package builds (all fixed structs of
		// strings/ints). Answering with a hand-built body rather than a naked 500
		// keeps even this branch a valid JSON status response.
		body = []byte(`{"status":"down"}`)
		code = http.StatusInternalServerError
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

// writeProblemJSON writes an RFC 9457 document on application/problem+json.
//
// Separate from writeJSON because the media type is part of the contract, not a
// detail: org-problem-json-errors requires the 4xx/5xx body to be BARE
// problem+json, so answering the readiness 503 on application/json would be a
// conformance failure even with a correctly shaped body.
func writeProblemJSON(w http.ResponseWriter, code int, payload any) {
	body, err := json.Marshal(payload)
	if err != nil {
		// Unreachable (fixed structs of strings/ints and a map of the same), but
		// the fallback stays a VALID problem document rather than borrowing
		// writeJSON's health-shaped one -- a 500 here would otherwise answer a
		// problem+json content type with a {"status":"down"} body.
		body = []byte(`{"type":"` + ProblemTypeNotReady +
			`","title":"` + problemTitleNotReady +
			`","status":500,"detail":"the readiness problem document could not be serialized"}`)
		code = http.StatusInternalServerError
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

// ---- metrics ---------------------------------------------------------------

// InstallMetrics wires the OTel SDK MeterProvider and returns it together with the
// handler that serves /metrics.
//
// OpenTelemetry is the SINGLE instrumentation source. Two readers hang off one
// provider:
//
//   - the Prometheus exporter, which registers a collector into a fresh
//     prometheus.Registry that promhttp serves as /metrics -- the mandatory
//     pull-compat surface, so conformance and smoke checks need no collector;
//   - an OTLP periodic reader, the PRIMARY pipeline, wired only when
//     OTEL_EXPORTER_OTLP_ENDPOINT (or OTEL_EXPORTER_OTLP_METRICS_ENDPOINT) is
//     set. OTEL_EXPORTER_OTLP_PROTOCOL picks grpc (the default when unset) or
//     http/protobuf, and OTEL_EXPORTER_OTLP_METRICS_PROTOCOL overrides it; any
//     other value is a startup error, never a silent fallback. The exporters read
//     the rest of the standard OTEL_* env vars themselves.
//
// The returned provider is the caller's to Shutdown -- Serve does it. A dedicated
// registry rather than prometheus.DefaultRegisterer keeps the Go runtime/process
// collectors out of the exposition, so /metrics carries what the SDK recorded and
// nothing a second metrics system smuggled in.
func InstallMetrics(ctx context.Context) (*sdkmetric.MeterProvider, http.Handler, error) {
	registry := prometheus.NewRegistry()
	pullExporter, err := otelprom.New(otelprom.WithRegisterer(registry))
	if err != nil {
		return nil, nil, fmt.Errorf("ops: prometheus exporter: %w", err)
	}

	opts := []sdkmetric.Option{sdkmetric.WithReader(pullExporter)}
	if pushExporter, err := newOTLPExporter(ctx); err != nil {
		return nil, nil, err
	} else if pushExporter != nil {
		opts = append(opts, sdkmetric.WithReader(sdkmetric.NewPeriodicReader(pushExporter)))
	}

	provider := sdkmetric.NewMeterProvider(opts...)
	otel.SetMeterProvider(provider)
	return provider, promhttp.HandlerFor(registry, promhttp.HandlerOpts{}), nil
}

// newOTLPExporter builds the OTLP push exporter, or returns (nil, nil) when no
// collector endpoint is configured.
//
// Absence of an endpoint is the NORMAL local/CI case and must not be an error: the
// exporters would otherwise dial localhost:4317 and log a connection failure every
// export interval. /metrics still works without a collector, which is exactly why
// the pull surface is mandatory rather than optional.
//
// OTEL_EXPORTER_OTLP_METRICS_ENDPOINT is checked too, because a service may push
// only metrics to a different collector than its traces -- reading just the
// general variable would silently ignore that configuration. The protocol reads
// the same pair: OTEL_EXPORTER_OTLP_METRICS_PROTOCOL wins over
// OTEL_EXPORTER_OTLP_PROTOCOL, per the OTel spec's signal-specific precedence.
//
// The accepted protocols are exactly grpc (the spec's default when unset) and
// http/protobuf. An unrecognised value is a LOUD error rather than a silent
// fallback -- including "http/json", which the Go SDK does not implement: routing
// it to the protobuf exporter would hand a JSON-expecting collector protobuf and
// fail every export interval while the operator believes the config was accepted.
func newOTLPExporter(ctx context.Context) (sdkmetric.Exporter, error) {
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" &&
		os.Getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") == "" {
		return nil, nil
	}
	protocol := os.Getenv("OTEL_EXPORTER_OTLP_METRICS_PROTOCOL")
	if protocol == "" {
		protocol = os.Getenv("OTEL_EXPORTER_OTLP_PROTOCOL")
	}
	switch protocol {
	case "http/protobuf":
		exporter, err := otlpmetrichttp.New(ctx)
		if err != nil {
			return nil, fmt.Errorf("ops: otlp http metric exporter: %w", err)
		}
		return exporter, nil
	case "", "grpc":
		// grpc is the spec's default when the variable is unset.
		exporter, err := otlpmetricgrpc.New(ctx)
		if err != nil {
			return nil, fmt.Errorf("ops: otlp grpc metric exporter: %w", err)
		}
		return exporter, nil
	default:
		return nil, fmt.Errorf("ops: unsupported OTLP protocol %q (want grpc or http/protobuf)", protocol)
	}
}

// ---- server ----------------------------------------------------------------

// Serve installs metrics and runs the ops surface on the MANAGEMENT port until ctx
// is done, then shuts down gracefully.
//
// addr is a net.Listen address, e.g. ":9090" (see DefaultAddr). It binds all
// interfaces so the kubelet's probes and the ops-conformance job can reach it; the
// network boundary is enforced by the deployment (a NetworkPolicy + a Service that
// omits this port).
func Serve(ctx context.Context, addr string, cfg Config) error {
	provider, metricsHandler, err := InstallMetrics(ctx)
	if err != nil {
		return err
	}
	defer func() {
		// Best-effort flush on the way out; a fresh context because ctx is
		// already done by the time this runs.
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		_ = provider.Shutdown(shutdownCtx)
	}()

	handler, err := NewHandler(cfg, metricsHandler)
	if err != nil {
		return err
	}

	server := &http.Server{
		Addr:    addr,
		Handler: handler,
		// Explicit timeouts: an unbounded management server is a Slowloris
		// target, and the probes it answers must never be starved by a stuck
		// connection. ReadHeaderTimeout in particular is what gosec G112 looks
		// for -- golangci-lint fails the build without it.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	// Listen before serving so a port clash is returned to the caller rather than
	// disappearing into the goroutine below.
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("ops: listen %s: %w", addr, err)
	}

	errCh := make(chan error, 1)
	go func() {
		err := server.Serve(listener)
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		errCh <- err
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			// The graceful drain ran out of budget, so some connection is still
			// held. Force it closed before returning: without this the error path
			// leaves those connections (and the goroutine blocked in Serve) alive
			// in an embedder that keeps running after Serve returns.
			_ = server.Close()
			return fmt.Errorf("ops: shutdown: %w", err)
		}
		return <-errCh
	}
}

// DefaultAddr is the management address to serve on: $OPS_PORT, else DefaultPort.
func DefaultAddr() string {
	if p := os.Getenv("OPS_PORT"); p != "" {
		return ":" + p
	}
	return fmt.Sprintf(":%d", DefaultPort)
}

// ---- build metadata --------------------------------------------------------

// defaultVersion resolves /info's build.version: $BUILD_VERSION, else the main
// module's version stamped by the toolchain, else "0.0.0". Never empty -- the
// conformance checker requires a non-empty string.
func defaultVersion() string {
	if v := os.Getenv("BUILD_VERSION"); v != "" {
		return v
	}
	// "(devel)" is what the toolchain stamps for a build that is not from a
	// tagged module version; it is noise in /info, not a version.
	if bi, ok := debug.ReadBuildInfo(); ok && bi.Main.Version != "" && bi.Main.Version != "(devel)" {
		return bi.Main.Version
	}
	return "0.0.0"
}

// defaultGitSHA resolves /info's build.git_sha: $GIT_SHA, else the VCS revision
// the Go toolchain stamps into the binary (a Go-specific convenience the other
// language payloads have no equivalent for -- it needs no build-time ldflags and
// no env plumbing), else "unknown". Never empty.
func defaultGitSHA() string {
	if v := os.Getenv("GIT_SHA"); v != "" {
		return v
	}
	if bi, ok := debug.ReadBuildInfo(); ok {
		for _, s := range bi.Settings {
			if s.Key == "vcs.revision" && s.Value != "" {
				return s.Value
			}
		}
	}
	return "unknown"
}
