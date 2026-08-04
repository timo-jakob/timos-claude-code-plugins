#!/usr/bin/env bats
#
# Structural tests for the per-language canonical ops-api payloads (#688 Python,
# #935 Java, #1192 Go).
#
# These payloads are bootstrap template files the SKILL's render.zsh steps copy
# verbatim into a target service; their RUNTIME conformance is verified downstream
# by the ops-conformance CI job, not here (the test toolchain has no JVM/Python
# service to run, and runs offline). What is cheap and worth guarding here is that
# the files the SKILL render blocks name still exist and keep their contract shape,
# so an accidental move/rename/gutting fails in this repo rather than silently
# breaking a downstream bootstrap. Grep-based and offline, like ops-api-fragment.bats.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LANGS="$REPO_ROOT/development/skills/bootstrap/templates/languages"
  PY="$LANGS/python/ops-api"
  JAVA="$LANGS/java/ops-api"
  GO="$LANGS/go/ops-api"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
}

# ---- Python payload (#688) -------------------------------------------------

@test "python ops-api payload files exist at the SKILL render paths" {
  [ -f "$PY/ops_api.py" ]
  [ -f "$PY/requirements.txt" ]
  [ -f "$PY/README.md" ]
}

@test "python ops_api.py registers all five ops endpoints" {
  grep -q '"/info"' "$PY/ops_api.py"
  grep -q '"/health/live"' "$PY/ops_api.py"
  grep -q '"/health/ready"' "$PY/ops_api.py"
  grep -q '"/health"' "$PY/ops_api.py"
  grep -q '"/metrics"' "$PY/ops_api.py"
}

@test "python requirements.txt declares the OTel SDK + Prometheus exporter deps" {
  grep -q 'opentelemetry-sdk' "$PY/requirements.txt"
  grep -q 'opentelemetry-exporter-prometheus' "$PY/requirements.txt"
  grep -q 'prometheus-client' "$PY/requirements.txt"
}

# ---- Java payload (#935) ---------------------------------------------------

@test "java ops-api payload files exist at the SKILL render paths" {
  [ -f "$JAVA/OpsApi.java" ]
  [ -f "$JAVA/build.gradle.kts" ]
  [ -f "$JAVA/README.md" ]
}

@test "java OpsApi keeps the flagged placeholder package (must be re-set on placement)" {
  grep -q '^package com.example.ops;' "$JAVA/OpsApi.java"
}

@test "java OpsApi registers all five ops endpoints" {
  grep -q 'createContext("/info"' "$JAVA/OpsApi.java"
  grep -q 'createContext("/health/live"' "$JAVA/OpsApi.java"
  grep -q 'createContext("/health/ready"' "$JAVA/OpsApi.java"
  grep -q 'createContext("/health"' "$JAVA/OpsApi.java"
  grep -q 'createContext("/metrics"' "$JAVA/OpsApi.java"
}

@test "java OpsApi enforces both halves of the lifecycle-sunset invariant (RFC 8594)" {
  # deprecated MUST carry a sunset, and active MUST NOT — guard both directions.
  grep -q 'needs a sunset date (RFC 8594)' "$JAVA/OpsApi.java"
  grep -q 'must not carry a sunset date' "$JAVA/OpsApi.java"
}

@test "java build.gradle.kts pins the coherent OTel BOMs and declares the three deps" {
  # The version-less deps resolve only via these two BOM pins — guard them too.
  grep -q 'platform("io.opentelemetry:opentelemetry-bom:' "$JAVA/build.gradle.kts"
  grep -q 'platform("io.opentelemetry:opentelemetry-bom-alpha:' "$JAVA/build.gradle.kts"
  grep -q 'opentelemetry-sdk' "$JAVA/build.gradle.kts"
  grep -q 'opentelemetry-exporter-otlp' "$JAVA/build.gradle.kts"
  grep -q 'opentelemetry-exporter-prometheus' "$JAVA/build.gradle.kts"
}

# ---- Go payload (#1192) ----------------------------------------------------
#
# The Go toolchain is NOT in the test image (see tests/Dockerfile), so these are
# grep-based like their Python/Java siblings: compilation and live conformance are
# verified out-of-band at authoring time and downstream by the ops-conformance CI
# job. What they pin is the contract shape a careless edit would break silently.
#
# THREE RULES, each learned from a defect the sibling suites already paid for:
#
#   1. ANCHOR EVERY NEEDLE TO CODE, NEVER TO PROSE. This payload documents its own
#      contract at length, in the same words the contract is written in — so a
#      bare `grep 'OTEL_EXPORTER_OTLP_ENDPOINT'` is satisfied by the package
#      comment even after the code it names is deleted. `go_flat` STRIPS comment
#      lines, which makes the rule structural rather than aspirational.
#   2. PIN A GUARD TOGETHER WITH ITS BODY, AS ONE NEEDLE. Asserting a condition
#      and its consequence separately cannot tell `A && B` from `A || B`, nor an
#      arm from its transposed twin — and for the readiness hinge that is the
#      difference between shedding traffic on a soft outage and not. `go_flat`
#      collapses whitespace so a whole `if … { … }` fits one needle, which also
#      makes every assertion immune to gofmt re-indentation and re-alignment.
#   3. NO NEEDLE MAY SPAN A SOURCE LINE. tests/find-inert-bracket-assertions.zsh
#      tracks quote carries per line, and a multi-line single-quoted needle whose
#      opening line contains `(` or `)` establishes a PHANTOM carry that silently
#      unscans the span that follows (#1068's documented residual gap) — this file
#      would then be exempt from the suite's own inert-assertion lint without
#      anything going red. Rule 2 is what makes rule 3 free: flattened needles are
#      one line by construction.

# go_func <signature-prefix> — the body of one top-level Go declaration, from its
# `func` line to the closing brace in column 0.
#
# Closure is proven by a SENTINEL the terminating branch emits, not by inspecting
# the result: opsapi.go's own last line is `}`, so a runaway extraction that ran to
# EOF would also *end* in `}` and pass a shape check — while silently handing back
# every following function as the haystack, which is exactly what makes a `lacks`
# assertion vacuous.
go_func() {
  local body
  body="$(awk -v sig="$1" '
    index($0, "func " sig) == 1 { inside = 1 }
    inside { print }
    inside && /^}$/ { print "//go_func:closed"; exit }
  ' "$GO/opsapi.go")"
  case "$body" in
    *"//go_func:closed") printf '%s' "${body%//go_func:closed}" ;;
    *) echo "go_func: 'func $1' not found, or its block never closed" >&2; return 1 ;;
  esac
}

# go_handler <registration-prefix> — one route's registration block, ending at the
# `})` in column-one-tab. Same sentinel discipline as go_func.
go_handler() {
  local body
  body="$(awk -v pat="$1" '
    index($0, pat) > 0 { inside = 1 }
    inside { print }
    inside && /^\t\}\)$/ { print "//go_handler:closed"; exit }
  ' "$GO/opsapi.go")"
  case "$body" in
    *"//go_handler:closed") printf '%s' "${body%//go_handler:closed}" ;;
    *) echo "go_handler: '$1' not found, or its block never closed" >&2; return 1 ;;
  esac
}

# flatten — drop whole-line comments, then collapse every run of whitespace to a
# single space. See rules 1 and 2 above: this is what lets one needle pin a guard
# together with its body, on one line, without pinning gofmt's alignment.
flatten() { printf '%s' "$1" | grep -v '^[[:space:]]*//' | tr -s ' \t\n' ' '; }

go_flat() { local b; b="$(go_func "$1")" || return 1; flatten "$b"; }
go_handler_flat() { local b; b="$(go_handler "$1")" || return 1; flatten "$b"; }

@test "go ops-api payload files exist at the SKILL render paths" {
  [ -f "$GO/opsapi.go" ]
  [ -f "$GO/go.mod.deps" ]
  [ -f "$GO/README.md" ]
}

@test "go_func proves closure rather than inferring it (self-test)" {
  # Rule 3's premise: without the sentinel, a signature that never closes returns
  # everything to EOF and every `lacks` built on it becomes vacuous. Prove the
  # helper actually fails on a signature that does not exist.
  run ! go_func 'ThisDeclarationDoesNotExist('
  run ! go_handler 'mux.HandleFunc("GET /nonexistent"'
}

@test "go opsapi declares package ops, the claim SKILL and how-to both make" {
  # Both docs promise "no package fix-up is needed" BECAUSE the file declares
  # `package ops`. Anchored to line start so the package doc's own mention of the
  # name cannot satisfy it.
  grep -qE '^package ops$' "$GO/opsapi.go"
}

@test "go opsapi REGISTERS all five ops endpoints as METHOD patterns" {
  # Each needle carries the registration call, not just the pattern string: the
  # package comment quotes "GET /health" verbatim while explaining the go>=1.22
  # trap, so a bare pattern needle stays green after the route is deleted.
  # The "GET " prefix is what makes these Go 1.22 method patterns; dropping it
  # still routes, so asserting the path alone would let that regression through.
  grep -qF 'mux.HandleFunc("GET /info", func(' "$GO/opsapi.go"
  grep -qF 'mux.HandleFunc("GET /health/live", func(' "$GO/opsapi.go"
  grep -qF 'mux.HandleFunc("GET /health/ready", func(' "$GO/opsapi.go"
  grep -qF 'mux.HandleFunc("GET /health", func(' "$GO/opsapi.go"
  grep -qF 'mux.Handle("GET /metrics", metricsHandler)' "$GO/opsapi.go"
  grep -qF 'mux.HandleFunc("GET /", func(' "$GO/opsapi.go"
}

@test "go opsapi's /info serves the build block and the served-majors table" {
  # Registration alone proves nothing about what the route answers: /info could
  # serve a statusBody and the JSON-tag test would still pass, because those tags
  # live on structs nothing would then reference.
  local h; h="$(go_handler_flat 'mux.HandleFunc("GET /info", func(')"
  contains "$h" 'writeJSON(w, http.StatusOK, infoBody{ Build: buildBlock{Version: c.Version, GitSHA: c.GitSHA}, API: c.ServedMajors, })'
}

@test "go opsapi's liveness probe is 200-and-dependency-free" {
  # Liveness must never consult a dependency: a failing liveness RESTARTS the pod,
  # so wiring it to dependency state turns a transient outage into a restart storm
  # — the anti-pattern the package doc, README and how-to all warn about.
  local h; h="$(go_handler_flat 'mux.HandleFunc("GET /health/live", func(')"
  contains "$h" 'writeJSON(w, http.StatusOK, statusBody{Status: StatusOK})'
  lacks "$h" 'c.ready('
  lacks "$h" 'c.components('
  lacks "$h" 'StatusServiceUnavailable'
}

@test "go opsapi's readiness probe answers 200 when ready and 503 when not" {
  # Both arms, in the handler that owns them. A file-wide needle for the 503 would
  # still match after it moved into /health — the #1139 regression both sibling
  # payloads shipped and had to be fixed for.
  local h; h="$(go_handler_flat 'mux.HandleFunc("GET /health/ready", func(')"
  contains "$h" 'if ready { writeJSON(w, http.StatusOK, statusBody{Status: StatusOK}) return }'
  contains "$h" 'writeJSON(w, http.StatusServiceUnavailable, statusBody{Status: StatusDown})'
  contains "$h" 'ready = c.ready(c.components())'
}

@test "go opsapi answers /health with 200 and confines 503 to the readiness probe" {
  # #1139 in Go form: /health carries the verdict in the BODY and must never 503.
  # Pinned three ways — the aggregate write, the ABSENCE of a 503 in that handler,
  # and exactly one 503 in the whole file.
  local h; h="$(go_handler_flat 'mux.HandleFunc("GET /health", func(')"
  contains "$h" 'writeJSON(w, http.StatusOK, body)'
  contains "$h" 'body = healthBody{Status: c.aggregate(components), Components: components}'
  lacks "$h" 'StatusServiceUnavailable'
  local n
  n="$(grep -c 'http.StatusServiceUnavailable' "$GO/opsapi.go")"
  [ "$n" -eq 1 ]
}

@test "go opsapi's catch-all names the offending path instead of a blank 404" {
  local h; h="$(go_handler_flat 'mux.HandleFunc("GET /", func(')"
  contains "$h" 'writeJSON(w, http.StatusNotFound, map[string]string{ "error": "not found", "path": r.URL.Path, })'
}

@test "go payload documents the go>=1.22 directive trap in all five arrival points" {
  # A module still declaring `go 1.21` compiles this cleanly and then 404s every
  # endpoint — no build error, no warning. Each needle is unique to the WARNING,
  # not to the version string: a bare 'go 1.22' is satisfied by any incidental
  # mention, including the README's own "go 1.22 -> 200" example line, so deleting
  # the whole paragraph would leave it green. go.mod.deps counts because folding
  # by hand is the one adoption path that passes through no other document.
  grep -qF 'go 1.22 OR NEWER' "$GO/opsapi.go"
  grep -qF '404 on every ops endpoint' "$GO/README.md"
  grep -qF 'go 1.22` OR NEWER' "$GO/go.mod.deps"
  grep -qF 'Check the `go` directive before you install' "$SKILL"
  grep -qF '404 on every ops endpoint' "$REPO_ROOT/docs/how-to/adopt-the-ops-surface.md"
}

@test "go opsapi pins every contract spelling, in both vocabularies" {
  # Two vocabularies, one letter of difference in consequence: the aggregate is
  # "ok" (renaming it to "up" breaks every ops-api v1.0 consumer) while a
  # component is "up". KindHard = "Hard" compiles and silently disarms the
  # readiness hinge, which compares against the literal spelling; a breaker value
  # outside the enum is rejected outright by check-ops-conformance.zsh.
  # Whitespace-tolerant so adding a longer constant — which makes gofmt re-align
  # the whole block — cannot redden these for an unrelated reason.
  grep -qE '^[[:space:]]*StatusOK[[:space:]]+= "ok"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*StatusDegraded[[:space:]]+= "degraded"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*StatusDown[[:space:]]+= "down"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*ComponentUp[[:space:]]+= "up"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*ComponentDegraded[[:space:]]+= "degraded"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*ComponentDown[[:space:]]+= "down"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*KindHard[[:space:]]+= "hard"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*KindSoft[[:space:]]+= "soft"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*BreakerClosed[[:space:]]+= "closed"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*BreakerOpen[[:space:]]+= "open"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*BreakerHalfOpen[[:space:]]+= "half_open"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*LifecycleActive[[:space:]]+= "active"$' "$GO/opsapi.go"
  grep -qE '^[[:space:]]*LifecycleDeprecated[[:space:]]+= "deprecated"$' "$GO/opsapi.go"
}

@test "go opsapi's JSON tags are the wire keys the conformance checker reads" {
  # Every served field is a struct tag. Renaming one (git_sha -> gitSha) or
  # dropping `,omitempty` from components — so a v1.0 body starts emitting
  # "components":{} — is gofmt-clean, compile-clean, and breaks every consumer.
  # Each tag is asserted WITH its field, because `json:"status"` alone is carried
  # by three structs and would survive a rename in any one of them.
  local f; f="$(flatten "$(cat "$GO/opsapi.go")")"
  contains "$f" 'Version string `json:"version"`'
  contains "$f" 'GitSHA string `json:"git_sha"`'
  contains "$f" 'Build buildBlock `json:"build"`'
  contains "$f" 'API []APIMajor `json:"api"`'
  contains "$f" 'Major int `json:"major"`'
  contains "$f" 'Lifecycle string `json:"lifecycle"`'
  contains "$f" 'Sunset string `json:"sunset,omitempty"`'
  # Dependency: status/kind are required, breaker/since MUST stay omitempty —
  # the checker rejects a present-but-empty breaker as a non-member of the enum
  # while an absent one is legal.
  contains "$f" 'Status string `json:"status"` Kind string `json:"kind"` Breaker string `json:"breaker,omitempty"` Since string `json:"since,omitempty"`'
  # healthBody: the aggregate's own status, and the components omission.
  contains "$f" 'Status string `json:"status"` Components map[string]Dependency `json:"components,omitempty"`'
  # statusBody: what both probes answer with.
  contains "$f" 'type statusBody struct { Status string `json:"status"` }'
}

@test "go opsapi omits components entirely when no dependency source is wired" {
  # This is what keeps an unwired service a valid ops-api v1.0 body — the state of
  # any service that leaves Config.Dependencies unset, i.e. a repo where the
  # resilience payload (#1144) was skipped or deferred along with this one.
  local fn; fn="$(go_flat '(c Config) components()')"
  contains "$fn" 'if c.Dependencies == nil { return nil }'
  contains "$fn" 'if len(raw) == 0 { return nil }'
  contains "$fn" 'out[name] = onContract(d)'
  # The coerced map must be what comes BACK: `return raw` compiles (raw is still
  # read by len and the range) and would hand every hand-written source's values
  # to /health and ready() uncoerced — the under-reporting the onContract test
  # exists to prevent, through the one door that test cannot see.
  ends_with "$fn" 'return out } '
}

@test "go opsapi fails readiness ONLY on a hard dependency that is down" {
  # The change's marquee contract, and every inversion of it is compile-clean:
  # KindHard->KindSoft sheds all traffic on a soft outage, ComponentDown->Up
  # reports a healthy hard dependency unready, and dropping the Readiness()
  # early return keeps a draining pod in rotation. Guard and body in ONE needle:
  # split apart, `||` would satisfy both while failing readiness on a soft outage.
  local fn; fn="$(go_flat '(c Config) ready(')"
  contains "$fn" 'if !c.Readiness() { return false }'
  contains "$fn" 'if d.Kind == KindHard && d.Status == ComponentDown { return false }'
  ends_with "$fn" 'return true } '
  # A soft dependency must never reach the readiness verdict at all.
  lacks "$fn" 'KindSoft'
}

@test "go opsapi floors the /health aggregate the way the checker demands" {
  # hard+down => down; any other down/degraded => degraded; internal state seeds
  # it so the over-reporting hook the contract mandates cannot be capped away.
  # Each arm is pinned WITH its body: swapping the two worseOf calls between arms
  # is compile-clean and inverts the marquee contract.
  local fn; fn="$(go_flat '(c Config) aggregate(')"
  contains "$fn" 'status := c.InternalStatus()'
  # BOTH clauses in ONE needle, in order. This is a Go EXPRESSION switch, so the
  # FIRST match wins — exchanging the two clauses (each still glued to its own
  # worseOf call) is compile-clean and leaves two separate needles green, while a
  # fully-down HARD dependency then matches the `||` clause first and floors the
  # aggregate at "degraded" instead of "down". That is the marquee contract
  # inverted, in the under-reporting direction the payload calls forbidden.
  contains "$fn" 'switch { case d.Status == ComponentDown && d.Kind == KindHard: status = worseOf(status, StatusDown) case d.Status == ComponentDown || d.Status == ComponentDegraded: status = worseOf(status, StatusDegraded) }'
  # An off-contract internal status must fail toward severity — with its guard,
  # since dropping the `!` inverts the branch onto every VALID status instead.
  contains "$fn" 'if _, ok := statusRank[status]; !ok { status = StatusDown }'
  # And the floored value must be what comes back: `return c.InternalStatus()`
  # compiles (status is still read above) and reports "ok" through a hard-down
  # outage with every needle above still green.
  ends_with "$fn" 'return status } '
}

@test "go opsapi's severity ordering is worst-wins" {
  # Inverting the comparator makes best-wins the rule, which reports "ok" during
  # a hard-down outage. Asserting the condition alone cannot see that: the
  # inversion is done by swapping the two RETURNS, so both are in the needle.
  grep -qF 'map[string]int{StatusOK: 0, StatusDegraded: 1, StatusDown: 2}' "$GO/opsapi.go"
  local fn; fn="$(go_flat 'worseOf(')"
  contains "$fn" 'if statusRank[a] >= statusRank[b] { return a } return b'
}

@test "go opsapi coerces an off-contract component toward severity, never health" {
  # A hand-written source returning "ok"/"Hard" must read as down/hard, not as a
  # healthy soft dependency — the silent under-reporting the contract forbids.
  # The accepted-value list is part of each needle: dropping ComponentUp from it
  # coerces every HEALTHY component to down, and dropping KindSoft makes every
  # soft dependency hard, which sheds traffic on a soft outage.
  local fn; fn="$(go_flat 'onContract(')"
  contains "$fn" 'switch d.Status { case ComponentUp, ComponentDegraded, ComponentDown: default: d.Status = ComponentDown }'
  contains "$fn" 'switch d.Kind { case KindHard, KindSoft: default: d.Kind = KindHard }'
  # An off-contract breaker is DROPPED, not coerced: the checker rejects a
  # present-but-invalid breaker and accepts an absent one.
  contains "$fn" 'switch d.Breaker { case "", BreakerClosed, BreakerOpen, BreakerHalfOpen: default: d.Breaker = "" }'
}

@test "go opsapi enforces both halves of the lifecycle-sunset invariant (RFC 8594)" {
  # Pinning the messages alone cannot discriminate an inverted operator or the
  # two messages transposed between arms — after which Validate rejects exactly
  # what it should accept. So pin each guard TOGETHER with its arm and message.
  local fn; fn="$(go_flat '(c Config) Validate()')"
  contains "$fn" 'case LifecycleDeprecated: if m.Sunset == "" { return fmt.Errorf("ops: deprecated major %d needs a sunset date (RFC 8594)", m.Major) }'
  contains "$fn" 'case LifecycleActive: if m.Sunset != "" { return fmt.Errorf("ops: active major %d must not carry a sunset date", m.Major) }'
}

@test "go opsapi's Validate rejects the other three malformed lifecycle tables" {
  # Each exists so the mistake fails at STARTUP instead of in a downstream repo's
  # ops-conformance job. Guards included: `m.Major < 1` flipped to `> 1` rejects
  # every legitimate major, and `if seen[...]` flipped to `if !seen[...]` rejects
  # every FIRST declaration, so no service could boot at all.
  local fn; fn="$(go_flat '(c Config) Validate()')"
  contains "$fn" 'if m.Major < 1 { return fmt.Errorf("ops: api major %d is invalid (want an integer >= 1)", m.Major) }'
  contains "$fn" 'if seen[m.Major] { return fmt.Errorf("ops: api major %d is declared twice", m.Major) }'
  contains "$fn" 'seen[m.Major] = true'
  contains "$fn" 'default: return fmt.Errorf("ops: major %d has an invalid lifecycle %q'
}

@test "go opsapi resolves its defaults so an unconfigured Config still conforms" {
  # Four contracts, each compile-clean to break: nil Readiness = always ready;
  # nil InternalStatus = ok (without it the off-contract coercion would report
  # every aggregate "down"); an empty ServedMajors table would fail conformance
  # with an empty /info api[]; and the defensive copy is what stops a caller's
  # later append from changing what /info serves AFTER Validate approved it.
  local fn; fn="$(go_flat '(c Config) resolved()')"
  contains "$fn" 'if out.Readiness == nil { out.Readiness = func() bool { return true } }'
  contains "$fn" 'if out.InternalStatus == nil { out.InternalStatus = func() string { return StatusOK } }'
  contains "$fn" 'if len(out.ServedMajors) == 0 { out.ServedMajors = []APIMajor{{Major: 1, Lifecycle: LifecycleActive}} } else { out.ServedMajors = append([]APIMajor(nil), out.ServedMajors...) }'
  contains "$fn" 'if out.Version == "" { out.Version = defaultVersion() }'
  contains "$fn" 'if out.GitSHA == "" { out.GitSHA = defaultGitSHA() }'
  # `return c` compiles — out is still read by every guard — and discards all of
  # it: a nil Readiness panics the first probe into the recover and the pod stays
  # unready forever, and an empty ServedMajors serves "api": [], failing conformance.
  ends_with "$fn" 'return out } '
}

@test "go opsapi refuses to build a handler without validation or the metrics half" {
  # /metrics is part of the contract, so a nil handler is a startup error rather
  # than a 404 the ops-conformance job discovers downstream. Dropping the
  # Validate call likewise defers every lifecycle mistake to CI, and dropping the
  # resolved() call serves an unconfigured Config's zero values.
  local fn; fn="$(go_flat 'NewHandler(')"
  contains "$fn" 'if err := cfg.Validate(); err != nil { return nil, err }'
  contains "$fn" 'if metricsHandler == nil { return nil, errors.New("ops: metricsHandler is required'
  contains "$fn" 'c := cfg.resolved()'
  contains "$fn" 'return normalizePath(mux), nil'
}

@test "go opsapi normalizes a trailing slash but leaves encoded paths alone" {
  # ServeMux's exact patterns do not match "/health/", so without the rewrite a
  # probe or curl with a trailing slash 404s against a conforming service. The
  # guards alone are not the contract: deleting the trim, the assignment or the
  # re-dispatch leaves the wrapper structurally present and every needle green.
  local fn; fn="$(go_flat 'normalizePath(')"
  contains "$fn" 'if r.URL.RawPath != "" { next.ServeHTTP(w, r) return }'
  contains "$fn" 'if p := r.URL.Path; len(p) > 1 && strings.HasSuffix(p, "/") {'
  contains "$fn" 'trimmed := strings.TrimRight(p, "/")'
  contains "$fn" 'if trimmed == "" { trimmed = "/" }'
  contains "$fn" 'u := *r.URL'
  contains "$fn" 'u.Path = trimmed'
  contains "$fn" 'r2.URL = &u'
  contains "$fn" 'next.ServeHTTP(w, &r2) return }'
  # The DEFAULT branch — every request without a trailing slash, i.e. every
  # conforming probe and every checker call. Deleting it is compile-clean and
  # leaves every needle above green while the whole surface answers an empty 200.
  ends_with "$fn" 'next.ServeHTTP(w, r) }) } '
}

@test "go opsapi's writeJSON sets the code and the content type" {
  # The single writer for every ops response. Dropping w.WriteHeader(code) makes
  # every response 200 — including the readiness 503 that three other tests go to
  # some length to pin, silently defeating the probe.
  local fn; fn="$(go_flat 'writeJSON(')"
  # ORDER is the contract, so both are one needle: swapping them is compile-,
  # vet- and gofmt-clean and makes the Set a no-op, shipping every ops response
  # without a Content-Type. The checker inspects content-type only on /metrics,
  # so that regression is silent downstream as well as here.
  contains "$fn" 'w.Header().Set("Content-Type", "application/json") w.WriteHeader(code)'
  contains "$fn" 'if err != nil { body = []byte(`{"status":"down"}`) code = http.StatusInternalServerError }'
}

@test "go opsapi documents that Components must return a snapshot, not a live map" {
  # The one fault the recover guards CANNOT cover: a concurrent map read/write is
  # a Go fatal error, not a panic, so a source handing back its live map kills the
  # process mid-scrape. The warning must reach the implementer, in both places.
  grep -qF 'IT MUST RETURN A FRESHLY BUILT MAP' "$GO/opsapi.go"
  grep -qF 'freshly built map every call' "$GO/README.md"
}

@test "go opsapi recovers a panicking dependency source on BOTH health paths, fail-closed" {
  # Unhandled, a panic in a hand-written DependencyHealthSource closes the
  # connection with no response and the checker reports "/health: unreachable"
  # instead of a diagnosis. The count alone is not enough: two recovers in one
  # handler satisfy it, as does a recover whose body no longer fails closed —
  # which is the under-reporting the guards exist to prevent. So pin the
  # DIRECTION of each recovery, inside the handler that owns it.
  local n
  n="$(grep -c 'if r := recover(); r != nil' "$GO/opsapi.go")"
  [ "$n" -eq 2 ]
  local ready health
  # …and the SHAPE, not just the body. Two compile-, vet- and lint-clean edits
  # would otherwise ship green: dropping the `defer` keyword (recover() outside a
  # deferred call returns nil, so the guard never fires and the panic unwinds —
  # connection closed, no response, "/health: unreachable"), or hoisting the
  # recover out of its immediately-invoked closure to the handler's top level
  # (the panic IS caught, but the writeJSON below never runs, so net/http emits a
  # bare 200 and a panicking source keeps an unready pod in rotation — fail-OPEN,
  # the exact inversion of this test's title). So the needle carries the closure,
  # the defer and the guarded call together.
  ready="$(go_handler_flat 'mux.HandleFunc("GET /health/ready", func(')"
  contains "$ready" 'func() { defer func() { if r := recover(); r != nil { ready = false } }() ready = c.ready(c.components()) }()'
  health="$(go_handler_flat 'mux.HandleFunc("GET /health", func(')"
  contains "$health" 'func() { defer func() { if r := recover(); r != nil { body = healthBody{Status: StatusDown} } }() components := c.components() body = healthBody{Status: c.aggregate(components), Components: components} }()'
}

@test "go opsapi installs ONE OTel provider feeding a dedicated registry" {
  # Three contracts the README sells: a dedicated registry (DefaultRegisterer
  # would smuggle the Go runtime/process collectors into /metrics), the global
  # provider (without SetMeterProvider every otel.Meter instrument a service
  # records goes to a no-op and /metrics is empty — silently useless yet still
  # conforming), and both readers hanging off the one provider.
  local fn; fn="$(go_flat 'InstallMetrics(')"
  contains "$fn" 'registry := prometheus.NewRegistry()'
  contains "$fn" 'otelprom.New(otelprom.WithRegisterer(registry))'
  contains "$fn" 'opts := []sdkmetric.Option{sdkmetric.WithReader(pullExporter)}'
  # The push reader with its whole hinge: dropping the `else if pushExporter !=
  # nil` half wraps a NIL exporter for every service with no collector — the
  # default state of every bootstrapped repo — and dropping the err branch
  # swallows the loud-startup-error contract the sibling test pins.
  contains "$fn" 'if pushExporter, err := newOTLPExporter(ctx); err != nil { return nil, nil, err } else if pushExporter != nil { opts = append(opts, sdkmetric.WithReader(sdkmetric.NewPeriodicReader(pushExporter))) }'
  # The assembled options must actually reach the provider: NewMeterProvider()
  # with no args is compile-clean (opts is still read by the append above) and
  # yields a provider with NO readers — /metrics serves an empty exposition and
  # OTLP never fires, while the surface still passes conformance.
  contains "$fn" 'provider := sdkmetric.NewMeterProvider(opts...)'
  contains "$fn" 'otel.SetMeterProvider(provider)'
  # …and both must be what the caller RECEIVES, not merely what was built.
  ends_with "$fn" 'return provider, promhttp.HandlerFor(registry, promhttp.HandlerOpts{}), nil } '
  lacks "$fn" 'DefaultRegisterer'
}

@test "go opsapi bounds every management-server timeout and drains on shutdown" {
  # An unbounded management server is a Slowloris target, and the probes it
  # answers must never be starved by a stuck connection. A bare
  # `ReadHeaderTimeout:` needle would be satisfied by a value of 0, which
  # re-creates the exposure the field exists to close — so pin the values, in a
  # whitespace-tolerant form that survives a longer field being added.
  local fn; fn="$(go_flat 'Serve(')"
  contains "$fn" 'ReadHeaderTimeout: 5 * time.Second'
  contains "$fn" 'ReadTimeout: 10 * time.Second'
  contains "$fn" 'WriteTimeout: 15 * time.Second'
  contains "$fn" 'IdleTimeout: 60 * time.Second'
  # The drain contract the README sells to adopters.
  contains "$fn" 'listener, err := net.Listen("tcp", addr)'
  contains "$fn" 'if errors.Is(err, http.ErrServerClosed) { err = nil }'
  # The flush must be DEFERRED: hoisted inline it shuts metrics down before the
  # server ever binds, leaving /metrics and OTLP dead for the whole process.
  contains "$fn" 'defer func() { shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second) defer cancel() _ = provider.Shutdown(shutdownCtx) }()'
  # BOTH select arms. Rewriting the error arm to `return nil` makes Serve report
  # success when the management server dies — the adopter's log.Fatalf never
  # fires and the process runs on with no ops surface at all.
  contains "$fn" 'case err := <-errCh: return err'
  # The drain itself, with the force-close its budget-exhausted branch owes.
  # Asserting a bare `_ = server.Close()` cannot tell a graceful drain from an
  # immediate kill — and an immediate kill severs in-flight requests on every
  # rolling update, which is precisely what this test's title claims it guards.
  # The drain arm's context, with its budget and its cancel. WithoutCancel is
  # load-bearing precisely here: the arm is entered BECAUSE ctx is done, so
  # deriving from ctx directly (an edit that reads as removing a redundancy)
  # yields a context born cancelled — Shutdown returns instantly and the
  # force-close branch becomes the only path, severing in-flight requests on
  # every rolling update. Naming shutdownCtx alone cannot see that.
  contains "$fn" 'case <-ctx.Done(): shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second) defer cancel()'
  contains "$fn" 'if err := server.Shutdown(shutdownCtx); err != nil { _ = server.Close() return fmt.Errorf("ops: shutdown: %w", err) }'
  # …and the drain arm's terminal return, so a post-drain Serve error is not
  # swallowed by a `return nil`.
  ends_with "$fn" 'return <-errCh } } '
}

@test "go opsapi's Serve propagates a startup error instead of binding a nil handler" {
  # Deleting either error check is compile-clean — err stays read by the net.Listen
  # check below — and leaves `handler` nil. http.Server{Handler: nil} falls back to
  # DefaultServeMux, so a Config that Validate REJECTS yields a process that starts
  # happily and 404s all five endpoints, instead of the startup error the NewHandler
  # test exists to guarantee. Every other error check in the payload is
  # compile-enforced; this is the only one that can vanish silently.
  local fn; fn="$(go_flat 'Serve(')"
  contains "$fn" 'provider, metricsHandler, err := InstallMetrics(ctx) if err != nil { return err }'
  contains "$fn" 'handler, err := NewHandler(cfg, metricsHandler) if err != nil { return err }'
  # …and the validated handler must be the one the server actually serves.
  contains "$fn" 'Handler: handler'
}

@test "go opsapi gates the OTLP push exporter on a configured endpoint" {
  # No collector configured is the normal local/CI case, not an error: wiring it
  # unconditionally logs an export failure against localhost:4317 every interval
  # in every bootstrapped repo. Block-scoped, because the package doc quotes both
  # env var names while explaining the pipeline — an unscoped grep for them stays
  # green after this whole function is deleted.
  local fn; fn="$(go_flat 'newOTLPExporter(')"
  contains "$fn" 'if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" && os.Getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") == "" { return nil, nil }'
  # Signal-specific protocol wins over the general one, per the OTel spec — the
  # FALLBACK is the contract, not merely reading the signal-specific variable.
  contains "$fn" 'protocol := os.Getenv("OTEL_EXPORTER_OTLP_METRICS_PROTOCOL") if protocol == "" { protocol = os.Getenv("OTEL_EXPORTER_OTLP_PROTOCOL") }'
  # Each arm with the exporter it must build: the two constructors share a
  # signature, so swapping them between arms is compile-clean and would send every
  # grpc-configured collector HTTP and vice versa.
  contains "$fn" 'case "http/protobuf": exporter, err := otlpmetrichttp.New(ctx)'
  contains "$fn" 'case "", "grpc": exporter, err := otlpmetricgrpc.New(ctx)'
  # An unsupported protocol must fail LOUDLY; http/json in particular must not be
  # quietly routed to the protobuf exporter.
  # The arm with its return: pinning the message alone cannot tell a loud error
  # from a default that logs the string and then builds an exporter anyway —
  # which is exactly the silent fallback this assertion is named for.
  contains "$fn" 'default: return nil, fmt.Errorf("ops: unsupported OTLP protocol %q'
  lacks "$fn" '"http/json"'
}

@test "go opsapi's /info build metadata can never be empty" {
  # The checker requires non-empty build.version and build.git_sha, so both
  # fallback chains must terminate in a literal rather than "".
  local ver sha
  # Each guard with its body: a bare token cannot tell an env var that is READ
  # from one that is HONOURED. Inverting either `!= ""` empties the field the
  # checker requires; inverting the `!= "(devel)"` reports the literal "(devel)"
  # as the version; inverting the vcs.revision key test returns some unrelated
  # build setting as the commit SHA — non-empty, so conformance passes on a lie.
  ver="$(go_flat 'defaultVersion()')"
  contains "$ver" 'if v := os.Getenv("BUILD_VERSION"); v != "" { return v }'
  contains "$ver" 'bi.Main.Version != "" && bi.Main.Version != "(devel)" { return bi.Main.Version }'
  ends_with "$ver" 'return "0.0.0" } '
  sha="$(go_flat 'defaultGitSHA()')"
  contains "$sha" 'if v := os.Getenv("GIT_SHA"); v != "" { return v }'
  contains "$sha" 'if s.Key == "vcs.revision" && s.Value != "" { return s.Value }'
  ends_with "$sha" 'return "unknown" } '
}

@test "go opsapi defaults to the management port, overridable by OPS_PORT" {
  # The management/app port split is the trust boundary the README and how-to
  # both sell; defaulting to the app port would quietly publish /info. Reading
  # OPS_PORT is not enough — losing the ":" prefix makes net.Listen fail at
  # startup for every adopter who sets it.
  grep -qE '^const DefaultPort = 9090$' "$GO/opsapi.go"
  local fn; fn="$(go_flat 'DefaultAddr()')"
  contains "$fn" 'if p := os.Getenv("OPS_PORT"); p != "" { return ":" + p }'
  contains "$fn" 'return fmt.Sprintf(":%d", DefaultPort)'
}

@test "go.mod.deps declares the OTel SDK, both OTLP exporters and the Prometheus pair" {
  # Both OTLP exporters are required because the protocol env var picks between
  # them at RUNTIME — dropping one turns a config value into a build error.
  # Scoped to the require block so a mention in the file's header comment cannot
  # stand in for an actual requirement; closure is proven, since a runaway range
  # would silently restore exactly the file-wide scope being avoided.
  local reqs
  reqs="$(sed -n '/^require (/,/^)/p' "$GO/go.mod.deps")"
  ends_with "$reqs" ')'
  contains "$reqs" 'github.com/prometheus/client_golang'
  contains "$reqs" 'go.opentelemetry.io/otel/sdk/metric'
  contains "$reqs" 'go.opentelemetry.io/otel/exporters/prometheus'
  contains "$reqs" 'otlpmetricgrpc'
  contains "$reqs" 'otlpmetrichttp'
  # The root module too — otel.SetMeterProvider comes from it.
  grep -qE '^[[:space:]]*go\.opentelemetry\.io/otel v' "$GO/go.mod.deps"
}

@test "go.mod.deps keeps the otel release train coherent" {
  # The file's own comment calls a mixed set fatal ("they are one release train;
  # a mixed set fails to compile"). Asserted as a COHERENCE property rather than
  # a pinned value, so Renovate can move the train without reddening this.
  # Filtered by MODULE, not by version: filtering on ^v1. would let a module that
  # drifted onto another major drop OUT of the compared set instead of reddening
  # it — the mixed state the comment calls fatal, shipping green.
  local versions count
  versions="$(sed -n '/^require (/,/^)/p' "$GO/go.mod.deps" \
    | awk '$1 ~ /^go\.opentelemetry\.io\/otel/ && $1 !~ /exporters\/prometheus/ { print $2 }' | sort -u)"
  [ -n "$versions" ]
  count="$(printf '%s\n' "$versions" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
}

@test "go payload's README go-get line and go.mod.deps name the same modules" {
  # Two hand-maintained module lists, one per adoption path (README's `go get`,
  # go.mod.deps' require block). Nothing but this ties them together, and drift is
  # the normal outcome — a module dropped from one path fails to build only for
  # the adopters who took it.
  #
  # Both directions, and TOKEN-exact: a substring test would let the root module
  # `go.opentelemetry.io/otel` be satisfied by `go.opentelemetry.io/otel/sdk/metric`,
  # so dropping the one module otel.SetMeterProvider comes from would go unseen.
  # The README haystack is the `go get` fence alone, so a module that migrated
  # from the command into prose does not count as installed either.
  local reqs goget req_mods get_mods m
  reqs="$(sed -n '/^require (/,/^)/p' "$GO/go.mod.deps")"
  ends_with "$reqs" ')'
  goget="$(sed -n '/^go get /,/^go mod tidy$/p' "$GO/README.md")"
  ends_with "$goget" 'go mod tidy'
  req_mods="$(printf '%s\n' "$reqs" | awk '$1 ~ /^[a-z].*\// { print $1 }')"
  get_mods="$(printf '%s\n' "$goget" | tr ' \\' '\n\n' | grep '^[a-z].*/' || true)"
  [ -n "$req_mods" ]
  [ -n "$get_mods" ]
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%s\n' "$get_mods" | grep -qxF "$m"
  done <<< "$req_mods"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    printf '%s\n' "$req_mods" | grep -qxF "$m"
  done <<< "$get_mods"
}

@test "bootstrap SKILL.md renders all three go ops-api files from the GO block" {
  # Scoped twice. SKILL.md is mostly prose and already discusses go.mod.deps by
  # name, so an unscoped grep would be satisfied by a sentence even after the file
  # is dropped from the command. But scoping to "all render blocks" is not enough
  # either: the sed range restarts at every render.zsh invocation in the file, so
  # the Go paths would still match from the Java or Python block — installing the
  # payload into non-Go repos and never into Go ones.
  local block fence
  block="$(sed -n '/^\*\*Go canonical implementation (#1192)\.\*\*/,/^The remaining languages/p' "$SKILL")"
  contains "$block" 'The remaining languages'          # proves the range closed
  fence="$(printf '%s\n' "$block" | sed -n '/render.zsh" \\/,/^```$/p')"
  ends_with "$fence" '```'                             # proves the fence closed
  contains "$fence" 'languages/go/ops-api/opsapi.go'
  contains "$fence" 'languages/go/ops-api/go.mod.deps'
  contains "$fence" 'languages/go/ops-api/README.md'
}

# The next three split what was one nine-assertion test, so a failure names the
# rule that regressed rather than "the Go block".

@test "bootstrap SKILL.md keeps the Go applicability gate, including both install arms" {
  # The gate decides whether a library gets an ops surface it has no use for.
  # Both the skip arms AND the install arm matter: delete case 3 and the block has
  # two ways to skip and no way to install, with every other needle still green.
  local block
  block="$(sed -n '/^\*\*Go canonical implementation (#1192)\.\*\*/,/^The remaining languages/p' "$SKILL")"
  contains "$block" 'The remaining languages'
  contains "$block" 'A Go LIBRARY rather than a service → skip this block'
  contains "$block" 'install-or-skip choice in the Step-2'
  # A user-set interfaces that contradicts the evidence must ask, in EITHER
  # direction — the mirror case reaches case 1 first, so case 1 carries its own
  # escape and both must survive.
  contains "$block" 'CONTRADICTS the evidence is case 2, not a'
  contains "$block" 'user says library, evidence says service'
  contains "$block" 'user says service, evidence says library'
  contains "$block" 'Otherwise (a runnable Go service)** → **install**'
  # The scoping rule is what stops the gate misfiring on every polyglot repo:
  # without it a Python-detected interfaces reads as the user's declaration.
  contains "$block" 'Read `interfaces` only through its evidence'
  contains "$block" 'confirm nor contradict, in any case of this gate'
  # …and the evidence the gate actually judges on.
  contains "$block" 'runnable-service evidence'
}

@test "bootstrap SKILL.md keeps the go-directive branch and its deferral rule" {
  # This branch decides whether a repo gets a payload that 404s on every route.
  local block
  block="$(sed -n '/^\*\*Go canonical implementation (#1192)\.\*\*/,/^The remaining languages/p' "$SKILL")"
  contains "$block" 'The remaining languages'
  contains "$block" 'language_meta.go.version'
  # The guessed-default trap: a missing directive must not read as 1.26.
  contains "$block" 'version_source == "default"'
  contains "$block" 'treat a missing directive exactly as `< 1.22`'
  # Multi-module: the directive that counts is the target module's, not the root's.
  contains "$block" 'only for a single-module repo'
  contains "$block" '≥ 1.22 (parsed)'
  contains "$block" 'defer the ENTIRE payload'
  # The deferral is only reachable if the user is actually offered the bump.
  contains "$block" 'own line in the Step-2 plan'
}

@test "bootstrap SKILL.md records the not-classified-as-Go case on the LIVE path" {
  # The Go block cannot catch a go.work repo whose modules are all nested: it
  # never runs for exactly those repos. So the duty lives in Step 1, which always
  # runs — asserted THERE, because a rule stated only inside the unreachable block
  # is a rule nothing executes.
  local step1
  step1="$(sed -n '/^## Step 1: Detect Repo State/,/^## Step 2: Show the Plan/p' "$SKILL")"
  contains "$step1" '## Step 2: Show the Plan'          # proves the range closed
  contains "$step1" 'A language token can be absent because detection could not see the module'
  contains "$step1" 'nested modules before believing it'
  # BOTH Q4 branches: the rule is only correct because it distinguishes them.
  # Collapsing to the unconditional "record the line" form would, on a Go-only
  # go.work repo where Q4 asks and the user answers `go`, report the payload as
  # not installed immediately after installing it — or be read as authority to
  # skip the payload for a repo the user just confirmed is Go.
  contains "$step1" 'so Q4 will run'
  contains "$step1" 'every Go-gated block runs normally'
  contains "$step1" 'so Q4 never fires'
  contains "$step1" 'saying the repo'
}

@test "bootstrap SKILL.md keeps the Go placement and dependency-folding rules" {
  local block
  block="$(sed -n '/^\*\*Go canonical implementation (#1192)\.\*\*/,/^The remaining languages/p' "$SKILL")"
  contains "$block" 'The remaining languages'
  contains "$block" 'internal/ops/opsapi.go'
  # A multi-module repo must ask rather than guess which module gets the payload.
  contains "$block" 'if zero or several qualify, surface the choice'
  # package ops collides with any directory that already declares another package.
  # Needles must not span a line wrap — SKILL.md is hard-wrapped at 80 — but this
  # rule fits one source line, so pin the constraint rather than a phrase.
  contains "$block" 'It must land in a directory that is **empty or already'
  contains "$block" 'the module stops compiling'
  contains "$block" 'Never place `opsapi.go` without its'
  # The tidy ORDER is what keeps that rule reachable: tidy run before the file is
  # placed strips the requires it was just told to fold, and exits 0.
  contains "$block" 'place `opsapi.go` into the repo FIRST'
  contains "$block" 'never run `go mod tidy` while `opsapi.go` is still'
}
