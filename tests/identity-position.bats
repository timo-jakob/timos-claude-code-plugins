#!/usr/bin/env bats
#
# The family's identity and authorization position (#1186, epic #1058).
#
# ARCHITECTURE.md's "Identity and authorization" section is the authoritative
# record: OIDC at the edge with Keycloak and PKCE, tenancy as Organizations in a
# single realm, the tenant identifier and roles as validated JWT claims, the
# service-validates-and-authorizes rule with issuer-aware validation and no
# trusted-header mode (plus both of its stated consequences), the ops-surface
# carve-out, the public-client clause, and the realization/enforcement record
# naming all seven children.
#
# WHY THIS FILE EXISTS: the defect #1186 repairs is an ABSENCE. The family stated
# no identity position at all while every other position assumed a service that
# knows who is calling it. A position nobody asserts can be softened, reversed,
# or quietly reacquire an escape hatch with the suite green — and this is the
# position where that is most expensive. So each clause is pinned individually: a
# section-level "mentions authorization" check would survive deleting any one of
# them.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` — this story's
# standing rule, inherited from #1189 rather than re-derived. Line numbers rot
# across unrelated merges; the tokens pinned here do not.
#
# ON THE NEGATIVE PINS: the section must DISCUSS a trusted-header mode and a
# local-dev bypass in order to forbid them, so the bare tokens appear
# legitimately and are useless as negatives — the same problem
# tests/deployment-position.bats has with `latest`, and the reason
# tests/messaging-position.bats's single-token trick (product names with no
# legitimate use anywhere) is unavailable here. Instead the guard greps the
# section for the VOCABULARY a softening would introduce — permissions rather
# than prohibitions — case-folded so a capitalised reintroduction is caught too.
# And because a negative needle that has never matched anything is
# indistinguishable from a typo, tests/fixtures/identity/softened-position.md
# commits a softened variant and a companion test asserts the detector FIRES on
# it, PER NEEDLE. Without that control the whole negative test is a permanent
# pass.
#
# These negatives are HEURISTIC tripwires, not a proof: they catch the vocabulary
# a softening tends to use, not the idea. A rephrasing that avoids all seven
# slips through, and an innocent future sentence containing one of them reds. The
# second failure mode is loud and self-correcting, which is the trade accepted
# here; the positive clause pins are what actually carry the contract.
#
# ON THE END ADDRESS: the extractor's end address is the GENERIC `^### `, not the
# specific heading that follows today. A specific end address catches a renamed
# or deleted anchor but NOT an inserted one — a new section slipped between this
# one and the next is swallowed into the range while the haystack still ends with
# the pinned heading, so every assertion here would silently start covering two
# sections. The `ends_with` pin then names the heading that follows TODAY, so a
# reorder or insertion reds loudly instead of widening quietly. Same idiom as
# tests/messaging-position.bats, tests/webui-positions.bats and
# tests/deployment-position.bats, so all four position suites behave identically.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  SOFTENED="$BATS_TEST_DIRNAME/fixtures/identity/softened-position.md"
  WRAPPED="$BATS_TEST_DIRNAME/fixtures/identity/wrapped-softening.md"
  GO_REVIEWER="$REPO_ROOT/development-go/agents/go-security-reviewer.md"
  JAVA_REVIEWER="$REPO_ROOT/development-java/agents/java-security-reviewer.md"
  PYTHON_REVIEWER="$REPO_ROOT/development-python/agents/python-security-reviewer.md"
  SWIFT_REVIEWER="$REPO_ROOT/development-swift/agents/security-reviewer.md"
  K8S_REVIEWER="$REPO_ROOT/development-kubernetes/agents/kubernetes-security-reviewer.md"
  BOOTSTRAP_REVIEWER="$REPO_ROOT/development/agents/bootstrap-security-reviewer.md"
  APIM_TMPL="$REPO_ROOT/development/skills/bootstrap/templates/common/apim/apiproxy.yaml.tmpl"
  MFE_SPEC="$REPO_ROOT/docs/superpowers/specs/2026-07-27-mfe-app-family-design.md"
  # The plugins the section claims ship no security reviewer. Hoisted so the
  # prose needle and the tree scan below are ONE transcription apiece — a rename
  # would otherwise rot the prose pin and the scan roots independently and
  # simultaneously.
  JS_PLUGIN="$REPO_ROOT/development-javascript"
  REACT_PLUGIN="$REPO_ROOT/development-react"
  SPRING_PLUGIN="$REPO_ROOT/development-spring"
  # a plugin that DOES ship one, for the scan's anti-vacuity control
  GO_PLUGIN="$REPO_ROOT/development-go"
}

# The basename of an agent file, without its .md — the form ARCHITECTURE cites
# a reviewer by when it names no path. Deriving the prose needle from the same
# variable the `[ -f ]` checks is what keeps the two halves one transcription.
agent_name() {
  local base="${1##*/}"
  printf '%s' "${base%.md}"
}

# The section's sed addresses, as constants rather than transcribed twice.
# identity_section() and raw_identity_section() MUST scan the same range: if they
# drift, the positive pins and the softening detector cover different text, and
# the detector can go clean over a narrowed range while the positives still pass
# over the real one — the vacuity class this file exists to remove.
IDENTITY_START='^### Identity and authorization'
SECTION_END='^### '

# Collapse a document region to one line: strip blockquote markers, collapse
# whitespace, trim the trailing space `tr` leaves behind. Same helper shape as
# tests/messaging-position.bats and tests/deployment-position.bats, and the trim
# is what makes `ends_with` usable as the end-anchor pin.
collapse() {
  sed 's/^>[[:space:]]\{0,1\}//' | tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

# Extract FILE's section from START to END (both sed BRE addresses, neither
# containing a `/`), collapsed. sed prints the END line itself, which is what the
# `ends_with` pins below rely on.
extract() {
  sed -n "/$2/,/$3/p" "$1" | collapse
}

# FILE contains the literal (single-line) string. Used to prove a quoted token
# the section cites still resolves in the file it names — the property that
# replaces `path:line` citations. `_assert_args` guards the dropped-second-
# argument case, since `grep -qF ''` matches every non-empty file and would turn
# the assertion into an unconditional pass.
file_has() {
  _assert_args "$#" "${2-}" || return 2
  grep -qF -e "$2" -- "$1"
}

# The softening vocabulary, as ONE array so the detector and its discrimination
# control cannot drift apart. Every needle here must be proven to match the
# fixture by the control test below — adding a needle without adding fixture
# coverage reds, which is the property a hand-written list of `contains` calls
# could not give.
#
# Each is a PERMISSION where the real section states a prohibition. The real
# section says "never a bypass switch" and "no trusted-header mode", so the bare
# words `bypass` and `trusted header` are unusable; these are the phrasings a
# weakening reaches for instead.
SOFTENING_NEEDLES=(
  'may be trusted'
  'trusted upstream'
  'may skip validation'
  'may be disabled'
  'except in local development'
  'acceptable in development'
  'validation is optional'
)

# Every case-insensitive softening phrase in FILE, as `<line>:<text>` records —
# empty when the file is clean, so `[ -z ]` on the CAPTURED value is the
# assertion and the records are the diagnostic.
#
# The status discipline, which DIFFERS from the sibling suites' and deliberately
# so. They end with `|| [ "$?" -eq 1 ]`, which folds grep's exit 2 (a REAL error
# — unreadable file, bad invocation) into a return of 1, indistinguishable from
# a clean no-match. This one captures grep's status and propagates anything
# other than 0/1 verbatim, which is what makes the `[ "$status" -eq 2 ]` pins at
# the bottom of this file mean something. `|| true` would be worse than either,
# folding an error into success and passing on a file that was never read.
#
# The explicit argument guards ahead of the grep are what make the distinction
# reachable at all — grep's own exit 2 arrives too late to tell an unset `$1`
# from a clean file — and every caller must capture into a variable FIRST rather
# than inlining `$(…)` into `[ -z … ]`, which would discard the status entirely.
softening_mentions() {
  [ -n "${1-}" ] || return 2
  [ -f "$1" ] || return 2
  [ -r "$1" ] || return 2
  local args=() n rc=0
  for n in "${SOFTENING_NEEDLES[@]}"; do args+=(-e "$n"); done
  # Without patterns, `grep -inF -- "$1"` would read $1 as the PATTERN and then
  # block reading stdin — a hang, not a failure. Refuse instead.
  [ "${#args[@]}" -gt 0 ] || return 2
  # Preserve grep's REAL status rather than folding every failure into 1: a
  # clean no-match (1) becomes success, and anything else (2 — unreadable file
  # racing the guard above, a directory on a platform that errors there)
  # propagates as itself, so a caller pinning `status -eq 2` is telling the
  # truth. `|| rc=$?` keeps the assignment reachable under errexit.
  grep -inF "${args[@]}" -- "$1" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
}

# The same detection over the COLLAPSED rendering, so a needle that straddles a
# hard line break is still caught.
#
# WHY BOTH PASSES: ARCHITECTURE.md is hard-wrapped at ~78 columns, and
# `softening_mentions` greps LINES. A softening phrase split across a wrap is
# invisible to it — 'except in local development' is 27 characters, so an
# arbitrary insertion splits it roughly a third of the time. The raw pass is
# kept because it reports line numbers, which is what makes a failure
# actionable; this one is what makes the guard sound.
# tests/fixtures/identity/wrapped-softening.md is its discrimination control.
softening_mentions_collapsed() {
  [ -n "${1-}" ] || return 2
  [ -f "$1" ] || return 2
  [ -r "$1" ] || return 2
  local flat
  flat="$BATS_TEST_TMPDIR/collapsed-$$.md"
  collapse < "$1" > "$flat"
  # `collapse` is a three-stage pipeline whose status is the LAST sed's, and bats
  # does not run test bodies under pipefail — so a failed leading `sed` still
  # leaves a trailing exit 0 and an EMPTY $flat, and the detection below would
  # then report CLEAN for a file it never actually read. Every caller asserts
  # emptiness, so that reads as a pass. Key the refusal on the input: a non-empty
  # input that collapses to nothing is a broken collapse, not a clean file.
  # Keyed on CONTENT, not on byte size. `[ ! -s "$flat" ]` asks whether the
  # rendering has zero bytes, but the property that matters is whether it has
  # anything to scan — and the two come apart across sed implementations, since
  # whether a trailing newline is re-appended to an incomplete last line is
  # implementation-defined. A whitespace-only rendering is equally unscannable
  # and equally a broken collapse. This form says one thing on both lanes of the
  # two-platform bats matrix.
  if [ -s "$1" ] && ! grep -q '[^[:space:]]' -- "$flat"; then
    printf 'collapse produced an empty rendering for a non-empty file: %s\n' "$1" >&2
    return 2
  fi
  softening_mentions "$flat"
}

# --- the authoritative record ------------------------------------------------

ARCH_END='### Cross-repo Claude: the big-picture problem'

identity_section() {
  extract "$ARCH" "$IDENTITY_START" "$SECTION_END"
}

# The section as raw lines rather than collapsed, for the grep-based negative
# above (which reports line numbers, and would lose them to the collapse).
raw_identity_section() {
  sed -n "/$IDENTITY_START/,/$SECTION_END/p" "$ARCH"
}

@test "ARCHITECTURE states OIDC at the edge with Keycloak and PKCE, with its rationale (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # pin our OWN heading, not just the one that follows: the extractor starts at
  # a loose address, so the subtitle and the issue number could otherwise drift
  # with this suite green. It IS pinned today as tests/deployment-position.bats's
  # ARCH_END, but that is an implicit cross-file dependency that evaporates the
  # moment the Deployment section moves.
  starts_with "$section" '### Identity and authorization — OIDC at the edge, claims as the only input (#1186)'
  contains "$section" '**OIDC at the edge, with Keycloak as the provider and PKCE for browser flows.**'
  # the rationale is half the deliverable: a position without one cannot be
  # argued with, and this clause would survive its own justification being cut
  contains "$section" 'one blessed path with one good default, applied to identity'
  # WHY PKCE specifically — without this the flow choice reads as arbitrary
  contains "$section" 'cannot keep a secret'
}

@test "ARCHITECTURE states tenancy as Organizations in a single realm, per-tenant realm the exception (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Tenancy is modelled as Keycloak Organizations in a single realm; a per-tenant realm is the deliberate exception, not the default.**'
  contains "$section" 'are then configured once and hold for every tenant'
  # the exception must stay an exception someone RECORDS — an unqualified
  # admission would make the per-tenant realm the shape the system drifts into,
  # which is the outcome this clause exists to prevent
  contains "$section" 'as a decision someone makes and records'
}

@test "ARCHITECTURE states the tenant and roles as VALIDATED JWT claims, never from client input (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**The access token is a JWT carrying the tenant identifier and roles as claims, and those claims are the authorization input.**'
  # all three forbidden sources, pinned individually — a needle naming only one
  # would survive the other two being quietly re-admitted
  contains "$section" 'never derives tenant or role from client input, a path parameter, or a header it did not validate'
  contains "$section" 'anything the caller can type, the caller can change'
  contains "$section" 'the shortest path from a working system to a cross-tenant read'
  # forbidding three SOURCES leaves the disagreement case unstated, and the only
  # behaviour the prohibition alone licenses is to serve the claim's tenant —
  # silently answering a different question than the one asked
  contains "$section" 'compared against the claim, and a mismatch is rejected**, never silently overridden'
  contains "$section" 'answers a different question than the one asked'
  # the SECOND branch — a tenantless token — pinned separately. Deleting it
  # re-admits trusting a caller-typed tenant whenever the token carries none,
  # and the softening detector cannot catch it: that detector fires on ADDED
  # permission vocabulary, never on a deleted prohibition.
  contains "$section" '**And where the token carries no tenant claim at all**'
  contains "$section" '**a request naming a tenant is rejected too**'
  contains "$section" 'the only remaining behaviour is to trust what the caller typed'
  # and the cardinality that makes "compared against" mean equality
  contains "$section" '**A token asserts exactly one active tenant**'
  # and the clause must not read as banning resource-level checks against the
  # service's own state, which are not caller-supplied at all
  contains "$section" 'This clause is about *caller-supplied* input only'
}

@test "ARCHITECTURE states the service validates and authorizes, issuer-aware, with NO trusted-header mode (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # the rewritten gateway clause IS the point of this story — the earlier framing
  # put the security-critical step outside everything the family scaffolds
  contains "$section" '**The service validates and authorizes; a gateway may validate first, but never instead.**'
  contains "$section" '**issuer-aware**'
  contains "$section" 'inside the scaffolded service'
  # issuer-awareness without its consequence is a word: pin what it BUYS, or the
  # clause survives being implemented as one statically bound issuer
  contains "$section" 'resolved per request rather than bound once at'
  contains "$section" 'stays supportable without a code change'
  # THE bound that makes per-request resolution safe rather than a bypass: an
  # implementation that trusts the token's own `iss` to name its key source
  # accepts anything, and "issuer-aware" alone reads as licensing exactly that
  contains "$section" 'selects from a configured allowlist of issuers'
  contains "$section" 'never introduces one'
  contains "$section" 'not weaker validation but none at all'
  # and "validates" must be defined, or it is a word each realization fills in
  contains "$section" 'using an expected algorithm rather than the one the token asks for'
  contains "$section" 'There is **no trusted-header mode**'
  # and the prohibition must stay UNSCOPED to both settings it names
  contains "$section" 'not in local development, not on service-to-service calls'
  # the gateway must stay admitted as defence in depth, or the clause reads as
  # banning a gateway check outright — which the position does not say
  contains "$section" 'not a substitute for the service knowing who is calling it'
}

@test "ARCHITECTURE writes out the LOCAL-DEV consequence of the no-trusted-header rule (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Local development runs against a dev issuer or a signed dev token, never a bypass switch.**'
  # the reasoning, without which the rule reads as purity rather than as a
  # statement about what ships in the binary
  contains "$section" 'is a code path that exists in the shipped binary'
  # the clause that gives the rule its teeth: without the environment scoping, an
  # implementation satisfies "no bypass switch" while allowlisting the dev issuer
  # in a shared test cluster — the same bypass in the form hardest to review for
  contains "$section" '**The issuer allowlist above is environment-scoped configuration, and a dev issuer belongs only in a *local* development allowlist**'
  contains "$section" 'never a locally-run or statically-keyed stub'
  contains "$section" 'this same bypass in another form'
}

@test "ARCHITECTURE writes out the SERVICE-TO-SERVICE consequence, including the tenant caveat (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**A service-to-service call carries either the propagated caller token or a client-credentials service-account token**'
  contains "$section" 'the former when the work is being done on behalf of a user'
  # the caveat is the half most easily dropped, and the one that matters: a
  # service-account token that always asserts a tenant is a standing forgery
  contains "$section" 'carries a tenant identifier only when it is genuinely acting for one tenant'
}

@test "ARCHITECTURE states the ops-surface carve-out AND why it is stated (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**The ops surface is outside the token rule — but only on the management port.**'
  # ALL FIVE exempt paths, pinned as ONE needle spanning the enumeration.
  #
  # Individual token pins do NOT work here: `/info` and `/metrics` each occur a
  # SECOND time in this section (the Java reconciliation bullet names them), so
  # a per-token `contains` is satisfied by that other sentence and dropping the
  # path from the carve-out itself would not red — a section-level "mentions
  # /info" check wearing the clothes of a per-path guard. The enumerated needle
  # is uniquely satisfied by the carve-out sentence and pins the set AND its
  # order, so removing any one path reds.
  contains "$section" '`/info`, `/health`, `/health/live`, `/health/ready` and `/metrics` are exempt'
  # the cross-reference the carve-out depends on. (A bare 'the separate
  # management port' needle would be a strict SUBSTRING of the port-condition
  # needle below and could never fail independently of it.)
  contains "$section" 'of the ops surface (#688)'
  # the PORT is the condition, not a description of where those paths sit. Read
  # as a path allowlist, the carve-out exempts precisely the exposed case — the
  # same five paths mounted on the public app port
  contains "$section" 'when, and only when, they are served on the separate management port'
  contains "$section" '**The port is the condition, not a description of where'
  contains "$section" 'mounted on the public application port are subject to the token rule'
  # the carve-out is bounded by something, or it is just a hole
  contains "$section" '`NetworkPolicy`'
  contains "$section" 'restricted to the kubelet and the monitoring namespace'
  # and that bound must not be claimed as a shipped fact: nothing in this family
  # verifies the policy exists, so an unqualified present-indicative claim would
  # license treating an unauthenticated management port as safe by default
  contains "$section" 'That boundary is a position, not a shipped guarantee'
  contains "$section" 'an unbounded hole this carve-out does not license'
  # the factual half of that claim, checked in prose AND against the tree below:
  # kubernetes-security-reviewer ships an ABSENCE check, not a permissiveness one
  contains "$section" 'flags a namespace carrying no policy at all, not a policy that admits everything'
  [ -f "$K8S_REVIEWER" ]
  file_has "$K8S_REVIEWER" 'a namespace with workloads and no policy'
  # the REASON it is stated is load-bearing for #1327: without it the deepened
  # reviewer's first run is unusable, and a future editor would read the
  # carve-out as an aside and cut it
  contains "$section" 'reads every kubelet probe as an endpoint missing authorization'
  contains "$section" 'drowns in false positives on its first run'
}

@test "ARCHITECTURE states the public-client clause in full (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # scoped to a DEVICE client: an unqualified "a client is a public client"
  # collides with the client-credentials service-account token the
  # service-to-service clause requires, which no public client can obtain
  contains "$section" '**A client that runs on a user'"'"'s device is a public client.**'
  # All four obligations, pinned as ONE clause-spanning needle.
  #
  # Per-token pins are vacuous here for the same reason as the ops paths above:
  # `**PKCE**`, `**no client secret in the binary**` and `**platform keystore**`
  # each occur a SECOND time in this section (the coverage bullets and the
  # unenforced list), so an individual `contains` is satisfied by those
  # paragraphs and deleting the obligation from the public-client clause would
  # not red. This needle is uniquely satisfied by the clause itself.
  contains "$section" 'uses **PKCE**, ships **no client secret in the binary**, keeps the token in the **platform keystore**, and **never uses a claim as a local authorization decision**'
  # the browser has NO platform keystore, so without this the one storage rule
  # stated is inapplicable to the surface #1326 has to implement, and the
  # implementer picks localStorage while believing they comply
  contains "$section" 'the shell holds the token in memory only — never in `localStorage` or `sessionStorage`'
  contains "$section" 'that is the storage rule #1326 implements, not one it gets to choose'
  # and the confidential case must be admitted somewhere, with its secret rule
  contains "$section" '**The confidential-client case is the service'"'"'s, and only the service'"'"'s:**'
  contains "$section" 'reaches the workload through the secrets operator'
  # the claim rule's reasoning — the one most often gotten wrong, and the one a
  # reader is most likely to argue with, so it must be stated rather than asserted
  contains "$section" 'claims are the server'"'"'s input'
  contains "$section" 'is enforcing nothing'
  # and it must not read as a services-only position: the family's own adopter
  # path includes repos with no server at all
  contains "$section" 'deliberately not a services-only position'
  contains "$section" 'omitted with no error, no warning, and nothing to search for later'
}

@test "ARCHITECTURE records the reusable reviewer/template criterion, not just this application of it (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Realization and enforcement — what ships where.**'
  contains "$section" 'a position gets a reviewer when a violation is visible in a diff, and a template when a service cannot comply without boilerplate'
  # both halves are claimed HERE, so the "both" outcome is derivable rather than
  # asserted — otherwise a reader cannot check the criterion was applied
  contains "$section" 'is visible in a diff, and no service does issuer-aware validation without scaffolding'
  # and nothing is built by this section
  contains "$section" 'Neither is built here.'
}

@test "ARCHITECTURE names ALL SEVEN children by number, each against its own work (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # pinned WITH their subject, not as bare numbers: a bare '#1321' needle would
  # survive the number being paired with the wrong child, which is exactly the
  # drift that makes a "record" unverifiable from the diff
  contains "$section" '**#1321** (Go), **#1322** (Java), **#1323** (Spring) and **#1324** (Python)'
  contains "$section" '**#1325** (Swift) — the client half'
  contains "$section" '**#1326** — the SPA shell owns session and auth acquisition'
  contains "$section" '**#1327** — the single enforcement child'
  # the children live under the EPIC, not under this issue (#802's contract)
  contains "$section" 'are filed under epic #1058'
  # the count claim over the seven children listed in the four bullets above
  # (#1321-#1324 share one bullet) — deletable today without this pin
  contains "$section" 'Six realization children and one enforcement child'
  # the MFE contract must resolve to something a reader can OPEN: this document
  # defines no `mfe-contract/v1` section, unlike every other versioned contract
  # it names, so a bare version token would send an implementer inventing a shape
  # both halves from one string, same rule as the reviewer citations: a bare
  # prose pin would let the spec be renamed and leave ARCHITECTURE citing a dead
  # path with this suite green — the defect the round-1 fix removed
  contains "$section" "${MFE_SPEC#"$REPO_ROOT/"}"
  [ -f "$MFE_SPEC" ]
  # Node is a blessed service language here with a shipped ops-api reference, so
  # its absence from the children must be a STATED gap, not silence a reader
  # resolves as either coverage or exemption
  contains "$section" '**Node is a named gap, not an exclusion.**'
  contains "$section" 'a stated gap rather than a decision that Node is out of scope'
}

@test "ARCHITECTURE names the four deepened reviewers BY FILE, and those files exist (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # BOTH halves of each citation from ONE string, so the prose and the tree
  # cannot drift apart. Deriving the prose needle from the same variable the
  # `[ -f ]` checks is what makes that true: two independent transcriptions
  # would let a rename be repaired in setup() alone, leaving ARCHITECTURE citing
  # a file that no longer exists with this suite green. Same idiom as
  # tests/deployment-position.bats's status-note citation test.
  contains "$section" "${GO_REVIEWER#"$REPO_ROOT/"}"
  [ -f "$GO_REVIEWER" ]
  contains "$section" "${JAVA_REVIEWER#"$REPO_ROOT/"}"
  [ -f "$JAVA_REVIEWER" ]
  contains "$section" "${PYTHON_REVIEWER#"$REPO_ROOT/"}"
  [ -f "$PYTHON_REVIEWER" ]
  # Swift's is unprefixed — the naming exception that makes a guessed path
  # wrong, and the one most likely to be "corrected" into its siblings' shape
  contains "$section" "${SWIFT_REVIEWER#"$REPO_ROOT/"}"
  [ -f "$SWIFT_REVIEWER" ]
  # The four do NOT all get the same checks. The split is keyed to the ARTIFACT,
  # and Swift's exception is about SCOPE — this position files no Swift service
  # realization, so service checks pointed at Swift's reviewer would have
  # nothing to point at. It is deliberately NOT justified by a false-positive
  # flood: under artifact keying a SwiftUI client repo ships no server and gets
  # no service checks, so that flood cannot arise and the rationale would
  # contradict the artifact rule (pinned below).
  contains "$section" '**The four do not all get the same checks, and the split is keyed to the artifact under review, not to the language:**'
  # the split must cut BOTH ways, or a Go/Python CLI — a public client this
  # position covers explicitly — is enforced by nobody
  contains "$section" 'a Go or Python CLI *that authenticates* is a public client'
  # the Swift exception must rest on SCOPE, not on a false-positive flood: under
  # artifact keying a SwiftUI client repo ships no server and gets no service
  # checks, so the flood is impossible and that rationale would contradict the
  # rule stated two sentences earlier
  contains "$section" '**because this position files no Swift service realization for service checks to point at**'
  contains "$section" 'not because a Swift artifact cannot be a server'
  # and the enumeration must be closed in both remaining directions
  contains "$section" 'A repo that ships **both** gets both halves'
  contains "$section" 'the absence of a validator in it is not a finding'
  # the client half must list ALL FOUR obligations — an enumeration of three
  # here would size #1327 to ship three checks while the coverage paragraph
  # assigns it the fourth
  contains "$section" 'the *client* behaviour — PKCE, no client secret in the binary, the platform keystore, and no claim-based local decision, all four'
  # the neither-bucket must not swallow an authenticating CLI — but the rule
  # keys on TOKEN ACQUISITION, not on the artifact's name, or a formatter CLI
  # gets flagged for missing PKCE it has no provider to speak to
  contains "$section" '*A CLI is not automatically in that bucket:*'
  contains "$section" '**token acquisition is the key, not the artifact'"'"'s name**'
  # and the POSITION paragraph's restatement must carry the same qualifier —
  # it calls itself "the same rule", so an unconditional CLI clause there would
  # license flagging a formatter for missing PKCE it has no provider to reach
  contains "$section" 'a service repo that also ships a CLI *that acquires a token* owes them for that CLI'
  contains "$section" 'is not a client at all, and owes none of them'
  contains "$section" 'one pair of behaviours written four times'
}

@test "ARCHITECTURE excludes two reviewers WITH their artifact-based reasons (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # the excluded pair is cited BY NAME in the prose (ARCHITECTURE spells no path
  # for them), so the needle is derived from the same variable the `[ -f ]`
  # checks — one transcription, exactly as for the four included reviewers. A
  # hard-coded literal here would let a rename be repaired in setup() alone.
  local k8s_name bootstrap_name
  k8s_name="$(agent_name "$K8S_REVIEWER")"
  bootstrap_name="$(agent_name "$BOOTSTRAP_REVIEWER")"
  contains "$section" "\`$k8s_name\` and \`$bootstrap_name\` are **excluded**"
  [ -f "$K8S_REVIEWER" ]
  [ -f "$BOOTSTRAP_REVIEWER" ]
  # an exclusion without a reason is indistinguishable from an oversight, and
  # would be "corrected" by the next reader
  contains "$section" 'The first reviews cluster manifests, which carry no token validation or claim extraction'
  # the bootstrap exclusion must NOT rest on "CI config carries no identity
  # decision" — the shipped apim auth policy is exactly that, so an unqualified
  # exclusion would leave a scaffolded gateway-trust policy reviewed by nobody
  contains "$section" 'covers workflow and scanner configuration only'
  contains "$section" 'deliberately left unreviewed **for now** because #1328 is repairing it'
  # a "for now" with no end is a permanent exclusion wearing a temporary label
  # stated as an OBLIGATION on #1328, not as a fact about its body that nothing
  # here verifies: "#1328 lands" is satisfied equally by a template-only repair,
  # after which the reviewer never gains the check
  contains "$section" 'that is an obligation on #1328, not a prediction about it:**'
  contains "$section" 'if it does not carry that today, it is added'
  contains "$section" 'bootstrap keeps emitting the contradicting file'
  # the two plugins that ship no security reviewer at all — needle derived from
  # the same variables the tree scan uses, so a rename cannot rot one half alone
  contains "$section" "\`${JS_PLUGIN##*/}\` and \`${REACT_PLUGIN##*/}\` ship no security reviewer"
  # and the CONSEQUENCE, not just the upstream fact: #1326's storage rule has no
  # reviewer at all, which a reader would otherwise have to derive
  contains "$section" '**#1326'"'"'s browser in-memory storage rule ships with no reviewer at all**'
  # Spring has a realization child (#1323) and no reviewer of its own, so the
  # record must say what enforces it or six children answer to four reviewers
  contains "$section" "\`${SPRING_PLUGIN##*/}\` ships no review panel of its own"
  # pinned THROUGH the reviewer name and derived from its path: truncating the
  # needle before the token would let the enforcer be changed to anything,
  # including a reviewer that does not exist
  contains "$section" "#1323's realization is enforced by \`$(agent_name "$JAVA_REVIEWER")\`"
}

@test "the no-security-reviewer claim still holds against the TREE, not just the prose (#1186)" {
  # The prose pin above is a NEGATIVE claim about two actively-developed plugins
  # (the WebUI epic is in flight). The moment a react or javascript security
  # reviewer lands, ARCHITECTURE asserts something false and #1327's enumeration
  # silently omits a real reviewer — with every prose pin still green. Only a
  # tree-side check can red on that.
  #
  # CAPTURE first, then assert: inlining the pipeline into `[ … ]` would discard
  # its status, so a failed enumeration would read as a clean zero.
  # The roots must EXIST before their emptiness means anything. `find` on a
  # missing path prints to stderr and contributes no results, so a renamed or
  # merged plugin (the WebUI epic is in flight) would yield 0 and pass — a
  # permanent pass, and one that hides the prose going stale at the same moment.
  [ -d "$JS_PLUGIN" ]
  [ -d "$REACT_PLUGIN" ]
  [ -d "$SPRING_PLUGIN" ]
  local found err
  err="$BATS_TEST_TMPDIR/find-stderr.txt"
  # stderr CAPTURED rather than discarded: `2>/dev/null` would swallow a genuine
  # find failure and report it as zero matches.
  found="$(find "$JS_PLUGIN" "$REACT_PLUGIN" "$SPRING_PLUGIN" \
             -type f -name '*security-reviewer.md' 2>"$err" | wc -l | tr -d ' ')"
  printf 'security reviewers found under the three plugins: %s\n' "$found" >&2
  cat "$err" >&2
  [ ! -s "$err" ]
  [ "$found" -eq 0 ]
  # anti-vacuity: the same find over a plugin that DOES ship one must be
  # non-zero, or a broken invocation (bad flag, wrong name pattern) would report
  # 0 above forever and the guard would prove nothing
  [ -d "$GO_PLUGIN" ]
  local control
  control="$(find "$GO_PLUGIN" -type f -name '*security-reviewer.md' 2>"$err" | wc -l | tr -d ' ')"
  [ ! -s "$err" ]
  [ "$control" -ge 1 ]
  # Spring's claim is about a review PANEL, not just a reviewer file — a
  # `skills/review` directory would falsify it while the reviewer scan above
  # stayed clean. Guarded with a positive control for the same reason.
  [ ! -d "$SPRING_PLUGIN/skills/review" ]
  [ -d "$GO_PLUGIN/skills/review" ]
}

@test "the coverage claim holds against the REVIEWER FILES, not just in the prose (#1186)" {
  # The section's coverage sentence is a factual claim about four shipped
  # reviewers, and it is the claim #1327 sizes its work from. Every other
  # shipped-artifact claim here is checked against the tree; this one was pinned
  # as words alone for two rounds, which is exactly how it drifted twice (first
  # crediting Swift with a missing-authorization check it does not have, then
  # crediting Swift alone with a secret check its three siblings also ship).
  #
  # This is what `file_has` is for: the quoted-token half of a citation, which
  # `[ -f ]` alone never proves.
  local r
  for r in "$GO_REVIEWER" "$JAVA_REVIEWER" "$PYTHON_REVIEWER"; do
    [ -f "$r" ]
    # the hardcoded-credential check that already covers the no-secret-in-the-
    # binary client obligation, which the prose must not attribute to Swift alone
    grep -qiE 'API keys, tokens, passwords' -- "$r"
  done
  # The missing-authorization check pinned THROUGH its scope, per reviewer. One
  # shared needle truncated at "checks on" would match a widened "checks on any
  # handler" too — and #1327 is named in the same paragraph as the issue that
  # WIDENS this check, so the falsifying edit is already scheduled. The two
  # shipped phrasings differ, so each file gets its own literal.
  file_has "$GO_REVIEWER" 'Missing authentication/authorization checks on a handler that mutates state'
  file_has "$JAVA_REVIEWER" 'Missing authentication/authorization checks on state-changing endpoints'
  file_has "$PYTHON_REVIEWER" 'Missing authentication/authorization checks on state-changing endpoints'
  # Java's read-side exception, which the prose now records as a partial
  # coverage needing reconciliation against the ops carve-out
  file_has "$JAVA_REVIEWER" 'Sensitive endpoints (actuator-style diagnostics, debug servlets) exposed without protection'
  # Swift's carries NO authorization check — the negative half of the claim.
  # `grep -c` exits 1 on zero matches, so this cannot pass vacuously on an
  # unreadable file the way a `[ -z "$(grep …)" ]` would.
  [ -f "$SWIFT_REVIEWER" ]
  run grep -ci 'authoriz' -- "$SWIFT_REVIEWER"
  [ "$status" -eq 1 ]
  # and the two client obligations it DOES already carry
  file_has "$SWIFT_REVIEWER" 'Client secrets for OAuth flows embedded in the binary'
  file_has "$SWIFT_REVIEWER" 'Sensitive data stored in `UserDefaults` instead of Keychain'
  # …and the "and nowhere else" HALF of the platform-keystore claim. Without it
  # only the positive is checked, and #1327 adding a keystore check to the Go or
  # Python reviewer — which the same section says it "owes the client checks
  # too" — would falsify the prose with this suite green.
  # The needles are TOKEN-STORAGE vocabulary. The bare word `keystore` is
  # deliberately excluded: java-security-reviewer flags "Keystore/truststore
  # passwords in code or build files", which is JKS credential hygiene and has
  # nothing to do with where a client keeps its access token. Including it would
  # red this assertion against a check that is not the obligation at all.
  for r in "$GO_REVIEWER" "$JAVA_REVIEWER" "$PYTHON_REVIEWER"; do
    run grep -ci -e 'UserDefaults' -e 'Keychain' -e 'keyring' -e 'platform keystore' -- "$r"
    [ "$status" -eq 1 ]
  done
}

@test "the shipped artifact the status note names really DOES contradict the position (#1186)" {
  # Anti-staleness in both directions. The status note claims a specific shipped
  # template says the opposite of the gateway clause; if that stops being true
  # (because #1328 landed), this reds and the note must be rewritten rather than
  # left claiming a contradiction that no longer exists — the same discipline
  # tests/deployment-position.bats applies to its ko and Docker gap notes.
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Status: one shipped artifact contradicts this position today.**'
  contains "$section" "${APIM_TMPL#"$REPO_ROOT/"}"
  contains "$section" 'It is a **rule violation, not a wording gap**'
  contains "$section" '**#1328** is the follow-up that repairs it'
  # BOTH halves of the contradiction are named, so a #1328 that repairs only the
  # comment cannot flip this note to "repaired" while the policy still selects
  # API-key auth at the edge
  contains "$section" '**Both halves contradict this position, and #1328 must repair both.**'
  contains "$section" 'no OIDC token reaches the service at all'
  # and the file still says what the note quotes — scoped to the `auth:` BLOCK,
  # because the prose makes a block-scoped claim. A file-scoped grep would stay
  # green if the comment were demoted to a historical note elsewhere in the file.
  [ -f "$APIM_TMPL" ]
  local auth_block sibling_keys
  # EXCLUSIVE range: the `auth:` line plus its body, stopping BEFORE the next
  # sibling key or at EOF. A `sed -n '/^  auth:/,/^  [a-z]/p'` range cannot
  # express this — `auth:` is the last key in this template today, so that form
  # runs to EOF and a future sibling would be swallowed into the slice instead.
  #
  # The exit class is DELIBERATELY WIDE: `^  [^[:space:]#-]` ends the slice on
  # any sibling key, not only a lowercase-ASCII one. A narrow `^  [a-z]` misses
  # `Auth2:`, `_legacy:` or a quoted key and silently runs to EOF —
  # tests/deployment-position.bats widened its own end address to
  # `^  [A-Za-z0-9_-]` after hitting exactly that.
  auth_block="$(awk '/^  auth:/{f=1; print; next} f && /^  [^[:space:]#-]/{exit} f{print}' "$APIM_TMPL")"
  [ -n "$auth_block" ]
  starts_with "$auth_block" '  auth:'
  # The one-block invariant. Its counting class must be STRICTLY BROADER than
  # awk's exit class, or the assertion is a tautology: counting the very thing
  # awk exits on can only ever return 1, so it proves nothing and hides the
  # widening it advertises. `^  [^[:space:]]` also catches a comment line at
  # this indent, which the exit class deliberately does not stop on.
  sibling_keys="$(printf '%s\n' "$auth_block" | grep -cE '^  [^[:space:]]')"
  [ "$sibling_keys" -eq 1 ]
  contains "$auth_block" 'The gateway validates the caller; the service trusts the gateway.'
  contains "$auth_block" 'type: apikey'
}

@test "the apim slice's one-block invariant can actually FAIL — mutation control (#1186)" {
  # Without this, the invariant above is indistinguishable from a tautology: an
  # earlier form counted the same class awk exits on, so it could only ever
  # return 1 and would have passed on any template whatsoever. Here a sibling
  # key is appended after `auth:` and the same slice+count is re-run; a slice
  # that swallowed it reds, which is the property the real assertion relies on.
  [ -f "$APIM_TMPL" ]
  local mutated block count
  mutated="$BATS_TEST_TMPDIR/apiproxy-mutated.yaml.tmpl"
  cp "$APIM_TMPL" "$mutated"
  # a sibling whose key does NOT start with a lowercase ASCII letter — the exact
  # shape a narrow `^  [a-z]` exit class fails to stop on
  printf '  Auth2:\n    type: apikey\n' >> "$mutated"
  block="$(awk '/^  auth:/{f=1; print; next} f && /^  [^[:space:]#-]/{exit} f{print}' "$mutated")"
  [ -n "$block" ]
  count="$(printf '%s\n' "$block" | grep -cE '^  [^[:space:]]')"
  # the slice must stop BEFORE the sibling, so the count is still 1 — proving
  # the exit class is wide enough. (Were it too narrow, the sibling would be
  # swallowed and the count would be 2, reddening here rather than silently
  # widening the real assertion above.)
  [ "$count" -eq 1 ]
  lacks "$block" 'Auth2:'
}

@test "ARCHITECTURE says EXPLICITLY that the review dimension enum is unchanged (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # cited as PROSE, not as a heading literal: the actual heading is
  # `## Review finding schema (review panels → consolidator)`, so a truncated
  # backticked form would not resolve as a copy-paste anchor
  contains "$section" '**The dimension enum under the *Review finding schema* section is unchanged**'
  contains "$section" 'the existing `security` dimension is deepened, not extended'
  # the reason it is said out loud rather than left implied — an unstated
  # invariant is one a passing pull request extends without noticing
  contains "$section" 'a cross-language contract shared by every review panel and the consolidator'
}

@test "ARCHITECTURE scopes the position honestly — what it excludes and what enforces it TODAY (#1186)" {
  local section
  section="$(identity_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" 'Identity-provider operations, credential and recovery policy, and tenant onboarding are outside this position'
  # #1187 is unblocked by this section, not answered by it — conflating the two
  # would let a reader take the tenancy question as settled here
  contains "$section" 'is #1187, which this section unblocks rather than answers'
  # the sibling position sections all close with this disclaimer; without it, a
  # section this detailed reads as describing something already enforced. It
  # must NOT overstate the gap either: the shipped `security` reviewers already
  # carry a generic missing-authorization check, and the Deployment section is
  # careful to record exactly that kind of partial coverage
  # the coverage claim must be TRUE against the tree in both directions: Swift's
  # reviewer carries no missing-authorization check, and it already carries two
  # of the four client obligations. Overstating either way mis-sizes #1327.
  # the missing-authorization coverage must NOT be called generic: all three
  # shipped checks are scoped to mutation, so an unqualified claim tells a
  # reader that read handlers are covered when they are not
  contains "$section" 'check **scoped to state-changing handlers** — Swift'"'"'s carries none at all'
  contains "$section" 'an unauthenticated *read* is largely uncovered even where the check exists'
  # Java's read-side exception, and that it is #1327's job to reconcile it with
  # the ops carve-out rather than to start from a clean slate
  contains "$section" '**Java'"'"'s is the partial exception**'
  contains "$section" 'reconciling against the ops carve-out above**'
  # the secret check is shipped by all FOUR, not Swift alone — crediting Swift
  # alone would size #1327 to write a check three reviewers already have
  contains "$section" 'The **Go, Java, Python and Swift** reviewers all flag a hardcoded credential'
  contains "$section" 'rather than adding a second check beside it'
  contains "$section" '**Swift'"'"'s alone** flags a token kept in `UserDefaults`'
  contains "$section" 'Everything else is unenforced:'
  # and the enumeration must be CLOSED, or it silently goes stale as the section
  # grows clauses
  contains "$section" '**Nothing in this section is enforced beyond the three coverages just named.**'
  contains "$section" 'a stated position awaiting mechanism rather than a shipped guarantee'
}

@test "ARCHITECTURE never softens the position into a permission (#1186)" {
  local raw hits flat_hits
  raw="$BATS_TEST_TMPDIR/identity-section.md"
  raw_identity_section > "$raw"
  # anti-vacuity: an empty extraction would make the greps below trivially clean.
  # The RAW anchor is a single token, not the whole clause: `no trusted-header
  # mode` is itself split across one of this file's hard wraps, so a phrase-level
  # raw anchor would red here for the very reason the collapsed pass exists —
  # which is also the neatest available proof that the wrap hazard is real and
  # not theoretical. The clause is anchored in full against the collapsed
  # rendering on the next line.
  [ -s "$raw" ]
  grep -qF 'trusted-header' -- "$raw"
  local flat
  flat="$(collapse < "$raw")"
  contains "$flat" 'There is **no trusted-header mode**'
  # the range must still END where it is meant to, or a heading change could
  # truncate it and hide softened prose below the cut
  ends_with "$flat" "$ARCH_END"
  # CAPTURE first: `[ -z "$(softening_mentions …)" ]` would discard the helper's
  # status, so an errored grep would produce empty output and PASS on a file
  # that was never read — the exact hole the helper's status handling closes.
  hits="$(softening_mentions "$raw")"
  printf 'softening mentions in the Identity section:\n%s\n' "$hits" >&2
  [ -z "$hits" ]
  # AND over the collapsed rendering, so a needle straddling one of this file's
  # ~78-column hard wraps cannot hide from the line-oriented pass above.
  flat_hits="$(softening_mentions_collapsed "$raw")"
  printf 'softening mentions (collapsed) in the Identity section:\n%s\n' "$flat_hits" >&2
  [ -z "$flat_hits" ]
}

@test "the COLLAPSED pass catches a wrapped softening the raw pass provably misses (#1186)" {
  # The discrimination control for softening_mentions_collapsed. Without it the
  # second pass is an unproven addition: it would report clean forever if the
  # collapse were broken, and nothing would say so.
  #
  # This needs its own fixture. softened-position.md deliberately keeps every
  # needle contiguous on one line so the per-needle control below can find them,
  # which makes it useless here — the raw pass would match anyway and prove
  # nothing about wrapping.
  [ -f "$WRAPPED" ]
  local raw_hits flat_hits
  raw_hits="$(softening_mentions "$WRAPPED")"
  printf 'raw pass over the wrapped fixture (expected empty):\n%s\n' "$raw_hits" >&2
  [ -z "$raw_hits" ]
  flat_hits="$(softening_mentions_collapsed "$WRAPPED")"
  printf 'collapsed pass over the wrapped fixture (expected non-empty):\n%s\n' "$flat_hits" >&2
  [ -n "$flat_hits" ]
  # name WHICH needle fired: a future edit to the fixture's explanatory prose
  # that happened to contain some other needle contiguously would keep a bare
  # non-empty check green while silently destroying the wrap property
  contains "$flat_hits" 'may be trusted'
}

@test "the detector really is case-folded, as its header claims (#1186)" {
  # Nothing else proves this: every needle phrase in the fixture is lowercase,
  # so dropping `-i` from softening_mentions would leave the negative test and
  # the per-needle control both green while the guard silently narrowed — a
  # capitalised reintroduction ("**May Be Trusted**") would then ship undetected.
  local capitalised hits
  capitalised="$BATS_TEST_TMPDIR/capitalised-softening.md"
  printf 'The identity headers an ingress gateway sets May Be Trusted by the service.\n' \
    > "$capitalised"
  hits="$(softening_mentions "$capitalised")"
  printf 'case-folded detection (expected non-empty):\n%s\n' "$hits" >&2
  [ -n "$hits" ]
}

@test "EVERY softening needle is proven to discriminate against the fixture (#1186)" {
  # Without this control the test above is a permanent pass: a mis-transcribed
  # needle would match nothing forever and nothing would say so.
  #
  # Proven PER NEEDLE, not per hit-record: `softening_mentions` greps LINES, so
  # one fixture line matching two needles makes a whole-output `contains` check
  # pass even when one of the two is broken. Each needle therefore gets its own
  # single-needle grep.
  [ -f "$SOFTENED" ]
  # a for-all over an emptied array passes proving nothing — the exact failure
  # this control exists to catch, reproduced in the control itself
  [ "${#SOFTENING_NEEDLES[@]}" -ge 7 ]
  local n hit
  for n in "${SOFTENING_NEEDLES[@]}"; do
    # an EMPTY fixed-string pattern matches every line, so a stray empty entry
    # would satisfy this control while proving nothing about itself
    [ -n "$n" ]
    # drive the DETECTOR, narrowed to one needle, rather than re-implementing
    # its grep here: a control that duplicates the detector's flags cannot
    # notice the detector's flags changing underneath it
    hit="$(SOFTENING_NEEDLES=("$n"); softening_mentions "$SOFTENED")"
    [ -n "$hit" ] || {
      printf 'needle matches nothing in the fixture (typo, or missing coverage): %s\n' "$n" >&2
      return 1
    }
  done
  # and the detector as a whole fires on that fixture
  local hits
  hits="$(softening_mentions "$SOFTENED")"
  [ -n "$hits" ]
}

@test "BOTH softening helpers report a bad path as an ERROR, not as a clean file (#1186)" {
  # The guard that makes the capture-then-assert discipline above meaningful.
  # Both detectors are covered: the collapsed one has its own copy of the three
  # guards and its own failure surface, and every one of its call sites asserts
  # EMPTINESS — the shape that passes vacuously if it ever returns empty output
  # for a file it never read.
  run softening_mentions "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 2 ]
  run softening_mentions ""
  [ "$status" -eq 2 ]
  run softening_mentions_collapsed "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 2 ]
  run softening_mentions_collapsed ""
  [ "$status" -eq 2 ]
}

@test "the collapsed helper refuses a BROKEN collapse rather than reporting it clean (#1186)" {
  # The collapsed helper's one distinctive guard, and the only one the shared
  # argument-guard cases above do not reach. `collapse` is a pipeline whose
  # status is its LAST stage's, so a failed leading stage leaves an EMPTY
  # rendering and the detection then reports nothing — which every caller
  # asserts as clean. Delete the guard and the suite would stay green while the
  # collapsed pass silently stopped reading anything.
  #
  # A whitespace-only file reaches the branch directly: `-s` is true (it has
  # bytes) and it collapses to nothing.
  local blank
  blank="$BATS_TEST_TMPDIR/blank.md"
  printf '   \n\n\t\n' > "$blank"
  [ -s "$blank" ]
  run softening_mentions_collapsed "$blank"
  [ "$status" -eq 2 ]
  # the MESSAGE distinguishes this branch from the three shared argument guards,
  # which also return 2 — without it the case could pass for the wrong reason
  contains "$output" 'collapse produced an empty rendering'
}

@test "the detector REFUSES an empty needle array instead of hanging on stdin (#1186)" {
  # Without the `[ "${#args[@]}" -gt 0 ]` refusal, `grep -inF -- "$1"` reads the
  # PATH as the pattern and then blocks reading stdin — a hung CI job, not a red
  # test. That is the worst failure mode in this file and nothing else exercises
  # it, so removing the guard would ship green.
  #
  # bats re-sources the file for every test, so narrowing the array here cannot
  # leak into any other test.
  SOFTENING_NEEDLES=()
  run softening_mentions "$SOFTENED"
  [ "$status" -eq 2 ]
}
