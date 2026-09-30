#!/usr/bin/env bats
#
# Structural tests for the canonical Swift resilience + dependency-health payload
# (#1146, epic #964) — the Swift sibling of tests/go-resilience-payload.bats.
#
# The Swift toolchain is NOT in the test image (see tests/Dockerfile), so these are
# grep-based: the payload's compilation (Swift 6 language mode, zero concurrency
# diagnostics), its unit behaviour and its live surface are verified out-of-band at
# authoring time — on macOS and inside the Linux container — and by the acceptance
# cases in tests/acceptance/{rest,cli}/swift-resilience.bats. What these pin is the
# contract shape a careless edit would break silently.
#
# THREE RULES, inherited from tests/go-resilience-payload.bats because each was
# learned from a defect that shipped green:
#
#   1. ANCHOR EVERY NEEDLE TO CODE, NEVER TO PROSE. This payload documents its own
#      contract at length, in the same words the contract is written in, so an
#      unscoped grep is satisfied by a doc comment even after the code it names is
#      deleted. `flatten` STRIPS comment lines, which makes the rule structural.
#   2. PIN A GUARD TOGETHER WITH ITS BODY, AS ONE NEEDLE. A condition and its
#      consequence asserted separately cannot tell `A && B` from `A || B`, nor an
#      arm from its transposed twin. `flatten` collapses whitespace so a whole
#      `if … { … }` fits one needle, immune to swift-format re-alignment.
#   3. NO NEEDLE MAY SPAN A SOURCE LINE. A multi-line single-quoted needle whose
#      opening line contains a paren establishes a PHANTOM quote carry in
#      tests/find-inert-bracket-assertions.zsh, silently exempting the span that
#      follows from the suite's own inert-assertion lint (#1068's residual gap).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SW="$REPO_ROOT/development/skills/bootstrap/templates/languages/swift/resilience"
  OPS="$REPO_ROOT/development/skills/bootstrap/templates/languages/swift/ops-api"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  HOWTO="$REPO_ROOT/docs/how-to/adopt-the-ops-surface.md"
}

# swift_decl <file> <signature-prefix> — one declaration, from the line whose first
# non-blank text STARTS with the signature to the closing brace at that line's own
# indentation. Closure is proven by a SENTINEL the terminating branch emits, not by
# inspecting the result: a runaway extraction that ran to EOF would also end in a
# brace, while silently handing back every following declaration as the haystack —
# which is exactly what makes a `lacks` assertion vacuous.
#
# The signature travels through the ENVIRONMENT, not `awk -v`, which escape-processes
# its value; and the match is anchored to the first non-blank column, so a doc
# comment or a call site mentioning the signature cannot arm the extraction.
swift_decl() {
  if [ "$#" -ne 2 ] || [ -z "$2" ]; then
    echo 'swift_decl: needs a file and a non-empty signature prefix' >&2; return 2
  fi
  local body
  # awk exits non-zero here only when it cannot read the file — a status of its own
  # (3), so a renamed template is never reported as a missing declaration.
  body="$(sig="$2" awk '
    BEGIN { sig = ENVIRON["sig"] }
    !inside {
      lead = match($0, /[^ \t]/)
      if (lead && index(substr($0, lead), sig) == 1) { inside = 1; indent = substr($0, 1, lead - 1) }
    }
    inside { print }
    inside && $0 == indent "}" { print "//swift_decl:closed"; exit }
  ' "$1")" || { echo "swift_decl: cannot read $1" >&2; return 3; }
  case "$body" in
    *"//swift_decl:closed") printf '%s' "${body%//swift_decl:closed}" ;;
    *) echo "swift_decl: '$2' not found in $1, or its block never closed" >&2; return 1 ;;
  esac
}

# flatten — drop whole-line comments, then collapse every whitespace run to one
# space. Rules 1 and 2 in one helper.
flatten() { printf '%s' "$1" | grep -v '^[[:space:]]*//' | tr -s ' \t\n' ' '; }

# prose_flat — stdin's PROSE as one line: comment markers dropped, whitespace runs
# collapsed. For negative checks on sentences, which wrap across lines wherever the
# prose happens to break — a raw `lacks` misses exactly the wrapped copy.
prose_flat() { sed -E 's#^[[:space:]]*/{2,}[[:space:]]?##' | tr -s ' \t\n' ' '; }

catalog_flat() { local b; b="$(swift_decl "$SW/DependencyCatalog.swift" "$1")" || return 1; flatten "$b"; }
health_flat() { local b; b="$(swift_decl "$SW/DependencyHealth.swift" "$1")" || return 1; flatten "$b"; }
client_flat() { local b; b="$(swift_decl "$SW/PricingAPIClient.swift" "$1")" || return 1; flatten "$b"; }

# code_of <file> — the file with its whole-line comments removed.
code_of() { grep -v '^[[:space:]]*//' "$1"; }

# resilience_identifiers — every top-level name the payload declares, DERIVED from
# its sources rather than listed: a closed list misses the type the next edit adds.
# These are what OpsApi.swift must never name. Matched as WHOLE identifiers
# (grep -w), which is what keeps the ops side's own `DependencyHealthSource` from
# tripping `DependencyHealth`.
# Takes the files to read; with none, every payload source.
resilience_identifiers() {
  local files=("$@")
  [ "$#" -gt 0 ] || files=("$SW"/*.swift)
  grep -hoE '^(public )?(final )?(struct|class|actor|enum|protocol|func|let) [A-Za-z_][A-Za-z0-9_]*' \
    "${files[@]}" | awk '{ print $NF }' | LC_ALL=C sort -u
}

# ops_names_no_resilience_type <OpsApi.swift> — the file-level half of the one-way
# rule. Returns 1 naming the first identifier it finds in CODE (comments may name
# the payload that fills the seam; code may not reference it).
ops_names_no_resilience_type() {
  local code id ids
  code="$(code_of "$1")" || return 2
  ids="$(resilience_identifiers)"
  [ -n "$ids" ] || { echo 'no resilience identifiers derived' >&2; return 2; }
  for id in $ids; do
    if grep -qw -- "$id" <<< "$code"; then
      echo "OpsApi.swift names resilience identifier '$id'" >&2
      return 1
    fi
  done
  return 0
}

# import_set <file>... — the imported MODULES, sorted and unique, one per line.
# Every spelling counts: indented (inside `#if canImport`), attributed
# (`@preconcurrency import X`) and qualified (`import struct X.Y` counts as X).
# Comment lines are dropped first, so prose naming an import is not one.
import_set() {
  cat "$@" | grep -v '^[[:space:]]*//' \
    | grep -E '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' \
    | sed -E 's/^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(typealias|struct|class|enum|protocol|let|var|func|actor)?[[:space:]]*([A-Za-z0-9_]+).*/\3/' \
    | LC_ALL=C sort -u
}

@test "swift resilience payload files exist at the SKILL render paths" {
  [ -f "$SW/DependencyCatalog.swift" ]
  [ -f "$SW/DependencyHealth.swift" ]
  [ -f "$SW/PricingAPIClient.swift" ]
  [ -f "$SW/resilience-dependencies.properties" ]
  [ -f "$SW/Package.swift.deps" ]
  [ -f "$SW/README.md" ]
}

@test "swift_decl proves closure rather than inferring it (self-test)" {
  # Pin the EXACT status: `-ne 0` cannot tell the intended not-found path from awk
  # failing to open the file, or from the misuse status.
  run swift_decl "$SW/DependencyCatalog.swift" 'func thisDeclarationDoesNotExist('
  [ "$status" -eq 1 ]
  run swift_decl "$SW/DependencyCatalog.swift" ''
  [ "$status" -eq 2 ]
  run swift_decl "$BATS_TEST_TMPDIR/no-such-template.swift" 'public func acquire()'
  [ "$status" -eq 3 ]
  run swift_decl "$SW/DependencyCatalog.swift" 'public func acquire()'
  [ "$status" -eq 0 ]
}

@test "OpsApi.swift names no resilience type in code, and imports no breaker library" {
  [ -f "$OPS/OpsApi.swift" ]
  ops_names_no_resilience_type "$OPS/OpsApi.swift"
  # Positive control: the seam this payload fills IS declared there, and the
  # whole-identifier match does not mistake it for `DependencyHealth`.
  contains "$(code_of "$OPS/OpsApi.swift")" 'public protocol DependencyHealthSource: Sendable {'
  # The import set, pinned EXACTLY (positive pairing, not a ban list): a breaker
  # library is whatever module a future edit adds, and a closed list of forbidden
  # names would miss the one nobody thought of.
  local imports expected
  imports="$(import_set "$OPS/OpsApi.swift")"
  expected="$(printf '%s\n' Foundation Metrics NIOCore NIOHTTP1 NIOPosix OTel Prometheus ServiceLifecycle)"
  [ "$imports" = "$expected" ]
  # Non-vacuity of the derived identifier list: it is the payload's real names.
  local ids; ids="$(resilience_identifiers)"
  contains "$ids" 'DependencyCatalog'
  contains "$ids" 'CircuitBreaker'
  contains "$ids" 'NotADependencyFailure'
  contains "$ids" 'parseDependencyDeclaration'
}

@test "the one-way needles are mutation-checked: each goes red on a planted identifier" {
  local copy="$BATS_TEST_TMPDIR/OpsApi.swift" id
  # Unplanted, the copy passes — so a red below is the plant, not the copy.
  cp "$OPS/OpsApi.swift" "$copy"
  ops_names_no_resilience_type "$copy"
  for id in $(resilience_identifiers); do
    cp "$OPS/OpsApi.swift" "$copy"
    printf '\nlet planted: Any = %s.self\n' "$id" >> "$copy"
    run ops_names_no_resilience_type "$copy"
    [ "$status" -eq 1 ]
    contains "$output" "'$id'"
  done
  # …a comment naming one does NOT trip it: the ops file's own docs point at the
  # payload that fills its seam, and that is prose, not a dependency.
  cp "$OPS/OpsApi.swift" "$copy"
  printf '\n// DependencyCatalog lives in the resilience payload.\n' >> "$copy"
  ops_names_no_resilience_type "$copy"
  # …and a planted breaker import changes the pinned import set, in every spelling:
  # plain, conditional-and-attributed, and qualified.
  local baseline plant; baseline="$(import_set "$OPS/OpsApi.swift")"
  for plant in 'import SwiftBreaker' $'#if canImport(SwiftBreaker)\n    @preconcurrency import SwiftBreaker\n#endif' 'import struct SwiftBreaker.Breaker'; do
    cp "$OPS/OpsApi.swift" "$copy"
    printf '%s\n' "$plant" >> "$copy"
    contains "$(import_set "$copy")" 'SwiftBreaker'
    [ "$(import_set "$copy")" != "$baseline" ]
  done
}

@test "the resilience files depend on Ops, in both layouts" {
  # Same target: `Ops` is not a module and the import compiles away. Separate
  # targets: it is, and the types resolve through it. Only the conditional form
  # compiles in both, which is what the two-target verification package proves.
  local f
  for f in DependencyCatalog.swift DependencyHealth.swift; do
    contains "$(flatten "$(cat "$SW/$f")")" '#if canImport(Ops) import Ops #endif'
  done
}

@test "DependencyHealth conforms, unchanged, to the landed DependencyHealthSource" {
  # The ops side of the seam, pinned by its signature: a rename there would ship
  # green through both payloads' structural suites and break every bootstrapped
  # repo's build — the two are placed together or not at all.
  contains "$(code_of "$OPS/OpsApi.swift")" 'func components() async -> [String: Dependency]'
  grep -qF 'public struct DependencyHealth: DependencyHealthSource {' "$SW/DependencyHealth.swift"
  grep -qF '    public func components() async -> [String: Dependency] {' "$SW/DependencyHealth.swift"
}

@test "DependencyHealth maps breaker state to the contract's vocabulary exactly" {
  # closed = up, half_open = degraded, open = down. The switch has NO default, so a
  # fourth breaker state is a compile error rather than a guess.
  local fn; fn="$(health_flat 'static func status(of state: BreakerState)')"
  contains "$fn" 'switch state { case .closed: return .up case .halfOpen: return .degraded case .open: return .down }'
  lacks "$fn" 'default'
}

@test "DependencyHealth builds each entry from ONE snapshot, into a FRESH dictionary" {
  local fn; fn="$(health_flat 'public func components()')"
  # Local and fresh per call — the seam is Sendable precisely so a live registry is
  # never handed out.
  contains "$fn" 'var out: [String: Dependency] = [:] for (name, kind) in catalog.dependencies {'
  ends_with "$fn" 'return out } '
  # State and since from the SAME actor hop, and each field from the right source:
  # a transposed status/breaker, a dropped kind (the readiness hinge) or a since
  # that is not the breaker's own transition stamp all ship green without this.
  contains "$fn" 'let snapshot = await breaker.snapshot() out[name] = Dependency( status: Self.status(of: snapshot.state), kind: kind, breaker: snapshot.state, since: Self.rfc3339(snapshot.since) )'
  # A declared dependency with no breaker is reported DOWN, never omitted.
  contains "$fn" 'guard let breaker = catalog.breaker(for: name) else { out[name] = Dependency( status: .down, kind: kind, breaker: .open, since: Self.rfc3339(Date())) continue }'
}

@test "DependencyHealth.seam leaves the slot UNSET for an empty declaration" {
  # An empty catalog behind a non-nil source serves "components":{} — a v1.1 body
  # announcing health and reporting none — where an unset slot is byte-identical v1.0.
  local fn; fn="$(health_flat 'public static func seam(for catalog: DependencyCatalog)')"
  contains "$fn" 'catalog.dependencies.isEmpty ? nil : DependencyHealth(catalog: catalog)'
  # …and the ops side really does omit the key for an unset slot.
  contains "$(code_of "$OPS/OpsApi.swift")" 'let components: [String: Dependency]?'
}

@test "DependencyHealth is PASSIVE: no probing machinery of any kind" {
  # Never calls a dependency, never probes on a schedule, never transitively calls a
  # downstream's /health — the health-check-storm anti-pattern.
  local code; code="$(code_of "$SW/DependencyHealth.swift")"
  contains "$code" 'public func components() async -> [String: Dependency] {'
  lacks "$code" 'URLSession'
  lacks "$code" 'Task.sleep'
  lacks "$code" 'Task {'
  lacks "$code" 'Timer'
  lacks "$code" '.call('
}

@test "the breaker admits, rejects and caps half-open probes without waiting" {
  local fn; fn="$(catalog_flat 'public func acquire()')"
  # Advanced for elapsed time FIRST, so a reset window that expired is honoured.
  contains "$fn" 'advance() switch phase {'
  contains "$fn" 'case .closed: return Permit(generation: generation)'
  # MANDATE 6: an open breaker rejects at once.
  contains "$fn" 'case .open: throw CallNotPermitted(dependency: name)'
  # Half-open admits at most halfOpenPermits probes, counting in-flight AND succeeded.
  contains "$fn" 'case .halfOpen(let inFlight, let successes): guard inFlight + successes < configuration.halfOpenPermits else { throw CallNotPermitted(dependency: name) } phase = .halfOpen(inFlight: inFlight + 1, successes: successes)'
  # Typed and synchronous: no suspension point inside the admission decision.
  grep -qF '    public func acquire() throws(CallNotPermitted) -> Permit {' "$SW/DependencyCatalog.swift"
}

@test "the breaker trips on a RATE over a count-based window with a minimum volume" {
  local fn; fn="$(catalog_flat 'public func record(_ outcome: CallOutcome, for permit: Permit)')"
  # A stale outcome — admitted in a phase that has since ended — is discarded.
  contains "$fn" 'guard permit.generation == generation else { return }'
  # Ignored outcomes never enter the window; counted ones slide it; the rate trips
  # only above the floor. One needle: the floor and the rate are ONE decision.
  contains "$fn" 'case .closed: guard outcome != .ignored else { return } window.append(outcome == .failure) if window.count > configuration.windowSize { window.removeFirst() } let failures = window.filter { $0 }.count if window.count >= configuration.minimumVolume, Double(failures) / Double(window.count) >= configuration.failureRateThreshold { trip() }'
  # Half-open: one failure re-opens, enough successes close, an ignored probe hands
  # its permit back.
  contains "$fn" 'case .failure: trip()'
  contains "$fn" 'case .success: if successes + 1 >= configuration.halfOpenPermits { transition(to: .closed) } else { phase = .halfOpen(inFlight: inFlight - 1, successes: successes + 1) }'
  contains "$fn" 'case .ignored: phase = .halfOpen(inFlight: inFlight - 1, successes: successes)'
}

@test "the breaker computes open -> half-open on READ and stamps since on each transition" {
  # MANDATE 5's visibility with no traffic and no scheduler.
  local adv; adv="$(catalog_flat 'private func advance()')"
  contains "$adv" 'if case .open(let until) = phase, clock.now >= until { transition(to: .halfOpen(inFlight: 0, successes: 0)) }'
  local snap; snap="$(catalog_flat 'public func snapshot() -> BreakerSnapshot')"
  contains "$snap" 'advance() switch phase {'
  contains "$snap" 'case .closed: return BreakerSnapshot(state: .closed, since: changedAt)'
  contains "$snap" 'case .open: return BreakerSnapshot(state: .open, since: changedAt)'
  contains "$snap" 'case .halfOpen: return BreakerSnapshot(state: .halfOpen, since: changedAt)'
  # Every transition bumps the generation, restamps since and clears the window.
  local tr; tr="$(catalog_flat 'private func transition(to next: Phase)')"
  contains "$tr" 'phase = next generation &+= 1 changedAt = Date() window.removeAll()'
  local trip; trip="$(catalog_flat 'private func trip()')"
  contains "$trip" 'transition(to: .open(until: clock.now.advanced(by: configuration.openDuration)))'
}

@test "the breaker's blessed configuration is pinned, at parity with the siblings" {
  local fn; fn="$(catalog_flat 'public struct BreakerConfiguration: Sendable {')"
  contains "$fn" 'failureRateThreshold: Double = 0.5, minimumVolume: Int = 10, windowSize: Int = 20, openDuration: Duration = .seconds(10), halfOpenPermits: Int = 3'
}

@test "the catalog creates one breaker per dependency, EAGERLY" {
  local fn; fn="$(catalog_flat 'public final class DependencyCatalog: Sendable {')"
  contains "$fn" 'for name in dependencies.keys { breakers[name] = CircuitBreaker(name: name, configuration: breakerConfiguration) }'
}

@test "catalog.call wires the six mandates and bounds the retry" {
  local fn; fn="$(catalog_flat 'public func call<T: Sendable>(')"
  # MANDATE 1's default IS the named constant the docs quote as 2s.
  contains "$fn" 'timeout: Duration = DependencyCatalog.defaultCallTimeout,'
  # A dependency must be declared before it can be called.
  contains "$fn" 'try await requireDeclared(name)'
  # A caller already gone reaches the fallback without touching the breaker.
  contains "$fn" 'if Task.isCancelled { return try await fallback(CancellationError()) }'
  # MANDATE 3: bounded.
  contains "$fn" 'for attempt in 1...max(Self.maxAttempts, 1) {'
  # MANDATE 6: an open breaker's rejection is never retried — acquire's catch BREAKS.
  contains "$fn" 'do { permit = try await breaker.acquire() } catch { lastError = error break }'
  # MANDATE 1 + 2: the call runs under the timeout, and its outcome is recorded.
  contains "$fn" 'let value = try await Self.withTimeout(timeout, dependency: name, operation) await breaker.record(.success, for: permit) return value'
  contains "$fn" 'await breaker.record(Self.outcome(of: error), for: permit) lastError = error'
  # The stop condition as ONE needle: `&&` here would retry an open breaker.
  contains "$fn" 'if !Self.retryable(lastError) || attempt == Self.maxAttempts { break }'
  # MANDATE 3's jittered backoff, cancellable: a cancelled sleep ends the loop.
  contains "$fn" 'do { try await Task.sleep(for: Self.backoff(attempt: attempt)) } catch { break }'
  # MANDATE 4.
  ends_with "$fn" 'return try await fallback(lastError) } '
}

@test "catalog.call classifies and retries by the mandates, with Task.isCancelled as the authority" {
  local oc; oc="$(catalog_flat 'static func outcome(of error: any Error)')"
  contains "$oc" 'if error is NotADependencyFailure { return .ignored } if Task.isCancelled { return .ignored } return .failure'
  # A timeout is NOT excluded: it is the brownout signal.
  lacks "$oc" 'DependencyTimeout'
  local rt; rt="$(catalog_flat 'static func retryable(_ error: any Error)')"
  contains "$rt" 'if Task.isCancelled { return false } if error is CallNotPermitted { return false } if error is NotADependencyFailure { return false } return true'
}

@test "the backoff is exponential, capped, FULL-jittered, and the timeout races and cancels" {
  local bo; bo="$(catalog_flat 'static func backoff(attempt: Int)')"
  # The shift is clamped at BOTH ends, so an adopter's zero-based loop or a large
  # budget cannot underflow or overflow the delay.
  contains "$bo" 'let shift = min(max(attempt - 1, 0), 20)'
  # The line that makes it EXPONENTIAL — without it every retry waits the base delay.
  contains "$bo" 'let grown = retryBaseDelay * (1 << shift)'
  contains "$bo" 'let delay = grown < retryMaxDelay ? grown : retryMaxDelay'
  contains "$bo" 'return delay * Double.random(in: 0...1)'
  local to; to="$(catalog_flat 'static func withTimeout<T: Sendable>(')"
  contains "$to" 'group.addTask { try await operation() } group.addTask { try await Task.sleep(for: timeout) throw DependencyTimeout(dependency: dependency, after: timeout) } defer { group.cancelAll() }'
}

@test "the retry budget and the timeout are named constants, not magic numbers" {
  grep -qE '^    public static let maxAttempts = 3$' "$SW/DependencyCatalog.swift"
  grep -qE '^    public static let retryBaseDelay: Duration = \.milliseconds\(100\)$' "$SW/DependencyCatalog.swift"
  grep -qE '^    public static let retryMaxDelay: Duration = \.seconds\(2\)$' "$SW/DependencyCatalog.swift"
  grep -qE '^    public static let defaultCallTimeout: Duration = \.seconds\(2\)$' "$SW/DependencyCatalog.swift"
}

@test "load prefers the env override, fails loudly on an unreadable one, and has no cwd tier" {
  # The env name is a cross-language contract shared with the Java, Python and Go
  # payloads; drifting it silently stops the ConfigMap override being read.
  grep -qE '^    public static let declarationFileEnv = "OPS_DEPENDENCIES_FILE"$' "$SW/DependencyCatalog.swift"
  grep -qE '^    public static let declarationFile = "resilience-dependencies\.properties"$' "$SW/DependencyCatalog.swift"
  local fn; fn="$(catalog_flat 'public static func load(')"
  contains "$fn" 'var source = bundledDependencyDeclaration'
  contains "$fn" 'if let path = environment[declarationFileEnv], !path.isEmpty { do { source = try String(contentsOfFile: path, encoding: .utf8) } catch { throw .unreadableOverride(path: path, reason: "\(error)") } origin = path }'
  lacks "$fn" 'currentDirectoryPath'
}

@test "the parser refuses a duplicate before it validates the kind, and rejects trailing comments" {
  local fn; fn="$(catalog_flat 'public func parseDependencyDeclaration(')"
  contains "$fn" 'if text.isEmpty || text.hasPrefix("#") { continue }'
  # A typo'd line and a nameless one are REFUSED, never skipped or declared as "".
  contains "$fn" 'guard let equals = text.firstIndex(of: "=") else { throw .malformedLine(origin: origin, line: line, text: text) }'
  contains "$fn" 'if name.isEmpty { throw .malformedLine(origin: origin, line: line, text: text) }'
  # The split on EVERY newline form: Swift reads "\r\n" as one Character that never
  # equals "\n", so a separator-"\n" split leaves a CRLF ConfigMap as a single line —
  # one that starts with `#` then declares nothing and disarms the readiness hinge.
  contains "$fn" 'let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)'
  lacks "$fn" 'split(separator: "\n"'
  contains "$fn" 'text = text.trimmingCharacters(in: .whitespacesAndNewlines)'
  contains "$fn" 'if index == 0 && text.hasPrefix("\u{FEFF}") { text.removeFirst() }'
  contains "$fn" 'if let previous = out[name] { throw .duplicate(origin: origin, line: line, name: name, previous: previous, now: value) }'
  contains "$fn" 'switch value.lowercased() { case "hard": out[name] = .hard case "soft": out[name] = .soft default: throw .unknownKind(origin: origin, line: line, name: name, kind: value) }'
  # Ordering: the duplicate check precedes the kind switch. Positive control first,
  # so a renamed anchor cannot turn the comparison vacuous.
  contains "$fn" 'switch value.lowercased()'
  local before after
  before="${fn%%switch value.lowercased()*}"
  after="${before##*"if let previous = out[name]"}"
  [ "$before" != "$after" ]
}

@test "the catalog refuses under-reporting from BOTH sides" {
  local declared; declared="$(catalog_flat 'public func requireDeclared(_ name: String)')"
  contains "$declared" 'guard dependencies[name] != nil else { throw .undeclared(name: name, origin: origin) } await claims.claim(name) return name'
  local guarded; guarded="$(catalog_flat 'public func requireAllDeclaredGuarded()')"
  contains "$guarded" 'let unguarded = dependencies.keys.filter { !claimed.contains($0) }.sorted() guard unguarded.isEmpty else { throw .unguarded(names: unguarded, origin: origin) }'
  # The message names the INITIALIZER claim, which runs before this check.
  contains "$(cat "$SW/DependencyCatalog.swift")" "call requireDeclared from the client's initializer"
}

@test "the compiled-in declaration IS the .properties file, verbatim" {
  # Swift has no //go:embed, so the declaration reaches the image as a literal. The
  # two copies must not drift: the literal is what the binary carries, the file is
  # what an operator mounts and reads.
  local literal
  literal="$(awk '
    /^public let bundledDependencyDeclaration = #"""$/ { inside = 1; next }
    inside && /^    """#$/ { closed = 1; exit }
    inside { sub(/^    /, ""); print }
    END { if (!closed) exit 1 }
  ' "$SW/DependencyCatalog.swift")"
  [ -n "$literal" ]
  [ "$literal" = "$(cat "$SW/resilience-dependencies.properties")" ]
}

@test "the declaration file ships replaceable examples and states the hard/soft consequence" {
  grep -qE '^orders-db=hard$' "$SW/resilience-dependencies.properties"
  grep -qE '^pricing-api=soft$' "$SW/resilience-dependencies.properties"
  local decl; decl="$(cat "$SW/resilience-dependencies.properties")"
  contains "$decl" 'REPLACE THE TWO EXAMPLES BELOW'
  contains "$decl" 'COMPILED INTO THE BINARY'
  contains "$decl" 'BOTH TOGETHER'
  contains "$decl" 'REBUILD, NOT A RESTART'
  contains "$decl" 'FULL-LINE `#` COMMENTS ONLY'
  contains "$decl" 'A cache marked hard'
  contains "$decl" 'a database marked soft'
}

@test "Package.swift.deps pins NO third-party dependency and states the 6.1 floor" {
  local deps; deps="$(cat "$SW/Package.swift.deps")"
  # Nothing to paste: a `.package(url:` line would contradict the README's decision.
  lacks "$deps" '.package(url:'
  lacks "$deps" '.product(name:'
  contains "$deps" 'NO THIRD-PARTY DEPENDENCY'
  contains "$deps" '// swift-tools-version:6.1'
  contains "$deps" 'swiftSettings: [.swiftLanguageMode(.v6)]'
  # The payload's own imports stay toolchain-only, so the claim holds in code.
  local imports
  imports="$(import_set "$SW"/*.swift)"
  [ "$imports" = "$(printf '%s\n' Foundation FoundationNetworking Ops)" ]
}

@test "the worked-example client claims at init, validates its URL and classifies the whole 4xx range" {
  local init; init="$(client_flat 'public init(')"
  contains "$init" 'try await catalog.requireDeclared(Self.dependencyName)'
  contains "$init" 'guard let url = URL(string: raw), url.scheme == "http" || url.scheme == "https", url.host != nil else { throw ConfigurationError('
  grep -qE '^    public static let dependencyName = "pricing-api"$' "$SW/PricingAPIClient.swift"
  local fetch; fetch="$(client_flat 'func fetch(sku: String)')"
  # In order: first match wins, so the catch-all must come after the caller arms.
  contains "$fetch" 'switch http.statusCode { case 404: throw NotADependencyFailure(ConfigurationError(message: "pricing-api: no such sku \"\(sku)\"")) case 400..<500: throw NotADependencyFailure(DependencyProtocolError(message: "pricing-api: status \(http.statusCode)")) case 500...: throw DependencyProtocolError(message: "pricing-api: status \(http.statusCode)") case 200..<300: break default: throw DependencyProtocolError(message: "pricing-api: unexpected status \(http.statusCode)") }'
  contains "$fetch" 'sku.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "?"]))'
}

@test "the worked-example fallback never calls the dependency, and never invents a price" {
  local fn; fn="$(client_flat 'public func price(sku: String)')"
  contains "$fn" 'try await catalog.call( Self.dependencyName, operation: { try await fetch(sku: sku) }, fallback: { cause in throw PriceUnavailable(sku: sku, cause: cause) })'
}

@test "the README records the fit-check over the six properties and a dismissal per candidate" {
  local readme; readme="$(cat "$SW/README.md")"
  contains "$readme" '| candidate | async/await-native | one instance per dependency | state readable without traffic | maintenance health | Swift 6 strict-concurrency clean | builds + tests on Linux |'
  contains "$readme" '| `Kitura/CircuitBreaker` 5.1.0 |'
  contains "$readme" '| `AlexanderNey/CircuitBreaker` 0.2.0 |'
  contains "$readme" '| `atacan/UsefulThings` 1.0.0 |'
  contains "$readme" '| `harryngict/ResilientNetworkKit` 0.0.1 |'
  contains "$readme" '| **payload-owned `CircuitBreaker` actor** |'
  contains "$readme" '### Rejected, and why'
  contains "$readme" '- **`Kitura/CircuitBreaker` — rejected'
  contains "$readme" '- **`AlexanderNey/CircuitBreaker` — rejected'
  contains "$readme" '- **`atacan/UsefulThings` — rejected'
  contains "$readme" '- **`harryngict/ResilientNetworkKit` — rejected'
  # The measured evidence, not just the claim.
  contains "$readme" '4 × 1s calls took **1.01s**'
  contains "$readme" 'pybreaker'
  # The wiring the SKILL block defers to this README.
  contains "$readme" 'DependencyCatalog.load()'
  contains "$readme" 'catalog.requireDeclared(name)'
  contains "$readme" 'catalog.requireAllDeclaredGuarded()'
  contains "$readme" 'dependencies: DependencyHealth.seam(for: catalog)'
  contains "$readme" 'OPS_DEPENDENCIES_FILE'
}

# The Swift resilience SKILL block, terminated by the heading that follows it, with
# closure proven HERE so no caller can forget the terminator.
swift_resilience_block() {
  local block
  block="$(sed -n '/^\*\*Swift resilience + dependency health (#1146)\.\*\*/,/^\*\*Java (non-Spring) resilience + dependency health (#1142)\.\*\*/p' "$SKILL")"
  case "$block" in
    *'**Java (non-Spring) resilience + dependency health (#1142).**'*) printf '%s' "$block" ;;
    *) echo 'swift_resilience_block: range not found or never closed' >&2; return 1 ;;
  esac
}

@test "bootstrap SKILL.md renders every swift resilience file from the SWIFT block" {
  # The two fences asserted SEPARATELY: PricingAPIClient.swift having its OWN command
  # is what makes "omit it" followable.
  local block main example
  block="$(swift_resilience_block)"
  main="$(printf '%s\n' "$block" | sed -n '/render.zsh" \\/,/^```$/p' | sed -n '1,/^```$/p')"
  ends_with "$main" '```'
  contains "$main" 'languages/swift/resilience/DependencyCatalog.swift'
  contains "$main" 'languages/swift/resilience/DependencyHealth.swift'
  contains "$main" 'languages/swift/resilience/Package.swift.deps'
  contains "$main" 'languages/swift/resilience/resilience-dependencies.properties'
  contains "$main" 'languages/swift/resilience/README.md'
  lacks "$main" 'PricingAPIClient.swift'
  example="$(printf '%s\n' "$block" | sed -n '/render.zsh" \\/,/^```$/p' | sed -n '/^```$/,$p' | sed -n '2,$p')"
  contains "$example" 'languages/swift/resilience/PricingAPIClient.swift'
  ends_with "$example" '```'
}

@test "bootstrap SKILL.md gates the swift resilience payload on the ops-api block alone" {
  local block; block="$(swift_resilience_block)"
  contains "$block" 'the Swift ops-api block'
  contains "$block" 'skipped, classified the repo a client, or deferred'
  contains "$block" 'installed** → **install**'
  contains "$block" 'Sources/<ServiceTarget>/Resilience/'
  contains "$block" 'Still no `targets:` edit'
  contains "$block" 'silently clobbers the first'
  contains "$block" 'edit BOTH copies identically'
  contains "$block" 'Record — do not perform'
  contains "$block" 'DependencyHealth.seam(for: catalog)'
  # Flattened, so a phrase the prose wraps across a line is still one needle.
  local flat; flat="$(tr -s ' \n' '  ' <<< "$block")"
  # Step-5 item (a) itself — the bare call name also appears in the substitution bullet.
  contains "$flat" '(a) startup must call `try await catalog.requireAllDeclaredGuarded()` once every client is built'
  # Gate case 1 and its consequence as one needle: an ops-block deferral defers the PAIR.
  contains "$flat" 'judgement is made *there*, never re-tested here. **A deferral there defers the pair:** whichever precondition deferred the ops block, its Step-5 TODO names this payload too, so resolving it later places both halves — never the ops half alone.'
  contains "$flat" '**not** the initializer'
  # Step-5 item (c): without it every declared dependency is refused and the pod never boots.
  contains "$flat" 'try await catalog.requireDeclared(<name>)'
  # Names may come from the stack; the hard/soft kind never does, and a missing kind
  # takes the same leave-the-examples path as a missing name.
  contains "$flat" '(the **names** may be derived from the detected stack — a database URL, a configured client)'
  contains "$flat" '**classifying each `hard` or `soft` — the kind comes from the user, never from a stack heuristic**'
  lacks "$flat" 'kinds may be derived'
  contains "$flat" '**If the names, or the kind of any one of them, cannot be determined during the run, leave BOTH examples in place and carry an explicit Step-5 checklist item**'
  contains "$flat" 'A name without a user-confirmed kind is never written: the declaration has no kind-unknown value, and a provisional `soft` disarms the readiness hinge.'
  contains "$flat" 'Never guess names or kinds, and never leave them verbatim and unrecorded.'
  # The adapt-or-omit decision the second render fence is keyed on.
  contains "$flat" 'Decide adapt-or-omit in the Step-2 plan'
  # Omit is keyed on the substitution OUTCOME, so an undetermined kind reaches it too.
  contains "$flat" 'When the substitution bullet above left the examples in place — names or a kind undetermined — there is nothing to adapt it to: take the omit path.'
  contains "$flat" 'unless the Step-2 plan says to omit it'
}

# placeability_names <core|example> — the backticked names the SKILL's placeability
# precondition lists, split at its "worked example's adapt path" anchor.
placeability_names() {
  local ops_block list names
  [ "$#" -eq 1 ] || { echo 'placeability_names: needs core|example' >&2; return 2; }
  ops_block="$(sed -n '/^\*\*Swift canonical implementation (#937)\.\*\*/,/^\*\*Swift resilience + dependency health (#1146)\.\*\*/p' "$SKILL")"
  list="$(prose_flat <<< "$ops_block" | sed -n 's/.*declare none of the payload.s top-level names: \(.*\) A clash is an invalid-redeclaration.*/\1/p')"
  [ -n "$list" ] || { echo 'placeability name list not found' >&2; return 2; }
  case "$1" in
    core) list="${list%%worked example*}" ;;
    example) list="${list#*worked example}" ;;
    *) echo "placeability_names: unknown arm '$1'" >&2; return 2 ;;
  esac
  names="$(grep -oE '`[A-Za-z_][A-Za-z0-9_]*`' <<< "$list" | tr -d '`' | LC_ALL=C sort -u)"
  [ -n "$names" ] || { echo "placeability_names: anchor found but no backticked $1 names" >&2; return 2; }
  printf '%s\n' "$names"
}

@test "the SKILL placeability name list IS the payload's derived top-level names" {
  # Positive pairing, both directions: a name dropped from the list misses a clash; a
  # type added to the payload without a SKILL update does too.
  local listed derived example_listed example_derived
  listed="$( { placeability_names core; placeability_names example; } | LC_ALL=C sort -u)"
  derived="$(resilience_identifiers)"
  [ -n "$derived" ]
  [ "$listed" = "$derived" ] || { diff <(echo "$listed") <(echo "$derived") >&2; false; }
  # …and the example's names are exactly the worked client's.
  example_listed="$(placeability_names example)"
  example_derived="$(resilience_identifiers "$SW/PricingAPIClient.swift")"
  [ -n "$example_derived" ]
  [ "$example_listed" = "$example_derived" ]
}

@test "no Swift #1146 forward reference survives in SKILL, the how-to or swift/ops-api" {
  # The Swift ops SKILL block's "once that lands / Until then" promise.
  local ops_block
  ops_block="$(sed -n '/^\*\*Swift canonical implementation (#937)\.\*\*/,/^\*\*Swift resilience + dependency health (#1146)\.\*\*/p' "$SKILL")"
  contains "$ops_block" '**Swift resilience + dependency health (#1146).**'
  lacks "$(prose_flat <<< "$ops_block")" 'once that lands'
  lacks "$(prose_flat <<< "$ops_block")" 'Until then'
  # …and the pairing sentence it was replaced with is really there.
  contains "$(prose_flat <<< "$ops_block")" 'the **Swift resilience payload below** (#1146) installs with it'
  # The placeability precondition's resolution rule: bootstrap never renames payload
  # types or edits adopter code, so every blocker has exactly one way through.
  contains "$(prose_flat <<< "$ops_block")" "Bootstrap never renames the payload's own types and never edits the adopter's sources: a clash on one of the example's names is resolved by renaming the example on the adapt path, a clash on any other name only by the adopter renaming their own type, and an occupied \`Resilience/\` only by the adopter freeing it."
  # …and what every unresolved blocker resolves to: the pair defers together.
  # A promise to rename is not a resolution: the check re-runs at placement time.
  contains "$(prose_flat <<< "$ops_block")" "**A promise to rename or free is not a resolution: re-run this check at placement time** against the names the pair will actually declare — on the adapt path, the example's *renamed* types, not the shipped ones — and place the pair only if none of them is in the tree by then."
  # A clash on the example's renamed type is the example's to resolve, never the pair's.
  contains "$(prose_flat <<< "$ops_block")" 'A clash confined to the example'"'"'s *renamed* type never costs the pair: give the example a type name that is free (only its `dependencyName` must match the declaration) or take the omit path, and say which in the placement report. If a clash on any other name is still there, or the user declines, **defer the ENTIRE pair** behind a Step-5 TODO naming what blocked it — never place the ops half alone.'
  # What the check covers, and that its outcome reaches the user before placement.
  contains "$(prose_flat <<< "$ops_block")" "check that \`Resilience/\` is free, and that the target's sources (under its declared \`path:\`) declare none"
  contains "$(prose_flat <<< "$ops_block")" '**Surface either as its own Step-2 plan line.**'
  contains "$(prose_flat <<< "$ops_block")" 'a redeclaration does not sit inert until it is wired: it breaks the build the moment it is placed.'
  # The closing line that named #1146 as a remaining child.
  lacks "$(cat "$SKILL")" '#1146 swift'
  # The how-to's Swift bullet, bounded by the next top-level section.
  local swift_bullet
  swift_bullet="$(sed -n '/^- \*\*Swift\*\* — bootstrap copies/,/^## /p' "$HOWTO")"
  contains "$swift_bullet" '## '
  lacks "$(prose_flat <<< "$swift_bullet")" 'not built yet'
  lacks "$(prose_flat <<< "$swift_bullet")" 'in the meantime'
  contains "$swift_bullet" 'DependencyHealth.seam(for: catalog)'
  # swift/ops-api/, text only.
  # Flattened: the original phrase wrapped across a line in both files.
  lacks "$(cat "$OPS/OpsApi.swift" "$OPS/README.md" | prose_flat)" 'not built yet'
  lacks "$(cat "$OPS/OpsApi.swift" "$OPS/README.md" | prose_flat)" 'in the meantime'
}
