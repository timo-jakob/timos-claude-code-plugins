#!/usr/bin/env bats
#
# Structural tests for the canonical Node / TypeScript resilience + dependency-health
# payload (#1145, epic #964) — the sibling of tests/go-resilience-payload.bats,
# tests/java-resilience-payload.bats and tests/python-resilience-payload.bats.
#
# Node is NOT in the test image (see tests/Dockerfile), so these are grep-based:
# the payload's compilation under the shipped strict tsconfig and its live
# behaviour are verified out-of-band — by tests/acceptance/{rest,cli}/
# javascript-resilience.bats, which compile and run it — and downstream by the
# bootstrapped repo's own CI. What they pin is the contract shape a careless edit
# would break silently.
#
# THREE RULES, inherited from tests/ops-api-language-payloads.bats (#1192) because
# each was learned from a defect that shipped green:
#
#   1. ANCHOR EVERY NEEDLE TO CODE, NEVER TO PROSE. This payload documents its own
#      contract at length, in the same words the contract is written in, so an
#      unscoped grep is satisfied by a doc comment even after the code it names is
#      deleted. `flatten` STRIPS comment lines, which makes the rule structural.
#   2. PIN A GUARD TOGETHER WITH ITS BODY, AS ONE NEEDLE. A condition and its
#      consequence asserted separately cannot tell `A && B` from `A || B`, nor an
#      arm from its transposed twin. `flatten` collapses whitespace so a whole
#      `if (…) { … }` fits one needle, immune to Prettier re-wrapping.
#   3. NO NEEDLE MAY SPAN A SOURCE LINE. A multi-line single-quoted needle whose
#      opening line contains a paren establishes a PHANTOM quote carry in
#      tests/find-inert-bracket-assertions.zsh, silently exempting the span that
#      follows from the suite's own inert-assertion lint (#1068's residual gap).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  JS="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript/resilience"
  OPS="$REPO_ROOT/development/skills/bootstrap/templates/languages/javascript/ops-api"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  HOWTO="$REPO_ROOT/docs/how-to/adopt-the-ops-surface.md"
}

# ts_block <file> <signature-prefix> — one TypeScript declaration (a top-level
# function, or a method inside the class), from the first line whose TRIMMED text
# starts with the prefix to the first `}` at that line's own indentation. Closure
# is proven by a SENTINEL the terminating branch emits rather than by inspecting
# the result: a runaway extraction that ran to EOF would pass a shape check while
# silently returning every following declaration as the haystack — which is
# exactly what makes a `lacks` assertion vacuous.
ts_block() {
  local body
  body="$(awk -v sig="$2" '
    !inside {
      trimmed = $0; sub(/^[ \t]+/, "", trimmed)
      if (index(trimmed, sig) == 1) { inside = 1; match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH) }
    }
    inside { print }
    inside && ($0 == ind "}" || $0 == ind "};") { print "//ts_block:closed"; exit }
  ' "$1")"
  case "$body" in
    *"//ts_block:closed") printf '%s' "${body%//ts_block:closed}" ;;
    *) echo "ts_block: '$2' not found in $1, or its block never closed" >&2; return 1 ;;
  esac
}

# flatten — drop whole-line comments (`//`, and the `/** … */` doc-comment lines),
# then collapse every whitespace run to one space. Rules 1 and 2 in one helper.
flatten() { printf '%s' "$1" | grep -v '^[[:space:]]*\(//\|/\*\|\*\)' | tr -s ' \t\n' ' '; }

# code_of <file> — the whole file with its comment lines stripped.
code_of() { flatten "$(cat "$1")"; }

catalog_flat() { local b; b="$(ts_block "$JS/dependencyCatalog.ts" "$1")" || return 1; flatten "$b"; }
health_flat() { local b; b="$(ts_block "$JS/dependencyHealth.ts" "$1")" || return 1; flatten "$b"; }
client_flat() { local b; b="$(ts_block "$JS/pricingApiClient.ts" "$1")" || return 1; flatten "$b"; }

@test "js resilience payload files exist at the SKILL render paths, as .ts" {
  [ -f "$JS/dependencyCatalog.ts" ]
  [ -f "$JS/dependencyHealth.ts" ]
  [ -f "$JS/pricingApiClient.ts" ]
  [ -f "$JS/package.json.deps" ]
  [ -f "$JS/resilience-dependencies.properties" ]
  [ -f "$JS/README.md" ]
  # TypeScript, not JavaScript: a .js twin would be a second copy to drift.
  run ! compgen -G "$JS/*.js"
  run ! compgen -G "$JS/*.mjs"
}

@test "ts_block proves closure rather than inferring it (self-test)" {
  run ! ts_block "$JS/dependencyCatalog.ts" 'thisDeclarationDoesNotExist('
  # …and a real extraction stops at its OWN closing brace, not at a later one.
  local fn; fn="$(catalog_flat 'function isCountedFailure(')"
  lacks "$fn" 'function retryable('
}

@test "js resilience imports ops TYPE-ONLY and ops never imports a breaker" {
  # The import direction is the invariant: resilience imports ops, never the
  # reverse. `import type` is erased at compile time, so the resilience module
  # never loads the ops module (or its OpenTelemetry graph) at runtime.
  local health; health="$(code_of "$JS/dependencyHealth.ts")"
  contains "$health" 'import type { Dependency, DependencyHealthSource } from "../ops/opsApi.js";'
  # The catalog does not import ops at all.
  lacks "$(code_of "$JS/dependencyCatalog.ts")" 'opsApi'
  # …and the ops module must still import no breaker. Guarded and positively
  # controlled: on a missing file the haystack is empty and `lacks` would pass
  # unconditionally.
  [ -f "$OPS/opsApi.ts" ]
  local opscode; opscode="$(code_of "$OPS/opsApi.ts")"
  # The seam's shape on the ops side. DependencyHealth stakes a compile-time
  # `implements` on it, but no tsc runs in this image — so a rename there would
  # ship green through both payloads' suites and break every bootstrapped build.
  contains "$opscode" 'export interface DependencyHealthSource {'
  contains "$opscode" 'components(): Record<string, Dependency> | undefined;'
  lacks "$opscode" 'from "opossum"'
  lacks "$opscode" 'resilience/'
}

@test "js dependencyHealth keeps the FLAGGED ops import (re-point if ops moved)" {
  grep -qF 'CHANGE THIS IMPORT' "$JS/dependencyHealth.ts"
  # The marker must sit IMMEDIATELY above the import block it flags, or an
  # adopter re-points the wrong line.
  local marker import
  marker="$(grep -n 'CHANGE THIS IMPORT' "$JS/dependencyHealth.ts" | head -1 | cut -d: -f1)"
  import="$(grep -n 'from "../ops/opsApi.js";' "$JS/dependencyHealth.ts" | head -1 | cut -d: -f1)"
  [ -n "$marker" ] && [ -n "$import" ]
  [ "$import" -gt "$marker" ] && [ $(( import - marker )) -le 6 ]
}

@test "js dependencyHealth proves at COMPILE TIME that it satisfies the ops seam" {
  # Without `implements`, a contract change would not break the build — it would
  # quietly leave /health with no components map.
  grep -qF 'export class DependencyHealth implements DependencyHealthSource {' "$JS/dependencyHealth.ts"
}

@test "js payload is NodeNext ESM: every relative import carries an explicit .js specifier" {
  # NodeNext resolution refuses an extensionless relative import, so a `./x`
  # compiles nowhere — but only a real tsc would say so, and none runs here.
  local f rel
  for f in "$JS/dependencyCatalog.ts" "$JS/dependencyHealth.ts" "$JS/pricingApiClient.ts"; do
    rel="$(grep -E '^(import|export) .* from "\.\.?/' "$f" || true)"
    # Positive control for the two files that DO import relatively.
    if [ "$f" != "$JS/dependencyCatalog.ts" ]; then [ -n "$rel" ]; fi
    run ! grep -E '^(import|export) .* from "\.\.?/[^"]*[^s]"' <<< "$rel"
    run ! grep -E '^(import|export) .* from "\.\.?/[^"]*\.ts"' <<< "$rel"
    run ! grep -E '^(import|export) .* from "\.\.?/[^"]*[^.][^j]s"' <<< "$rel"
  done
  # No CommonJS anywhere in the payload's code: the gating ops block installs only
  # into an ESM package, so a require() would be a second module system.
  lacks "$(code_of "$JS/dependencyCatalog.ts")" 'require('
  lacks "$(code_of "$JS/dependencyHealth.ts")" 'require('
  lacks "$(code_of "$JS/pricingApiClient.ts")" 'require('
  # opossum is CommonJS whose module.exports IS the class: the DEFAULT import is
  # the correct one. A named import compiles and is undefined at runtime.
  grep -qxF 'import CircuitBreaker from "opossum";' "$JS/dependencyCatalog.ts"
}

@test "js dependencyHealth maps breaker state to the contract's vocabulary exactly" {
  # closed = up, half_open = degraded, open = down. A component is healthy as
  # "up"; returning the AGGREGATE's spelling "ok" would be coerced to down.
  local fn; fn="$(health_flat 'export function statusOf(')"
  contains "$fn" 'switch (state) { case "closed": return "up"; case "half_open": return "degraded"; case "open": return "down"; }'
  lacks "$fn" '"ok"'
  # opossum's SHUTDOWN (and a disabled breaker) is not one of the contract's
  # states and not evidence of health: it must fail toward severity. The arms as
  # ONE needle so `closed` alone (dropping the enabled check) cannot pass.
  local st; st="$(health_flat 'export function breakerStateOf(')"
  contains "$st" 'if (breaker.closed && breaker.enabled) { return "closed"; } if (breaker.halfOpen) { return "half_open"; } return "open"; }'
}

@test "js dependencyHealth builds the ops-api v1.1 entry from the right sources" {
  local fn; fn="$(health_flat 'components(): Record<string, Dependency> {')"
  # The single line where the contract is realized. status/breaker transposed, or
  # a dropped kind (the readiness hinge — an absent kind is coerced to hard by the
  # ops module, so a soft dependency's outage would start failing readiness), all
  # ship green without this.
  contains "$fn" 'const state = breakerStateOf(breaker); out[name] = { status: statusOf(state), kind, breaker: state, since };'
  # A FRESH object every call, ranged over the catalog's COPY.
  contains "$fn" 'const out: Record<string, Dependency> = {}; for (const [name, kind] of this.#catalog.dependencies()) {'
  ends_with "$fn" 'return out; } '
  # A declared dependency with no breaker is reported DOWN, never omitted.
  contains "$fn" 'if (breaker === undefined) { out[name] = { status: "down", kind, breaker: "open", since }; continue; }'
  # since is RFC 3339 at second precision, the siblings' spelling.
  local r; r="$(health_flat 'function rfc3339(')"
  contains "$r" 'return at.toISOString().replace(/\.\d{3}Z$/, "Z");'
}

@test "js dependencyHealth stamps since on ALL THREE transitions" {
  # Without the listeners `since` freezes at construction forever, while every
  # status assertion stays green. half-open is the one easiest to forget, and it
  # is the transition opossum makes on its own timer with no traffic.
  local fn; fn="$(health_flat 'constructor(catalog: DependencyCatalog')"
  contains "$fn" 'this.#since.set(name, startedAt);'
  contains "$fn" 'const stamp = (): void => { this.#since.set(name, this.#now()); }; breaker.on("open", stamp); breaker.on("halfOpen", stamp); breaker.on("close", stamp);'
}

@test "js dependencyHealth is PASSIVE: no probing machinery of any kind" {
  local code; code="$(code_of "$JS/dependencyHealth.ts")"
  # Positive control: the strip did not eat the file.
  contains "$code" 'components(): Record<string, Dependency> {'
  lacks "$code" 'fetch('
  lacks "$code" 'setInterval'
  lacks "$code" 'setTimeout'
  lacks "$code" 'node:http'
  lacks "$code" '.fire('
}

@test "js catalog loads the env override first, else the file BESIDE the module" {
  local fn; fn="$(catalog_flat 'static load(): DependencyCatalog {')"
  # The override, and the line that APPLIES it — without which load validates the
  # file and then throws it away.
  contains "$fn" 'const override = process.env[DECLARATION_FILE_ENV]; if (override !== undefined && override !== "") {'
  contains "$fn" 'return new DependencyCatalog(parseDeclaration(override, content), override);'
  # An unreadable override fails LOUDLY rather than silently falling back.
  contains "$fn" 'is set to "${override}" but it cannot be read'
  # Beside the COMPILED module, resolved from import.meta.url — never the working
  # directory, which differs between a laptop and the image.
  contains "$fn" 'const beside = fileURLToPath(new URL(DECLARATION_FILE, import.meta.url));'
  lacks "$fn" 'process.cwd'
  # The missing-file error names the fix: tsc does not copy the file.
  contains "$fn" 'tsc does not copy it'
  ends_with "$fn" 'return new DependencyCatalog(parseDeclaration(beside, content), beside); } '
}

@test "js declaration constants match the shipped file and the family env name" {
  grep -qxF 'export const DECLARATION_FILE = "resilience-dependencies.properties";' "$JS/dependencyCatalog.ts"
  grep -qxF 'export const DECLARATION_FILE_ENV = "OPS_DEPENDENCIES_FILE";' "$JS/dependencyCatalog.ts"
  [ -f "$JS/resilience-dependencies.properties" ]
}

@test "js parseDeclaration refuses a duplicate before it validates the kind" {
  local fn; fn="$(catalog_flat 'export function parseDeclaration(')"
  contains "$fn" 'const previous = out.get(name); if (previous !== undefined) { throw new Error('
  contains "$fn" 'is declared twice'
  # BEFORE the kind check. Positive control first: `##` with no match leaves the
  # operand untouched, so the ordering comparison would pass on an absent anchor.
  contains "$fn" 'if (kind !== "hard" && kind !== "soft") { throw new Error('
  local before after
  before="${fn%%is declared twice*}"
  after="${before##*if (kind !== \"hard\" && kind !== \"soft\")}"
  [ "$before" = "$after" ]
  # The malformed-line guard: a stray `=hard` must not register a nameless
  # dependency that can never be guarded.
  contains "$fn" 'if (eq === -1 || name === "") { throw new Error('
  # Full-line comments and blanks are skipped; nothing else is.
  contains "$fn" 'if (text === "" || text.startsWith("#")) { return; }'
  contains "$fn" 'FULL-LINE'
  # The BOM strip: without it the first name parses as "﻿orders-db".
  contains "$fn" 'content.replace(/^﻿/, "")'
  contains "$fn" 'out.set(name, kind);'
}

@test "js catalog creates one breaker per dependency, EAGERLY, and resets its window on transitions" {
  local fn; fn="$(catalog_flat 'private constructor(')"
  contains "$fn" 'for (const name of dependencies.keys()) { const window: boolean[] = []; const breaker = newBreaker(name);'
  contains "$fn" 'this.#breakers.set(name, breaker); this.#windows.set(name, window);'
  # A fresh window per state change: failures from before an outage must not
  # re-trip a breaker the half-open probe just proved healthy.
  contains "$fn" 'breaker.on("close", () => { window.length = 0; });'
  contains "$fn" 'breaker.on("open", () => { window.length = 0; });'
}

@test "js breaker disables opossum's own trip and keeps its state machine" {
  local fn; fn="$(catalog_flat 'function newBreaker(')"
  # opossum counts a filtered error as a SUCCESS and divides by every fire,
  # rejections included — measured: 100 filtered 404s + 20 real failures = 20/120,
  # closed. MAX_SAFE_INTEGER returns its closed-state check early, so the only
  # closed -> open transition is the catalog's #record.
  contains "$fn" 'volumeThreshold: Number.MAX_SAFE_INTEGER,'
  lacks "$fn" 'errorThresholdPercentage'
  # MANDATE 1 as opossum's own timeout (a backstop that holds even when the action
  # ignores its signal) and MANDATE 5 as its reset timer.
  contains "$fn" 'timeout: ATTEMPT_TIMEOUT_MS,'
  contains "$fn" 'resetTimeout: RESET_TIMEOUT_MS,'
  # Half-open: a caller error closes (the dependency answered); a cancellation
  # re-opens (it proved nothing). As ONE needle — `||` flipped to `&&` would close
  # a breaker on a probe that never got an answer.
  contains "$fn" 'errorFilter: (err: unknown) => err instanceof NotADependencyFailure && (err.reason === "caller-error" || !breaker.halfOpen),'
  # Name is what /health keys and opossum's events report by.
  contains "$fn" 'name,'
  # One generic invoker per breaker, so one breaker serves every call shape.
  contains "$fn" 'new CircuitBreaker((invoke: () => Promise<unknown>) => invoke(), {'
}

@test "js catalog trips on a RATE over COUNTED outcomes, closed breakers only" {
  local fn; fn="$(catalog_flat '#record(name: string, failed: boolean): void {')"
  # Only a CLOSED breaker records: a half-open probe is opossum's to act on.
  contains "$fn" 'if (breaker === undefined || window === undefined || !breaker.closed) { return; }'
  # Count-based, bounded window.
  contains "$fn" 'window.push(failed); if (window.length > SLIDING_WINDOW_SIZE) { window.shift(); }'
  # The minimum volume: one failure after a reset is not a 100% rate.
  contains "$fn" 'if (window.length < MINIMUM_NUMBER_OF_CALLS) { return; }'
  contains "$fn" 'if (failures / window.length >= FAILURE_RATE_THRESHOLD) { breaker.open(); }'
  # The numbers, at parity with the Java sibling's resilience4j settings.
  grep -qxF 'export const SLIDING_WINDOW_SIZE = 20;' "$JS/dependencyCatalog.ts"
  grep -qxF 'export const MINIMUM_NUMBER_OF_CALLS = 10;' "$JS/dependencyCatalog.ts"
  grep -qxF 'export const FAILURE_RATE_THRESHOLD = 0.5;' "$JS/dependencyCatalog.ts"
  grep -qxF 'export const RESET_TIMEOUT_MS = 10_000;' "$JS/dependencyCatalog.ts"
  grep -qxF 'export const ATTEMPT_TIMEOUT_MS = 2_000;' "$JS/dependencyCatalog.ts"
}

@test "js catalog excludes caller errors and breaker rejections from the counted set" {
  # Excluded errors and an open breaker's own rejections are NEITHER success nor
  # failure. A timeout IS a failure — the brownout signal.
  local fn; fn="$(catalog_flat 'function isCountedFailure(')"
  contains "$fn" 'return !(err instanceof NotADependencyFailure) && !isBreakerRejection(err);'
  grep -qxF 'const REJECTION_CODES = new Set(["EOPENBREAKER", "ESEMLOCKED", "ESHUTDOWN"]);' "$JS/dependencyCatalog.ts"
  run ! grep -F 'ETIMEDOUT"' "$JS/dependencyCatalog.ts"
}

@test "js catalog refuses under-reporting from BOTH sides" {
  local declared; declared="$(catalog_flat 'requireDeclared(name: string): string {')"
  contains "$declared" 'if (!this.#dependencies.has(name)) { throw new Error('
  contains "$declared" 'is guarded in code but not declared in'
  # The WRITER half — drop it and every service following the README dies at boot.
  ends_with "$declared" 'this.#guarded.add(name); return name; } '
  local guarded; guarded="$(catalog_flat 'requireAllDeclaredGuarded(): void {')"
  # Deterministic, sorted output.
  contains "$guarded" 'const unguarded = [...this.#dependencies.keys()].filter((name) => !this.#guarded.has(name)).sort();'
  contains "$guarded" 'if (unguarded.length === 0) { return; } throw new Error('
  contains "$guarded" 'but no client claimed them'
  # The message names the CONSTRUCTOR claim, not something that happens later.
  contains "$guarded" "requireDeclared from the client's constructor"
}

@test "js catalog.of refuses an off-contract kind" {
  # Types are erased at runtime, so a JS caller can hand in "Hard".
  local fn; fn="$(catalog_flat 'static of(')"
  contains "$fn" 'if (kind !== "hard" && kind !== "soft") { throw new Error('
}

@test "js call wires the six mandates and bounds the retry" {
  local fn; fn="$(catalog_flat 'async call<T>(')"
  # A missing fallback is refused on the FIRST call, not the first outage.
  contains "$fn" 'if (typeof action !== "function" || typeof fallback !== "function") { throw new TypeError('
  contains "$fn" 'if (!Number.isInteger(MAX_ATTEMPTS) || MAX_ATTEMPTS < 1) { throw new RangeError('
  contains "$fn" 'this.requireDeclared(name);'
  # An already-aborted caller reaches the FALLBACK without touching the breaker —
  # pinned together with the loop that follows it, so it cannot move inside.
  contains "$fn" 'if (caller?.aborted === true) { return fallback(new NotADependencyFailure(caller.reason, "cancelled")); } let lastError: unknown; for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {'
  # Through the breaker — mandate 2 — and a success is recorded.
  contains "$fn" 'const value = (await breaker.fire(() => attemptOnce(action, caller))) as T; this.#record(name, false); return value;'
  # Only a COUNTED failure is recorded.
  contains "$fn" 'if (isCountedFailure(err)) { this.#record(name, true); }'
  # The stop rule as ONE needle: `&&` would retry an open breaker to exhaustion.
  contains "$fn" 'if (!retryable(err, caller) || attempt === MAX_ATTEMPTS) { break; }'
  # MANDATE 3 is only "with jittered backoff" because of this line; the sleep is
  # abortable by the caller's signal, so a drain is not held up.
  contains "$fn" 'await sleep(backoffDelayMs(attempt), undefined, caller === undefined ? {} : { signal: caller });'
  # The dependency's error survives an abort during the backoff.
  contains "$fn" 'lastError = new AggregateError([err, sleepErr],'
  # MANDATE 4.
  ends_with "$fn" 'return fallback(lastError); } '
}

@test "js attemptOnce imposes the timeout and reclassifies a caller's cancellation" {
  local fn; fn="$(catalog_flat 'async function attemptOnce<T>(')"
  # MANDATE 1 reaches the socket through the signal the action receives.
  contains "$fn" 'const timeout = AbortSignal.timeout(ATTEMPT_TIMEOUT_MS); const signal = caller === undefined ? timeout : AbortSignal.any([caller, timeout]);'
  contains "$fn" 'return await action(signal);'
  # Keyed on the CALLER's signal, never the combined one: the attempt's own
  # timeout is the brownout signal and must stay counted.
  contains "$fn" 'if (caller?.aborted === true && !(err instanceof NotADependencyFailure)) { throw new NotADependencyFailure(err, "cancelled"); } throw err;'
}

@test "js retry predicate refuses every non-retryable class" {
  local fn; fn="$(catalog_flat 'function retryable(')"
  contains "$fn" 'if (caller?.aborted === true) { return false; }'
  # MANDATE 6: an open or saturated breaker is already known down.
  contains "$fn" 'if (isBreakerRejection(err)) { return false; }'
  ends_with "$fn" 'return !(err instanceof NotADependencyFailure); } '
}

@test "js backoff is exponential, capped, FULL-jittered, and clamped at both ends" {
  local fn; fn="$(catalog_flat 'export function backoffDelayMs(')"
  contains "$fn" 'const shift = Math.min(Math.max(attempt - 1, 0), 20);'
  contains "$fn" 'const delay = Math.min(RETRY_BASE_DELAY_MS * 2 ** shift, RETRY_MAX_DELAY_MS);'
  # A uniform draw over the WHOLE delay.
  contains "$fn" 'return Math.floor(random() * (delay + 1));'
  grep -qxF 'export const MAX_ATTEMPTS = 3;' "$JS/dependencyCatalog.ts"
  grep -qxF 'export const RETRY_BASE_DELAY_MS = 100;' "$JS/dependencyCatalog.ts"
  grep -qxF 'export const RETRY_MAX_DELAY_MS = 2_000;' "$JS/dependencyCatalog.ts"
}

@test "js NotADependencyFailure carries its reason and cause" {
  local fn; fn="$(catalog_flat 'export class NotADependencyFailure extends Error {')"
  contains "$fn" 'readonly reason: "caller-error" | "cancelled";'
  contains "$fn" 'super(`not a dependency failure (${reason}): ${describe(cause)}`, { cause });'
  contains "$fn" 'this.reason = reason;'
  local w; w="$(catalog_flat 'export function notADependency(')"
  contains "$w" 'return new NotADependencyFailure(cause, "caller-error");'
}

@test "js worked-example client claims at construction and validates its URL" {
  local ctor; ctor="$(client_flat 'constructor(catalog: DependencyCatalog')"
  contains "$ctor" 'catalog.requireDeclared(DEPENDENCY_NAME);'
  contains "$ctor" 'baseUrl: string | undefined = process.env.PRICING_API_BASE_URL'
  # Validated, not merely present: a scheme-less service name would otherwise reach
  # the COUNTED arm and open a breaker on a dependency never contacted.
  contains "$ctor" 'if (parsed === undefined || (parsed.protocol !== "http:" && parsed.protocol !== "https:") || parsed.host === "") { throw new Error('
  grep -qxF 'export const DEPENDENCY_NAME = "pricing-api";' "$JS/pricingApiClient.ts"
}

@test "js worked-example client passes the signal and classifies the whole 4xx range" {
  local fetch; fetch="$(client_flat 'async #fetch(')"
  # MANDATE 1 reaches the socket only through this signal.
  contains "$fetch" 'const response = await fetch(url, { signal, headers: { accept: "application/json" } });'
  contains "$fetch" 'encodeURIComponent(sku)'
  # The non-2xx arms in ORDER, as one needle: the body discarded first, then the
  # 404, then the rest of the 4xx range excluded, then everything else counted.
  contains "$fetch" 'if (response.status < 200 || response.status >= 300) { await discard(response); if (response.status === 404) { throw notADependency(new Error(`pricing-api: no such sku "${sku}"`)); } if (response.status >= 400 && response.status < 500) { throw notADependency(new Error(`pricing-api: status ${response.status}`)); } throw new Error(`pricing-api: status ${response.status}`); }'
  # A body the dependency cannot serialize, or of the wrong shape, counts.
  contains "$fetch" 'throw new Error("pricing-api: decoding response", { cause: err });'
  contains "$fetch" 'if (!isPrice(body)) { throw new Error("pricing-api: response is not a price"); }'
}

@test "js worked-example fallback RESOLVES, never calls the dependency, never invents a price" {
  local fn; fn="$(client_flat 'async price(')"
  contains "$fn" 'return this.#catalog.call<PriceResult>( DEPENDENCY_NAME,'
  contains "$fn" 'async (signal) => ({ available: true, price: await this.#fetch(sku, signal) }),'
  # The fallback's WHOLE body: an honest absence, resolved — a rejection nobody
  # awaits terminates a Node process by default.
  contains "$fn" '(cause) => ({ available: false, cause }),'
  grep -qxF 'export type PriceResult = { available: true; price: Price } | { available: false; cause: unknown };' \
    "$JS/pricingApiClient.ts"
}

@test "js package.json.deps pins opossum and its types, and nothing else" {
  run jq -e . "$JS/package.json.deps"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dependencies.opossum' "$JS/package.json.deps")" = '^10.0.0' ]
  [ "$(jq -r '.devDependencies["@types/opossum"]' "$JS/package.json.deps")" = '^8.1.9' ]
  # ONE library, deliberately — and its types as a DEV dependency only.
  [ "$(jq -r '.dependencies | keys | join(",")' "$JS/package.json.deps")" = 'opossum' ]
  [ "$(jq -r '.devDependencies | keys | join(",")' "$JS/package.json.deps")" = '@types/opossum' ]
  [ "$(jq -r '.type' "$JS/package.json.deps")" = 'module' ]
}

@test "js declaration file ships replaceable examples and states the hard/soft consequence" {
  grep -qxE 'orders-db=hard' "$JS/resilience-dependencies.properties"
  grep -qxE 'pricing-api=soft' "$JS/resilience-dependencies.properties"
  local decl; decl="$(cat "$JS/resilience-dependencies.properties")"
  contains "$decl" 'REPLACE THE TWO EXAMPLES BELOW'
  # Its own account of where it is read from must match the loader.
  contains "$decl" 'BESIDE THE COMPILED dependencyCatalog.js'
  contains "$decl" 'tsc does not copy it'
  contains "$decl" 'FULL-LINE `#` COMMENTS ONLY'
  contains "$decl" 'A cache marked hard'
  contains "$decl" 'a database marked soft'
}

@test "js resilience README records the opossum fit-check, measured, and dismisses cockatiel" {
  local readme; readme="$(cat "$JS/README.md")"
  # The measured evidence, not just the claim.
  contains "$readme" '4 × 1s calls took **1.00s**'
  contains "$readme" 'read `20/120`'
  contains "$readme" '`fires=30 successes=30 failures=0`'
  contains "$readme" 'with **no calls at all**'
  contains "$readme" '`EOPENBREAKER` in **0.0000s**'
  # The runner-up, dismissed in writing and on measurement.
  contains "$readme" '### Why not `cockatiel`'
  contains "$readme" 'still read `state === Open`'
  # The typing and floor decisions.
  contains "$readme" 'byte-identical from'
  contains "$readme" '`^22 || ^24 || ^26`'
  contains "$readme" 'A *named* import would compile and'
  contains "$readme" 'Why opossum and no retry library'
  # The wiring the SKILL block explicitly defers to this README.
  contains "$readme" 'DependencyCatalog.load()'
  contains "$readme" 'catalog.requireDeclared(name)'
  contains "$readme" 'catalog.requireAllDeclaredGuarded()'
  contains "$readme" 'new DependencyHealth(catalog)'
  contains "$readme" 'OPS_DEPENDENCIES_FILE'
}

@test "bootstrap SKILL.md renders every js resilience file from the NODE resilience block" {
  # Doubly scoped, and the two fences asserted SEPARATELY: the worked example has
  # its OWN command, which is what makes "omit it" followable.
  local block main example
  block="$(sed -n '/^\*\*Node resilience + dependency health (#1145)\.\*\*/,/^\*\*Swift canonical implementation (#937)\.\*\*/p' "$SKILL")"
  contains "$block" '**Swift canonical implementation (#937).**'          # proves the range closed
  main="$(printf '%s\n' "$block" | sed -n '/render.zsh" \\/,/^```$/p' | sed -n '1,/^```$/p')"
  ends_with "$main" '```'
  contains "$main" 'languages/javascript/resilience/dependencyCatalog.ts'
  contains "$main" 'languages/javascript/resilience/dependencyHealth.ts'
  contains "$main" 'languages/javascript/resilience/package.json.deps'
  contains "$main" 'languages/javascript/resilience/resilience-dependencies.properties'
  contains "$main" 'languages/javascript/resilience/README.md'
  lacks "$main" 'pricingApiClient.ts'
  example="$(printf '%s\n' "$block" | sed -n '/render.zsh" \\/,/^```$/p' | sed -n '/^```$/,$p' | sed -n '2,$p')"
  contains "$example" 'languages/javascript/resilience/pricingApiClient.ts'
  ends_with "$example" '```'
}

@test "bootstrap SKILL.md gates the js resilience payload on the Node ops-api block alone" {
  local block
  block="$(sed -n '/^\*\*Node resilience + dependency health (#1145)\.\*\*/,/^\*\*Swift canonical implementation (#937)\.\*\*/p' "$SKILL")"
  contains "$block" '**Swift canonical implementation (#937).**'
  contains "$block" "the Node ops-api block's"
  contains "$block" 'skipped or deferred'
  contains "$block" 'installed** → **install**'
  contains "$block" 'src/resilience/'
  contains "$block" 'imports `ops`, never the reverse'
  contains "$block" 'CHANGE THIS'
  # The declaration must reach the compiled output.
  contains "$block" 'copies no non-TypeScript file'
  contains "$block" '**append a copy step to the package'
  # Record-do-not-perform, all three wirings.
  contains "$block" 'Record — do not perform'
  contains "$block" 'requireAllDeclaredGuarded()'
  contains "$block" 'new DependencyHealth(catalog)'
  contains "$block" 'requireDeclared(<name>)'
  # The README/package.json.deps clobber, and BOTH fragments merged.
  contains "$block" 'silently clobbers the first'
  contains "$block" 'they are different files'
}

@test "bootstrap SKILL.md's Node ops-api floor is the JOINT floor, and declining defers both" {
  local block
  block="$(sed -n '/^\*\*Node canonical implementation (#936)\.\*\*/,/^\*\*Node resilience + dependency health (#1145)\.\*\*/p' "$SKILL")"
  contains "$block" '**Node resilience + dependency health (#1145).**'  # proves the range closed
  contains "$block" "**The payloads' joint Node floor is \`^22 || ^24 || ^26\`**"
  # Not a range: the odd majors between the listed ones are outside it.
  contains "$block" '**23 and 25**'
  # engine-strict=false means npm would not stop it — unsupported, not uninstallable.
  contains "$block" '*unsupported* there, not uninstallable'
  # One raise line covers both; declining defers the ops block, and with it this one.
  contains "$block" 'surface **one** Node-pin raise as its own Step-2 plan line'
  contains "$block" 'which defers the resilience payload with it'
  # …and the pairing sentence is the landed wording, not a promise.
  contains "$block" 'Whenever this block installs, the **Node resilience payload below** (#1145)'
}

@test "#1145 is no longer described as pending anywhere it was" {
  local skill ops howto
  skill="$(cat "$SKILL")"
  lacks "$skill" 'installs with it once that lands'
  lacks "$skill" 'the remaining children of epic #967 are #1145'
  ops="$(cat "$OPS/README.md")"
  lacks "$ops" 'alongside this one once it lands'
  # The Node entry of the how-to — scoped to it, because the Swift entry below
  # legitimately still says "Until it lands" about #1146.
  howto="$(sed -n '/^- \*\*Node (TypeScript)\*\*/,/^- \*\*Swift\*\*/p' "$HOWTO")"
  contains "$howto" '- **Swift**'                                        # proves the range closed
  lacks "$howto" 'Until it lands'
  lacks "$howto" 'will bind `opossum`'
  contains "$howto" 'resilience-dependencies.properties'
  contains "$howto" '`/health/ready` with a 503'
}
