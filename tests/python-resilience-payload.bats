#!/usr/bin/env bats
#
# Tests for the canonical Python resilience + dependency-health payload
# (#1143, epic #964 / sub-epic #967).
#
# TWO KINDS OF TEST HERE, and the split is deliberate.
#
#   BEHAVIOURAL. Unlike the Java and Spring payloads (whose tests can only grep,
#   because this toolchain has no JVM), Python runs here -- so the payload is
#   EXECUTED: breaker state in, /health JSON out, over a real HTTP server.
#   Everything that decides what an operator sees during an outage -- the
#   state->status table, the aggregate floor, the readiness hinge, the `since`
#   stamp, the status CODES -- is asserted against real output rather than
#   against the source that produces it.
#
#   The harness stubs exactly three things, each for a stated reason, and stubs
#   NOTHING that is under test:
#     (a) the OTel/prometheus imports, which serve /metrics and have no bearing
#         on health -- without them ops_api is unimportable on a toolchain that
#         has no OTel;
#     (b) `circuitbreaker` and `tenacity`, so dependency_catalog can be IMPORTED.
#         What is then exercised against those stubs is only the payload's own
#         pure logic -- the declaration parser, the two guards, the loader's three
#         branches -- none of which touches breaker or retry semantics. The
#         composition that DOES (decoration order, the open-breaker rejection) is
#         asserted structurally instead, because a stub would honour whatever we
#         made it honour, and the whole reason `_reject_if_open` exists is a real
#         circuitbreaker behaviour;
#     (c) a fake breaker/catalog for dependency_health, exposing the two members
#         it reads. That one is not a fiction but the module's design -- it
#         imports no breaker library precisely so the ops surface can be exercised
#         without one -- and the seam is pinned against the REAL catalog below, so
#         a rename cannot leave the fake describing a shape nothing implements.
#
#   STRUCTURAL. Everything a stub would beg the question on, plus the bootstrap
#   contract in SKILL.md.
#
# FOUR RULES THIS FILE HOLDS ITSELF TO, inherited from the Java payload's tests
# because a vacuous assertion is worse than no assertion (it advertises a guard
# that is not there):
#
#   1. ANCHOR EVERY NEEDLE TO CODE, NOT PROSE. The payload documents its own
#      invariants in comments and docstrings, so a bare `grep -q '<invariant>'` is
#      satisfied by the comment that explains the line even after the line itself
#      is deleted. The same rule applies to NEGATIVES from the other side: a
#      "must not contain X" is defeated by the comment saying why X is absent.
#   2. NEGATIVES PIN STATUS 1, NOT "NOT ZERO". `run ! grep` also passes on grep's
#      error exit 2 (unreadable or missing path), so a renamed payload directory
#      would turn a negative assertion into an unconditional pass. Every negative
#      below is `run grep ...` followed by `[ "$status" -eq 1 ]`, and every
#      whole-tree negative carries a positive control proving the scan saw files.
#   3. SCOPE A NEEDLE TO ITS BLOCK, AND PROVE THE BLOCK CLOSED. The payload is
#      full of sync/async twins and the SKILL of Java/Python twins, so an
#      unscoped needle is routinely satisfied by the wrong twin. A raw
#      `sed -n '/a/,/b/p'` whose END address stops matching runs silently to EOF
#      and un-scopes itself, which `[ -n "$block" ]` cannot detect -- hence
#      `block_between`.
#   4. PORTABLE REGEXES ONLY. `\|` is a GNU extension; where it is not honoured
#      the pattern is literal text that can never match, so a negative built on it
#      passes unconditionally -- and vacuously green on BOTH matrix legs, which is
#      the one failure the two-lane bats matrix cannot catch. Use `grep -E`.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PY="$REPO_ROOT/development/skills/bootstrap/templates/languages/python"
  RES="$PY/resilience"
  OPS="$PY/ops-api/ops_api.py"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  CATALOG="$RES/dependency_catalog.py"
  HEALTH="$RES/dependency_health.py"
  CLIENT="$RES/pricing_api_client.py"
  DECL="$RES/resilience-dependencies.properties"
}

# Extract <start-re>..<end-line> from a file and PROVE the range closed (ported
# from the Java sibling; see rule 3).
#
# <start-re> is a sed BRE. <end-line> is a LITERAL line, escaped here before it
# reaches sed: the Python payload's block boundaries are function signatures full
# of `(`, `[`, `.` and `*`, and hand-escaping them at each call site is how a
# range quietly stops matching and un-scopes every needle built on it. Escaping
# once, here, also keeps the literal available for the closure check below.
block_between() {
  # nl MUST be ANSI-C quoted, not $(printf '\n'): command substitution strips
  # trailing newlines, so the latter expands to the empty string and the anchor
  # silently degrades to a floating suffix match.
  local start_re="$1" end_line="$2" file="$3" block start_addr end_re nl=$'\n'
  # `/` must be escaped in BOTH addresses or it terminates them early -- and in the
  # start REGEX it is the one character that is never a metacharacter, so escaping
  # it there is safe and leaves the caller's pattern otherwise intact.
  start_addr="$(printf '%s' "$start_re" | sed 's/\//\\\//g')"
  # BRE metacharacters, plus that same `/`.
  end_re="$(printf '%s' "$end_line" | sed 's/[][\.*^$\/]/\\&/g')"
  block="$(sed -n "/${start_addr}/,/^${end_re}\$/p" "$file")"
  [ -n "$block" ] || { echo "empty block for ${start_re} -- sed range did not match" >&2; return 1; }
  case "$block" in
    "${end_line}"|*"${nl}${end_line}") : ;;
    *) echo "block for ${start_re} never reached '${end_line}' -- range ran to EOF" >&2; return 1 ;;
  esac
  printf '%s\n' "$block"
}

# Strip full-line `#` comments so a negative about CODE is not defeated by the
# prose that explains it (rule 1, from the negative side). Docstrings are NOT
# stripped, so a needle that could match docstring prose must be spelled in a form
# only code can satisfy (e.g. `with breaker:` carries the colon the prose lacks).
code_only() {
  grep -v '^[[:space:]]*#' <<< "$1"
}

# Write the stub module into <dir>. Its own function because BOTH layouts need it
# — the flat one `pyrun` stages, and the package one the placement test builds.
write_stubs() {
  cat > "$1/_stubs.py" <<'STUBS'
"""Stubs for the imports that are absent on this toolchain. Nothing under test."""
import sys
import types

# --- (a) metrics deps: unrelated to health -------------------------------------
for name in ("opentelemetry", "opentelemetry.exporter", "opentelemetry.exporter.prometheus",
             "opentelemetry.sdk", "opentelemetry.sdk.metrics", "prometheus_client"):
    sys.modules.setdefault(name, types.ModuleType(name))
sys.modules["opentelemetry"].metrics = types.SimpleNamespace(set_meter_provider=lambda p: None)
sys.modules["opentelemetry.exporter.prometheus"].PrometheusMetricReader = object
sys.modules["opentelemetry.sdk.metrics"].MeterProvider = object
_pc = sys.modules["prometheus_client"]
_pc.CONTENT_TYPE_LATEST = "text/plain"
_pc.REGISTRY = None
_pc.generate_latest = lambda registry: b"# HELP up up\n# TYPE up gauge\nup 1.0\n"


# --- (b) circuitbreaker + tenacity: only so dependency_catalog IMPORTS ----------
# Deliberately inert. Only the catalog's PURE logic (parser, guards, loader) is
# exercised against these; its composition is asserted structurally, because a
# stub breaker would honour whatever this file made it honour.
_cb = types.ModuleType("circuitbreaker")


class _StubCircuitBreaker:
    def __init__(self, failure_threshold=None, recovery_timeout=None,
                 expected_exception=None, name=None, **_kw):
        self.name = name
        self.state = "closed"
        self.opened = False


class CircuitBreakerError(Exception):
    def __init__(self, breaker=None, *args):
        super().__init__(*args)
        self.breaker = breaker


_cb.CircuitBreaker = _StubCircuitBreaker
_cb.CircuitBreakerError = CircuitBreakerError
sys.modules["circuitbreaker"] = _cb

_tn = types.ModuleType("tenacity")
for _name in ("AsyncRetrying", "Retrying", "retry_if_exception_type",
              "retry_if_not_exception_type", "stop_after_attempt", "wait_random_exponential"):
    setattr(_tn, _name, lambda *a, **k: None)
sys.modules["tenacity"] = _tn


# --- (c) the dependency_health seam -------------------------------------------
class FakeBreaker:
    """The one member dependency_health reads from a breaker: nothing else exists."""

    def __init__(self, state="closed"):
        self.state = state


class FakeCatalog:
    """The two members dependency_health reads from a catalog."""

    def __init__(self, dependencies, states=None):
        self.dependencies = dict(dependencies)
        self._breakers = {n: FakeBreaker((states or {}).get(n, "closed")) for n in self.dependencies}

    def breaker(self, name):
        return self._breakers[name]
STUBS
}

# Stage the payload FLAT plus the stubs into the test's tmpdir, then run the
# python snippet on stdin against it. Everything the snippet imports from the
# payload is the REAL template file.
pyrun() {
  local work="$BATS_TEST_TMPDIR/svc"
  mkdir -p "$work"
  cp "$OPS" "$HEALTH" "$CATALOG" "$CLIENT" "$DECL" "$work/"
  write_stubs "$work"
  cat > "$work/_case.py"
  ( cd "$work" && PYTHONPYCACHEPREFIX="$BATS_TEST_TMPDIR/pycache" python3 _case.py )
}

# ---------------------------------------------------------------------------
# Payload shape + the bootstrap contract
# ---------------------------------------------------------------------------

@test "python resilience payload files exist at the SKILL render paths" {
  [ -f "$CATALOG" ]
  [ -f "$HEALTH" ]
  [ -f "$CLIENT" ]
  [ -f "$DECL" ]
  [ -f "$RES/requirements.txt" ]
  [ -f "$RES/README.md" ]
}

@test "the SKILL render commands name every payload file" {
  # Anchored to the fenced render blocks, not to SKILL.md at large: the file is
  # mostly prose, so an unscoped grep would be satisfied by any sentence naming
  # the path even after the file is dropped from the command.
  local blocks f base
  blocks="$(sed -n '/render.zsh" \\/,/^```$/p' "$SKILL")"
  [ -n "$blocks" ]
  for f in "$CATALOG" "$HEALTH" "$CLIENT" "$DECL" "$RES/requirements.txt" "$RES/README.md"; do
    base="$(basename "$f")"
    contains "$blocks" "languages/python/resilience/$base"
  done
}

@test "pricing_api_client is rendered by its own command, so the omit path can drop it" {
  # It names a dependency the service does not have. If it shared the main render
  # command, "omit it" would be un-followable without editing the command.
  local main_block
  main_block="$(block_between 'languages/python/resilience/requirements.txt' '```' "$SKILL")"
  lacks "$main_block" "pricing_api_client.py"
}

@test "the SKILL states the placement rules whose loss breaks a bootstrapped service" {
  # SCOPED to the Python block: every one of these strings also appears in the
  # Java resilience block (RESILIENCE.md three times), so a whole-file grep would
  # stay green after the Python rule was deleted outright.
  local block
  block="$(block_between '^\*\*Python resilience + dependency health' '**Java canonical implementation (#935).** For a **non-Spring** Java service repo,' "$SKILL")"
  # EACH needle is unique WITHIN the block, and asserted to be: scoping alone is not
  # enough when the same string recurs inside the scope. "RESILIENCE.md" appears three
  # times here and "require_all_declared_guarded()" four, so the obvious needles would
  # survive deleting the very bullet they claim to pin -- rule 3 failing from the inside.
  local rule
  for rule in \
    "would put this payload's README at the exact" \
    "BESIDE \`dependency_catalog.py\`" \
    "Substitute the service's real direct" \
    "Bootstrap does not edit the service entrypoint" \
    "fold \`requirements.txt\`'s two pins" \
    "SAME package as \`ops_api.py\`" \
    "ModuleNotFoundError"
  do
    contains "$block" "$rule"
    run grep -cF "$rule" <<< "$block"
    [ "$output" -eq 1 ]
  done
}

@test "the resilience payload's gate is a pure function of the ops-api block's outcome" {
  # A second gate here could disagree with the ops-api one and place an OpsConfig
  # wired for components with no DependencyHealth to supply them.
  local block
  block="$(block_between '^\*\*Python resilience + dependency health' '**Java canonical implementation (#935).** For a **non-Spring** Java service repo,' "$SKILL")"
  # The needle stops at the line wrap: SKILL.md is hard-wrapped, so "the Python
  # ops-api block's own outcome" spans a newline and would never match.
  contains "$block" "own outcome and nothing else"
  # The anti-drift guard: a new condition belongs in the ops-api gate, not here.
  contains "$block" "add it to the ops-api gate instead"
}

# ---------------------------------------------------------------------------
# The library decision
# ---------------------------------------------------------------------------

@test "requirements pins BOTH blessed libraries with an upper bound" {
  # Two libraries, because no Python library is resilience4j. An unbounded pin on
  # either would let a major version land silently on the next fresh install.
  grep -Eq '^circuitbreaker>=2\.1,<3' "$RES/requirements.txt"
  grep -Eq '^tenacity>=9\.[0-9]+,<10' "$RES/requirements.txt"
}

@test "pybreaker is never imported or pinned by the payload" {
  # Rejected on a MEASURED property: its call() holds a threading.RLock for the
  # whole guarded call, so callers of one dependency serialize. Naming it in the
  # README's rejection table is fine; importing or pinning it is not.
  run grep -rn --include='*.py' --include='requirements.txt' 'pybreaker' "$RES"
  [ "$status" -eq 1 ]
  # Positive control: grep -r also exits 1 when the include filters matched NO
  # files, so a renamed payload directory would otherwise "prove" the absence.
  grep -rq --include='*.py' 'import' "$RES"
}

# ---------------------------------------------------------------------------
# The six mandates, as composed by dependency_catalog
# ---------------------------------------------------------------------------

@test "the decoration order is fallback(retry(breaker(call)))" {
  # The breaker is INNERMOST so its counter sees each attempt; the fallback is
  # OUTERMOST so it fires only once the bounded retries are exhausted. A fallback
  # inside the retry would convert the first failure into a success and the call
  # would never be retried.
  local sync_call attempt flat
  sync_call="$(block_between '^    def call($' '    async def call_async(' "$CATALOG")"
  # ORDER, not membership: asserting the three lines exist somewhere in the body
  # stays green when `return fallback(failure)` is moved INSIDE the retry loop --
  # which converts the first failure into a success so the call is never retried,
  # the exact inversion this test is named for. Flattened whitespace pins the
  # nesting; code_only first so a comment cannot satisfy it.
  flat="$(printf '%s' "$(code_only "$sync_call")" | tr -d '[:space:]')"
  contains "$flat" "try:forattemptinself._retrying():withattempt:returnself._guarded_attempt(breaker,call)exceptExceptionasfailure:"
  contains "$flat" "returnfallback(failure)"
  # ...and the breaker wraps the call itself, one level in.
  attempt="$(block_between '^    def _guarded_attempt(' '    async def _guarded_attempt_async(self, breaker: CircuitBreaker, call: Callable[[], Awaitable[T]]) -> T:' "$CATALOG")"
  contains "$attempt" "with breaker:"
  contains "$attempt" "return call()"
}

@test "call_async carries the SAME decoration order and its own fallback" {
  # The async twin is the one that silently drifts: it is a separate method, so a
  # sync-only fix leaves every asyncio service without mandate 4.
  local async_call flat
  async_call="$(block_between '^    async def call_async($' '    # -- internals ----------------------------------------------------------------------' "$CATALOG")"
  flat="$(printf '%s' "$(code_only "$async_call")" | tr -d '[:space:]')"
  contains "$flat" "try:asyncforattemptinself._retrying_async():withattempt:returnawaitself._guarded_attempt_async(breaker,call)exceptExceptionasfailure:"
  contains "$flat" "returnfallback(failure)"
}

@test "an OPEN breaker is rejected BEFORE the call, and outside the breaker block" {
  # THE mandate-6 guard, and the one a tidy-up would delete: circuitbreaker's
  # call() and context manager do NOT honour an open circuit (only its decorator
  # does), so without this the dependency is hammered through every open breaker.
  local guard
  guard="$(block_between '^    def _reject_if_open(' '    def _is_dependency_failure(self, exc_type: type[BaseException], exc: BaseException) -> bool:' "$CATALOG")"
  contains "$guard" "if breaker.opened:"
  contains "$guard" "raise CircuitBreakerError(breaker)"
  # The rejection must not sit inside a `with breaker:` block, or it would itself
  # be recorded as a dependency failure. Needle carries the COLON: the docstring
  # right above explains this rule in prose (``with breaker``), and code_only
  # strips `#` comments but not docstrings, so the bare form matches the very
  # sentence that documents the invariant -- rule 1, from the negative side.
  run grep -c 'with breaker:' <<< "$(code_only "$guard")"
  [ "$output" -eq 0 ]
}

@test "both call paths check the open breaker before touching the dependency" {
  local sync_attempt async_attempt flat
  sync_attempt="$(block_between '^    def _guarded_attempt(' '    async def _guarded_attempt_async(self, breaker: CircuitBreaker, call: Callable[[], Awaitable[T]]) -> T:' "$CATALOG")"
  async_attempt="$(block_between '^    async def _guarded_attempt_async(' '    @staticmethod' "$CATALOG")"
  # ORDER, not membership. Moved INSIDE the `with breaker:` block the rejection
  # still happens -- and mandate 6 is INVERTED rather than merely lost:
  # CircuitBreakerError is in the ignored set, so the breaker's predicate rejects
  # it, so circuitbreaker records the rejection as a SUCCESS and calls reset(),
  # re-closing an open breaker on its first rejected call.
  flat="$(printf '%s' "$(code_only "$sync_attempt")" | tr -d '[:space:]')"
  contains "$flat" "self._reject_if_open(breaker)withbreaker:returncall()"
  flat="$(printf '%s' "$(code_only "$async_attempt")" | tr -d '[:space:]')"
  contains "$flat" "self._reject_if_open(breaker)withbreaker:returnawaitcall()"
}

@test "the retry is BOUNDED and uses Full Jitter with a cap (mandate 3)" {
  local retrying
  retrying="$(block_between '^    def _retrying(self)' '    def _retrying_async(self) -> AsyncRetrying:' "$CATALOG")"
  contains "$retrying" "stop=stop_after_attempt(self._max_attempts)"
  contains "$retrying" "wait=wait_random_exponential(multiplier=self.INITIAL_BACKOFF, max=self.MAX_BACKOFF)"
  # PIN THE VALUES, not "some number": `MAX_ATTEMPTS = [0-9]+` passes on 30, i.e.
  # on the retry storm this test is named after, and `MAX_BACKOFF = [0-9.]+` passes
  # on 600.0. FAILURE_THRESHOLD and INITIAL_BACKOFF are pinned here too because
  # nothing else asserts they are DEFINED -- delete INITIAL_BACKOFF and the suite
  # stays green while the adopter's first guarded call raises AttributeError.
  grep -Eq '^    MAX_ATTEMPTS = 3$' "$CATALOG"
  grep -Eq '^    MAX_BACKOFF = 2\.0$' "$CATALOG"
  grep -Eq '^    INITIAL_BACKOFF = 0\.2$' "$CATALOG"
  grep -Eq '^    FAILURE_THRESHOLD = 5$' "$CATALOG"
}

@test "the retry predicate is BOUNDED to Exception and subtracts the ignored set" {
  # BOTH clauses are load-bearing and both fail silently. Without the Exception
  # bound, overriding tenacity's default predicate widens retrying to
  # BaseException -- so a graceful shutdown's CancelledError is swallowed,
  # backoff-slept and the dead dependency re-called for the rest of the budget.
  # Without the subtraction, an open breaker's rejection is retried through the
  # whole schedule.
  local predicate
  predicate="$(block_between '^    def _retry_predicate(self)' '    def _retrying(self) -> Retrying:' "$CATALOG")"
  contains "$predicate" "return retry_if_exception_type(Exception) & retry_if_not_exception_type(self._ignored)"
}

@test "BOTH retry policies use that one predicate, and both reraise" {
  # An async service that quietly retried cancellations is where this divergence
  # would hurt most, so the two policies must not drift.
  local sync_policy async_policy
  sync_policy="$(block_between '^    def _retrying(self)' '    def _retrying_async(self) -> AsyncRetrying:' "$CATALOG")"
  async_policy="$(block_between '^    def _retrying_async(self)' 'def parse_declaration(text: str) -> dict[str, str]:' "$CATALOG")"
  contains "$sync_policy" "retry=self._retry_predicate()"
  contains "$async_policy" "retry=self._retry_predicate()"
  # reraise: the fallback must receive the dependency's own exception, not
  # tenacity's RetryError wrapper, or it cannot tell a caller error from an outage.
  contains "$sync_policy" "reraise=True"
  contains "$async_policy" "reraise=True"
  contains "$async_policy" "stop=stop_after_attempt(self._max_attempts)"
}

@test "ONE ignored-exception tuple feeds both the breaker and the retry" {
  # Widening only the breaker's list stops a caller error counting toward the
  # threshold but still burns the full retry schedule on every one. A single
  # tuple makes that divergence unrepresentable.
  contains "$(cat "$CATALOG")" "self._ignored: tuple[type[BaseException], ...] = ("
  local predicate
  predicate="$(block_between '^    def _is_dependency_failure(' '    def _retry_predicate(self) -> object:' "$CATALOG")"
  contains "$predicate" "return issubclass(exc_type, Exception) and not issubclass(exc_type, self._ignored)"
}

@test "the ignored set always contains both built-ins, and EXTENDS rather than replaces" {
  # resilience4j's ignoreExceptions ASSIGNS, so a naive override drops the
  # built-ins; this one splats the caller's types after them.
  local block
  block="$(block_between 'self._ignored: tuple' '        )' "$CATALOG")"
  contains "$block" "NotADependencyFailure,"
  contains "$block" "CircuitBreakerError,"
  contains "$block" "*tuple(not_a_dependency_failure),"
}

@test "one breaker PER DEPENDENCY, created eagerly, with ALL FOUR kwargs" {
  # Lazily created, a dependency nothing has called yet would be missing from
  # /health entirely -- under-reporting, at startup, when an operator is watching.
  local block
  block="$(block_between 'self._breakers: dict' '        }' "$CATALOG")"
  contains "$block" "for name in self._dependencies"
  contains "$block" "name=name,"
  # EVERY kwarg is pinned, because dropping any one of them is silent. The worst is
  # expected_exception: circuitbreaker DEFAULTS it to Exception, so without it
  # NotADependencyFailure and CircuitBreakerError start counting toward the
  # threshold and a burst of user-driven 404s opens the breaker on a dependency
  # that answered every request correctly. recovery_timeout is mandate 5's timer --
  # the Python counterpart of resilience4j's automaticTransitionFromOpenToHalfOpen.
  contains "$block" "failure_threshold=self._failure_threshold,"
  contains "$block" "recovery_timeout=self._recovery_timeout,"
  contains "$block" "expected_exception=self._is_dependency_failure,"
}

@test "behavioural: the breaker's failure predicate ignores exactly the right types" {
  # Pure logic, no breaker semantics -- so it is executed against the REAL catalog.
  # This is the other half of "one tuple feeds both": the predicate the breaker is
  # handed must reject the ignored set AND everything outside Exception.
  run pyrun <<'CASE'
import _stubs
from circuitbreaker import CircuitBreakerError
from dependency_catalog import DependencyCatalog, NotADependencyFailure


class TheirNotFound(Exception):
    pass


cat = DependencyCatalog({"a": "hard"}, not_a_dependency_failure=(TheirNotFound,))
for exc in (NotADependencyFailure, CircuitBreakerError, TheirNotFound,
            KeyboardInterrupt, SystemExit, BaseException, ConnectionError, ValueError):
    print(f"{exc.__name__:22} is a dependency failure ->", cat._is_dependency_failure(exc, exc()))
CASE
  [ "$status" -eq 0 ]
  # the built-in ignored pair, and the caller-supplied extension
  contains "$output" "NotADependencyFailure  is a dependency failure -> False"
  contains "$output" "CircuitBreakerError    is a dependency failure -> False"
  contains "$output" "TheirNotFound          is a dependency failure -> False"
  # a cancellation is OUR event: counting it opens the breaker on a healthy dependency
  contains "$output" "KeyboardInterrupt      is a dependency failure -> False"
  contains "$output" "SystemExit             is a dependency failure -> False"
  contains "$output" "BaseException          is a dependency failure -> False"
  # ...and a real failure still counts
  contains "$output" "ConnectionError        is a dependency failure -> True"
  contains "$output" "ValueError             is a dependency failure -> True"
}

@test "mandate 5: the recovery window is a pinned constant the breaker is built with" {
  # An open breaker returns to half-open after this window WITHOUT traffic, which is
  # what makes recovery visible on /health with no deploy. Pinned by value: a
  # RECOVERY_TIMEOUT of 3600 would satisfy "some number" while making the payload's
  # background-reconnect claim false for an hour.
  grep -Eq '^    RECOVERY_TIMEOUT = 10\.0$' "$CATALOG"
}

@test "the fallback catches Exception, never BaseException" {
  # BaseException would swallow asyncio.CancelledError into the fallback, so a
  # graceful shutdown would hang on exactly the dead dependency this is about.
  # Both call paths carry their own handler, so count them.
  run grep -c 'except Exception as failure:' "$CATALOG"
  [ "$output" -eq 2 ]
  run grep -n 'except BaseException' "$CATALOG"
  [ "$status" -eq 1 ]
}

@test "breaker() is a PURE read and does not record guardedness" {
  # dependency_health calls breaker() for every dependency on every scrape. If
  # that recorded guardedness, building DependencyHealth before
  # require_all_declared_guarded() would mark everything guarded and the guard
  # could never fire again -- silently restoring the failure it exists to prevent.
  local reader
  reader="$(block_between '^    def breaker(self, name: str)' '    def require_declared(self, name: str) -> str:' "$CATALOG")"
  contains "$reader" "self._assert_declared(name)"
  contains "$reader" "return self._breakers[name]"
  run grep -c 'self._guarded' <<< "$(code_only "$reader")"
  [ "$output" -eq 0 ]
  # ...while the call path DOES record it: routing a call through the catalog is
  # guarding the dependency.
  run grep -c 'breaker = self._breakers\[self.require_declared(name)\]' "$CATALOG"
  [ "$output" -eq 2 ]
}

# ---------------------------------------------------------------------------
# The declaration and its two guards
# ---------------------------------------------------------------------------

@test "the declaration file uses <name>=hard|soft and ships both worked examples" {
  grep -q '^orders-db=hard$' "$DECL"
  grep -q '^pricing-api=soft$' "$DECL"
}

@test "the default declaration is read from beside the module, not the working directory" {
  # A container's CWD is whatever the entrypoint set. Resolved against it, a
  # missing file is a LEGAL empty catalog -- so /health would silently report
  # nothing at all.
  contains "$(cat "$CATALOG")" 'Path(__file__).with_name(DEFAULT_DECLARATION_FILE)'
}

@test "an unreadable NAMED declaration file is a startup failure, not silently empty" {
  # $OPS_DEPENDENCIES_FILE points at a mounted ConfigMap. A mistyped mount path
  # must not degrade into "no dependencies", which is a health surface that
  # reports nothing wrong during a total outage.
  local load_body
  load_body="$(block_between '        named = os.environ.get(DECLARATION_FILE_ENV' '        return cls(' "$CATALOG")"
  contains "$load_body" 'declared = parse_declaration(Path(named).read_text(encoding="utf-8"))'
  # no try/except anywhere in the loader: the named read must propagate
  run grep -c 'except' <<< "$(code_only "$load_body")"
  [ "$output" -eq 0 ]
}

@test "behavioural: the loader's three branches -- named, default, absent" {
  run pyrun <<'PY'
import _stubs, os, pathlib, shutil, tempfile
from dependency_catalog import DependencyCatalog

# 1. $OPS_DEPENDENCIES_FILE wins, and its content is parsed
mounted = pathlib.Path("mounted.properties")
mounted.write_text("# a ConfigMap\ncache=soft\n", encoding="utf-8")
os.environ["OPS_DEPENDENCIES_FILE"] = str(mounted)
print("1. named file  ->", dict(DependencyCatalog.load().dependencies))

# 2. a NAMED file that cannot be read is a startup failure, never an empty catalog
os.environ["OPS_DEPENDENCIES_FILE"] = "/nope/not/here.properties"
try:
    DependencyCatalog.load()
except OSError as exc:
    print("2. missing named file ->", type(exc).__name__)
else:
    print("2. SILENTLY EMPTY -- the health surface would report nothing during an outage")

# 3. env unset -> the file beside the module (the SHIPPED declaration)
del os.environ["OPS_DEPENDENCIES_FILE"]
print("3. beside module ->", dict(DependencyCatalog.load().dependencies))

# 4. env unset AND no file beside the module -> a legitimately empty catalog
alone = pathlib.Path(tempfile.mkdtemp())
shutil.copy("dependency_catalog.py", alone / "dependency_catalog.py")
shutil.copy("_stubs.py", alone / "_stubs.py")   # the module must resolve from HERE, not the
import subprocess, sys                          # staging dir, which ships a declaration
code = ("import sys; sys.path.insert(0, %r); import _stubs;"
        "from dependency_catalog import DependencyCatalog;"
        "print('4. no declaration ->', dict(DependencyCatalog.load().dependencies))"
        % str(alone))
subprocess.run([sys.executable, "-c", code], check=True, cwd=str(alone))
PY
  [ "$status" -eq 0 ]
  contains "$output" "1. named file  -> {'cache': 'soft'}"
  contains "$output" "2. missing named file -> FileNotFoundError"
  contains "$output" "3. beside module -> {'orders-db': 'hard', 'pricing-api': 'soft'}"
  contains "$output" "4. no declaration -> {}"
}

@test "behavioural: the parser skips comments, preserves order, and lower-cases the kind" {
  # The comment-skip is load-bearing: the SHIPPED declaration is ~44 comment and
  # blank lines around 2 entries, so losing that branch makes the parser raise on
  # line 1 and bricks EVERY bootstrapped service at boot. The lower-casing is
  # equally silent: a `HARD` in an adopter's ConfigMap would otherwise yield a
  # kind matching neither ready() nor aggregate(), disarming the readiness hinge.
  run pyrun <<'PY'
import _stubs, pathlib
from dependency_catalog import parse_declaration

shipped = parse_declaration(pathlib.Path("resilience-dependencies.properties").read_text())
print("shipped ->", shipped)
print("kind case ->", parse_declaration("OrdersDB=HARD\n  cache = Soft \n"))
for bad in ("orders-db=maybe", "orders-db hard", "=hard"):
    try:
        parse_declaration(bad)
    except ValueError as exc:
        print(f"rejected {bad!r}:", str(exc)[:40])
    else:
        print(f"SILENTLY ACCEPTED {bad!r}")
PY
  [ "$status" -eq 0 ]
  contains "$output" "shipped -> {'orders-db': 'hard', 'pricing-api': 'soft'}"
  # names keep their case (a lower-cased key would match no client's
  # require_declared call), kinds do not
  contains "$output" "kind case -> {'OrdersDB': 'hard', 'cache': 'soft'}"
  contains "$output" "rejected 'orders-db=maybe':"
  contains "$output" "rejected 'orders-db hard':"
  contains "$output" "rejected '=hard':"
}

@test "behavioural: a dependency declared twice is refused, not silently last-wins" {
  # The one malformation a silent parser would swallow, and it disarms the readiness
  # hinge: a merged or appended-to ConfigMap that ends up with `orders-db=hard` early
  # and a stray `orders-db=soft` later would quietly keep `soft`, so a total outage of
  # a HARD dependency would never fail readiness -- while /health still lists it and
  # looks perfectly conformant.
  run pyrun <<'CASE'
import _stubs
from dependency_catalog import parse_declaration

for text, label in (("orders-db=hard\norders-db=soft\n", "conflicting"),
                    ("cache=soft\ncache=soft\n", "identical")):
    try:
        parse_declaration(text)
    except ValueError as exc:
        print(f"{label} duplicate -> refused:", str(exc)[:44])
    else:
        print(f"{label} duplicate -> SILENTLY LAST-WINS")
CASE
  [ "$status" -eq 0 ]
  contains "$output" "conflicting duplicate -> refused:"
  contains "$output" "identical duplicate -> refused:"
}

@test "behavioural: an off-contract component from a custom source fails toward severity" {
  # DependencyHealthSource is a PROTOCOL, so a service may hand-write one -- and the
  # module ships two vocabularies (the aggregate says "ok", a component says "up").
  # A source emitting "Down" or kind="Hard" must not read as healthy/soft: that would
  # keep the pod ready and the aggregate "ok" through a hard dependency's outage.
  run pyrun <<'CASE'
import _stubs
from ops_api import Dependency, OpsConfig


class CustomSource:
    def __init__(self, **entry):
        self._entry = Dependency(**entry)

    def components(self):
        return {"orders-db": self._entry}


for label, entry in (
    ("wrong case status", {"status": "Down", "kind": "hard"}),
    ("aggregate vocab   ", {"status": "ok", "kind": "hard"}),
    ("wrong case kind   ", {"status": "down", "kind": "Hard"}),
    ("on contract       ", {"status": "down", "kind": "soft"}),
):
    cfg = OpsConfig(dependencies=CustomSource(**entry))
    snapshot = cfg.components()
    print(f"{label} -> aggregate={cfg.aggregate(snapshot)} ready={cfg.ready(snapshot)}")
CASE
  [ "$status" -eq 0 ]
  # an unrecognised status reads as down, and an unrecognised kind as hard
  contains "$output" "wrong case status -> aggregate=down ready=False"
  contains "$output" "aggregate vocab    -> aggregate=down ready=False"
  contains "$output" "wrong case kind    -> aggregate=down ready=False"
  # ...while a correctly-spelled SOFT dependency down still keeps the pod ready
  contains "$output" "on contract        -> aggregate=degraded ready=True"
}

@test "behavioural: both guards fire, in both directions" {
  # They are only useful as a pair -- each covers one direction of the same
  # under-reporting failure. Asserted behaviourally because a needle on the
  # message survives an inverted membership test.
  run pyrun <<'PY'
import _stubs
from dependency_catalog import DependencyCatalog

cat = DependencyCatalog({"orders-db": "hard", "pricing-api": "soft"})
try:
    cat.require_declared("undeclared-cache")
except LookupError as exc:
    print("1. undeclared in code ->", type(exc).__name__)
else:
    print("1. ACCEPTED an undeclared dependency")

print("2. declared is accepted ->", cat.require_declared("orders-db"))

try:
    cat.require_all_declared_guarded()
except RuntimeError as exc:
    print("3. declared-but-unguarded ->", "pricing-api" in str(exc))
else:
    print("3. GUARD NEVER FIRED")

cat.require_declared("pricing-api")
cat.require_all_declared_guarded()
print("4. all guarded -> clean")

# the vacating bug: a scrape (which reads every breaker) must NOT mark anything guarded
fresh = DependencyCatalog({"orders-db": "hard"})
fresh.breaker("orders-db")
try:
    fresh.require_all_declared_guarded()
except RuntimeError:
    print("5. read path left the guard armed -> True")
else:
    print("5. VACATED -- a scrape silently disarmed the guard")
PY
  [ "$status" -eq 0 ]
  contains "$output" "1. undeclared in code -> LookupError"
  contains "$output" "2. declared is accepted -> orders-db"
  contains "$output" "3. declared-but-unguarded -> True"
  contains "$output" "4. all guarded -> clean"
  contains "$output" "5. read path left the guard armed -> True"
}

@test "behavioural: a non-positive tuning override is rejected, not silently defaulted" {
  run pyrun <<'PY'
import _stubs
from dependency_catalog import DependencyCatalog

for kwargs in ({"failure_threshold": 0}, {"max_attempts": 0}, {"recovery_timeout": -1},
               {"recovery_timeout": 0}):
    try:
        DependencyCatalog({"a": "hard"}, **kwargs)
    except ValueError:
        print("rejected", kwargs)
    else:
        print("SILENTLY DEFAULTED", kwargs)
PY
  [ "$status" -eq 0 ]
  contains "$output" "rejected {'failure_threshold': 0}"
  contains "$output" "rejected {'max_attempts': 0}"
  contains "$output" "rejected {'recovery_timeout': -1}"
  # ZERO is the interesting one: circuitbreaker computes state from elapsed time, so a
  # zero window makes an open breaker read half_open at once and `opened` never True --
  # _reject_if_open would never fire and mandate 6 would be off, by config.
  contains "$output" "rejected {'recovery_timeout': 0}"
}

@test "behavioural: dependency_health reads the REAL catalog's seam" {
  # The fake used by the tests below exposes `dependencies` and `breaker(name)`.
  # This is what stops that fake describing a shape nothing implements: rename
  # either member and every bootstrapped service breaks at the first /health
  # scrape, so the rename must redden HERE rather than pass silently.
  run pyrun <<'PY'
import _stubs
from dependency_catalog import DependencyCatalog
from dependency_health import DependencyHealth

catalog = DependencyCatalog({"orders-db": "hard", "pricing-api": "soft"})
components = DependencyHealth(catalog).components()
print("components ->", {n: (d.status, d.kind, d.breaker) for n, d in components.items()})
PY
  [ "$status" -eq 0 ]
  contains "$output" "components -> {'orders-db': ('up', 'hard', 'closed'), 'pricing-api': ('up', 'soft', 'closed')}"
}

# ---------------------------------------------------------------------------
# The worked client
# ---------------------------------------------------------------------------

@test "the worked client routes its call through the catalog (mandates 2-6)" {
  # The single line that makes this a GUARDED client. Replace the body with a
  # direct self._fetch(sku) and every other client test still passes while the
  # worked example ships with no breaker, no retry and no fallback.
  local quote flat
  quote="$(block_between '^    def quote(self, sku: str)' '    def _fetch(self, sku: str) -> PriceQuote:' "$CLIENT")"
  flat="$(printf '%s' "$quote" | tr -d '[:space:]')"
  contains "$flat" "returnself._catalog.call(DEPENDENCY,lambda:self._fetch(sku),lambdacause:self._last_known_price(sku,cause),)"
}

@test "the worked client sets a transport timeout (mandate 1)" {
  # The one mandate the catalog cannot impose -- and in Python it carries extra
  # weight, since circuitbreaker has no slow-call detection: this value IS the
  # slow-call threshold.
  # Pinned by VALUE: `[0-9.]+` passes on 300.0, and a loosened timeout is the one
  # edit that makes a brownout invisible -- no exception, so the breaker never
  # opens and /health reports the dependency up for the whole event.
  grep -Eq '^TIMEOUT_SECONDS = 3\.0$' "$CLIENT"
  contains "$(cat "$CLIENT")" "urlopen(request, timeout=TIMEOUT_SECONDS)"
}

@test "the worked client reclassifies a 4xx as a caller error and re-raises a 5xx" {
  # urllib RAISES on 4xx/5xx, so the Python trap is the mirror of Java's: the
  # failure is never missed, it is MIS-attributed. Unclassified, a burst of
  # lookups for nonexistent SKUs opens the breaker on a healthy dependency.
  local fetch
  fetch="$(block_between '^    def _fetch(self, sku: str)' '    def _price_url(self, sku: str) -> str:' "$CLIENT")"
  contains "$fetch" "if 400 <= error.code < 500 and error.code not in RETRYABLE_4XX:"
  contains "$fetch" "raise NotADependencyFailure("
  # 429 and 408 stay DEPENDENCY failures: they mean the dependency is shedding load
  # or gave up waiting, not that the caller erred. Misclassified they would be worse
  # than a lost retry -- the library records a rejected exception as a SUCCESS, so
  # every 429 in a rate-limit storm would zero the failure count and hold the
  # breaker closed on a struggling dependency.
  grep -Eq '^RETRYABLE_4XX = frozenset\(\{408, 429\}\)$' "$CLIENT"
  # A 5xx must still reach the breaker. ANCHORED to the whole line: a substring
  # needle for the bare `raise` is also satisfied by the more-indented
  # `raise NotADependencyFailure(` above it, so deleting this line -- making a 503
  # a caller error the breaker ignores -- would stay green.
  run grep -cE '^            raise$' "$CLIENT"
  [ "$output" -eq 1 ]
}

@test "the worked client encodes the SKU and preserves the base path" {
  # Both traps turn a CALLER's input into a reported dependency outage.
  local url
  url="$(block_between '^    def _price_url(self, sku: str)' '    def _last_known_price(self, sku: str, cause: BaseException) -> PriceQuote | None:' "$CLIENT")"
  contains "$url" 'urllib.parse.quote(sku, safe="")'
  contains "$url" 'base = self._base_url if self._base_url.endswith("/") else self._base_url + "/"'
}

@test "the fallback returns rather than re-raising, marks the price stale, and never calls the dependency" {
  local fb
  fb="$(sed -n '/^    def _last_known_price(/,$p' "$CLIENT")"
  [ -n "$fb" ]
  # a caller error gets an honest absence, NOT the delisted SKU's old price
  contains "$fb" "if isinstance(cause, NotADependencyFailure):"
  contains "$fb" "return None"
  contains "$fb" "cached = self._last_known_good.get(sku)"
  # stale=True is silent when wrong: a fallback price served as live
  contains "$fb" "stale=True"
  run grep -cE 'self\._fetch|urlopen' <<< "$fb"
  [ "$output" -eq 0 ]
  # ...and it must not RE-RAISE, which is the clause the title leads with and the
  # one no needle above can see: `raise cause` appended here would defeat mandate 4
  # (call()'s except has already run, so the exception reaches the caller and the
  # breaker protects nothing) while every other assertion stayed green.
  run grep -cE '^ *raise' <<< "$(code_only "$fb")"
  [ "$output" -eq 0 ]
}

@test "behavioural: _fetch caches the live quote and classifies each status code" {
  # _fetch was structurally asserted only, and the fallback test hand-seeds the cache --
  # so nothing executed the line that FILLS it. Delete `self._last_known_good[sku] = quote`
  # and every other test stays green while the registered fallback returns None for every
  # SKU in every outage: mandate 4 becomes decorative and invisible. Served over real HTTP;
  # no breaker or retry semantics are involved, so the stubs beg no question here.
  run pyrun <<'CASE'
import _stubs, threading, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from dependency_catalog import DependencyCatalog, NotADependencyFailure
from pricing_api_client import PricingApiClient


class Pricing(BaseHTTPRequestHandler):
    def do_GET(self):
        code = {"/pricing/v1/prices/ESP-1042-BLK": 200, "/pricing/v1/prices/GONE": 404,
                "/pricing/v1/prices/BUSY": 429, "/pricing/v1/prices/SLOW": 408,
                "/pricing/v1/prices/BROKEN": 503}.get(self.path, 404)
        body = b"12.50" if code == 200 else b"nope"
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_a):
        return


server = ThreadingHTTPServer(("127.0.0.1", 0), Pricing)
threading.Thread(target=server.serve_forever, daemon=True).start()
client = PricingApiClient(DependencyCatalog({"pricing-api": "soft"}),
                          f"http://127.0.0.1:{server.server_address[1]}/pricing")

quote = client._fetch("ESP-1042-BLK")
print("live quote  ->", quote)
print("cached      ->", client._last_known_good.get("ESP-1042-BLK") == quote)
# the end-to-end link: the live fetch is what makes the later fallback possible
print("then stale  ->", client._last_known_price("ESP-1042-BLK", ConnectionError("down")))

for sku in ("GONE", "BUSY", "SLOW", "BROKEN"):
    try:
        client._fetch(sku)
    except NotADependencyFailure:
        print(f"{sku:7} -> NotADependencyFailure")
    except urllib.error.HTTPError as exc:
        print(f"{sku:7} -> HTTPError {exc.code} (reaches the breaker)")
server.shutdown()
CASE
  [ "$status" -eq 0 ]
  # a live quote is NOT stale -- the distinction the fallback depends on
  contains "$output" "live quote  -> PriceQuote(sku='ESP-1042-BLK', amount=Decimal('12.50'), currency='EUR', stale=False)"
  contains "$output" "cached      -> True"
  contains "$output" "then stale  -> PriceQuote(sku='ESP-1042-BLK', amount=Decimal('12.50'), currency='EUR', stale=True)"
  # a caller error is reclassified so it never opens the breaker...
  contains "$output" "GONE    -> NotADependencyFailure"
  # ...while 429/408 and every 5xx stay dependency failures the breaker must see
  contains "$output" "BUSY    -> HTTPError 429 (reaches the breaker)"
  contains "$output" "SLOW    -> HTTPError 408 (reaches the breaker)"
  contains "$output" "BROKEN  -> HTTPError 503 (reaches the breaker)"
}

@test "behavioural: the fallback serves the CACHED price stale, and an honest absence otherwise" {
  # Executed, not grepped: `stale=True` as a literal does not prove the quote carries
  # the cached amount -- a regression to `amount=Decimal(0)` would keep that needle
  # green while serving a fabricated number a caller could bill on.
  run pyrun <<'CASE'
import _stubs
from decimal import Decimal
from dependency_catalog import DependencyCatalog, NotADependencyFailure
from pricing_api_client import PriceQuote, PricingApiClient

client = PricingApiClient(DependencyCatalog({"pricing-api": "soft"}), "https://gw/pricing")
client._last_known_good["ESP-1042-BLK"] = PriceQuote(
    sku="ESP-1042-BLK", amount=Decimal("12.50"), currency="EUR", stale=False)

served = client._last_known_price("ESP-1042-BLK", ConnectionError("pricing-api down"))
print("outage, cached   ->", served)
print("outage, no cache ->", client._last_known_price("UNKNOWN-SKU", ConnectionError("down")))
print("caller error     ->", client._last_known_price("ESP-1042-BLK", NotADependencyFailure("404")))
# ...and the 404 must EVICT, or the next outage re-serves the delisted SKU's price
print("after eviction   ->", client._last_known_price("ESP-1042-BLK", ConnectionError("down")))
CASE
  [ "$status" -eq 0 ]
  # the cached amount and currency survive, marked stale
  contains "$output" "outage, cached   -> PriceQuote(sku='ESP-1042-BLK', amount=Decimal('12.50'), currency='EUR', stale=True)"
  # nothing cached for THIS sku: an honest absence, never a fabricated zero
  contains "$output" "outage, no cache -> None"
  # a delisted SKU is not re-served its old price...
  contains "$output" "caller error     -> None"
  # ...and stays gone once the dependency said so, even during a later outage
  contains "$output" "after eviction   -> None"
}

@test "behavioural: the request URL encodes the SKU and keeps the gateway base path" {
  # Both traps turn a CALLER's input into a reported dependency outage, and both are
  # invisible to a source needle: swapping the relative join for an absolute one
  # ("/v1/prices/...") passes every structural assertion while silently calling
  # https://gw/v1/... instead of https://gw/pricing/v1/... behind a gateway prefix.
  run pyrun <<'CASE'
import _stubs
from dependency_catalog import DependencyCatalog
from pricing_api_client import PricingApiClient

catalog = DependencyCatalog({"pricing-api": "soft"})
for base in ("https://gw/pricing", "https://gw/pricing/"):
    client = PricingApiClient(catalog, base)
    print(f"{base:21} -> {client._price_url('A/B?x y')}")
CASE
  [ "$status" -eq 0 ]
  # the base path survives with and without its trailing slash...
  contains "$output" "https://gw/pricing    -> https://gw/pricing/v1/prices/A%2FB%3Fx%20y"
  contains "$output" "https://gw/pricing/   -> https://gw/pricing/v1/prices/A%2FB%3Fx%20y"
}

@test "the client declares its dependency at WIRING time" {
  local ctor
  ctor="$(block_between '^    def __init__(self, catalog: DependencyCatalog, base_url: str)' '    def quote(self, sku: str) -> PriceQuote | None:' "$CLIENT")"
  contains "$ctor" "catalog.require_declared(DEPENDENCY)"
}

# ---------------------------------------------------------------------------
# Placement-proofness and the ops surface's independence
# ---------------------------------------------------------------------------

@test "behavioural: the payload imports cleanly when placed INSIDE a package" {
  # The documented placement is src/<pkg>/. Python 3 has no implicit relative
  # imports, so a bare `from ops_api import Dependency` raises ModuleNotFoundError
  # there and the bootstrapped service never boots -- while a flat-layout test
  # harness sees nothing wrong. Both layouts are exercised: this test is the
  # package one, every other behavioural test is the flat one.
  local work="$BATS_TEST_TMPDIR/pkgsvc"
  mkdir -p "$work/src/acme"
  cp "$OPS" "$HEALTH" "$CATALOG" "$CLIENT" "$DECL" "$work/src/acme/"
  touch "$work/src/acme/__init__.py"
  write_stubs "$work/src/acme"
  cat > "$work/main.py" <<'PY'
import pathlib
import sys

# from __file__, not "src": bats runs from the repo root, so a relative path here
# would silently resolve somewhere else and the test would prove nothing.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "src"))
import acme._stubs  # noqa: E402,F401  (stubs the absent third-party imports)
from acme.dependency_catalog import DependencyCatalog  # noqa: E402
from acme.dependency_health import DependencyHealth  # noqa: E402
from acme.ops_api import OpsConfig  # noqa: E402
from acme.pricing_api_client import PricingApiClient  # noqa: E402,F401  (must resolve)

catalog = DependencyCatalog({"orders-db": "hard"})
cfg = OpsConfig(dependencies=DependencyHealth(catalog))
print("package layout ->", cfg.health_payload(cfg.components()))
PY
  run env PYTHONPYCACHEPREFIX="$BATS_TEST_TMPDIR/pycache" python3 "$work/main.py"
  [ "$status" -eq 0 ]
  contains "$output" "package layout -> {'status': 'ok', 'components':"
}

@test "the sibling imports are relative-FIRST behind an ImportError fallback" {
  # Order matters: the package layout is the documented one, so the relative form
  # must be tried first. A single bare import would break it outright.
  local health_import client_import
  health_import="$(block_between '^try:$' 'except ImportError:  # not a package -- flat layout' "$HEALTH")"
  client_import="$(block_between '^try:$' 'except ImportError:  # not a package -- flat layout' "$CLIENT")"
  contains "$health_import" "from .ops_api import Dependency"
  contains "$client_import" "from .dependency_catalog import DependencyCatalog, NotADependencyFailure"
}

@test "ops_api carries no breaker-library import, so it stands alone without this payload" {
  # The binding is a Protocol over a dataclass precisely so a service with no
  # outbound dependencies can serve the ops surface with neither library installed.
  run grep -nE 'circuitbreaker|tenacity|dependency_catalog' "$OPS"
  [ "$status" -eq 1 ]
  grep -q 'class DependencyHealthSource(Protocol):' "$OPS"
}

@test "dependency_health imports no breaker library either" {
  run grep -nE '^(from|import) (circuitbreaker|tenacity)' "$HEALTH"
  [ "$status" -eq 1 ]
  grep -q 'class DependencyHealth:' "$HEALTH"
}

@test "dependency health is PASSIVE -- it never calls a dependency or a downstream /health" {
  # The defining property of the whole model: an open breaker IS a down
  # dependency, so health is READ, never probed. A scheduled probe or a
  # transitive /health call is the cascading health-check-storm anti-pattern.
  # Comment-stripped, since the docstring names /health repeatedly.
  local hits
  hits="$(code_only "$(cat "$HEALTH")" | grep -cE 'urllib|httpx|requests|socket|http\.client|urlopen' || true)"
  [ "$hits" -eq 0 ]
  # positive control: the strip must not have eaten the file
  contains "$(code_only "$(cat "$HEALTH")")" "class DependencyHealth:"
}

@test "/health is NOT served by the readiness handler and never answers 503" {
  # #1139: the earlier revision aliased the two, so /health 503'd exactly when an
  # operator needed to read it. The verdict belongs in the body.
  run grep -n 'route in ("/health/ready", "/health")' "$OPS"
  [ "$status" -eq 1 ]
  local handler
  handler="$(block_between '        elif route == "/health":' '        elif route == "/metrics":' "$OPS")"
  contains "$handler" 'body = json.dumps(self.config.health_payload(self.config.components()))'
  contains "$handler" 'self._send(200, "application/json", body.encode("utf-8"))'
  # ...and the raising-source guard answers the WORST verdict, never "ok"
  contains "$handler" 'body = json.dumps({"status": "down"})'
  run grep -c '503' <<< "$(code_only "$handler")"
  [ "$output" -eq 0 ]
}

@test "the readiness PROBE still answers 200/503" {
  local handler
  handler="$(block_between '        elif route == "/health/ready":' '        elif route == "/health":' "$OPS")"
  # ops-api v2 (#1330): 200 keeps the health envelope, the 503 becomes an RFC 9457
  # problem document on application/problem+json — the health "down" string
  # collides with RFC 9457's integer `status`, which is why v2 exists. Both arms
  # and the polarity are pinned together: one arm alone passes an inverted
  # condition, which reports every unready pod as ready.
  contains "$handler" 'if ready:'
  contains "$handler" 'self._json(200, {"status": "ok"})'
  contains "$handler" '"type": PROBLEM_TYPE_NOT_READY,'
  contains "$handler" '"status": 503,'
  contains "$handler" '"detail": _readiness_detail(components),'
  contains "$handler" 'self._problem(503, problem)'
  lacks "$handler" '{"status": "ok" if ready else "down"}'
  # The snapshot is read ONCE and reused for the verdict and the body: calling
  # components() again would re-enter the source, and the 503 could then name a
  # dependency the verdict was not taken on.
  contains "$handler" 'components = self.config.components()'
  contains "$handler" 'ready = self.config.ready(components)'
  lacks "$handler" 'ready = self.config.ready(self.config.components())'
}

@test "liveness stays dependency-free" {
  # A dependency wired into liveness turns a transient outage into a restart storm.
  local handler
  handler="$(block_between '        elif route == "/health/live":' '        elif route == "/health/ready":' "$OPS")"
  contains "$handler" 'self._json(200, {"status": "ok"})'
  run grep -cE 'components|readiness' <<< "$(code_only "$handler")"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# BEHAVIOURAL: the health surface, executed
# ---------------------------------------------------------------------------

@test "behavioural: all three breaker states map to the contract's statuses" {
  run pyrun <<'PY'
import _stubs, json
from _stubs import FakeCatalog
from dependency_health import DependencyHealth

cat = FakeCatalog({"a": "hard", "b": "soft", "c": "soft"},
                  {"a": "closed", "b": "half_open", "c": "open"})
comps = DependencyHealth(cat).components()
print(json.dumps({n: (d.status, d.breaker) for n, d in comps.items()}))
PY
  [ "$status" -eq 0 ]
  contains "$output" '"a": ["up", "closed"]'
  contains "$output" '"b": ["degraded", "half_open"]'
  contains "$output" '"c": ["down", "open"]'
}

@test "behavioural: an unknown breaker state is loud, never defaulted to up" {
  # Defaulting would report a dependency healthy on the strength of a string
  # nobody recognised.
  run pyrun <<'PY'
import _stubs
from _stubs import FakeCatalog
from dependency_health import DependencyHealth

cat = FakeCatalog({"a": "hard"}, {"a": "OPENED"})
try:
    DependencyHealth(cat).components()
except ValueError as exc:
    print("raised:", exc)
else:
    print("SILENTLY ACCEPTED")
PY
  [ "$status" -eq 0 ]
  contains "$output" "raised:"
  contains "$output" "unknown breaker state 'OPENED'"
}

@test "behavioural: components keep declaration order and carry kind + since" {
  run pyrun <<'PY'
import _stubs, re
from _stubs import FakeCatalog
from dependency_health import DependencyHealth

cat = FakeCatalog({"zeta": "soft", "alpha": "hard"})
comps = DependencyHealth(cat).components()
print("order:", list(comps))
print("kinds:", [d.kind for d in comps.values()])
since = list(comps.values())[0].since
print("rfc3339:", bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", since)), since)
PY
  [ "$status" -eq 0 ]
  contains "$output" "order: ['zeta', 'alpha']"
  contains "$output" "kinds: ['soft', 'hard']"
  contains "$output" "rfc3339: True"
}

@test "behavioural: since is stable while the state holds and re-stamps on a change" {
  # A `since` that moved on every scrape would make every blip look like a fresh
  # outage; one frozen at boot would make a sustained outage look ancient.
  run pyrun <<'PY'
import _stubs
from datetime import datetime, timedelta, timezone
from _stubs import FakeCatalog
from dependency_health import DependencyHealth

clock = {"t": datetime(2026, 8, 4, 9, 0, 0, tzinfo=timezone.utc)}
def now():
    clock["t"] += timedelta(seconds=30)
    return clock["t"]

cat = FakeCatalog({"a": "hard"})
health = DependencyHealth(cat, now=now)
first = health.components()["a"].since
second = health.components()["a"].since
print("stable:", first == second, first)
cat.breaker("a").state = "open"
third = health.components()["a"].since
print("restamped:", third != first, third)
PY
  [ "$status" -eq 0 ]
  contains "$output" "stable: True"
  contains "$output" "restamped: True"
}

@test "behavioural: the aggregate floor is hard-down => down, any down/degraded => degraded" {
  run pyrun <<'PY'
import _stubs
from _stubs import FakeCatalog
from dependency_health import DependencyHealth
from ops_api import OpsConfig

def aggregate(deps, states):
    cfg = OpsConfig(dependencies=DependencyHealth(FakeCatalog(deps, states)))
    return cfg.aggregate(cfg.components())

print("all up          ->", aggregate({"a": "hard"}, {"a": "closed"}))
print("soft down       ->", aggregate({"a": "hard", "b": "soft"}, {"b": "open"}))
print("hard down       ->", aggregate({"a": "hard"}, {"a": "open"}))
print("hard half-open  ->", aggregate({"a": "hard"}, {"a": "half_open"}))
print("soft half-open  ->", aggregate({"a": "soft"}, {"a": "half_open"}))
PY
  [ "$status" -eq 0 ]
  contains "$output" "all up          -> ok"
  contains "$output" "soft down       -> degraded"
  contains "$output" "hard down       -> down"
  # a HARD dependency merely being re-probed floors at degraded, NOT down
  contains "$output" "hard half-open  -> degraded"
  contains "$output" "soft half-open  -> degraded"
}

@test "behavioural: over-reporting is honoured, under-reporting is impossible" {
  # The components are a FLOOR. A service impaired for a reason no dependency
  # models must be able to say so; the reverse must not be expressible. An
  # OFF-CONTRACT internal status must fail toward severity, never to "ok" -- a
  # typo'd hook that reported "ok" through the impairment it exists to flag is
  # exactly the under-reporting the contract forbids.
  run pyrun <<'PY'
import _stubs
from _stubs import FakeCatalog
from dependency_health import DependencyHealth
from ops_api import OpsConfig

def agg(states, internal):
    cfg = OpsConfig(dependencies=DependencyHealth(FakeCatalog({"a": "hard"}, states)),
                    internal_status=internal)
    return cfg.aggregate(cfg.components())

print("internal down, deps up ->", agg({"a": "closed"}, lambda: "down"))
print("internal ok, hard down ->", agg({"a": "open"}, lambda: "ok"))
print("internal degraded      ->", agg({"a": "closed"}, lambda: "degraded"))
print("off-contract 'up'      ->", agg({"a": "closed"}, lambda: "up"))
print("off-contract ''        ->", agg({"a": "closed"}, lambda: ""))
print("off-contract None      ->", agg({"a": "closed"}, lambda: None))
PY
  [ "$status" -eq 0 ]
  contains "$output" "internal down, deps up -> down"
  contains "$output" "internal ok, hard down -> down"
  contains "$output" "internal degraded      -> degraded"
  contains "$output" "off-contract 'up'      -> down"
  contains "$output" "off-contract ''        -> down"
  contains "$output" "off-contract None      -> down"
}

@test "behavioural: readiness fails on a HARD dependency down and never on a SOFT one" {
  # The readiness hinge: this is what decides whether Kubernetes sheds traffic.
  run pyrun <<'PY'
import _stubs
from _stubs import FakeCatalog
from dependency_health import DependencyHealth
from ops_api import OpsConfig

def ready(deps, states, readiness=lambda: True):
    cfg = OpsConfig(dependencies=DependencyHealth(FakeCatalog(deps, states)), readiness=readiness)
    return cfg.ready(cfg.components())

print("soft down        ->", ready({"a": "soft"}, {"a": "open"}))
print("hard down        ->", ready({"a": "hard"}, {"a": "open"}))
print("hard half-open   ->", ready({"a": "hard"}, {"a": "half_open"}))
print("draining, all up ->", ready({"a": "hard"}, {"a": "closed"}, readiness=lambda: False))
PY
  [ "$status" -eq 0 ]
  contains "$output" "soft down        -> True"
  contains "$output" "hard down        -> False"
  # being re-probed is not being down: it must not shed traffic
  contains "$output" "hard half-open   -> True"
  # a non-dependency reason still makes the pod unready
  contains "$output" "draining, all up -> False"
}

@test "behavioural: the /health body carries the contract's exact keys and spellings" {
  run pyrun <<'PY'
import _stubs, json
from _stubs import FakeCatalog
from dependency_health import DependencyHealth
from ops_api import Dependency, OpsConfig

cfg = OpsConfig(dependencies=DependencyHealth(
    FakeCatalog({"orders-db": "hard", "pricing-api": "soft"}, {"pricing-api": "open"})))
body = cfg.health_payload(cfg.components())
print("keys:", sorted(body["components"]["orders-db"]))
print("aggregate:", body["status"])
print("pricing-api:", body["components"]["pricing-api"]["status"],
      body["components"]["pricing-api"]["breaker"])

# the two optional fields are OMITTED when absent, so a source that supplies only
# status+kind still emits a valid component
print("minimal:", Dependency(status="up", kind="hard").to_component())

# a healthy service's aggregate is "ok", NEVER "up" -- renaming it would break
# every ops-api v1.0 consumer
healthy = OpsConfig(dependencies=DependencyHealth(FakeCatalog({"orders-db": "hard"})))
print("healthy:", healthy.aggregate(healthy.components()))
PY
  [ "$status" -eq 0 ]
  contains "$output" "keys: ['breaker', 'kind', 'since', 'status']"
  contains "$output" "aggregate: degraded"
  contains "$output" "pricing-api: down open"
  contains "$output" "minimal: {'status': 'up', 'kind': 'hard'}"
  contains "$output" "healthy: ok"
}

@test "behavioural: a service with no dependencies omits components entirely" {
  # It must stay a valid ops-api v1.0 body -- that is what makes v1.1 additive.
  # Three ways to have none: no source at all, an empty catalog, and a source
  # whose components() returns None (the `or {}` guard).
  run pyrun <<'PY'
import _stubs, json
from ops_api import OpsConfig
from _stubs import FakeCatalog
from dependency_health import DependencyHealth

class NoneSource:
    def components(self):
        return None

for label, cfg in (("no source", OpsConfig()),
                   ("empty catalog", OpsConfig(dependencies=DependencyHealth(FakeCatalog({})))),
                   ("None source", OpsConfig(dependencies=NoneSource()))):
    print(label, "->", json.dumps(cfg.health_payload(cfg.components())))
PY
  [ "$status" -eq 0 ]
  contains "$output" 'no source -> {"status": "ok"}'
  contains "$output" 'empty catalog -> {"status": "ok"}'
  contains "$output" 'None source -> {"status": "ok"}'
  run grep -c 'components' <<< "$output"
  [ "$output" -eq 0 ]
}

@test "behavioural: the aggregate and the components come from ONE snapshot" {
  # Taken twice, a breaker flipping between the two reads produces a body whose
  # headline contradicts its own component list. The fake alternates on EVERY
  # read, so under one snapshot the two always agree and under two they cannot.
  run pyrun <<'PY'
import _stubs
from _stubs import FakeCatalog, FakeBreaker
from dependency_health import DependencyHealth
from ops_api import OpsConfig

class FlippingBreaker(FakeBreaker):
    """A different state on every single read."""
    def __init__(self):
        self._reads = 0
    @property
    def state(self):
        self._reads += 1
        return "closed" if self._reads % 2 else "open"

cat = FakeCatalog({"a": "hard"})
cat._breakers["a"] = FlippingBreaker()
cfg = OpsConfig(dependencies=DependencyHealth(cat))
for i in range(6):
    snapshot = cfg.components()
    body = cfg.health_payload(snapshot)
    component = body["components"]["a"]["status"]
    agrees = (body["status"] == "down") == (component == "down")
    print(f"request {i}: aggregate={body['status']} component={component} agrees={agrees}")
PY
  [ "$status" -eq 0 ]
  # Captured FIRST: `run` reassigns $output, so a second grep fed from "$output"
  # would search the previous grep's count ("6") and pass unconditionally.
  local report
  report="$output"
  # every request agrees with itself, whichever state the flip landed on
  run grep -c 'agrees=True' <<< "$report"
  [ "$output" -eq 6 ]
  run grep -c 'agrees=False' <<< "$report"
  [ "$output" -eq 0 ]
}

@test "behavioural: the served ops surface answers the contract's status CODES" {
  # #1139 happened in the ROUTING table, so route it for real over HTTP rather
  # than grepping the handler: /health always 200 with the verdict in the body,
  # 503 reserved for the readiness probe, liveness dependency-free.
  run pyrun <<'PY'
import _stubs, json, threading, urllib.request, urllib.error
from http.server import ThreadingHTTPServer
from _stubs import FakeCatalog
from dependency_health import DependencyHealth
from ops_api import OpsConfig, OpsHandler

cat = FakeCatalog({"orders-db": "hard"}, {"orders-db": "open"})   # HARD dependency DOWN
OpsHandler.config = OpsConfig(dependencies=DependencyHealth(cat))
server = ThreadingHTTPServer(("127.0.0.1", 0), OpsHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"

def get(path):
    try:
        with urllib.request.urlopen(base + path, timeout=5) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read().decode()

for path in ("/health", "/health/", "/health?verbose=1", "/health/ready", "/health/live", "/nope"):
    code, ctype, body = get(path)
    print(f"{path:20} -> {code} {body}")
    print(f"CTYPE {path:20} -> {ctype}")
server.shutdown()
PY
  [ "$status" -eq 0 ]
  # the aggregate is "down" and STILL 200 -- the verdict rides in the body
  # matched on the ROUTE + CODE pair, without depending on the report's padding
  matches "$output" '/health +-> 200 \{"status": "down", "components"'
  # trailing slash and query string normalize to the same route
  matches "$output" '/health/ +-> 200 \{"status": "down"'
  matches "$output" '/health\?verbose=1 +-> 200 \{"status": "down"'
  # the probe is where 503 belongs, and a hard dependency down fails it.
  # ops-api v2 (#1330): that 503 is an RFC 9457 problem document, and the
  # dependency that caused it is NAMED in the canonical detail sentence.
  matches "$output" '/health/ready +-> 503 \{"type": "urn:problem-type:ops:not-ready"'
  contains "$output" "\"detail\": \"hard dependency 'orders-db' is down\""
  contains "$output" '"components": {"orders-db": {"status": "down", "kind": "hard"'
  # BARE problem+json is a runtime property, not only a spec one: a correctly
  # shaped body on application/json is still an org-problem-json-errors failure.
  # Nothing else asserted this end-to-end before v2.
  matches "$output" 'CTYPE /health/ready +-> application/problem\+json'
  # …and the 200 paths keep the ordinary JSON type.
  matches "$output" 'CTYPE /health +-> application/json'
  matches "$output" 'CTYPE /health/live +-> application/json'
  # liveness never consults a dependency
  matches "$output" '/health/live +-> 200 \{"status": "ok"\}'
  matches "$output" '/nope +-> 404'
}

@test "behavioural: a RAISING dependency source still answers the contract's shapes" {
  # The blessed source raises BY DESIGN on an unrecognised breaker state, and a
  # hand-written one may do anything. Unhandled, the exception unwinds out of do_GET,
  # http.server closes the connection with no response, and the checker reports
  # "/health: unreachable" instead of a diagnosis. So /health must still answer 200
  # with the WORST verdict, and readiness must fail closed.
  run pyrun <<'CASE'
import _stubs, threading, urllib.request, urllib.error
from http.server import ThreadingHTTPServer
from ops_api import OpsConfig, OpsHandler


class ExplodingSource:
    def components(self):
        raise ValueError("dependency 'orders-db' reported unknown breaker state 'OPENED'")


class UnserializableSource:
    """Returns fine, but carries a value json.dumps cannot encode."""

    def components(self):
        from datetime import datetime

        from ops_api import Dependency
        return {"orders-db": Dependency(status="up", kind="hard", since=datetime(2026, 8, 4))}


OpsHandler.config = OpsConfig(dependencies=ExplodingSource())
server = ThreadingHTTPServer(("127.0.0.1", 0), OpsHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"

for path in ("/health", "/health/ready", "/health/live"):
    try:
        with urllib.request.urlopen(base + path, timeout=5) as r:
            print(f"{path:14} -> {r.status} {r.read().decode()}")
    except urllib.error.HTTPError as e:
        print(f"{path:14} -> {e.code} {e.read().decode()}")
    except Exception as e:
        print(f"{path:14} -> NO RESPONSE ({type(e).__name__})")

# ...and a source that RETURNS but carries an unserializable field: the failure then
# lands in json.dumps, one frame past the source call, and must be caught just the same.
OpsHandler.config = OpsConfig(dependencies=UnserializableSource())
try:
    with urllib.request.urlopen(base + "/health", timeout=5) as r:
        print(f"unserializable -> {r.status} {r.read().decode()}")
except Exception as e:
    print(f"unserializable -> NO RESPONSE ({type(e).__name__})")

# ...and the same unencodable source on the READINESS path, which ops-api v2
# routes through a second serializer. The source must be BOTH unencodable and
# DOWN: a healthy one answers 200 with the bare health envelope, which serializes
# no components at all and so never reaches the problem writer's json.dumps.
class UnserializableDownSource:
    def components(self):
        from datetime import datetime

        from ops_api import Dependency
        return {"orders-db": Dependency(status="down", kind="hard", since=datetime(2026, 8, 4))}


OpsHandler.config = OpsConfig(dependencies=UnserializableDownSource())
try:
    with urllib.request.urlopen(base + "/health/ready", timeout=5) as r:
        print(f"unserializable-ready -> {r.status} {r.read().decode()}")
except urllib.error.HTTPError as e:
    print(f"unserializable-ready -> {e.code} {e.read().decode()}")
except Exception as e:
    print(f"unserializable-ready -> NO RESPONSE ({type(e).__name__})")
server.shutdown()
CASE
  [ "$status" -eq 0 ]
  # 200 with the worst verdict -- never a closed connection, never "ok"
  matches "$output" '/health +-> 200 \{"status": "down"\}'
  # the probe fails closed, as an RFC 9457 document (ops-api v2, #1330). The
  # source RAISED, so the snapshot is cleared and the detail falls back to the
  # non-dependency wording rather than naming a half-read map — a 503 that named
  # a dependency the verdict was not taken on would be worse than a generic one.
  matches "$output" '/health/ready +-> 503 \{"type": "urn:problem-type:ops:not-ready"'
  contains "$output" '"detail": "the service is starting up"'
  lacks "$output" '"components": {}'
  # ...and liveness is untouched: it consults no dependency, so it cannot be broken by one
  matches "$output" '/health/live +-> 200 \{"status": "ok"\}'
  # the serialization half: a returning-but-unencodable source must not close the
  # connection either -- json.dumps runs INSIDE the guard, not one frame outside it
  contains "$output" 'unserializable -> 200 {"status": "down"}'
  # The SAME hazard on the readiness path, which v2 introduced: the problem body
  # carries source-provided values too, so its json.dumps must be guarded as
  # well. The fallback stays a VALID problem document rather than borrowing
  # /health's {"status": "down"}, which would answer problem+json with a health
  # body.
  contains "$output" 'unserializable-ready -> 503 {"type": "urn:problem-type:ops:not-ready"'
  contains "$output" 'could not be serialized'
}

@test "the placed RESILIENCE.md documents the wiring the SKILL defers to it" {
  # Bootstrap deliberately does NOT wire require_all_declared_guarded(); it
  # records a Step-5 item pointing the adopter at this README. If the snippet
  # drifts, that instruction dangles and the guard never gets wired.
  local readme
  readme="$(cat "$RES/README.md")"
  contains "$readme" "catalog.require_all_declared_guarded()"
  contains "$readme" "OpsConfig(dependencies=DependencyHealth(catalog))"
  contains "$readme" "call_async"
  contains "$readme" "NotADependencyFailure"
  contains "$readme" "OPS_DEPENDENCIES_FILE"
}

@test "the python resilience reviewer knows this payload is the reference implementation" {
  # These rules only exist as of #1143 and are payload-coupled: delete them and the
  # reviewer starts re-reporting mandates 2-6 on every catalog-routed call (the noise
  # the block exists to suppress) and stops flagging the one library this payload
  # rejects on a measured property. tests/resilience-review-dimension.bats pins only
  # the cross-language contract, so nothing else covers them.
  local agent
  agent="$(cat "$REPO_ROOT/development-python/agents/python-resilience-reviewer.md")"
  contains "$agent" "circuitbreaker\` + \`tenacity\` is the reference implementation"
  contains "$agent" "catalog.call(name, call, fallback)"
  contains "$agent" "mandates 2-6 need no re-review"
  contains "$agent" "pybreaker\` IS a finding"
  # the COUNT as well as the set: the prose lead-in is a scope statement, so a
  # "Three things" above four bullets invites the next editor to delete one --
  # and the hard/soft bullet's loss removes a CRITICAL finding class.
  contains "$agent" "Four things stay"
  # the carve-out's four survivors, as a SET
  contains "$agent" "the timeout the client owns"
  contains "$agent" "the exception classification"
  contains "$agent" "the hard/soft declaration"
  contains "$agent" "the sync/async form match"
  # the tenacity predicate defect class, and the 408/429 band it must agree with
  contains "$agent" "retry_if_not_exception_type"
  contains "$agent" "other than 408/429"
}

@test "behavioural: ops_api and the payload compile under the repo's python" {
  # A syntax error in a template is invisible until an adopter runs it. The cache
  # prefix keeps py_compile from writing __pycache__ into the template tree.
  run env PYTHONPYCACHEPREFIX="$BATS_TEST_TMPDIR/pycache" \
    python3 -m py_compile "$OPS" "$HEALTH" "$CATALOG" "$CLIENT"
  [ "$status" -eq 0 ]
}
