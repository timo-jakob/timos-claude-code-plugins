// Passive dependency health, read from circuit-breaker state, for Go services
// (issue #1144, epic #964).
//
// The unifying idea of the org resilience policy: THE CIRCUIT BREAKER KEEPS YOU
// SERVING; THE DEPENDENCY-HEALTH SURFACE TELLS YOU WHAT'S DEGRADED. An open breaker
// IS a down dependency, so health is READ from the breaker rather than measured by
// a second mechanism.
//
// PASSIVE means exactly that: this file never calls a dependency, never runs a
// scheduled probe, and NEVER transitively calls a downstream's /health (the
// health-check-storm anti-pattern, where one slow leaf hangs every ancestor's
// health check). Real request traffic -- or the breaker's own half-open probe --
// has already moved the state; reading it costs nothing and generates no traffic.
// gobreaker goes one better: it computes the open -> half-open transition from
// elapsed time inside State(), so a recovering dependency becomes visible on
// /health even while the service is receiving no traffic at all.
//
// WHERE THE AGGREGATE AND THE READINESS RULE LIVE: not here. This file maps breaker
// state to the per-dependency `components` entries and stops. The ops payload
// derives the aggregate floor and the readiness answer from those entries -- which
// is what lets the ops package stay free of any breaker import, as its own doc
// comment promises. The dependency runs one way: resilience imports ops, never the
// reverse.
package resilience

import (
	"sync"
	"time"

	"github.com/sony/gobreaker/v2"

	// <-- CHANGE THIS IMPORT to your service's real module path for the ops
	// payload (e.g. "github.com/acme/orders/internal/ops"). It is the one
	// placeholder in this payload; nothing else needs editing on placement.
	ops "example.com/service/internal/ops"
)

// Compile-time proof that this satisfies the seam the ops payload ships. If the
// ops-api contract ever changes shape, this line fails the build rather than
// letting /health quietly lose its components map.
var _ ops.DependencyHealthSource = (*DependencyHealth)(nil)

// DependencyHealth derives the ops-api v1.1 `components` map from gobreaker state.
//
// The mapping is exact and defined by the contract: closed = up, half-open =
// degraded (being re-probed), open = down.
type DependencyHealth struct {
	catalog *Catalog
	now     func() time.Time

	// mu guards since. It is written from gobreaker's OnStateChange, which runs
	// on whichever goroutine moved the breaker, and read by Components on the
	// goroutine serving /health -- so the two genuinely race without it.
	mu sync.Mutex
	// since maps a dependency to when it last changed breaker state, so a
	// dashboard can tell a blip from a sustained outage.
	since map[string]time.Time
}

// NewDependencyHealth wires the health view onto a catalog.
//
// It must be constructed BEFORE the catalog's breakers see traffic, because the
// OnStateChange hooks that keep `since` honest are attached here. A breaker that
// transitioned earlier would still report the right STATUS -- that is read live --
// but its `since` would be the construction time rather than the transition.
func NewDependencyHealth(catalog *Catalog) *DependencyHealth {
	return newDependencyHealth(catalog, time.Now)
}

// newDependencyHealth takes an injectable clock so a test can assert on `since`
// without sleeping.
func newDependencyHealth(catalog *Catalog, now func() time.Time) *DependencyHealth {
	d := &DependencyHealth{
		catalog: catalog,
		now:     now,
		since:   make(map[string]time.Time, len(catalog.dependencies)),
	}
	startedAt := now().UTC()
	for name := range catalog.dependencies {
		d.since[name] = startedAt
		// The catalog created every declared breaker eagerly, so this can neither
		// create one nor miss one; it only chains the listener that stamps `since`.
		// Use the name the callback is HANDED, not the loop variable: capturing the
		// range variable is correct only under Go >= 1.22 per-iteration scoping, and
		// this payload is also documented as copy-pasteable by hand.
		catalog.observe(name, func(n string, _, _ gobreaker.State) {
			d.stamp(n)
		})
	}
	return d
}

func (d *DependencyHealth) stamp(name string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.since[name] = d.now().UTC()
}

// Components returns the ops-api `components` map: one entry per DIRECT dependency.
//
// It builds a FRESH map every call, which the seam's contract requires rather than
// merely suggests: /health and /health/ready both range over what comes back, and
// handing out a map another goroutine writes is a concurrent map read/write -- a
// Go FATAL error, not a panic, so the ops handler's recover guards cannot catch it
// and the process dies mid-scrape. That is the outage-time crash mandate 6 forbids,
// arriving through the one door those guards do not cover.
//
// A service that declares no dependencies gets an empty map, and the ops payload
// then omits the field entirely, leaving the response a valid ops-api v1.0 body.
func (d *DependencyHealth) Components() map[string]ops.Dependency {
	dependencies := d.catalog.Dependencies()
	out := make(map[string]ops.Dependency, len(dependencies))

	// Read every breaker state FIRST. gobreaker computes the open -> half-open
	// transition inside State() and dispatches the observer synchronously, so a
	// scrape can be the thing that moves a breaker -- and snapshotting `since`
	// before that would report the new state with the previous timestamp.
	//
	// The states are read WITHOUT d.mu held, which is what keeps the lock order
	// one-way: the observer this may trigger takes d.mu itself.
	states := make(map[string]gobreaker.State, len(dependencies))
	for name := range dependencies {
		if breaker := d.catalog.Breaker(name); breaker != nil {
			states[name] = breaker.State()
		}
	}

	d.mu.Lock()
	stamps := make(map[string]time.Time, len(d.since))
	for name, at := range d.since {
		stamps[name] = at
	}
	d.mu.Unlock()

	for name, kind := range dependencies {
		state, known := states[name]
		if !known {
			// Unreachable by construction -- Of creates a breaker for every
			// declared dependency. If it ever became reachable, report the
			// dependency DOWN rather than omitting it: silently dropping a
			// declared dependency is exactly the under-reporting the two startup
			// guards exist to refuse.
			out[name] = ops.Dependency{
				Status: "down", Kind: kind.Wire(), Breaker: "open",
				Since: d.now().UTC().Format(time.RFC3339),
			}
			continue
		}
		at, ok := stamps[name]
		if !ok {
			at = d.now().UTC()
		}
		out[name] = ops.Dependency{
			Status:  statusOf(state),
			Kind:    kind.Wire(),
			Breaker: breakerOf(state),
			Since:   at.UTC().Format(time.RFC3339),
		}
	}
	return out
}

// statusOf maps breaker state to the contract's dependency status.
//
// Note the two vocabularies the ops payload warns about: a COMPONENT is healthy as
// "up", while the /health AGGREGATE spells healthy "ok". Returning "ok" here would
// be coerced to "down" by the ops payload's fail-toward-severity rule -- loudly,
// which is the intended outcome, but the spelling below is the correct one.
func statusOf(state gobreaker.State) string {
	switch state {
	case gobreaker.StateOpen:
		return "down"
	case gobreaker.StateHalfOpen:
		return "degraded"
	case gobreaker.StateClosed:
		return "up"
	default:
		// gobreaker ships exactly three states. An unrecognised one can only mean
		// the library grew a fourth, and a state this code has never seen is not
		// evidence of health -- fail toward severity, the same rule the ops
		// payload applies to an off-contract status.
		return "down"
	}
}

// breakerOf maps breaker state to the contract's three-value `breaker` field.
func breakerOf(state gobreaker.State) string {
	switch state {
	case gobreaker.StateOpen:
		return "open"
	case gobreaker.StateHalfOpen:
		return "half_open"
	case gobreaker.StateClosed:
		return "closed"
	default:
		// Same reasoning as statusOf: an unknown state reports as open rather
		// than being silently rendered healthy.
		return "open"
	}
}
