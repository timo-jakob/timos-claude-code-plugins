#!/usr/bin/env bats
#
# Structural tests for the per-language canonical ops-api payloads (#688 Python,
# #935 Java, #1192 Go, #936 Node).
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
  NODE="$LANGS/javascript/ops-api"
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
  # still match after it moved into /health — the #1139 regression the Java and
  # Python payloads shipped and had to be fixed for (Go and Node shipped the v1.1
  # shape from the start).
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
  block="$(sed -n '/^\*\*Go canonical implementation (#1192)\.\*\*/,/^\*\*Go resilience + dependency health (#1144)\.\*\*/p' "$SKILL")"
  contains "$block" '**Go resilience + dependency health (#1144).**'          # proves the range closed
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
  block="$(sed -n '/^\*\*Go canonical implementation (#1192)\.\*\*/,/^\*\*Go resilience + dependency health (#1144)\.\*\*/p' "$SKILL")"
  contains "$block" '**Go resilience + dependency health (#1144).**'
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
  block="$(sed -n '/^\*\*Go canonical implementation (#1192)\.\*\*/,/^\*\*Go resilience + dependency health (#1144)\.\*\*/p' "$SKILL")"
  contains "$block" '**Go resilience + dependency health (#1144).**'
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
  block="$(sed -n '/^\*\*Go canonical implementation (#1192)\.\*\*/,/^\*\*Go resilience + dependency health (#1144)\.\*\*/p' "$SKILL")"
  contains "$block" '**Go resilience + dependency health (#1144).**'
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

# ---- Node payload (#936) ---------------------------------------------------
#
# Node IS in the test image (tests/Dockerfile installs it for the orval
# transformer), but the suite runs OFFLINE and the payload's five
# @opentelemetry/* dependencies are not vendored — so these are grep-based like
# their Python/Java/Go siblings. Compilation (`tsc --noEmit` under the shipped
# strict tsconfig) and live conformance (`check-ops-conformance.zsh` against a
# service built from the template) are verified out-of-band at authoring time and
# downstream by the ops-conformance CI job. What they pin is the contract shape a
# careless edit would break silently.
#
# The Go section's THREE RULES apply here verbatim, and for the same reasons:
# anchor every needle to CODE not prose (this payload documents its contract in
# the contract's own words, so a bare needle is satisfied by the doc comment even
# after the code is deleted — `ts_flatten` strips comment lines, including the
# `/** … */` block form TypeScript uses); pin a guard together with its body as
# ONE needle (asserting a condition and its consequence separately cannot tell
# `&&` from `||`, nor an arm from its transposed twin); and no needle may span a
# source line (tests/find-inert-bracket-assertions.zsh tracks quote carries per
# line). Flattened needles are one line by construction, which makes the third
# rule free — and makes every assertion immune to Prettier re-wrapping, which
# matters more here than in Go: the shipped formatter re-flows these exact
# expressions on width alone.

# ts_func <signature-prefix> — the body of one top-level TS declaration, from its
# `function` line to the closing brace in column 0. Matches `export function` too.
#
# Closure is proven by a SENTINEL the terminating branch emits, not by inspecting
# the result: opsApi.ts's own last line is `}`, so a runaway extraction that ran to
# EOF would also *end* in `}` and pass a shape check — while silently handing back
# every following function as the haystack, which is exactly what makes a `lacks`
# assertion vacuous.
ts_func() {
  local body
  body="$(awk -v sig="$1" '
    index($0, "function " sig) > 0 { inside = 1 }
    inside { print }
    inside && /^}$/ { print "//ts_func:closed"; exit }
  ' "$NODE/opsApi.ts")"
  case "$body" in
    *"//ts_func:closed") printf '%s' "${body%//ts_func:closed}" ;;
    *) echo "ts_func: 'function $1' not found, or its block never closed" >&2; return 1 ;;
  esac
}

# ts_flatten — drop whole-line comments in BOTH TypeScript comment forms (`//` and
# the `/** … */` block, whose continuation lines start with `*`), then collapse
# every run of whitespace to a single space.
ts_flatten() {
  printf '%s' "$1" | grep -v '^[[:space:]]*\(//\|\*\|/\*\)' | tr -s ' \t\n' ' '
}

ts_flat() { local b; b="$(ts_func "$1")" || return 1; ts_flatten "$b"; }

@test "node ops-api payload files exist at the SKILL render paths" {
  [ -f "$NODE/opsApi.ts" ]
  [ -f "$NODE/package.json.deps" ]
  [ -f "$NODE/README.md" ]
}

@test "ts_func proves closure rather than inferring it (self-test)" {
  # Rule 3's premise: without the sentinel, a signature that never closes returns
  # everything to EOF and every `lacks` built on it becomes vacuous.
  run ! ts_func 'thisDeclarationDoesNotExist('
}

@test "node opsApi REGISTERS all five ops endpoints, each with what it answers" {
  # Registration alone proves nothing about what a route answers, and in a `switch`
  # a case label is one line away from its body — so each needle carries the case
  # TOGETHER with the response it writes. The module doc quotes every path verbatim
  # while explaining the contract, so a bare path needle stays green after the
  # route is deleted; ts_flat strips those comments.
  local h; h="$(ts_flat 'createOpsHandler(')"
  contains "$h" 'case "/info": writeJson(req, res, 200, { build: { version: cfg.version, git_sha: cfg.gitSha }, api: cfg.servedMajors, } satisfies InfoBody); return;'
  contains "$h" 'case "/health/live": writeJson(req, res, 200, { status: STATUS_OK }); return;'
  contains "$h" 'case "/metrics": metricsHandler(req, res); return;'
  contains "$h" 'case "/health/ready": {'
  contains "$h" 'case "/health": {'
  contains "$h" 'default: writeJson(req, res, 404, { error: "not found", path }); return;'
}

@test "node opsApi's liveness probe is 200-and-dependency-free" {
  # Liveness must never consult a dependency: a failing liveness RESTARTS the pod,
  # so wiring it to dependency state turns a transient outage into a restart storm
  # — the anti-pattern the module doc, README and how-to all warn about. Pinned as
  # the whole case plus the label that follows it, because the surrounding cases DO
  # consult dependencies and a file-wide `lacks` could not tell whose body a call
  # belonged to.
  local h; h="$(ts_flat 'createOpsHandler(')"
  contains "$h" 'case "/health/live": writeJson(req, res, 200, { status: STATUS_OK }); return; case "/health/ready"'
}

@test "node opsApi's readiness probe answers 200 when ready and 503 when not" {
  # BOTH arms, glued to the case that owns them. A file-wide needle for the 503
  # would still match after it moved into /health — the #1139 regression the Java
  # and Python payloads shipped and had to be fixed for (Go and Node shipped the
  # v1.1 shape from the start).
  local h; h="$(ts_flat 'createOpsHandler(')"
  contains "$h" 'if (ready) { writeJson(req, res, 200, { status: STATUS_OK }); return; } writeJson(req, res, 503, { status: STATUS_DOWN }); return;'
  # The guarded call AND its fail-closed catch, as one needle: a catch rewritten to
  # `ready = true` fails OPEN and keeps a broken pod in rotation — the exact
  # inversion of this test's title — while leaving a bare `catch` needle green.
  contains "$h" 'let ready = false; try { ready = isReady(cfg, componentsSnapshot(cfg)); } catch { ready = false; }'
}

@test "node opsApi answers /health with 200 and confines 503 to the readiness probe" {
  # #1139 in Node form: /health carries the verdict in the BODY and must never 503.
  # Pinned three ways — the aggregate write, the fail-closed catch, and exactly one
  # 503 in the whole file.
  local h; h="$(ts_flat 'createOpsHandler(')"
  contains "$h" 'let body: HealthBody = { status: STATUS_DOWN }; try { const components = componentsSnapshot(cfg); body = { status: aggregate(cfg, components), ...(components !== undefined ? { components } : {}) }; } catch { body = { status: STATUS_DOWN }; } writeJson(req, res, 200, body); return;'
  # Exactly ONE 503 in the whole module — counted over the COMMENT-STRIPPED source
  # (rule 1). The prose explains the probe/body split at length and mentions 503
  # four more times, so a count over the raw file would be pinned to the
  # documentation rather than to the code, and would drift on any edit to either.
  local stripped n
  stripped="$(ts_flatten "$(cat "$NODE/opsApi.ts")")"
  n="$(printf '%s' "$stripped" | grep -o '503' | wc -l | tr -d '[:space:]')"
  [ "$n" -eq 1 ]
}

@test "node opsApi omits components entirely when no dependency source is wired" {
  # The spread is what keeps an unwired service a valid ops-api v1.0 body: a plain
  # `components` property would serialize away as `undefined` today but emit
  # `"components": {}` the moment the guard below is relaxed — and `{}` announces a
  # v1.1 body that then reports nothing.
  local h; h="$(ts_flat 'createOpsHandler(')"
  contains "$h" '...(components !== undefined ? { components } : {})'
  local fn; fn="$(ts_flat 'componentsSnapshot(')"
  contains "$fn" 'if (cfg.dependencies === undefined) { return undefined; }'
  contains "$fn" 'if (raw === undefined || raw === null) { return undefined; }'
  contains "$fn" 'if (entries.length === 0) { return undefined; }'
  contains "$fn" 'out[name] = onContract(d);'
  # The coerced object must be what comes BACK: `return raw` type-checks under a
  # cast and would hand every hand-written source's values to /health and isReady
  # uncoerced — the under-reporting the onContract test exists to prevent, through
  # the one door that test cannot see.
  ends_with "$fn" 'return out; } '
}

@test "node opsApi fails readiness ONLY on a hard dependency that is down" {
  # The change's marquee contract, and every inversion of it type-checks:
  # KIND_HARD->KIND_SOFT sheds all traffic on a soft outage, COMPONENT_DOWN->UP
  # reports a healthy hard dependency unready, and dropping the readiness() early
  # return keeps a draining pod in rotation. Guard and body in ONE needle: split
  # apart, `||` would satisfy both while failing readiness on a soft outage.
  local fn; fn="$(ts_flat 'isReady(')"
  contains "$fn" 'if (!cfg.readiness()) { return false; }'
  contains "$fn" 'if (d.kind === KIND_HARD && d.status === COMPONENT_DOWN) { return false; }'
  ends_with "$fn" 'return true; } '
  # A soft dependency must never reach the readiness verdict at all.
  lacks "$fn" 'KIND_SOFT'
}

@test "node opsApi floors the /health aggregate the way the checker demands" {
  # hard+down => down; any other down/degraded => degraded; internal state seeds it
  # so the over-reporting hook the contract mandates cannot be capped away.
  local fn; fn="$(ts_flat 'aggregate(')"
  contains "$fn" 'const declared: unknown = cfg.internalStatus();'
  # BOTH clauses in ONE needle, in order. This is a first-match if/else chain —
  # exchanging the two arms (each still glued to its own worseOf call) type-checks
  # and leaves two separate needles green, while a fully-down HARD dependency then
  # matches the `||` arm first and floors the aggregate at "degraded" instead of
  # "down". That is the marquee contract inverted, in the under-reporting direction
  # the payload calls forbidden.
  contains "$fn" 'if (d.status === COMPONENT_DOWN && d.kind === KIND_HARD) { status = worseOf(status, STATUS_DOWN); } else if (d.status === COMPONENT_DOWN || d.status === COMPONENT_DEGRADED) { status = worseOf(status, STATUS_DEGRADED); }'
  # An off-contract internal status must fail toward severity — with its guard,
  # since inverting the ternary maps every VALID status to "down" instead.
  contains "$fn" 'let status: AggregateStatus = isAggregateStatus(declared) ? declared : STATUS_DOWN;'
  # …and the predicate that ternary rests on. Loosening it to
  # `typeof value === "string"` compiles under the shipped strict config and lets a
  # hook returning the COMPONENTS vocabulary ("up") through as an AggregateStatus;
  # STATUS_RANK["up"] is then undefined, every worseOf comparison is false, and the
  # dependency floor is discarded — /health reports "up" through a hard-down
  # outage, the marquee under-reporting failure, with the needle above still green.
  local pred; pred="$(ts_flat 'isAggregateStatus(')"
  contains "$pred" 'return value === STATUS_OK || value === STATUS_DEGRADED || value === STATUS_DOWN;'
  # And the floored value must be what comes back: `return declared as
  # AggregateStatus` type-checks and reports "ok" through a hard-down outage with
  # every needle above still green.
  ends_with "$fn" 'return status; } '
}

@test "node opsApi's severity ordering is worst-wins" {
  # Inverting the comparator makes best-wins the rule, which reports "ok" during a
  # hard-down outage. Asserting the condition alone cannot see that: the inversion
  # is done by swapping the two branches, so both are in the needle.
  local f; f="$(ts_flatten "$(cat "$NODE/opsApi.ts")")"
  contains "$f" 'const STATUS_RANK: Record<AggregateStatus, number> = { [STATUS_OK]: 0, [STATUS_DEGRADED]: 1, [STATUS_DOWN]: 2, };'
  local fn; fn="$(ts_flat 'worseOf(')"
  contains "$fn" 'return STATUS_RANK[a] >= STATUS_RANK[b] ? a : b;'
}

@test "node opsApi coerces an off-contract component toward severity, never health" {
  # TypeScript's types are ERASED at runtime, so a JS caller — or a value parsed
  # from JSON — really can supply "ok"/"Hard". Read literally by isReady and
  # aggregate, that would be a healthy soft dependency: silent under-reporting. The
  # accepted-value list is part of each needle: dropping COMPONENT_UP from it
  # coerces every HEALTHY component to down, and dropping KIND_SOFT makes every
  # soft dependency hard, which sheds traffic on a soft outage.
  local fn; fn="$(ts_flat 'onContract(')"
  contains "$fn" 'const status: ComponentStatus = d.status === COMPONENT_UP || d.status === COMPONENT_DEGRADED || d.status === COMPONENT_DOWN ? d.status : COMPONENT_DOWN;'
  contains "$fn" 'const kind: DependencyKind = d.kind === KIND_HARD || d.kind === KIND_SOFT ? d.kind : KIND_HARD;'
  # An off-contract breaker is DROPPED, not coerced: the checker rejects a
  # present-but-invalid breaker and accepts an absent one. Pinned with its guard,
  # because assigning unconditionally is what would ship the invalid value.
  contains "$fn" 'if (d.breaker === BREAKER_CLOSED || d.breaker === BREAKER_OPEN || d.breaker === BREAKER_HALF_OPEN) { out.breaker = d.breaker; }'
  # `since` is the ONLY free-form field, so it is the only way a source could
  # smuggle in a value JSON.stringify throws on mid-response. The typeof guard is
  # what closes that, not tidiness.
  contains "$fn" 'if (typeof d.since === "string" && d.since !== "") { out.since = d.since; }'
  # The non-object guard, which is the branch that keeps a TypeError out of
  # /health entirely. DependencyHealthSource is an interface a service hand-writes
  # and TS types are ERASED, so a source really can return {"orders-db": null}.
  # Without this, `d.status` throws, /health's catch converts that into a blanket
  # "down" for a service whose other dependencies are fine, and /health/ready 503s
  # — a fail-closed shed on ONE malformed entry, not the coerce-toward-severity
  # contract every needle above describes.
  contains "$fn" 'const d: Partial<Record<keyof Dependency, unknown>> = typeof raw === "object" && raw !== null ? (raw as Partial<Record<keyof Dependency, unknown>>) : {};'
  # And the coerced object must be what comes BACK: `return raw as Dependency`
  # type-checks and hands every uncoerced value straight to /health and isReady,
  # through the one door the needles above cannot see.
  ends_with "$fn" 'return out; } '
}

@test "node opsApi defaults to the management port, overridable by OPS_PORT" {
  # DEFAULT_PORT alone (pinned with the other constants) proves nothing about the
  # override: dropping the process.env read hard-codes 9090 and every needle in the
  # suite stays green, while $OPS_PORT — which the ops-conformance job and the
  # acceptance tier both set — silently stops working.
  local fn; fn="$(ts_flat 'defaultPort(')"
  contains "$fn" 'const raw = process.env.OPS_PORT;'
  contains "$fn" 'if (raw === undefined || raw === "") { return DEFAULT_PORT; }'
  # The validation WITH its throw, in one needle. A malformed value must be a
  # startup error, not a silent fall back to 9090 — the README says so, and the
  # silent version binds a port the operator did not ask for and then passes
  # conformance on it.
  contains "$fn" 'if (!Number.isInteger(port) || port < 0 || port > 65535) { throw new Error(`ops: OPS_PORT "${raw}" is not a valid port (want an integer 0-65535)`); }'
  ends_with "$fn" 'return port; } '
  # …and serve() must actually USE it as the default. A hard-coded 9090 here
  # bypasses the whole function with every needle above still green.
  local s; s="$(ts_flat 'serve(')"
  contains "$s" 'export async function serve(config: OpsConfig, port: number = defaultPort())'
}

@test "node opsApi pins every contract spelling, in both vocabularies" {
  # Two vocabularies, one letter of difference in consequence: the aggregate is
  # "ok" (renaming it to "up" breaks every ops-api v1.0 consumer) while a component
  # is "up". KIND_HARD = "Hard" type-checks — the union is derived FROM the
  # constant — and silently disarms the readiness hinge against every real source;
  # a breaker value outside the enum is rejected outright by
  # check-ops-conformance.zsh.
  grep -qF 'export const STATUS_OK = "ok";' "$NODE/opsApi.ts"
  grep -qF 'export const STATUS_DEGRADED = "degraded";' "$NODE/opsApi.ts"
  grep -qF 'export const STATUS_DOWN = "down";' "$NODE/opsApi.ts"
  grep -qF 'export const COMPONENT_UP = "up";' "$NODE/opsApi.ts"
  grep -qF 'export const COMPONENT_DEGRADED = "degraded";' "$NODE/opsApi.ts"
  grep -qF 'export const COMPONENT_DOWN = "down";' "$NODE/opsApi.ts"
  grep -qF 'export const KIND_HARD = "hard";' "$NODE/opsApi.ts"
  grep -qF 'export const KIND_SOFT = "soft";' "$NODE/opsApi.ts"
  grep -qF 'export const BREAKER_CLOSED = "closed";' "$NODE/opsApi.ts"
  grep -qF 'export const BREAKER_OPEN = "open";' "$NODE/opsApi.ts"
  grep -qF 'export const BREAKER_HALF_OPEN = "half_open";' "$NODE/opsApi.ts"
  grep -qF 'export const LIFECYCLE_ACTIVE = "active";' "$NODE/opsApi.ts"
  grep -qF 'export const LIFECYCLE_DEPRECATED = "deprecated";' "$NODE/opsApi.ts"
  grep -qF 'export const DEFAULT_PORT = 9090;' "$NODE/opsApi.ts"
}

@test "node opsApi serves the wire keys the conformance checker reads" {
  # /info's build block is the one place a JS-idiomatic rename (git_sha -> gitSha)
  # is both natural and fatal: the checker reads `.build.git_sha`. The optional
  # markers matter as much: making `sunset` required would force every active major
  # to carry the date the contract forbids, and making `components` required would
  # emit it on a v1.0 body.
  local f; f="$(ts_flatten "$(cat "$NODE/opsApi.ts")")"
  contains "$f" 'interface InfoBody { build: { version: string; git_sha: string }; api: ApiMajor[]; }'
  contains "$f" 'interface HealthBody { status: AggregateStatus; components?: Record<string, Dependency>; }'
  contains "$f" 'export interface ApiMajor { major: number; lifecycle: Lifecycle; sunset?: string; }'
  contains "$f" 'export interface Dependency { status: ComponentStatus; kind: DependencyKind; breaker?: BreakerState; since?: string; }'
}

@test "node opsApi enforces both halves of the lifecycle-sunset invariant (RFC 8594)" {
  # Pinning the messages alone cannot discriminate an inverted operator or the two
  # messages transposed between arms — after which validateConfig rejects exactly
  # what it should accept. So pin each guard TOGETHER with its arm and message.
  local fn; fn="$(ts_flat 'validateConfig(')"
  contains "$fn" 'if (m.lifecycle === LIFECYCLE_DEPRECATED) { if (m.sunset === undefined || m.sunset === "") { throw new Error(`ops: deprecated major ${String(m.major)} needs a sunset date (RFC 8594)`); }'
  contains "$fn" 'else if (m.lifecycle === LIFECYCLE_ACTIVE) { if (m.sunset !== undefined && m.sunset !== "") { throw new Error(`ops: active major ${String(m.major)} must not carry a sunset date`); }'
}

@test "node opsApi's validateConfig rejects the other three malformed lifecycle tables" {
  # Each exists so the mistake fails at STARTUP instead of in a downstream repo's
  # ops-conformance job — and for the duplicate and the active-with-sunset case,
  # instead of nowhere at all. Guards included: `m.major < 1` flipped to `> 1`
  # rejects every legitimate major, and `seen.has` flipped to `!seen.has` rejects
  # every FIRST declaration, so no service could boot.
  local fn; fn="$(ts_flat 'validateConfig(')"
  contains "$fn" 'if (!Number.isInteger(m.major) || m.major < 1) { throw new Error(`ops: api major ${String(m.major)} is invalid (want an integer >= 1)`); }'
  contains "$fn" 'if (seen.has(m.major)) { throw new Error(`ops: api major ${String(m.major)} is declared twice`); }'
  contains "$fn" 'seen.add(m.major);'
  contains "$fn" 'else { throw new Error( `ops: major ${String(m.major)} has an invalid lifecycle'
}

@test "node opsApi resolves its defaults so an unconfigured config still conforms" {
  # Four contracts, each type-clean to break: an unset readiness = always ready; an
  # unset internalStatus = ok (without it the off-contract coercion would report
  # every aggregate "down"); an empty servedMajors table would fail conformance with
  # an empty /info api[]; and the defensive COPY is what stops a caller's later push
  # from changing what /info serves AFTER validateConfig approved it.
  local fn; fn="$(ts_flat 'resolveConfig(')"
  contains "$fn" 'readiness: config.readiness ?? (() => true),'
  contains "$fn" 'internalStatus: config.internalStatus ?? (() => STATUS_OK),'
  contains "$fn" 'const servedMajors: ApiMajor[] = config.servedMajors !== undefined && config.servedMajors.length > 0 ? config.servedMajors.map((m) => ({ ...m })) : [{ major: 1, lifecycle: LIFECYCLE_ACTIVE }];'
  contains "$fn" 'version: resolveVersion(config.version),'
  contains "$fn" 'gitSha: resolveGitSha(config.gitSha),'
  # The whole returned literal, as ONE needle. Two omissions here are invisible
  # otherwise, and both are type-clean:
  #
  #   * dropping `dependencies: config.dependencies,` — ResolvedConfig.dependencies
  #     is optional, so it compiles — makes componentsSnapshot return undefined for
  #     EVERY service. The entire ops-api v1.1 feature silently reverts to v1.0: no
  #     `components` on /health, the hard-dependency readiness hinge permanently
  #     disarmed, and check-ops-conformance.zsh passes the v1.0 body. That is this
  #     change's marquee contract, defeated by a one-line deletion.
  #   * returning `config.servedMajors ?? []` instead of the local discards both
  #     the defensive copy pinned above and the default active major, shipping
  #     `"api": []` on /info — a conformance failure — with the declaration needle
  #     verbatim and green.
  ends_with "$fn" 'return { version: resolveVersion(config.version), gitSha: resolveGitSha(config.gitSha), servedMajors, readiness: config.readiness ?? (() => true), dependencies: config.dependencies, internalStatus: config.internalStatus ?? (() => STATUS_OK), }; } '
}

@test "node opsApi refuses to build a handler without validation or the metrics half" {
  # /metrics is part of the contract, so a missing handler is a startup error rather
  # than a 404 the ops-conformance job discovers downstream. Dropping the
  # validateConfig call likewise defers every lifecycle mistake to CI, and dropping
  # resolveConfig serves an unconfigured config's undefined values.
  local fn; fn="$(ts_flat 'createOpsHandler(')"
  contains "$fn" 'validateConfig(config); if (typeof metricsHandler !== "function") { throw new Error("ops: metricsHandler is required (/metrics is part of the ops contract)"); } const cfg = resolveConfig(config);'
}

@test "node opsApi's build.version falls back but build.git_sha FAILS FAST" {
  # The asymmetry IS the contract (#936): version has a truthful fallback chain,
  # git_sha has none, because Node stamps no VCS revision into a build and every
  # candidate placeholder is either a lie or a conformance failure. A `return
  # "unknown"` in place of the throw type-checks and is exactly the regression.
  # Each arm is pinned WITH its guard and its return, per this section's rule 2. A
  # bare `const fromEnv = process.env.BUILD_VERSION;` needle proves the variable is
  # READ, never that it is HONOURED: rewriting the guard to
  # `if (fromEnv !== undefined)` compiles clean (fromEnv stays used, so
  # noUnusedLocals does not fire) and makes BUILD_VERSION="" serve an empty
  # build.version, which check-ops-conformance.zsh rejects — with a token needle
  # still green. The `configured` arm is the first link of the documented chain and
  # the acceptance fixture never sets OpsConfig.version, so this is its only cover.
  local v; v="$(ts_flat 'resolveVersion(')"
  contains "$v" 'if (configured !== undefined && configured !== "") { return configured; }'
  contains "$v" 'const fromEnv = process.env.BUILD_VERSION; if (fromEnv !== undefined && fromEnv !== "") { return fromEnv; }'
  ends_with "$v" 'return readPackageVersion() ?? "0.0.0"; } '
  local g; g="$(ts_flat 'resolveGitSha(')"
  # Same treatment, and here the empty-string half of the guard is the whole
  # contract: dropping it makes GIT_SHA="" serve an empty build.git_sha instead of
  # throwing — the placeholder this test is named for, arriving through the one
  # door the throw needle below cannot see.
  contains "$g" 'if (configured !== undefined && configured !== "") { return configured; }'
  contains "$g" 'const fromEnv = process.env.GIT_SHA; if (fromEnv !== undefined && fromEnv !== "") { return fromEnv; }'
  contains "$g" 'throw new Error( "ops: GIT_SHA is not set and OpsConfig.gitSha was not supplied'
  # The throw must be TERMINAL: a fallback added after it would be dead code, but
  # one added before it silently restores the placeholder this contract forbids.
  ends_with "$g" 'deploy time.", ); } '
  lacks "$g" 'return "unknown"'
}

@test "node opsApi's package.json walk is bounded, and never reports an empty version" {
  # The two functions BEHIND resolveVersion's last arm. The test above stops at
  # the `readPackageVersion() ?? "0.0.0"` call site, which cannot see any of this.
  local r; r="$(ts_flat 'readVersionField(')"
  # The empty-string half of the guard is the load-bearing one, and `?? "0.0.0"`
  # does NOT rescue it — "" is not nullish. Drop it and a service whose
  # package.json declares "version": "" serves an empty build.version, which
  # check-ops-conformance.zsh rejects, with the call-site needle still green.
  contains "$r" 'if (typeof version === "string" && version !== "") { return version; }'
  # Missing, unreadable or malformed must KEEP WALKING, not fail startup: turning
  # the catch into a rethrow makes one stray broken package.json anywhere up the
  # tree a boot failure for a service whose own manifest is fine. Pinned as one
  # needle with the no-version-field fallthrough that precedes it, so both exits
  # from this function are asserted to be `undefined`.
  ends_with "$r" 'return undefined; } catch { return undefined; } } '
  local p; p="$(ts_flat 'readPackageVersion(')"
  # The bound and the root stop, each with its body. Without the bound a placement
  # outside any package walks toward the filesystem root on every startup; without
  # the `parent === dir` stop the loop spins on "/" until the bound saves it.
  contains "$p" 'for (let depth = 0; depth < 16; depth += 1) {'
  contains "$p" 'const parent = dirname(dir); if (parent === dir) { break; }'
  ends_with "$p" 'return undefined; } '
}

@test "node opsApi installs ONE OTel provider and binds NO second port" {
  # preventServerStart is the single flag standing between one listener and two:
  # without it the Prometheus exporter starts its own server on 9464, a silent
  # second listener on a management surface. The global registration is the other
  # silent one — without it every metrics.getMeter instrument a service records
  # goes to a no-op and /metrics is empty, yet still conforming.
  local fn; fn="$(ts_flat 'installMetrics(')"
  contains "$fn" 'const pullExporter = new PrometheusExporter({ preventServerStart: true });'
  contains "$fn" 'const readers: MetricReader[] = [pullExporter];'
  # The push reader with its whole hinge: dropping the `!== undefined` half wraps an
  # undefined exporter for every service with no collector — the default state of
  # every bootstrapped repo.
  contains "$fn" 'const pushExporter = newOtlpExporter(); if (pushExporter !== undefined) { readers.push(new PeriodicExportingMetricReader({ exporter: pushExporter })); }'
  # The assembled readers must actually reach the provider: `new MeterProvider({})`
  # type-checks (readers is still read by the push above) and yields a provider with
  # NO readers — /metrics serves an empty exposition and OTLP never fires, while the
  # surface still passes conformance.
  contains "$fn" 'const provider = new MeterProvider({ readers }); metrics.setGlobalMeterProvider(provider);'
  # …and /metrics must be served from the exporter's OWN handler, not a second server.
  contains "$fn" 'metricsHandler: (req, res) => { pullExporter.getMetricsRequestHandler(req, res); },'
}

@test "node opsApi selects the OTLP protocol loudly, and skips OTLP when unconfigured" {
  # No endpoint is the NORMAL local/CI case and must not be an error; an
  # unrecognised protocol must be an error rather than a silent fallback that hands
  # a JSON-expecting collector protobuf every export interval.
  local fn; fn="$(ts_flat 'newOtlpExporter(')"
  contains "$fn" 'const endpoint = process.env.OTEL_EXPORTER_OTLP_METRICS_ENDPOINT ?? process.env.OTEL_EXPORTER_OTLP_ENDPOINT;'
  contains "$fn" 'if (endpoint === undefined || endpoint === "") { return undefined; }'
  # The signal-specific twin must WIN — reversing the ?? operands makes the general
  # variable override the specific one, the opposite of the OTel spec.
  contains "$fn" 'const protocol = process.env.OTEL_EXPORTER_OTLP_METRICS_PROTOCOL ?? process.env.OTEL_EXPORTER_OTLP_PROTOCOL ?? "";'
  contains "$fn" 'case "http/protobuf": return new OTLPProtoMetricExporter();'
  contains "$fn" 'case "": case "grpc": return new OTLPGrpcMetricExporter();'
  contains "$fn" 'default: throw new Error(`ops: unsupported OTLP protocol "${protocol}" (want grpc or http/protobuf)`);'
  # "http/json" must reach the DEFAULT arm, never an arm of its own. The JS SDK's
  # metrics exporters do not implement it, so routing it to the protobuf exporter
  # — a one-line addition that type-checks and leaves every needle above green,
  # since a new case is matched before the default — would hand a JSON-expecting
  # collector protobuf and fail every export interval while the operator believes
  # the config was accepted. ts_flat has already stripped the doc comment that
  # discusses it, so this is anchored to code.
  lacks "$fn" '"http/json"'
}

@test "node opsApi bounds every management-server timeout and drains on shutdown" {
  # An unbounded management server is a Slowloris target, and the probes it answers
  # must never be starved by a stuck connection. A bare `headersTimeout` needle
  # would be satisfied by 0, which in Node DISABLES the timeout — re-creating the
  # exposure the field exists to close — so pin the values.
  local fn; fn="$(ts_flat 'serve(')"
  contains "$fn" 'server.headersTimeout = 5_000;'
  contains "$fn" 'server.requestTimeout = 10_000;'
  contains "$fn" 'server.keepAliveTimeout = 60_000;'
  # A startup failure must not leak the provider's OTLP export timer into a process
  # that is about to report a failure — on BOTH failure paths.
  contains "$fn" 'try { handler = createOpsHandler(config, metricsHandler); } catch (err) { await provider.shutdown(); throw err; }'
  # The VALIDATED handler must be the one the server actually serves.
  # `createServer(metricsHandler)` type-checks — both are node:http request
  # handlers — keeps the try/catch, all three timeouts, the listening promise and
  # the drain needles green, and ships a management port that serves the Prometheus
  # exposition on every path: no /info, no probes, no 404/405 arms. Only the
  # acceptance tier would see it, and that tier is deliberately not in this gate.
  contains "$fn" 'const server = createServer(handler);'
  contains "$fn" '}).catch(async (err: unknown) => { await provider.shutdown(); throw err; });'
  # ORDER is the contract: drain the server, THEN flush the provider. Swapping them
  # leaves the still-serving /metrics route reading a dead reader for the length of
  # the drain.
  contains "$fn" 'server.close((err) => { if (err) { reject(err); return; } resolve(); }); server.closeIdleConnections(); }); await provider.shutdown();'
  # closeIdleConnections makes the drain's termination EXPLICIT rather than
  # runtime-dependent: on a Node where close() waits out every existing connection,
  # an idle keep-alive socket left by a probe or a scraper lingers for the full 60s
  # keepAliveTimeout pinned above, so SIGTERM appears to hang and a rolling update
  # sits in "terminating" for a minute after its last request. (Measured on Node 26,
  # close() already releases those sockets — which is why the acceptance tier
  # cannot discriminate this line, and why the guard lives here instead.) Pinned
  # WITH the close call, in order: hoisting it above close() would destroy idle
  # sockets while the server is still accepting new ones.
  contains "$fn" 'server.closeIdleConnections();'
}

@test "node opsApi resolves serve() only once the surface is LISTENING" {
  # Resolving early turns a port clash into an unhandled 'error' event later, rather
  # than a rejection the caller can log and exit on. The REMOVALS are as
  # load-bearing as the registrations: leaving the loser attached leaks a handler
  # per call, and an 'error' arriving after resolve crashes the process.
  local fn; fn="$(ts_flat 'serve(')"
  # The `await` is the whole contract, and it is ONE token. Deleting it is
  # tsc-clean under the shipped strict config (noUnusedLocals does not fire, and
  # no-floating-promises is not in the shipped eslint.config.js) and leaves every
  # needle below green — while serve() returns before the port is bound, so a port
  # clash becomes an unhandled rejection that crashes the process instead of the
  # rejection this test's title says the caller gets. Pinned WITH the executor's
  # opening line, because the bare word appears elsewhere in the function.
  contains "$fn" 'await new Promise<void>((resolve, reject) => { const onError = (err: Error): void => {'
  contains "$fn" 'const onError = (err: Error): void => { server.removeListener("listening", onListening); reject(err); };'
  contains "$fn" 'const onListening = (): void => { server.removeListener("error", onError); resolve(); };'
  contains "$fn" 'server.once("error", onError); server.once("listening", onListening); server.listen(port);'
}

@test "node opsApi routes on the RAW path: trailing slash normalized, %2F is not" {
  # ServeMux-equivalent behaviour by hand. Without the trim, a probe or curl with a
  # trailing slash 404s against a conforming service; WITH a decode, "/health%2F"
  # would route to /health and %2F would mean one thing here and another everywhere
  # else.
  local n; n="$(ts_flat 'normalizePath(')"
  contains "$n" 'if (path.length > 1 && path.endsWith("/")) { const trimmed = path.replace(/\/+$/, ""); return trimmed === "" ? "/" : trimmed; }'
  # The DEFAULT branch — every request WITHOUT a trailing slash, i.e. every
  # conforming probe and every checker call. Deleting it would 404 the whole surface
  # while every needle above stayed green.
  ends_with "$n" 'return path; } '
  local p; p="$(ts_flat 'pathOf(')"
  contains "$p" 'const q = target.indexOf("?");'
  ends_with "$p" 'return q === -1 ? target : target.slice(0, q); } '
  # No decoding anywhere on the routing path.
  lacks "$p" 'decodeURI'
  lacks "$n" 'decodeURI'
  # …and the line that WIRES both into dispatch. Both helpers can be pinned
  # perfectly and still be dead code: `const path = req.url ?? "/"` type-checks,
  # leaves them present, keeps every needle above green, and re-introduces both
  # regressions this test names — "/health/" 404s against a conforming service,
  # and so does any request carrying a query string, which the checker sends.
  local h; h="$(ts_flat 'createOpsHandler(')"
  contains "$h" 'const path = normalizePath(pathOf(req.url));'
}

@test "node opsApi answers a non-GET with 405 and an Allow header, not a bare 404" {
  # A management surface that silently 404s a POST reads as "wrong path" rather than
  # "wrong method". HEAD must be allowed alongside GET: it is what a probe or a
  # scraper may use, and rejecting it would fail those callers.
  local h; h="$(ts_flat 'createOpsHandler(')"
  contains "$h" 'if (req.method !== "GET" && req.method !== "HEAD") { res.setHeader("Allow", "GET, HEAD"); writeJson(req, res, 405, { error: "method not allowed", method: req.method ?? "", }); return; }'
}

@test "node opsApi's writeJson sets the code and the content type, and skips a HEAD body" {
  # The single writer for every ops response. Dropping `res.statusCode = status`
  # makes every response 200 — including the readiness 503 that three other tests go
  # to some length to pin, silently defeating the probe.
  local fn; fn="$(ts_flat 'writeJson(')"
  # ORDER is the contract, so these are one needle: Node ignores a setHeader issued
  # after the body is written, and the checker inspects content-type on /metrics
  # only, so that regression would be silent downstream as well as here.
  contains "$fn" 'res.statusCode = status; res.setHeader("Content-Type", "application/json"); res.setHeader("Content-Length", Buffer.byteLength(body));'
  # The WHOLE catch arm, per rule 2 — a needle stopping at `body =` asserts only
  # that something is assigned. Dropping `status = 500` alone answers a
  # serialization failure with the caller's own code (a 200 carrying a down body),
  # and dropping the literal serves an empty one. Double-quoted so the single
  # quotes inside stay on one source line.
  contains "$fn" "try { body = JSON.stringify(payload); } catch { body = '{\"status\":\"down\"}'; status = 500; }"
  # node:http does NOT suppress a HEAD body for us the way Go's net/http does.
  contains "$fn" 'if (req.method === "HEAD") { res.end(); return; } res.end(body);'
}

@test "node opsApi imports node:http and NO web framework, and no breaker library" {
  # The payload must drop into an Express service, a Fastify service and a service
  # with no framework alike — and the dependency-health binding is an INTERFACE, so
  # the ops surface never grows a breaker on its import path (#1145 owns that).
  # Asserted on the source AND on the dependency fragment: an import can be added
  # without a manifest entry (resolving via a hoisted transitive dep), and a
  # manifest entry can be added ahead of the import.
  grep -qF 'from "node:http"' "$NODE/opsApi.ts"
  # `run <cmd>; [ "$status" -eq 1 ]`, never `run ! <cmd>`: bats' `run !` accepts
  # ANY non-zero status, and grep exits 2 on an unreadable file or an uncompilable
  # ERE. A typo in one of these alternations, or a rename of opsApi.ts, would
  # otherwise leave all three assertions permanently green while matching nothing.
  # tests/assertions.bash states this rule for the repo.
  run grep -qE 'from "(express|fastify|koa|hapi|@nestjs/|@hapi/)' "$NODE/opsApi.ts"
  [ "$status" -eq 1 ]
  run grep -qE 'from "(opossum|cockatiel|brakes)"' "$NODE/opsApi.ts"
  [ "$status" -eq 1 ]
  # The manifest half asks jq for the dependency KEYS rather than grepping the
  # raw text, so the `//` prose block (which names several of these packages)
  # can neither satisfy nor trip it.
  # `any(...)` so the no-match case is a FALSE output (jq -e exit 1), not an empty
  # one (exit 4) — the difference between asserting "found nothing" and asserting
  # "produced nothing", which a filter expression would have made indistinguishable
  # from a jq that failed to run.
  run jq -e '(.dependencies + .devDependencies) | keys
             | any(test("^(express|fastify|koa|@nestjs/|@hapi/|hapi|opossum|cockatiel|brakes)"))' \
    "$NODE/package.json.deps"
  [ "$status" -eq 1 ]
}

@test "node ops-api fragment declares the OTel set, ESM, and stays valid JSON" {
  # It is merged into a real package.json, so it must parse — the `//` comment key
  # is npm's own convention precisely so the prose does not cost that.
  run jq -e . "$NODE/package.json.deps"
  [ "$status" -eq 0 ]
  run jq -er '.dependencies["@opentelemetry/api"]' "$NODE/package.json.deps"
  [ "$status" -eq 0 ]
  run jq -er '.dependencies["@opentelemetry/sdk-metrics"]' "$NODE/package.json.deps"
  [ "$status" -eq 0 ]
  run jq -er '.dependencies["@opentelemetry/exporter-prometheus"]' "$NODE/package.json.deps"
  [ "$status" -eq 0 ]
  # BOTH OTLP exporters: the protocol is selected at RUNTIME, so dropping one turns
  # a config value into a module-resolution crash on startup.
  run jq -er '.dependencies["@opentelemetry/exporter-metrics-otlp-grpc"]' "$NODE/package.json.deps"
  [ "$status" -eq 0 ]
  run jq -er '.dependencies["@opentelemetry/exporter-metrics-otlp-proto"]' "$NODE/package.json.deps"
  [ "$status" -eq 0 ]
  # ESM is not optional: the payload reads import.meta.url.
  run jq -er '.type' "$NODE/package.json.deps"
  [ "$status" -eq 0 ]
  [ "$output" = "module" ]
}

@test "node ops-api payload obeys the printWidth the scaffold's own Prettier config sets" {
  # The payload lands in a repo that ALSO gets .prettierrc.json (printWidth 120),
  # a pre-commit `prettier --write` hook matching *.ts, and a CI job running
  # `prettier --check .` — with no .prettierignore. A payload wrapped at Prettier's
  # default 80 therefore reds the adopter's own format check on a file bootstrap
  # placed, or is silently rewritten on their first commit. No sibling has this
  # exposure (gofmt is width-agnostic), so nothing else in this suite would catch
  # it. Asserted on WIDTH rather than by running Prettier, so the gate stays
  # offline: 120 is the config's number, and a re-wrap to 80 leaves lines that
  # would join well inside it.
  local cfg width
  cfg="$LANGS/javascript/.prettierrc.json"
  width="$(jq -r '.printWidth' "$cfg")"
  [ "$width" = "120" ]
  # No line may EXCEED the configured width. Reported as the offending LINES, not
  # a count: a bare `[ "$over" -eq 0 ]` failure means re-running the awk by hand
  # to find out which line. (awk's length() counts bytes, so this is marginally
  # stricter than Prettier's character count on a non-ASCII line — which only ever
  # over-reports, never hides a regression.)
  local over
  over="$(awk -v w="$width" 'length($0) > w { printf "%d (%d cols): %s\n", FNR, length($0), $0 }' "$NODE/opsApi.ts")"
  [ -z "$over" ] || { printf 'lines over %s columns:\n%s\n' "$width" "$over" >&2; return 1; }
  # …and the file must not be wrapped for a NARROWER width either, which the
  # length check alone cannot see: an 80-column file has every line under 120.
  # These are constructs Prettier reflows on WIDTH alone — none is an object
  # literal, the one node type it preserves a break in — each joining inside 120
  # and so required to be on ONE line here. The last two sit at ~108 and ~116
  # columns deliberately: the short ones only catch a re-wrap below ~84, while
  # these catch any re-wrap below ~110.
  local f; f="$(cat "$NODE/opsApi.ts")"
  contains "$f" 'import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";'
  contains "$f" 'export type OpsRequestHandler = (req: IncomingMessage, res: ServerResponse) => void;'
  contains "$f" 'export async function serve(config: OpsConfig, port: number = defaultPort()): Promise<OpsServer> {'
  contains "$f" '  const endpoint = process.env.OTEL_EXPORTER_OTLP_METRICS_ENDPOINT ?? process.env.OTEL_EXPORTER_OTLP_ENDPOINT;'
  contains "$f" '  const protocol = process.env.OTEL_EXPORTER_OTLP_METRICS_PROTOCOL ?? process.env.OTEL_EXPORTER_OTLP_PROTOCOL ?? "";'
}

@test "node ops-api fragment keeps the otel exporter release train coherent" {
  # The fragment's own comment calls a mixed set fatal ("one release train; a mixed
  # set fails at runtime on an API mismatch"), and Renovate/Dependabot bump these
  # entries INDEPENDENTLY — so a grpc exporter at ^0.221.0 beside a proto exporter
  # at ^0.230.0 is valid JSON, has every key the test above asserts, and ships to
  # every bootstrapped repo.
  #
  # Scoped to the three exporter-* packages, which are the ones sharing a line.
  # @opentelemetry/api (1.x) and @opentelemetry/sdk-metrics (2.x) are upstream's
  # own separate trains — the fragment says so — and folding them in would demand a
  # coherence that does not exist.
  #
  # Filtered by KEY, never by version prefix: a `^0.` filter would let a package
  # that drifted onto another major drop OUT of the compared set instead of
  # reddening it, which is the mixed state the comment calls fatal, passing green.
  local versions count
  versions="$(jq -r '.dependencies | to_entries[]
                     | select(.key | startswith("@opentelemetry/exporter-"))
                     | .value' "$NODE/package.json.deps" | sort -u)"
  [ -n "$versions" ]
  count="$(printf '%s\n' "$versions" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
}

@test "node payload's README npm-install lines and package.json.deps name the same packages" {
  # Two hand-maintained package lists, one per adoption path (the README's `npm
  # install` block, the fragment's dependency objects). Nothing but this ties them
  # together, and drift is the normal outcome — a package dropped from one path
  # fails to resolve only for the adopters who took that path, at startup.
  #
  # Both directions, and TOKEN-exact: a substring test would let
  # `@opentelemetry/api` be satisfied by a longer package name, so dropping the one
  # package `metrics.getMeter` comes from would go unseen. The README haystack is
  # the fenced install block alone, so a package that migrated from the command
  # into prose does not count as installed either.
  local fence fence_pkgs dep_pkgs p
  fence="$(sed -n '/^npm install @opentelemetry/,/^```$/p' "$NODE/README.md")"
  ends_with "$fence" '```'                      # proves the range closed
  # A trailing `@<range>` is stripped before comparing, so a pinned entry
  # (`@types/node@^24`) still matches its fragment key. The leading `@` of a scope
  # is untouched — the pattern requires a character before the `@` it removes.
  fence_pkgs="$(printf '%s\n' "$fence" | tr ' \\' '\n\n' | grep '^@' \
    | sed -E 's/(.)@[^@]+$/\1/' | sort -u)"
  dep_pkgs="$(jq -r '(.dependencies + .devDependencies) | keys[]' \
    "$NODE/package.json.deps" | sort -u)"
  [ -n "$fence_pkgs" ]
  [ -n "$dep_pkgs" ]
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$fence_pkgs" | grep -qxF "$p"
  done <<< "$dep_pkgs"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$dep_pkgs" | grep -qxF "$p"
  done <<< "$fence_pkgs"
}

@test "node ops-api fragment types against the Node major the scaffold pins" {
  # @types/node's MAJOR tracks the Node release it types. Typing against a newer
  # major than .nvmrc installs is SILENTLY wrong in the worst direction: tsc accepts
  # APIs that are absent at runtime, so the failure lands in production rather than
  # in the build. The two artifacts ship in the same bootstrap run, so nothing but
  # this ties them together.
  local pinned floor
  pinned="$(tr -d '[:space:]' < "$LANGS/javascript/.nvmrc")"
  floor="$(jq -r '.devDependencies["@types/node"]' "$NODE/package.json.deps")"
  [ -n "$pinned" ]
  [ "${floor#^}" != "$floor" ]                  # a caret range, not a hard pin
  [ "${floor#^${pinned}.}" != "$floor" ]
  # The README's install command must carry the major too. It is the adoption path
  # a reader follows FIRST, and an unversioned `npm install --save-dev @types/node`
  # resolves whatever is newest — landing types ahead of the runtime, which is the
  # silent direction. The drift test above compares package NAMES only, so without
  # this needle nothing observes it.
  grep -qF "@types/node@^${pinned}" "$NODE/README.md"
}

@test "node payload documents the ESM + GIT_SHA adoption traps in every arrival point" {
  # Two traps, each fatal-but-quiet in a different way: a CommonJS package.json
  # fails the BUILD (loud, but nothing else names why), and an unset $GIT_SHA fails
  # the first DEPLOY. Each needle is unique to the WARNING, not to the token, so
  # deleting the paragraph cannot leave it green on an incidental mention.
  # package.json.deps counts because merging by hand is the one adoption path that
  # passes through no other document.
  grep -qF 'no truthful fallback' "$NODE/opsApi.ts"
  grep -qF 'must declare `"type": "module"`' "$NODE/README.md"
  grep -qF 'has **no fallback**' "$NODE/README.md"
  grep -qF 'MUST DECLARE' "$NODE/package.json.deps"
  grep -qF 'build plumbing the adopter owes' "$SKILL"
  grep -qF 'no truthful fallback' "$REPO_ROOT/docs/how-to/adopt-the-ops-surface.md"
  # The third trap, pinned like the Go sibling pins its own: a DependencyHealthSource
  # is hand-written, and returning the caller's live registry instead of a snapshot
  # serializes a health report the service never intended. Milder than Go's (single
  # threaded, no fatal concurrent-map read), which is why it is here rather than in
  # its own test — but the acceptance fixture's structuredClone exists to honour it,
  # so the contract is live.
  grep -qF 'RETURN A FRESHLY BUILT OBJECT' "$NODE/opsApi.ts"
  grep -qF 'freshly built object every call' "$NODE/README.md"
}

# Three tests over one SKILL block rather than one test over three rules — the
# shape the Go section settled on, so a failure names the rule that regressed
# rather than "the Node block". Each re-proves its own sed range closed.

@test "bootstrap SKILL.md's Node gate carries all seven arms, install included" {
  local block
  block="$(sed -n '/^\*\*Node canonical implementation (#936)\.\*\*/,/^The last remaining language/p' "$SKILL")"
  contains "$block" 'The last remaining language'
  # All FIVE skip conditions. Each is a package shape with no ops surface to
  # expose; dropping one installs a management port into a package that cannot
  # use it. The CLI case is the one that keeps the install arm from being a
  # catch-all: a bin-only CLI matches none of the other four (case 2's evidence is
  # main/exports), so without it the gate ships a management listener and five
  # OTel runtime deps into a process that runs and exits.
  contains "$block" 'A frontend-only / SPA package (#683)'
  contains "$block" 'A library-only package'
  contains "$block" 'A contract-consumer-only package'
  contains "$block" 'A serverless / edge handler'
  contains "$block" 'A CLI-only package'
  contains "$block" 'This case is why the install arm is not a catch-all'
  # The unit the gate is evaluated against. Without it the cases read repo-wide,
  # and an ordinary workspace (an SPA package beside a service package) matches
  # case 1, case 6 and case 7 at once, with nothing to choose between them.
  contains "$block" 'Evaluate the gate against the candidate service PACKAGE, not the repo tree.'
  # …and the recording duty, which now covers the user-chosen skip too — the one
  # path where a reader is most likely to mistake a decision for an omission.
  contains "$block" 'or a case-6 ambiguity the user resolves as *skip* — gets a Step-5'
  # Case 6, the ambiguity escape, and case 7, the INSTALL arm. Without the install
  # arm the block has five ways to skip and no way to install — every needle above
  # still green, and no Node service ever gets an ops surface.
  contains "$block" 'surface the install-or-skip choice in the Step-2'
  contains "$block" '**Otherwise (a runnable Node service)** → **install**'
}

@test "bootstrap SKILL.md's Node gate keeps case 6 REACHABLE past the five skips" {
  # The gate is "first match wins", so every case-6 shape that an earlier skip's
  # evidence also matches is unreachable without an explicit escape — and the
  # failure is silent: the repo the author means you to ASK about is skipped, with
  # a checklist line that contradicts the user's own declaration. Both escapes are
  # pinned as rules AND at the two cases whose evidence would otherwise swallow
  # them, because a model that matches case 4 may never read the preamble.
  local block
  block="$(sed -n '/^\*\*Node canonical implementation (#936)\.\*\*/,/^The last remaining language/p' "$SKILL")"
  contains "$block" 'The last remaining language'
  contains "$block" 'Two escapes apply to the skip cases below'
  contains "$block" 'A user-override `interfaces` that contradicts the skip evidence is case 6,'
  contains "$block" 'A long-lived listener beats an absence-of-listener skip**, and it is judged'
  # The listener test is judged by what the package STARTS. A filename-only test
  # (`src/server.ts` and friends) misses the framework-served SSR service — which
  # HAS a listener, and which case 1's bundler evidence would otherwise skip.
  contains "$block" 'by what the package **starts**, never by filenames'
  contains "$block" '(`next start`, `nuxt start`, Angular SSR)'
  contains "$block" 'HAS a long-lived listener and is case 6, not a skip'
  # "Contradicts" is stated PER CASE, because it differs per case, and every one
  # of the five closes its enumeration (both the agreeing and the contradicting
  # values) rather than leaving the rest to inference. Case 4 is the trap: an edge
  # HTTP handler is legitimately `rest`, so reading `rest` as a contradiction
  # there sends every serverless repo to case 6.
  contains "$block" '`web-ui` and `library` agree with this case; any'
  contains "$block" '*`library` and `cli` agree with this case; any other value'
  contains "$block" '`library`, `web-ui` and `cli` agree'
  contains "$block" '**No `interfaces` value contradicts this'
  contains "$block" '`cli` and `library` agree with this case; any other value'
  contains "$block" 'skip only when there is no long-lived listener at all, and a package that also'
  # And the scoping rule that keeps the override escape from misfiring: the JS
  # detector never populates `interfaces`, so only a USER override counts.
  contains "$block" '`interfaces` that CONTRADICTS the evidence, in either direction'
  contains "$block" 'A detector-populated `interfaces` is neither'
}

@test "bootstrap SKILL.md places the Node payload and renders all three files" {
  local block
  block="$(sed -n '/^\*\*Node canonical implementation (#936)\.\*\*/,/^The last remaining language/p' "$SKILL")"
  contains "$block" 'The last remaining language'
  # The monorepo question: several package.jsons, only one runnable service — and
  # it is answered FIRST, because it names the package the gate then judges.
  contains "$block" 'Answer this FIRST in'
  contains "$block" 'surface the choice in the Step-2 plan'
  # An SPA package beside the service is the ordinary case, not an ambiguity;
  # without this the gate's own case-6 list reads as covering it.
  contains "$block" 'An SPA package sitting beside it is simply not the candidate'
  # ZERO candidates is a SKIP, not a question. An SPA package plus a shared
  # library has no candidate by construction, and asking which package should
  # receive the ops surface invites an answer that installs a management port into
  # one of them — the outcome cases 1 and 2 exist to prevent.
  contains "$block" '**Zero qualify** → **do not ask.**'
  contains "$block" 'Ask only when no package starts a'
  # Placing the module does not expose the surface. Bootstrap does not edit
  # entrypoints, so the wiring is RECORDED; without this the run ends with a
  # placed file, no ops surface, and a checklist that never mentions it.
  contains "$block" '**Record — do not perform — the startup wiring.**'
  contains "$block" 'await serve(config)'
  # npm resolves and locks workspace packages at the ROOT. A nested install writes
  # a second lockfile that diverges from CI while appearing to work locally.
  contains "$block" 'the workspace ROOT in a workspaces repo, and from the package'
  # `typescript` is conventionally hoisted to a workspace root, so a check scoped
  # to the target package alone would defer a payload whose precondition is met.
  contains "$block" 'or the workspace root'"'"'s** in a workspaces repo'
  # @types/node moves in BOTH directions, and the decline branch must not fall
  # back to merging a types major above the runtime. The pin it is matched
  # against must be the repo's PRE-EXISTING one: .nvmrc is a fragment this same
  # run installs when absent, so reading it after staging always returns 24 and
  # the two arms could never fire.
  contains "$block" 'Target major LOWER than'
  contains "$block" '**Target major HIGHER**'
  contains "$block" 'this is never a reason to defer the payload'
  contains "$block" 'never the `.nvmrc` this run may have just staged'
  contains "$block" 'the Dockerfile'"'"'s `FROM node:<major>`'
  # An already-instrumented service is the likely adopter, and its own OTel pins
  # are a decision, not a detail: overwriting them moves it across the SDK 2.x
  # boundary, keeping them leaves the payload's 2.x constructor uncompilable.
  contains "$block" '**`@opentelemetry/*` the package already declares — but only when its range'
  contains "$block" 'either direction: raising it moves the adopter'
  # The branch must NOT fire on a compatible pin: an unqualified trigger asks
  # about a range that already works, and the decline arm then defers a payload
  # that would have built.
  contains "$block" 'A declared range whose every admitted version is at or above the'
  # …and when it DOES fire, both the offer and the deferral are the point. Pinned
  # by phrases unique to THIS branch — the block now carries three separate
  # "defer the ENTIRE payload" sentences.
  contains "$block" 'Surface it as its own Step-2 plan line naming the declared and required ranges;'
  contains "$block" 'cannot build.'
  # $GIT_SHA: the Dockerfile-less repo gets no ops-conformance job at all, so a
  # checklist line pointing at a Dockerfile would be unactionable there.
  contains "$block" 'first depends on whether the repo has a Dockerfile'
  contains "$block" 'Do **not** write a checklist'
  # Placement + the deps rule, and the render command's three files.
  contains "$block" 'src/ops/opsApi.ts'
  contains "$block" 'Never place `opsApi.ts` without its dependencies'
  # All THREE rendered files are placed, not two: the shipped README points at
  # `package.json.deps` "beside this file", so discarding the fragment after
  # folding ships a dangling reference into the adopter's repo.
  contains "$block" 'and `package.json.deps`** beside it'
  # The failure branch for the one fallible command in the block. Without it a
  # failed `npm install` invites invented recovery — reverting the merge, or
  # deleting the placed payload — with no checklist record either way.
  contains "$block" 'If `npm install` fails'
  # A .ts payload is inert in a package that compiles no TypeScript, and
  # detect-stack.sh classifies a plain-JS repo as `javascript` all the same.
  contains "$block" 'the target package must be able to compile TypeScript'
  # The OFFER and the DEFERRAL, not just the precondition. Delete either and the
  # block places a .ts file into a package that compiles no TypeScript with every
  # other needle green — and the deferral is only reachable if the user was
  # actually asked. Both needles are unique to this gate.
  contains "$block" 'as its own line in the Step-2 plan**, naming the half that is absent'
  contains "$block" 'TODO. Placing a `.ts`'
  # The payload's Node floor is the OTel packages' own engines.node, not a house
  # rule — and it is checked BEFORE placement, because below it the dependencies
  # do not install and the surface can never run.
  contains "$block" "The payload's own Node floor is \`^18.19.0 || >=20.6.0\`"
  contains "$block" 'placing anything**: below the floor, the OTel dependencies will not install'
  # …and what to DO about it. Without these two the block states a floor with no
  # instruction attached — the same gap the three other deferral sites had.
  contains "$block" 'Below the floor, surface the Node-pin raise as its own Step-2 plan line, and if'
  contains "$block" 'the user declines, **defer the ENTIRE payload** behind a Step-5 TODO. At or'
  # The floor is minor-granular while the resolution yields a MAJOR, so the block
  # must say which majors decide it outright and which two need a minor read —
  # otherwise "major 20 vs >=20.6.0" has no answer and the model guesses, in
  # either direction.
  contains "$block" 'Majors **21 and up** are above'
  contains "$block" 'treat it as **below** the floor rather than guessing'
  # The @types/node LOWER arm must NOT also claim the below-floor case: it says
  # "never defer over this", which is the opposite of what the floor demands.
  contains "$block" 'the floor rule below governs it, decline arm'
  # A ranges-only repo needs a closed answer, or the model invents one — and the
  # nearest available invention is the lower bound the rule just forbade.
  contains "$block" '**When none of the four yields'
  # …and the ORDER it resolves in, not just that it asks. Reverting this body to
  # the range's lower bound is the silent direction the same block names, and the
  # trigger needle alone would not see it.
  contains "$block" 'admit; and with no source at all, the shipped 24.'
  contains "$block" '`.nvmrc` (24) if the ranges admit it; failing that, the highest major they'
  # Major 19 satisfies NEITHER floor clause, and it shares a sentence with the
  # 21-and-up rule — so without its own needle it can be deleted alone, leaving 19
  # unclassified between "18/20 straddle" and "21 and up".
  contains "$block" 'major **19** is below it outright'
  # The OTel conflict must be keyed on "admits no version at or above the floor",
  # not on "does not admit the floor version" — a range strictly ABOVE the floor
  # satisfies the payload while failing the latter test.
  contains "$block" 'admits NO version at or above the fragment'
  # …and the third shape: a range straddling the floor satisfies neither the
  # conflict test nor the escape, so it is settled by the RESOLVED version. A
  # `>=1.0.0` locked at 1.8.x passes the range test while leaving the package on
  # the 1.x line the payload cannot compile against.
  contains "$block" '**A range that admits versions on BOTH sides of the floor**'
  contains "$block" 'RESOLVED (the lockfile entry, or what is installed), not by the range'
  # The image CMD is listener evidence at case 2 too: a containerized service
  # started only by its Dockerfile satisfies every other negative there.
  contains "$block" '**no image `CMD` that runs one**'
  # The rootDir/TS5011 rule is what makes an emitting build actually work from the
  # shipped config, and it is stated as an on-approval action.
  contains "$block" 'add `"rootDir": "src"` to it'
  # Both arms of the $GIT_SHA branch, not just the hinge and the without-one guard.
  contains "$block" '`ENV GIT_SHA` pair into the Dockerfile with a CI-supplied'
  # A range is a FLOOR, not the runtime: taking engines.node ">=20" as the runtime
  # is how a repo that actually runs 24 gets typed against 20.
  contains "$block" '**Only an EXACT major counts as a pin.**'
  # src/ is a convention; the payload must land under the root the build compiles.
  contains "$block" 'place it under the package'"'"'s actual compiled'
  # `"type": "module"` is not carried by the dependency-block merge, and an ABSENT
  # `type` key is the common CommonJS case the trigger has to catch.
  contains "$block" 'an absent `type` key is CommonJS and counts'
  contains "$block" 'set `"type": "module"` in that package'
  # The escape hatch is the point of this bullet: the switch changes how every
  # existing `require` in the package resolves, so performing it unasked is the
  # regression. Both the offer and its decline arm, pinned uniquely.
  contains "$block" 'user can say no'
  contains "$block" 'rather than placing a module that cannot compile'
  # The three render paths are asserted against the FENCE, not the block — the Go
  # sibling's rule, and for its reason: the block names package.json.deps in prose
  # four times, so one sentence quoting a full template path would make an
  # unscoped needle unfalsifiable. The ends_with proves the sed range closed.
  local fence
  fence="$(printf '%s\n' "$block" | sed -n '/render.zsh" \\/,/^```$/p')"
  ends_with "$fence" '```'
  contains "$fence" 'languages/javascript/ops-api/opsApi.ts'
  contains "$fence" 'languages/javascript/ops-api/package.json.deps'
  contains "$fence" 'languages/javascript/ops-api/README.md'
}
