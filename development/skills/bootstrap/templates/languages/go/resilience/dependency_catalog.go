// Package resilience is the hard/soft dependency declaration and the six-mandate
// call wrapper for Go services (issue #1144, epic #964).
//
// It is the Go half of the org resilience policy: every outbound dependency call
// gets a timeout, a circuit breaker, bounded retry with jittered backoff, a
// registered fallback, background reconnect, and stay-stable fast-fail. The
// blessed breaker is sony/gobreaker; the retry is the small bounded loop below,
// deliberately not a second library (see README.md, "Why gobreaker and no retry
// library").
//
// It EXTENDS the ops-api payload beside it rather than standing alone:
// DependencyHealth (dependency_health.go) implements the DependencyHealthSource
// seam that payload already ships, so the ops surface reports what these breakers
// know. The dependency direction is one-way and load-bearing -- resilience imports
// ops, never the reverse -- which is what keeps the ops package free of any
// breaker library, exactly as its own doc comment promises.
//
// PLACEMENT: copy this file, dependency_health.go and (optionally)
// pricing_api_client.go into ONE directory in your service, conventionally
// internal/resilience/ -- every file here declares `package resilience`, so
// splitting them across directories does not compile. resilience-dependencies.properties
// must sit in that SAME directory: it is //go:embed-ed at build time, so its path
// is resolved by the compiler, not at runtime. Then fix the FLAGGED ops import in
// dependency_health.go to your service's real module path.
package resilience

import (
	"bufio"
	"context"
	_ "embed"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/sony/gobreaker/v2"
)

// The declaration is COMPILED IN, not read from the working directory.
//
// This is the Go-specific half of a decision the siblings get for free: Python
// resolves its copy with Path(__file__).with_name and Java reads a classpath
// resource, so in both the declaration travels inside the deployable. A Go binary
// has no such notion, and the blessed image path is ko onto
// gcr.io/distroless/static -- which ships the binary and a CA bundle and nothing
// else. A declaration read from the process working directory would simply not
// exist there, and every bootstrapped service would die at startup.
//
// Embedding also puts the file where it belongs: hard-vs-soft is an architectural
// fact about the service, reviewed in the same PR as the code that depends on it,
// not a per-environment knob. DeclarationFileEnv remains for the case that
// genuinely is per-environment -- a mounted ConfigMap -- and takes precedence.
//
//go:embed resilience-dependencies.properties
var embeddedDeclaration string

// DeclarationFile is the name of the hard/soft declaration, which ships beside
// these sources and is embedded into the binary at build time.
//
// A plain Go service has no configuration framework to bind, so the declaration is
// a file rather than a config key -- the same choice the non-Spring Java payload
// made, and for the same reason.
const DeclarationFile = "resilience-dependencies.properties"

// DeclarationFileEnv points at a declaration to read INSTEAD of the embedded one,
// so an operator can override it from a mounted ConfigMap without rebuilding the
// image. Unset -- the normal case -- means the embedded declaration is used.
const DeclarationFileEnv = "OPS_DEPENDENCIES_FILE"

// Kind is the readiness hinge: the single classification that resolves "shed
// traffic when a dependency is down" against "stay up and degrade".
type Kind int

const (
	// Hard means nothing works without it. Its loss FAILS /health/ready, so
	// Kubernetes sheds traffic -- correct, because the pod genuinely cannot serve.
	Hard Kind = iota
	// Soft means degraded operation is possible. Its loss never fails readiness:
	// the breaker opens, the service serves degraded responses, it reconnects in
	// the background, and /health reports it down while the pod stays ready.
	Soft
)

// Wire returns the spelling the ops-api contract uses for this kind.
func (k Kind) Wire() string {
	if k == Soft {
		return "soft"
	}
	return "hard"
}

// Retry budget -- MANDATE 3, bounded retry with jittered backoff.
//
// Bounded and jittered are both load-bearing. Unbounded (or un-backed-off) retry
// turns one dependency blip into a synchronized stampede that keeps it down; the
// jitter is what stops every caller in the fleet retrying on the same tick.
const (
	// MaxAttempts counts the FIRST call, so this is one initial call and two
	// retries -- the same 3 the Java and Python siblings use.
	MaxAttempts = 3
	// RetryBaseDelay is the first backoff, doubled per attempt.
	RetryBaseDelay = 100 * time.Millisecond
	// RetryMaxDelay caps the exponential growth.
	RetryMaxDelay = 2 * time.Second
)

// NotADependencyFailure marks an error that must NOT count against a dependency's
// breaker: a caller error (a 4xx the request itself provoked), or a local
// cancellation such as an interrupt during a drain.
//
// Wrapping matters more than it looks. Without it, thirty user-driven 404s open a
// breaker on a perfectly healthy dependency, /health starts reporting it down, and
// -- if it is declared hard -- readiness starts failing. The dependency was never
// unwell; the callers were wrong. Wrap with %w so errors.As finds it through your
// own error chain.
type NotADependencyFailure struct{ Err error }

func (e *NotADependencyFailure) Error() string {
	// Nil-total on purpose. NotADependency is EXPORTED and both the README and the
	// review dimension tell adopters to call it from their own clients, so a nil
	// cause is reachable -- and the panic would fire only where the error is
	// FORMATTED, i.e. inside the fallback's %w during an outage, never in a green
	// test. Same shape as Call's nil-fallback guard, at the other instance.
	if e == nil || e.Err == nil {
		return "not a dependency failure: <nil>"
	}
	return "not a dependency failure: " + e.Err.Error()
}

// Unwrap exposes the cause, so errors.Is/As still reach it.
func (e *NotADependencyFailure) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

// NotADependency wraps err so the breaker and the retry both ignore it.
func NotADependency(err error) error { return &NotADependencyFailure{Err: err} }

// Catalog holds the declared dependencies and one breaker per dependency.
//
// One breaker PER DEPENDENCY is mandate 2, and it is also what makes the /health
// components map meaningful: the breaker is the unit the surface reports, so
// sharing one across two dependencies would report them as a single fused
// component that is down whenever either is.
type Catalog struct {
	dependencies map[string]Kind
	// Created EAGERLY for every declared dependency at construction, so this map
	// is never written after that -- concurrent reads need no lock, and
	// RequireAllDeclaredGuarded can tell "declared but nobody guards it" from
	// "not declared", which a lazily-populated map could not.
	breakers map[string]*gobreaker.CircuitBreaker[any]

	// mu guards everything below it.
	mu      sync.Mutex
	guarded map[string]bool
	// observers is how dependency_health.go learns about transitions. gobreaker
	// fixes OnStateChange when the breaker is CONSTRUCTED, so a listener cannot
	// be attached afterwards -- the catalog installs one dispatching hook per
	// breaker and fans out to whatever registers later.
	observers map[string][]func(string, gobreaker.State, gobreaker.State)
}

// Load builds the catalog from the declaration: the file named by
// DeclarationFileEnv when it is set, otherwise the embedded one.
//
// There is deliberately no working-directory fallback. It would be the tier that
// silently does the wrong thing: present in local dev, absent in the distroless
// image, so a declaration mistake would surface only after deploy.
func Load() (*Catalog, error) {
	source, origin := embeddedDeclaration, "the embedded "+DeclarationFile
	if path := os.Getenv(DeclarationFileEnv); path != "" {
		content, err := os.ReadFile(path) //nolint:gosec // the path is operator-supplied config, by design
		if err != nil {
			return nil, fmt.Errorf(
				"resilience: %s is set to %q but it cannot be read: %w", DeclarationFileEnv, path, err)
		}
		source, origin = string(content), path
	}
	declared, err := parseDeclaration(origin, source)
	if err != nil {
		return nil, err
	}
	return Of(declared), nil
}

// Of builds a catalog from an explicit declaration -- the seam a test uses, and
// the escape hatch for a service that keeps its declaration somewhere else.
func Of(dependencies map[string]Kind) *Catalog {
	c := &Catalog{
		dependencies: make(map[string]Kind, len(dependencies)),
		breakers:     make(map[string]*gobreaker.CircuitBreaker[any], len(dependencies)),
		guarded:      make(map[string]bool, len(dependencies)),
		observers:    make(map[string][]func(string, gobreaker.State, gobreaker.State), len(dependencies)),
	}
	for name, kind := range dependencies {
		c.dependencies[name] = kind
		settings := BreakerSettings(name)
		settings.OnStateChange = func(n string, from, to gobreaker.State) { c.dispatch(n, from, to) }
		c.breakers[name] = gobreaker.NewCircuitBreaker[any](settings)
	}
	return c
}

// observe registers a state-transition listener for one dependency.
//
// Note what BreakerSettings deliberately does NOT set: an OnStateChange of its
// own. Of installs the dispatching hook instead, so a caller who builds their own
// breaker from BreakerSettings still gets the documented behaviour, and a caller
// who uses the catalog gets fan-out. If BreakerSettings set a hook, Of would have
// to overwrite it and the two would silently disagree.
func (c *Catalog) observe(name string, fn func(string, gobreaker.State, gobreaker.State)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.observers[name] = append(c.observers[name], fn)
}

// dispatch fans a transition out to the registered observers.
//
// The listeners are copied out under c.mu and invoked WITHOUT it: gobreaker calls
// OnStateChange while holding its own mutex, so an observer that touched the
// catalog under c.mu would invert the two lock orders and deadlock the first time a
// breaker tripped -- during an outage, which is the worst possible moment.
//
// Note what is still held: gobreaker's OWN mutex, for the whole fan-out. So a
// listener must be short and must NEVER call back into the same breaker --
// State() or Counts() would self-deadlock on a non-reentrant sync.Mutex.
func (c *Catalog) dispatch(name string, from, to gobreaker.State) {
	c.mu.Lock()
	listeners := make([]func(string, gobreaker.State, gobreaker.State), len(c.observers[name]))
	copy(listeners, c.observers[name])
	c.mu.Unlock()
	for _, fn := range listeners {
		fn(name, from, to)
	}
}

// BreakerSettings is the blessed per-dependency breaker configuration.
//
// MANDATE 5, background reconnect, is Timeout: after it elapses the breaker moves
// itself to half-open and lets a probe through, so full function resumes with no
// deploy and no manual step. gobreaker computes that transition from elapsed time
// inside State(), which buys something the config does not obviously say: recovery
// becomes visible on /health even with NO traffic at all.
//
// ReadyToTrip is a FAILURE RATE with a minimum volume, not gobreaker's default of
// five consecutive failures. A rate is what actually describes a sick dependency:
// consecutive-only never trips a dependency that fails every other call, and the
// minimum volume is what stops the first single failure after a reset from tripping
// a 100%-failure-rate breaker on a sample of one.
//
// IsExcluded is where NotADependencyFailure earns its keep: excluded errors count
// as neither success nor failure, so a caller's own 4xx cannot move the breaker in
// either direction. (An open breaker's own rejection never reaches here -- gobreaker
// returns ErrOpenState before it invokes the call at all.)
func BreakerSettings(name string) gobreaker.Settings {
	return gobreaker.Settings{
		Name: name,
		// Half-open lets a small burst through rather than a single probe, so a
		// recovered dependency closes the breaker promptly instead of on the
		// next lone request.
		MaxRequests: 3,
		// Rolling window for the closed-state counters.
		//
		// Interval and minimumVolume below are ONE decision, and getting it wrong
		// is silent: gobreaker clears the closed-state counters every Interval, so
		// a dependency called fewer than minimumVolume times per Interval can
		// NEVER trip -- the counters reset before the floor is reached, and /health
		// reports it up straight through a total outage. Five minutes against a
		// floor of 10 keeps a batch-shaped or rarely-hit dependency trippable.
		// (resilience4j sidesteps this with a count-based sliding window that
		// never time-resets, which is what the Java sibling uses.)
		Interval: 5 * time.Minute,
		// Open -> half-open. MANDATE 5, and the same 10s the Java and Python
		// siblings use -- deliberately at parity, so recovery becomes visible on
		// /health at the same moment across every language in the fleet.
		Timeout: 10 * time.Second,
		ReadyToTrip: func(c gobreaker.Counts) bool {
			const minimumVolume = 10
			// EXCLUDE the excluded calls from the denominator. gobreaker counts
			// every admitted call in Requests and never decrements it when
			// IsExcluded later drops one -- onExclusion only bumps TotalExclusions
			// -- so dividing by Requests lets excluded traffic hold a DEAD
			// dependency's breaker closed. Measured: 100 caller-provoked 404s plus
			// 20 straight real failures gives 20/120 = 0.17, so the breaker stays
			// closed and /health reports the dependency up through a total outage.
			// That is the lying health surface this payload exists to prevent, and
			// it is also what makes the IsExcluded comment above true in BOTH
			// directions rather than only one. This is the library's own
			// validRequests(), which is unexported, underflow guard included.
			if c.Requests < c.TotalExclusions {
				return false
			}
			counted := c.Requests - c.TotalExclusions
			if counted < minimumVolume {
				return false
			}
			return float64(c.TotalFailures)/float64(counted) >= 0.5
		},
		IsExcluded: func(err error) bool {
			var notADependency *NotADependencyFailure
			if errors.As(err, &notADependency) {
				return true
			}
			// A cancelled CALLER is not a failing dependency. net/http cancels a
			// request's context when the peer disconnects, and a graceful drain
			// cancels every in-flight context -- so without this a burst of client
			// disconnects, or one rolling deploy, pushes the failure rate over the
			// threshold and opens the breaker on a dependency that never
			// misbehaved. For a hard dependency that then sheds traffic from a
			// healthy pod: the self-inflicted outage this payload exists to avoid.
			//
			// DeadlineExceeded is deliberately NOT excluded. That is what an
			// expired client timeout looks like, and since gobreaker has no
			// slow-call detection, the timeout IS the slow-call signal -- excluding
			// it would make a brownout invisible.
			return errors.Is(err, context.Canceled)
		},
	}
}

// Dependencies returns the declared name -> kind mapping.
//
// The returned map is a copy: the catalog's own is never handed out. Iteration
// order is a map's, i.e. unspecified -- sort the keys if you need determinism, as
// RequireAllDeclaredGuarded does for its message.
func (c *Catalog) Dependencies() map[string]Kind {
	out := make(map[string]Kind, len(c.dependencies))
	for name, kind := range c.dependencies {
		out[name] = kind
	}
	return out
}

// Breaker returns the breaker for a declared dependency, or nil when it is not
// declared. dependency_health.go reads State() off these.
func (c *Catalog) Breaker(name string) *gobreaker.CircuitBreaker[any] {
	return c.breakers[name]
}

// RequireDeclared refuses a dependency that code guards but the declaration file
// never named.
//
// CALL THIS FROM EACH DEPENDENCY CLIENT'S CONSTRUCTOR, not only through Call.
// It is the only writer of the guarded set, so a service whose clients never claim
// their dependencies has an EMPTY one when startup runs
// RequireAllDeclaredGuarded -- which then refuses every declared dependency and the
// pod never boots. Claiming at construction also turns "guarded in code but missing
// from the declaration" into a startup failure rather than a surprise on the first
// request after a deploy.
//
// Half of the under-reporting guard, and it fails at STARTUP rather than during an
// outage: an undeclared dependency has no breaker, so it would appear nowhere in
// /health and nowhere in the readiness answer -- the surface would simply be silent
// about a dependency the service genuinely has.
func (c *Catalog) RequireDeclared(name string) (string, error) {
	if _, ok := c.dependencies[name]; !ok {
		return "", fmt.Errorf(
			"resilience: dependency %q is guarded in code but not declared in %s (add %q=hard|soft)",
			name, declarationOrigin(), name)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.guarded[name] = true
	return name, nil
}

// RequireAllDeclaredGuarded refuses a dependency the declaration names but no
// client guards. Call it ONCE at startup, AFTER every client is built.
//
// The other half of the guard, and the half that fails silently without this call.
// An unguarded dependency's breaker is created eagerly and then never sees a call,
// so it can never leave the closed state -- and /health would swear the dependency
// is up straight through a total outage. That is the lying health surface this
// whole payload exists to prevent, so the check is worth the one line at startup.
func (c *Catalog) RequireAllDeclaredGuarded() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	var unguarded []string
	for name := range c.dependencies {
		if !c.guarded[name] {
			unguarded = append(unguarded, name)
		}
	}
	if len(unguarded) == 0 {
		return nil
	}
	sort.Strings(unguarded)
	return fmt.Errorf(
		"resilience: %s declares %v, but no client claimed them -- their breakers can never "+
			"leave closed, so /health would report them up during an outage; either call "+
			"RequireDeclared from the client's constructor or remove them from the declaration",
		declarationOrigin(), unguarded)
}

// Call runs an outbound call under all six mandates and falls back if it fails.
//
// It is a package-level generic function rather than a method because Go methods
// cannot have type parameters -- the catalog stores breakers as
// CircuitBreaker[any] and this restores the caller's concrete type.
//
//	price, err := resilience.Call(ctx, catalog, "pricing-api",
//	    func(ctx context.Context) (Price, error) { return client.fetch(ctx, sku) },
//	    func(error) (Price, error) { return cachedPrice(sku), nil })
//
// MANDATE 1, the timeout, is the ONE mandate this cannot impose for you, because it
// does not own your socket: `call` must carry its own transport timeout (a
// context deadline, an http.Client.Timeout). In Go that timeout does double duty,
// and the second job is easy to miss -- gobreaker has NO slow-call detection, so
// your timeout IS the slow-call threshold. A generous one lets a brownout pass
// unnoticed: the dependency answers every call in 9s, nothing ever fails, the
// breaker stays closed and /health reports it up while the service is unusable.
//
// MANDATE 6 is what the retry loop does NOT do: an open breaker's rejection arrives
// immediately, un-retried, and goes straight to the fallback.
func Call[T any](
	ctx context.Context,
	catalog *Catalog,
	name string,
	call func(context.Context) (T, error),
	fallback func(error) (T, error),
) (T, error) {
	var zero T
	// Checked BEFORE any attempt, so the misuse surfaces on the first call rather
	// than on the first failure. `fallback(lastErr)` on a nil fallback would panic
	// the request goroutine only once a dependency broke -- i.e. only during an
	// outage, never in a green test, which is the worst time to discover it.
	if call == nil || fallback == nil {
		return zero, fmt.Errorf("resilience: Call(%q) needs both a call and a fallback (mandate 4)", name)
	}
	// A non-positive budget would skip the loop entirely: the dependency is never
	// contacted on any request, lastErr stays nil, and the fallback is handed a nil
	// cause -- silently, on every call.
	if MaxAttempts < 1 {
		return zero, fmt.Errorf(
			"resilience: MaxAttempts is %d; the retry budget must allow at least one attempt (mandate 3)",
			MaxAttempts)
	}
	if _, err := catalog.RequireDeclared(name); err != nil {
		return zero, err
	}
	// The caller's budget was already spent before we attempted anything, so the
	// dependency was never contacted -- charging it a failure would let caller-side
	// overload open a HEALTHY dependency's breaker, and a `hard` declaration would
	// then shed traffic from a pod whose only problem was impatient callers. Note
	// this does NOT weaken the "DeadlineExceeded is the brownout signal" rule: a
	// deadline that expires DURING an attempt is a genuinely slow call and still
	// counts. Only an already-done context is refused here, and IsExcluded stays
	// unchanged -- it cannot see a context.
	if err := ctx.Err(); err != nil {
		return fallback(fmt.Errorf("resilience: %s not attempted, caller context already done: %w", name, err))
	}
	breaker := catalog.Breaker(name)

	var lastErr error
	for attempt := 1; attempt <= MaxAttempts; attempt++ {
		result, err := breaker.Execute(func() (any, error) { return call(ctx) })
		if err == nil {
			value, _ := result.(T)
			return value, nil
		}
		lastErr = err
		if !retryable(ctx, err) || attempt == MaxAttempts {
			break
		}
		if sleepErr := sleepBackoff(ctx, attempt); sleepErr != nil {
			// JOIN rather than replace: the fallback (and everything it logs)
			// needs the 5xx that actually caused the degradation, not just
			// "context deadline exceeded" from the budget expiring mid-backoff.
			// errors.Is still finds the context error; errors.As still reaches
			// the dependency error.
			lastErr = errors.Join(lastErr, sleepErr)
			break
		}
	}
	// MANDATE 4: the fallback. This package enforces that one is WIRED; what it
	// returns is your application's business logic, not the org's.
	return fallback(lastErr)
}

// retryable decides whether another attempt could possibly help.
//
// Every false branch here is a mandate, not a preference:
//   - an open (or half-open-saturated) breaker means the dependency is already
//     known to be down, so retrying only parks the caller -- mandate 6;
//   - a NotADependencyFailure is the caller's own error, so a retry reproduces it
//     exactly while counting nothing;
//   - a spent caller context means the budget is gone; retrying past it would
//     ignore the deadline the caller set.
func retryable(ctx context.Context, err error) bool {
	if ctx.Err() != nil {
		return false
	}
	if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
		return false
	}
	var notADependency *NotADependencyFailure
	return !errors.As(err, &notADependency)
}

// sleepBackoff waits out the jittered exponential backoff, or returns early if the
// caller's context is cancelled first -- a drain must not be held up by a retry
// sleeping on a dependency that is already gone.
func sleepBackoff(ctx context.Context, attempt int) error {
	// Clamp the shift, not just its result: MaxAttempts is exported and the README
	// invites changing the retry budget, and a large attempt would overflow int64
	// into a NEGATIVE duration that the cap below cannot catch -- after which
	// rand.Int64N panics on a non-positive bound.
	// Clamp the SHIFT, not the result, and clamp it toward the BASE delay: a
	// negative shift panics, and falling back to the cap for an out-of-range low
	// attempt would make the backoff non-monotonic (2s, then 100ms, then 200ms)
	// for the very adopter this guard exists for -- one who rewrites the loop as
	// `for attempt := 0; attempt < MaxAttempts; attempt++`. The upper bound stays
	// because a large shift overflows int64 into a negative duration.
	shift := attempt - 1
	if shift < 0 {
		shift = 0
	}
	delay := RetryMaxDelay
	if shift <= 20 {
		if grown := RetryBaseDelay << shift; grown > 0 && grown < RetryMaxDelay {
			delay = grown
		}
	}
	// FULL jitter: a uniform draw over [0, delay], not delay±a few percent. Equal
	// jitter still leaves every caller in the fleet retrying inside the same
	// narrow window, which is the synchronized stampede the backoff exists to break.
	//
	// gosec's G404 fires on math/rand here and is a false positive worth dismissing
	// explicitly rather than silencing repo-wide: this draw picks a sleep duration,
	// not a token, a nonce or a key. Nothing about retry timing is a secret, and
	// crypto/rand would add a syscall on every backoff for no security gain. The
	// directive is scoped to this one line so a genuinely sensitive use elsewhere in
	// the payload would still be caught.
	jittered := time.Duration(rand.Int64N(int64(delay) + 1)) //nolint:gosec // jitter is a sleep duration, not a secret
	timer := time.NewTimer(jittered)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// declarationOrigin names the declaration actually in force, so a startup failure
// sends the operator to the right place rather than to a file that may not be the
// one being read.
func declarationOrigin() string {
	if path := os.Getenv(DeclarationFileEnv); path != "" {
		return path
	}
	return "the embedded " + DeclarationFile
}

// parseDeclaration reads `<name>=hard|soft` lines.
//
// FULL-LINE `#` COMMENTS ONLY -- a trailing `orders-db=hard # primary` would make
// the kind literally "hard # primary", which is neither hard nor soft. Rather than
// silently guessing, that is an error: a misparsed kind decides whether an outage
// sheds traffic or not.
func parseDeclaration(origin, content string) (map[string]Kind, error) {
	// A BOM is not whitespace, so TrimSpace leaves it on the first line and the
	// name parses as "\ufefforders-db" -- accepted, given a breaker, and then
	// refused at RequireDeclared("orders-db") while the file visibly contains it.
	content = strings.TrimPrefix(content, "\ufeff")

	out := make(map[string]Kind)
	scanner := bufio.NewScanner(strings.NewReader(content))
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		name, value, found := strings.Cut(text, "=")
		name, value = strings.TrimSpace(name), strings.TrimSpace(value)
		if !found || name == "" {
			return nil, fmt.Errorf("%s:%d: expected `<name>=hard|soft`, got %q", origin, line, text)
		}
		// A duplicate is checked BEFORE the kind, so `a=hard` + `a=maybe` reports the
		// duplicate rather than making the operator fix the kind and meet the
		// duplicate on the next boot. Last-wins is the one malformation a silent
		// parser would swallow, and it DISARMS THE READINESS HINGE: a ConfigMap
		// assembled from two sources can quietly downgrade a hard dependency to
		// soft, after which its total outage never fails readiness while /health
		// still lists it and looks perfectly conformant.
		if previous, duplicate := out[name]; duplicate {
			return nil, fmt.Errorf(
				"%s:%d: dependency %q is declared twice (%s, then %q); one line per dependency",
				origin, line, name, previous.Wire(), value)
		}
		switch strings.ToLower(value) {
		case "hard":
			out[name] = Hard
		case "soft":
			out[name] = Soft
		default:
			return nil, fmt.Errorf(
				"%s:%d: dependency %q has kind %q (want hard|soft; note that only FULL-LINE "+
					"`#` comments are supported, so a trailing comment lands here)",
				origin, line, name, value)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("resilience: reading %s: %w", origin, err)
	}
	return out, nil
}
