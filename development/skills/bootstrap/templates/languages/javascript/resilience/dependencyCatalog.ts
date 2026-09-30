/**
 * The hard/soft dependency declaration and the six-mandate call wrapper for Node
 * services (issue #1145, epic #964).
 *
 * It is the Node half of the org resilience policy: every outbound dependency call
 * gets a timeout, a circuit breaker, bounded retry with jittered backoff, a
 * registered fallback, background reconnect, and stay-stable fast-fail. The
 * blessed breaker is `opossum`; the retry is the small bounded loop in `call`,
 * deliberately not a second library (see README.md, "Why opossum and no retry
 * library").
 *
 * It EXTENDS the ops-api payload beside it rather than standing alone:
 * DependencyHealth (dependencyHealth.ts) implements the DependencyHealthSource seam
 * that payload already ships, so the ops surface reports what these breakers know.
 * The import direction is one-way and load-bearing -- resilience imports ops, never
 * the reverse -- which is what keeps the ops module free of any breaker library,
 * exactly as its own doc comment promises. This file imports nothing from ops at
 * all; only dependencyHealth.ts does, and only its types.
 *
 * WHAT OPOSSUM DOES AND DOES NOT DO HERE. opossum owns the per-dependency STATE --
 * closed, open, half-open -- the fast-fail rejection of an open breaker, the
 * per-attempt timeout, and the open -> half-open timer that makes recovery visible
 * with no traffic. It does NOT own the decision to trip. Its own trip rule counts a
 * filtered caller error as a SUCCESS and divides by every call it was handed,
 * rejected ones included, so a crawler's 404s would hold a dead dependency's breaker
 * closed. The catalog therefore disables opossum's rate trip and applies its own:
 * a count-based window over COUNTED outcomes only (README.md, the fit-check).
 *
 * PLACEMENT: copy this file, dependencyHealth.ts and (optionally)
 * pricingApiClient.ts into ONE directory of your service, conventionally
 * `src/resilience/` beside `src/ops/`. resilience-dependencies.properties must reach
 * the COMPILED output directory beside the compiled dependencyCatalog.js -- tsc does
 * not copy it, so add it to your build's copy step (README.md, "Placement").
 */

import { readFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

// opossum is a CommonJS package whose module.exports IS the class. Under NodeNext
// ESM the default import is that module.exports object, and @types/opossum declares
// it with `export =`, which esModuleInterop (on in the shipped tsconfig.json) maps
// to exactly this default import. A named import would compile and be undefined.
import CircuitBreaker from "opossum";

/**
 * The name of the hard/soft declaration, read from beside this module at runtime.
 *
 * A plain Node service has no configuration framework to bind, so the declaration
 * is a file rather than a config key -- the same choice the Go, Python and
 * non-Spring Java payloads made, and for the same reason.
 */
export const DECLARATION_FILE = "resilience-dependencies.properties";

/**
 * Points at a declaration to read INSTEAD of the one beside this module, so an
 * operator can override it from a mounted ConfigMap without rebuilding the image.
 * The name is a cross-language contract, shared with every sibling payload.
 */
export const DECLARATION_FILE_ENV = "OPS_DEPENDENCIES_FILE";

/**
 * The readiness hinge: the single classification that resolves "shed traffic when
 * a dependency is down" against "stay up and degrade". The spellings are the ops-api
 * contract's own, so they pass straight into the components map.
 *
 *   hard  nothing works without it; its loss FAILS /health/ready.
 *   soft  degraded operation is possible; its loss never fails readiness.
 */
export type Kind = "hard" | "soft";

// ---- the numbers ------------------------------------------------------------
//
// Every one of these is at PARITY with the Java sibling's resilience4j settings,
// so a dependency trips, recovers and becomes visible on /health at the same moment
// whichever language the service is written in.

/** MANDATE 3: attempts per call, counting the FIRST -- one call and two retries. */
export const MAX_ATTEMPTS = 3;
/** MANDATE 3: the first backoff, doubled per attempt. */
export const RETRY_BASE_DELAY_MS = 100;
/** MANDATE 3: the cap on the exponential growth. */
export const RETRY_MAX_DELAY_MS = 2_000;
/**
 * MANDATE 1: the per-attempt timeout. It is also the SLOW-CALL THRESHOLD, because
 * opossum has no slow-call detection of its own: a dependency that answers every
 * call in 9s never FAILS, so without a timeout it would never trip the breaker and
 * /health would report it up while the service is unusable. Two seconds is the
 * Java and Spring siblings' slow-call bound.
 */
export const ATTEMPT_TIMEOUT_MS = 2_000;
/** MANDATE 5: open -> half-open after this long, with or without traffic. */
export const RESET_TIMEOUT_MS = 10_000;
/** The count-based window the trip rule reads: the last N COUNTED outcomes. */
export const SLIDING_WINDOW_SIZE = 20;
/** No trip below this many counted outcomes, so one failure is never a 100% rate. */
export const MINIMUM_NUMBER_OF_CALLS = 10;
/** Trip at or above this failure rate. */
export const FAILURE_RATE_THRESHOLD = 0.5;

/** One breaker per dependency. The guarded call is passed in per fire. */
export type Breaker = CircuitBreaker<[() => Promise<unknown>], unknown>;

/** The call options a client passes through from its own caller. */
export interface CallOptions {
  /**
   * The CALLER's signal -- its deadline, a client disconnect, a drain. An aborted
   * one is never retried, never charged to the dependency, and ends the backoff
   * sleep early.
   */
  signal?: AbortSignal;
}

/**
 * Marks an error that must NOT count against a dependency's breaker.
 *
 *   caller-error  a 4xx the request itself provoked. The dependency answered
 *                 correctly and promptly; it is not unwell.
 *   cancelled     the CALLER went away -- its signal aborted mid-attempt. The
 *                 dependency was never asked to do anything wrong.
 *
 * Wrapping matters more than it looks. Without it, thirty user-driven 404s open a
 * breaker on a perfectly healthy dependency, /health starts reporting it down, and
 * -- if it is declared hard -- readiness starts failing for the whole pod.
 */
export class NotADependencyFailure extends Error {
  readonly reason: "caller-error" | "cancelled";

  constructor(cause: unknown, reason: "caller-error" | "cancelled" = "caller-error") {
    super(`not a dependency failure (${reason}): ${describe(cause)}`, { cause });
    this.name = "NotADependencyFailure";
    this.reason = reason;
  }
}

/** Wraps a caller's own error so the breaker and the retry both ignore it. */
export function notADependency(cause: unknown): NotADependencyFailure {
  return new NotADependencyFailure(cause, "caller-error");
}

/**
 * The declared dependencies, one breaker per dependency, and the window each
 * breaker's trip rule reads.
 *
 * One breaker PER DEPENDENCY is mandate 2, and it is also what makes the /health
 * components map meaningful: the breaker is the unit the surface reports, so sharing
 * one across two dependencies would report them as a single fused component that is
 * down whenever either is.
 */
export class DependencyCatalog {
  readonly #dependencies: ReadonlyMap<string, Kind>;
  // Created EAGERLY for every declared dependency, so these maps are never written
  // after construction, and requireAllDeclaredGuarded can tell "declared but nobody
  // guards it" from "not declared", which a lazily-populated map could not.
  readonly #breakers = new Map<string, Breaker>();
  // true = a counted FAILURE, false = a counted SUCCESS. Excluded outcomes and an
  // open breaker's rejections are never written here.
  readonly #windows = new Map<string, boolean[]>();
  readonly #guarded = new Set<string>();
  readonly #origin: string;

  private constructor(dependencies: ReadonlyMap<string, Kind>, origin: string) {
    this.#dependencies = dependencies;
    this.#origin = origin;
    for (const name of dependencies.keys()) {
      const window: boolean[] = [];
      const breaker = newBreaker(name);
      // A state change starts a fresh window. Failures recorded before an outage
      // must not re-trip a breaker the half-open probe has just proved healthy.
      breaker.on("close", () => {
        window.length = 0;
      });
      breaker.on("open", () => {
        window.length = 0;
      });
      this.#breakers.set(name, breaker);
      this.#windows.set(name, window);
    }
  }

  /**
   * Builds the catalog from the declaration: the file named by $OPS_DEPENDENCIES_FILE
   * when it is set, otherwise the one beside this module.
   *
   * There is deliberately no working-directory fallback. It would be the tier that
   * silently does the wrong thing -- present when you run from the repo root, absent
   * in the image -- so a declaration mistake would surface only after deploy. An
   * unreadable override fails LOUDLY rather than falling back, because a typo'd
   * ConfigMap path that quietly used the default would boot the pod with the wrong
   * readiness hinge.
   */
  static load(): DependencyCatalog {
    const override = process.env[DECLARATION_FILE_ENV];
    if (override !== undefined && override !== "") {
      let content: string;
      try {
        content = readFileSync(override, "utf8");
      } catch (err) {
        throw new Error(
          `resilience: ${DECLARATION_FILE_ENV} is set to "${override}" but it cannot be read: ${describe(err)}`,
          { cause: err },
        );
      }
      return new DependencyCatalog(parseDeclaration(override, content), override);
    }
    const beside = fileURLToPath(new URL(DECLARATION_FILE, import.meta.url));
    let content: string;
    try {
      content = readFileSync(beside, "utf8");
    } catch (err) {
      throw new Error(
        `resilience: ${beside} cannot be read (${describe(err)}). The declaration must ship BESIDE ` +
          `the compiled dependencyCatalog.js -- tsc does not copy it, so add it to your build's copy ` +
          `step -- or be supplied through ${DECLARATION_FILE_ENV}.`,
        { cause: err },
      );
    }
    return new DependencyCatalog(parseDeclaration(beside, content), beside);
  }

  /**
   * Builds a catalog from an explicit declaration -- the seam a test uses, and the
   * escape hatch for a service that keeps its declaration somewhere else.
   */
  static of(dependencies: Readonly<Record<string, Kind>>): DependencyCatalog {
    const declared = new Map<string, Kind>();
    for (const [name, kind] of Object.entries(dependencies)) {
      // Types are erased at runtime, so a JS caller can hand in "Hard" or "maybe".
      // A misread kind decides whether an outage sheds traffic -- refuse it.
      if (kind !== "hard" && kind !== "soft") {
        throw new Error(`resilience: dependency "${name}" has kind "${String(kind)}" (want hard|soft)`);
      }
      declared.set(name, kind);
    }
    return new DependencyCatalog(declared, "an explicit declaration");
  }

  /**
   * The declared name -> kind mapping, as a COPY: the catalog's own is never handed
   * out, so no caller can add a dependency the startup guards never saw.
   */
  dependencies(): Map<string, Kind> {
    return new Map(this.#dependencies);
  }

  /** The breaker for a declared dependency, or undefined when it is not declared. */
  breaker(name: string): Breaker | undefined {
    return this.#breakers.get(name);
  }

  /**
   * Refuses a dependency that code guards but the declaration never named.
   *
   * CALL THIS FROM EACH DEPENDENCY CLIENT'S CONSTRUCTOR, not only through `call`.
   * It is the only writer of the guarded set, so a service whose clients never claim
   * their dependencies has an EMPTY one when startup runs requireAllDeclaredGuarded
   * -- which then refuses every declared dependency and the pod never boots.
   *
   * Half of the under-reporting guard: an undeclared dependency has no breaker, so it
   * would appear nowhere in /health and nowhere in the readiness answer.
   */
  requireDeclared(name: string): string {
    if (!this.#dependencies.has(name)) {
      throw new Error(
        `resilience: dependency "${name}" is guarded in code but not declared in ${this.#origin} ` +
          `(add ${name}=hard|soft)`,
      );
    }
    this.#guarded.add(name);
    return name;
  }

  /**
   * Refuses a dependency the declaration names but no client guards. Call it ONCE at
   * startup, AFTER every client is built.
   *
   * The other half of the guard, and the half that fails silently without this call:
   * an unguarded dependency's breaker never sees a call, so it can never leave
   * closed -- and /health would swear the dependency is up straight through a total
   * outage.
   */
  requireAllDeclaredGuarded(): void {
    const unguarded = [...this.#dependencies.keys()].filter((name) => !this.#guarded.has(name)).sort();
    if (unguarded.length === 0) {
      return;
    }
    throw new Error(
      `resilience: ${this.#origin} declares ${unguarded.join(", ")}, but no client claimed them -- their ` +
        `breakers can never leave closed, so /health would report them up during an outage; either call ` +
        `requireDeclared from the client's constructor or remove them from the declaration`,
    );
  }

  /**
   * Runs an outbound call under all six mandates and falls back if it fails.
   *
   *   const price = await catalog.call("pricing-api",
   *     (signal) => fetchPrice(sku, signal),
   *     (cause) => ({ available: false, cause }),
   *     { signal: request.signal });
   *
   * `action` receives an AbortSignal and MUST pass it to its I/O (fetch's `signal`,
   * your driver's equivalent). That signal is how MANDATE 1 reaches the socket: it
   * aborts when the attempt's timeout expires or the caller's own signal does. An
   * action that ignores it still cannot park its caller -- opossum's timeout rejects
   * the attempt regardless -- but the abandoned request keeps its socket until the
   * dependency answers.
   *
   * MANDATE 4 is `fallback`, and it is also Node's stay-stable rule: an outage must
   * END in the fallback's answer, not in a rejected promise. A rejection nobody awaits
   * is an unhandled rejection, and Node TERMINATES the process on one by default -- an
   * upstream outage turned into a pod crash. Make the fallback resolve.
   *
   * MANDATE 6 is what the retry loop does NOT do: an open breaker's rejection arrives
   * immediately, un-retried, and goes straight to the fallback.
   */
  async call<T>(
    name: string,
    action: (signal: AbortSignal) => Promise<T>,
    fallback: (cause: unknown) => T | Promise<T>,
    options: CallOptions = {},
  ): Promise<T> {
    // Checked BEFORE any attempt, so the misuse surfaces on the first call rather
    // than on the first failure. A missing fallback would otherwise throw only once
    // a dependency broke -- during an outage, never in a green test.
    if (typeof action !== "function" || typeof fallback !== "function") {
      throw new TypeError(`resilience: call("${name}") needs both an action and a fallback (mandate 4)`);
    }
    // A non-positive budget would skip the loop entirely: the dependency is never
    // contacted on any request, and the fallback is handed an undefined cause.
    if (!Number.isInteger(MAX_ATTEMPTS) || MAX_ATTEMPTS < 1) {
      throw new RangeError(`resilience: MAX_ATTEMPTS is ${MAX_ATTEMPTS}; it must allow at least one attempt (mandate 3)`);
    }
    this.requireDeclared(name);
    const breaker = this.#breakers.get(name);
    if (breaker === undefined) {
      // Unreachable by construction -- requireDeclared passed, and every declared
      // dependency got a breaker eagerly. Refuse rather than run unguarded.
      throw new Error(`resilience: dependency "${name}" has no breaker`);
    }
    const caller = options.signal;
    // The caller's budget was spent before we attempted anything, so the dependency
    // was never contacted -- charging it would let caller-side overload open a
    // HEALTHY dependency's breaker.
    if (caller?.aborted === true) {
      return fallback(new NotADependencyFailure(caller.reason, "cancelled"));
    }

    let lastError: unknown;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      try {
        const value = (await breaker.fire(() => attemptOnce(action, caller))) as T;
        this.#record(name, false);
        return value;
      } catch (err) {
        lastError = err;
        if (isCountedFailure(err)) {
          this.#record(name, true);
        }
        if (!retryable(err, caller) || attempt === MAX_ATTEMPTS) {
          break;
        }
        try {
          await sleep(backoffDelayMs(attempt), undefined, caller === undefined ? {} : { signal: caller });
        } catch (sleepErr) {
          // KEEP the dependency's error: the fallback (and everything it logs) needs
          // the failure that caused the degradation, not only the abort that ended
          // the backoff.
          lastError = new AggregateError([err, sleepErr], `resilience: ${name} retry abandoned during backoff`);
          break;
        }
      }
    }
    // MANDATE 4: the fallback. The catalog enforces that one is WIRED; what it
    // returns is your application's business logic, not the org's.
    return fallback(lastError);
  }

  /**
   * The trip rule opossum's own rate is disabled for (see newBreaker).
   *
   * Only a CLOSED breaker records: a half-open probe's outcome is opossum's to act
   * on (success closes, failure re-opens), and a call that finished after another
   * call tripped the breaker must not pre-load the window the next close clears.
   */
  #record(name: string, failed: boolean): void {
    const breaker = this.#breakers.get(name);
    const window = this.#windows.get(name);
    if (breaker === undefined || window === undefined || !breaker.closed) {
      return;
    }
    window.push(failed);
    if (window.length > SLIDING_WINDOW_SIZE) {
      window.shift();
    }
    if (window.length < MINIMUM_NUMBER_OF_CALLS) {
      return;
    }
    const failures = window.filter((f) => f).length;
    if (failures / window.length >= FAILURE_RATE_THRESHOLD) {
      breaker.open();
    }
  }
}

/**
 * The blessed per-dependency breaker.
 *
 * volumeThreshold is MAX_SAFE_INTEGER on purpose: it DISABLES opossum's own trip in
 * the closed state (its check returns early while fires < volumeThreshold), so the
 * only closed -> open transition is the catalog's #record. opossum still re-opens a
 * breaker whose half-open probe fails -- that branch ignores the threshold -- which
 * is exactly the half of its state machine the catalog keeps.
 *
 * errorFilter decides what opossum does with an excluded error, and it only matters
 * in HALF-OPEN (in the closed state opossum's counters are not read). A caller error
 * there proves the dependency answered, so it closes the breaker like a success; a
 * caller's cancellation proves nothing, so it re-opens it. Filtering a cancellation
 * would close a breaker on a probe that never got an answer.
 */
function newBreaker(name: string): Breaker {
  const breaker: Breaker = new CircuitBreaker((invoke: () => Promise<unknown>) => invoke(), {
    name,
    timeout: ATTEMPT_TIMEOUT_MS,
    resetTimeout: RESET_TIMEOUT_MS,
    volumeThreshold: Number.MAX_SAFE_INTEGER,
    errorFilter: (err: unknown) =>
      err instanceof NotADependencyFailure && (err.reason === "caller-error" || !breaker.halfOpen),
    // The periodic 'snapshot' event is unused here; disabling it removes a timer
    // per breaker.
    enableSnapshots: false,
  });
  return breaker;
}

/**
 * One attempt: the action under its own timeout signal, joined to the caller's.
 *
 * A failure after the CALLER's signal aborted is re-classified as a cancellation,
 * whatever the action threw -- fetch reports it as a plain AbortError, which would
 * otherwise be counted against a dependency that never misbehaved (a client
 * disconnect, or a drain aborting every in-flight request). The attempt's OWN
 * timeout is deliberately not re-classified: that is the brownout signal.
 */
async function attemptOnce<T>(action: (signal: AbortSignal) => Promise<T>, caller: AbortSignal | undefined): Promise<T> {
  const timeout = AbortSignal.timeout(ATTEMPT_TIMEOUT_MS);
  const signal = caller === undefined ? timeout : AbortSignal.any([caller, timeout]);
  try {
    return await action(signal);
  } catch (err) {
    if (caller?.aborted === true && !(err instanceof NotADependencyFailure)) {
      throw new NotADependencyFailure(err, "cancelled");
    }
    throw err;
  }
}

/** opossum's own rejection codes: the breaker refused, the dependency was never called. */
const REJECTION_CODES = new Set(["EOPENBREAKER", "ESEMLOCKED", "ESHUTDOWN"]);

function isBreakerRejection(err: unknown): boolean {
  return typeof err === "object" && err !== null && REJECTION_CODES.has(String((err as { code?: unknown }).code));
}

/**
 * Whether an outcome counts toward the trip rule. Excluded errors and an open
 * breaker's own rejections are NEITHER success nor failure. A timeout (opossum's
 * ETIMEDOUT, or the action's own abort on the attempt signal) IS a failure: with no
 * slow-call detection, it is how a brownout trips the breaker.
 */
function isCountedFailure(err: unknown): boolean {
  return !(err instanceof NotADependencyFailure) && !isBreakerRejection(err);
}

/**
 * Whether another attempt could possibly help. Every false branch is a mandate, not a
 * preference:
 *   - a spent or aborted CALLER signal means the budget is gone;
 *   - an open (or half-open, probe in flight) breaker means the dependency is already
 *     known to be down, so retrying only parks the caller -- mandate 6;
 *   - a NotADependencyFailure is the caller's own error, which a retry reproduces
 *     exactly while counting nothing.
 */
function retryable(err: unknown, caller: AbortSignal | undefined): boolean {
  if (caller?.aborted === true) {
    return false;
  }
  if (isBreakerRejection(err)) {
    return false;
  }
  return !(err instanceof NotADependencyFailure);
}

/**
 * The jittered exponential backoff before retry `attempt + 1`.
 *
 * FULL jitter -- a uniform draw over [0, delay], not delay +/- a few percent. Equal
 * jitter still leaves every caller in the fleet retrying inside the same narrow
 * window, which is the synchronized stampede the backoff exists to break. The
 * exponent is clamped at both ends so an adopter who rewrites the loop from 0, or
 * raises MAX_ATTEMPTS, gets a monotonic, capped delay rather than NaN or Infinity.
 *
 * Math.random is correct here: this picks a sleep duration, not a token or a key.
 */
export function backoffDelayMs(attempt: number, random: () => number = Math.random): number {
  const shift = Math.min(Math.max(attempt - 1, 0), 20);
  const delay = Math.min(RETRY_BASE_DELAY_MS * 2 ** shift, RETRY_MAX_DELAY_MS);
  return Math.floor(random() * (delay + 1));
}

/**
 * Reads `<name>=hard|soft` lines.
 *
 * FULL-LINE `#` COMMENTS ONLY -- a trailing `orders-db=hard # primary` would make the
 * kind literally "hard # primary", which is neither hard nor soft. Rather than
 * silently guessing, that is an error: a misparsed kind decides whether an outage
 * sheds traffic or not.
 */
export function parseDeclaration(origin: string, content: string): Map<string, Kind> {
  const out = new Map<string, Kind>();
  // A BOM is not whitespace, so trim() leaves it on the first name, which then
  // parses as "﻿orders-db" -- accepted, given a breaker, and refused at
  // requireDeclared("orders-db") while the file visibly contains it.
  const lines = content.replace(/^﻿/, "").split(/\r?\n/);
  lines.forEach((raw, index) => {
    const line = index + 1;
    const text = raw.trim();
    if (text === "" || text.startsWith("#")) {
      return;
    }
    const eq = text.indexOf("=");
    const name = eq === -1 ? "" : text.slice(0, eq).trim();
    const value = eq === -1 ? "" : text.slice(eq + 1).trim();
    if (eq === -1 || name === "") {
      throw new Error(`${origin}:${line}: expected \`<name>=hard|soft\`, got "${text}"`);
    }
    // A duplicate is checked BEFORE the kind, so `a=hard` + `a=maybe` reports the
    // duplicate rather than making the operator fix the kind and meet the duplicate
    // on the next boot. Last-wins would DISARM THE READINESS HINGE: a ConfigMap
    // assembled from two sources could quietly downgrade a hard dependency to soft.
    const previous = out.get(name);
    if (previous !== undefined) {
      throw new Error(
        `${origin}:${line}: dependency "${name}" is declared twice (${previous}, then "${value}"); one line per dependency`,
      );
    }
    const kind = value.toLowerCase();
    if (kind !== "hard" && kind !== "soft") {
      throw new Error(
        `${origin}:${line}: dependency "${name}" has kind "${value}" (want hard|soft; note that only FULL-LINE ` +
          "`#` comments are supported, so a trailing comment lands here)",
      );
    }
    out.set(name, kind);
  });
  return out;
}

function describe(value: unknown): string {
  if (value instanceof Error) {
    return value.message;
  }
  return String(value);
}
