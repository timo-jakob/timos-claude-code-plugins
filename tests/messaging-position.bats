#!/usr/bin/env bats
#
# The family's messaging position (#1060, epic #1058).
#
# ARCHITECTURE.md's "Messaging" section is the authoritative record: NATS
# JetStream is the single event backbone, every event carries a CloudEvents 1.0
# envelope, and five wire-contract specifics hold by default. Two other places
# restate it for a different audience — docs/explanation/why-per-language-plugins.md
# (the worked example of what an opinion IS) and the 2026-07-23 resilience
# design spec's Adjacencies section — and the c4/v1 worked example uses the
# blessed broker as its `ContainerQueue` technology in three lockstepped places.
#
# WHY THIS FILE EXISTS: the defect #1060 repairs is a *silent* one. The repo
# stated one messaging opinion (a JMS broker by default, a log-structured one at
# scale) while the family held another, and each side was internally consistent,
# so nothing went red. A position nobody asserts can be softened, reversed, or
# quietly reacquire an escape hatch with the suite green — which is exactly how
# the drift got in. So the position is pinned clause-by-clause, and pinned
# NEGATIVELY too: half of #1060's deliverable is that the superseded broker
# names are GONE from ARCHITECTURE.md and docs/, which no positive assertion can
# express.
#
# The negative needles here are single robust TOKENS (`artemis`, `kafka`), not
# transcriptions of deleted wording, so — unlike tests/webui-positions.bats —
# they need no committed fixture to prove they discriminate: they cannot be
# mis-transcribed, and they red on a re-introduction however it is phrased. They
# are matched case-folded, so a lowercase or shouted reintroduction is caught
# too.
#
# The sweep is REPO-WIDE, not a three-file spot check. A comment surveying the
# repo at authoring time is not an assertion: a reintroduction in a bootstrap
# template, an agent, a README or a new dated spec would ship green while the
# file claimed to prevent exactly that. So the last negative test greps EVERY
# tracked file — no extension pathspec, binaries skipped by content — and the
# exemptions are an inline ALLOWLIST of THREE paths: the two deliberate
# survivors below, plus this file itself, which necessarily transcribes the
# needles it searches for. Widening that list is a visible edit, which is the
# property a comment cannot give you. (This is the one place this file departs
# from tests/webui-positions.bats, which correctly refuses a repo-wide `Angular`
# sweep because dated specs legitimately name Angular historically. There is no
# comparable legitimate use here.)
#
# Both survivors are also pinned POSITIVELY below, so a future over-eager sweep
# that deletes them reds here rather than passing:
# development-go/agents/go-resilience-reviewer.md states factual client-timeout
# defaults (not a family position), and tests/fixtures/c4/c4-container-exclusions.md
# depicts an EXTERNAL third-party queue (external systems are not family
# opinions).

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  WHY="$REPO_ROOT/docs/explanation/why-per-language-plugins.md"
  RESILIENCE_SPEC="$REPO_ROOT/docs/superpowers/specs/2026-07-23-resilience-dependency-health-design.md"
  C4_FIXTURE="$REPO_ROOT/tests/fixtures/c4/c4-container.md"
  C4_EXCLUSIONS="$REPO_ROOT/tests/fixtures/c4/c4-container-exclusions.md"
  GO_REVIEWER="$REPO_ROOT/development-go/agents/go-resilience-reviewer.md"
  WORKFLOW="$REPO_ROOT/.github/workflows/script-tests.yml"
}

# Collapse a document region to one line: strip blockquote markers, collapse
# whitespace, trim the trailing space `tr` leaves behind. Same helper shape as
# tests/webui-positions.bats, and the trim is what makes `ends_with` usable as
# the end-anchor pin.
collapse() {
  sed 's/^>[[:space:]]\{0,1\}//' | tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

# Extract FILE's section from START to END (both sed BRE addresses, neither
# containing a `/`), collapsed. sed prints the END line itself, which is what
# the `ends_with` pins below rely on — a renamed END anchor otherwise widens the
# range silently to EOF instead of failing.
extract() {
  sed -n "/$2/,/$3/p" "$1" | collapse
}

# Every case-insensitive mention of a superseded broker name in FILE, as
# `<line>:<text>` records — empty when the file is clean, so `[ -z ]` is the
# assertion and the records are the diagnostic.
#
# THE TOKEN SET is `artemis|kafka|activemq`: both product spellings of the
# retired JMS default (a restatement worded "ActiveMQ" alone would match neither
# of the other two) plus the retired log-structured one. All three have zero
# legitimate occurrences outside this file's allowlist.
#
# WHY grep AND NOT a collapsed-string `lacks`: `grep -i` reports WHERE the hit
# is, which the collapsed form cannot, and it does not slurp the whole
# ARCHITECTURE.md (~380 KB) into a shell variable to answer a yes/no question.
# Those two reasons are what keep this helper here.
#
# The other half of this rationale is HISTORICAL and no longer true: when
# `contains`/`lacks` were `${1#*"$2"}`, bash's prefix removal over that haystack
# was quadratic enough to cost ~100 seconds for one assertion (the canonical
# measurements in tests/assertions.bash put it at 57 s hit / 94 s miss over
# 380 KB). #1507 replaced the idiom with `[[ "$1" == *"$2"* ]]` / `!=`
# (0.0205 s on that haystack), so the cost argument is gone — do not cite it.
#
# `|| [ "$?" -eq 1 ]` rather than `|| true`: grep exits 1 on a clean no-match and
# 2 on a REAL error (missing or unreadable file, empty `$1`). `|| true` folds the
# error into the clean case, so the caller's `[ -z ]` would pass on a file that
# was never read — the permanent-pass class this file exists to remove. This
# form returns non-zero on exit 2, which errexit catches at the call site.
broker_mentions() {
  grep -in -e artemis -e kafka -e activemq -- "$1" || [ "$?" -eq 1 ]
}

# FILE contains the literal (single-line) string — the positive anchor that
# proves a negative test's haystack is the real file. Same reason as above for
# not routing a whole file through `contains`.
#
# The guard is not optional: `grep -qF ''` matches every non-empty file, so a
# dropped second argument (bats does not run test bodies under `set -u`) would
# turn the anti-vacuity anchor of three purely-negative tests into an
# unconditional pass. That is exactly what tests/assertions.bash's `_assert_args`
# exists to prevent, so reuse it rather than re-deriving it. `-e`/`--` keep a
# needle that begins with `-` from being read as an option.
file_has() {
  _assert_args "$#" "${2-}" || return 2
  grep -qF -e "$2" -- "$1"
}

# --- the authoritative record ------------------------------------------------

ARCH_END='### Browser UI — SPA shell, micro-frontends, React default (#1059)'

# The end ADDRESS is the generic `^### `, not the specific heading named by
# ARCH_END. A specific address catches a renamed or deleted anchor but NOT an
# inserted one: a section slipped in between is swallowed into the range while
# the haystack still ends with the pinned heading, so every assertion below
# would silently widen to cover two sections. The `ends_with` pin then names the
# heading that follows TODAY. Same idiom as tests/deployment-position.bats and
# tests/webui-positions.bats and tests/identity-position.bats, so all four
# position suites behave identically.
arch_section() {
  extract "$ARCH" '^### Messaging' '^### '
}

@test "ARCHITECTURE states ONE messaging default — NATS JetStream + CloudEvents 1.0, no reserve broker (#1060)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**The default event backbone is NATS JetStream, and every event on it carries a CloudEvents 1.0 envelope.**'
  # the singleness is the position. A bare "NATS is the default" survives
  # re-adding an at-scale escape hatch, which is precisely what #1060 retired.
  contains "$section" 'one broker, none held in reserve for scale'
  contains "$section" 'no stated class of use that reaches for a different mechanism'
}

@test "ARCHITECTURE states all FIVE wire-contract specifics as defaults, not options (#1060)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**The wire contract is part of the position, not a per-service choice.**'
  contains "$section" '**A CloudEvents 1.0 envelope on every event**'
  contains "$section" '**At-least-once delivery**'
  contains "$section" '**Idempotent consumers**'
  contains "$section" '**Transactional-outbox publishing**'
  contains "$section" '**Replayable streams**'
}

@test "ARCHITECTURE gives each wire-contract specific its reason, so it can be argued with (#1060)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # the envelope's reason IS its required attribute set — the most operational
  # detail of the whole wire contract, and what an implementer codes to. Pinning
  # only the bullet's bold label (the five-defaults test above) would let a trim
  # to "a CloudEvents envelope on every event" delete the contract and pass.
  contains "$section" '`id`, `source`, `type`, `specversion` and `time` are structural'
  contains "$section" 'without knowing which service wrote it'
  # at-least-once and idempotency are one decision stated as two bullets; the
  # link between them is the part a later edit would most easily drop
  contains "$section" 'Exactly-once is not promised at the transport'
  contains "$section" 'the necessary consequence of the line above'
  # the outbox exists for one specific failure, and naming it is what stops the
  # bullet degrading into ceremony
  contains "$section" 'a crash between commit and publish drops an event silently'
  contains "$section" 'rebuilding a projection an ordinary operation'
}

@test "ARCHITECTURE closes the outbox default's enumeration — both branches, no silent gap (#1060)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  # "all five hold by default" over a bullet defined in terms of the producer's
  # OWN database leaves a producer with no local state undefined. Unclosed, an
  # implementer's only options are to invent a datastore to host an outbox or to
  # violate a stated default silently — so the branch is part of the position.
  contains "$section" 'a producer that holds no transactional state of its own'
  contains "$section" 'publishes directly, and inherits whatever guarantee its source gives it'
  # and the shape the replay bullet makes easy to reach for is refused explicitly
  # rather than left arguable
  contains "$section" 'Making the stream itself the system of record is a **different** architecture'
}

@test "ARCHITECTURE gives the position a family-native rationale (#1060)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" 'one blessed path with one good default'
  contains "$section" 'a second admitted broker is a permanent maintenance and expertise cost'
  # the two adjacencies that make this cohere with positions already recorded
  # above rather than read as a standalone preference
  contains "$section" 'CloudEvents 1.0 then makes the envelope contract-first'
  contains "$section" 'composes with the gRPC-internal direction'
}

@test "ARCHITECTURE states the Java trade-off honestly rather than selling the position (#1060)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**The trade-off, stated honestly.**'
  contains "$section" 'gives up the first-class `jakarta.jms` ecosystem and its Spring Boot starter'
  contains "$section" 'uses the NATS Java client plus the CloudEvents SDK instead'
}

@test "ARCHITECTURE scopes the section to the POSITION, not to building it (#1060)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" 'is a separate and currently unscheduled concern'
  contains "$section" 'the position that machinery would be built *to*'
}

# --- the negative half: the superseded position is GONE ----------------------

@test "ARCHITECTURE names neither superseded broker anywhere in the file (#1060)" {
  local hits
  # positive anchor FIRST: a purely-negative test passes on an empty or
  # unreadable haystack, so prove the file is the real one before asserting
  # what it does not contain.
  file_has "$ARCH" 'The default event backbone is NATS JetStream,'
  hits="$(broker_mentions "$ARCH")"
  printf 'ARCHITECTURE.md superseded-broker mentions:\n%s\n' "$hits" >&2
  [ -z "$hits" ]
}

@test "the why-per-language-plugins worked example names the current position only (#1060)" {
  local hits
  file_has "$WHY" 'NATS JetStream carrying CloudEvents 1.0 envelopes'
  # the list closes with "the per-language plugin is where those decisions live",
  # but no plugin under development*/ SCAFFOLDS the NATS/CloudEvents position
  # (go-resilience-reviewer's `nats.go dials at 2s` is client trivia, not the
  # opinion — this file pins it as a survivor below) and ARCHITECTURE says
  # building it is unscheduled — so the clause carries its own status, or this
  # file overclaims a shipped opinion
  file_has "$WHY" 'plugin scaffolds yet — see ARCHITECTURE.md)'
  # ...and the item's CLOSING sentence has to agree with that hedge. Unqualified,
  # "the per-language plugin is where those decisions live" is false for the one
  # decision the parenthetical just exempted, and sends a reader hunting under
  # development-*/ for a position that lives in ARCHITECTURE.md.
  file_has "$WHY" 'per-language plugin is where those decisions live once they are mechanized;'
  # this file's whole point is "here is what an opinion looks like", so a stale
  # opinion here is worse than a stale one in a dated spec
  hits="$(broker_mentions "$WHY")"
  printf 'why-per-language-plugins.md superseded-broker mentions:\n%s\n' "$hits" >&2
  [ -z "$hits" ]
}

@test "the resilience spec's Adjacencies bullet is corrected IN PLACE, broker policy unchanged (#1060)" {
  local section
  section="$(extract "$RESILIENCE_SPEC" '^## 6\. Adjacencies' '^## 7\.')"
  [ -n "$section" ]
  ends_with "$section" '## 7. Considered and rejected'
  contains "$section" '**Messaging (NATS JetStream + CloudEvents 1.0, #1060)**'
  # the breaker policy is broker-agnostic; #1060 corrected the name it cited and
  # nothing else, and saying so is what stops a reader inferring a policy change
  contains "$section" 'a broker is a dependency like any other'
  contains "$section" 'The breaker policy itself is broker-agnostic and unchanged by the messaging position.'
  # the hard/soft EXAMPLE has to cohere with the outbox default this bullet now
  # cites: under an outbox the broker is off the synchronous write path, so a
  # producer's broker loss is soft. The pre-#1060 example said the opposite, and
  # following it would shed traffic on a path that still works.
  contains "$section" 'the broker is **off** the synchronous write path'
  contains "$section" "a producer's broker loss is characteristically **soft**"
  contains "$section" 'Hard is for a service whose core function is driven by what it **consumes**'
  # ...and the OTHER producer shape ARCHITECTURE carves out. Without this clause
  # the rule reads as a flat producer/consumer dichotomy, and a resilience
  # reviewer would push a direct-publishing bridge's hard broker declaration to
  # soft — keeping a pod "ready" that can do nothing.
  contains "$section" 'publishes **directly**, so the broker *is* its synchronous path'
  # ...and ONE verdict for that shape. "classifies like any other dependency"
  # read two ways — hard by the head clause, per-service by the tail — and a
  # reviewer applying either would contradict one applying the other.
  contains "$section" "when that direct publish IS the service's core function (the bridge case), its broker is **hard**"
}

@test "the resilience spec's aggregate rule matches the SHIPPED conformance checker (#1060)" {
  local section
  # Not a messaging assertion, and here on purpose. #1060 edits this spec, and
  # correcting its Adjacencies bullet surfaced that §2's aggregate rule
  # contradicted development/skills/bootstrap/templates/common/scripts/check-ops-conformance.zsh
  # on three points — the middle branch is kind-agnostic and includes `degraded`,
  # and a `down` aggregate fails outright rather than being legal over-reporting.
  # That correction is this PR's, so its guard is this PR's too: unpinned it
  # would revert as silently as the messaging position did.
  section="$(extract "$RESILIENCE_SPEC" '^## 2\. The health model' '^## 3\.')"
  [ -n "$section" ]
  ends_with "$section" '## 3. The resilience policy — the six mandates'
  contains "$section" 'else at least `degraded` if **any** component, hard or soft, is down **or degraded**'
  contains "$section" 'The middle branch is deliberately **kind-agnostic**'
  contains "$section" 'It separately fails a `down` aggregate **outright**'
  # the aggregate's vocabulary is not the components' — conflating them is what
  # would send an implementer to emit `ok` for a healthy COMPONENT
  contains "$section" "**On the wire the AGGREGATE's healthy value is \`ok\`, not \`up\`**"
  contains "$section" 'closed = `up`, half-open = `degraded`, open = `down`'
}

@test "the resilience spec names neither superseded broker anywhere (#1060)" {
  local hits
  file_has "$RESILIENCE_SPEC" '**Messaging (NATS JetStream + CloudEvents 1.0, #1060)**'
  hits="$(broker_mentions "$RESILIENCE_SPEC")"
  printf 'resilience spec superseded-broker mentions:\n%s\n' "$hits" >&2
  [ -z "$hits" ]
}

@test "NO tracked file names a superseded broker, bar the two survivors and this file (#1060)" {
  local raw err hits
  err="$BATS_TEST_TMPDIR/sweep.err"
  # EVERY tracked file, with NO extension pathspec. An extension list is the
  # obvious spelling and it silently exempted the highest-blast-radius surface
  # in the repo: bootstrap ships ~60 `*.tmpl` templates (CLAUDE.md.tmpl, compose
  # and workflow templates, `templates/languages/**` Java/Python/TS sources)
  # verbatim INTO every bootstrapped repo, and none of them end in .md/.yml. A
  # broker default reintroduced in a scaffolded dependency catalog or a Gradle
  # template is the worst case this test exists for, so it must be swept.
  #   -z / -0  NUL-delimited, so a path with a space — or one git would C-quote
  #            under core.quotePath — reaches grep intact instead of as a name
  #            that does not exist (which the old `2>/dev/null` then hid).
  #   -I       skip binaries BY CONTENT, which is what the extension list was
  #            really approximating.
  #   -i / -l  the case fold, and name-the-file output.
  raw="$(cd "$REPO_ROOT" && git ls-files -z |
    xargs -0 grep -rIil -e artemis -e kafka -e activemq -- 2>"$err" || true)"
  # POSITIVE CONTROL, and the reason this negative cannot pass vacuously: the
  # three allowlisted files are KNOWN to contain the tokens, so an unfiltered
  # scan MUST find all three. Anchoring on the file LIST instead — the obvious
  # spelling — proves only that `git ls-files` spoke; it says nothing about
  # whether grep ever ran, so a grep that could not exec, or died on every file,
  # would read as a clean repo. This also makes each allowlist entry
  # self-verifying: a stale entry reds here instead of rotting into a blind spot.
  contains "$raw" 'development-go/agents/go-resilience-reviewer.md'
  contains "$raw" 'tests/fixtures/c4/c4-container-exclusions.md'
  # The third entry is this file, and it is a control only once git tracks it —
  # `ls-files` cannot see it on the run that first introduces it, before the
  # commit. Guarded rather than dropped: from the commit onward (so on every CI
  # run and every run after merge) the control is live, and a stale self-entry
  # reds like the other two. The two survivors above are always tracked, so the
  # anti-vacuity guarantee never depends on this branch.
  if git -C "$REPO_ROOT" ls-files --error-unmatch tests/messaging-position.bats >/dev/null 2>&1; then
    contains "$raw" 'tests/messaging-position.bats'
  fi
  # grep writes to stderr on a real error (exit 2) and stays silent on a clean
  # no-match (exit 1), so an empty stderr proves every listed file was actually
  # read. Keeping the old `2>/dev/null` would fold "unreadable file" into "clean".
  printf 'sweep stderr:\n%s\n' "$(cat "$err")" >&2
  [ ! -s "$err" ]
  # THE ALLOWLIST — three entries, each with its reason. Widening it is a visible
  # edit, which is the whole point of an allowlist over a survey comment:
  #   go-resilience-reviewer.md   factual client-timeout defaults, not a position
  #   c4-container-exclusions.md  an EXTERNAL third-party queue
  #   this file                   it transcribes the needles it searches for
  # The `|| true` is NOT a neutralised assertion: `grep -v` exits 1 when it
  # filters everything away, which is the CLEAN case. `[ -z "$hits" ]` is the
  # assertion, and the scan's own health is already pinned above.
  hits="$(printf '%s\n' "$raw" |
    grep -v -e '^development-go/agents/go-resilience-reviewer\.md$' \
      -e '^tests/fixtures/c4/c4-container-exclusions\.md$' \
      -e '^tests/messaging-position\.bats$' || true)"
  printf 'tracked files naming a superseded broker:\n%s\n' "$hits" >&2
  [ -z "$hits" ]
}

@test "the bats suite's PR path filter is a superset of the repo-wide sweep (#1060)" {
  local block collapsed
  # The sweep above asserts over EVERY tracked file, so this suite must run on a
  # PR touching ANY of them. An enumerated filter cannot express that — the first
  # attempt missed docs/adding-a-language-plugin.md, the other workflows and
  # every repo-root config file — so the workflow carries a `**` catch-all, and
  # this test is what stops a later tidy-up from silently re-narrowing it back
  # into a list that looks complete and is not.
  #
  # Assert on the RAW block, not a collapsed one, and line-anchored — the idiom
  # tests/resilience-review-dimension.bats and tests/kubernetes-topic-marker.bats
  # already use on this same file, for the reason they state: this region is
  # mostly COMMENTS, and a collapsed substring cannot tell a live entry from
  # prose. `contains` over the collapsed block passes on all three realistic
  # re-narrowings — a commented-out `#   - '**'`, a `paths:` → `paths-ignore:`
  # key swap (catch-all still present, trigger inverted), and an appended
  # negation — i.e. it is vacuous exactly where it is meant to bite.
  block="$(sed -n '/^  pull_request:/,/^  push:/p' "$WORKFLOW")"
  [ -n "$block" ]
  # the extractor's own end-anchor pin: a renamed `push:` would run the range to
  # EOF and drag the rest of the workflow into the haystack
  collapsed="$(printf '%s\n' "$block" | collapse)"
  ends_with "$collapsed" 'push:'
  # the KEY must still be `paths:` — `-x` refuses `paths-ignore:`, which would
  # invert the trigger while leaving every entry below it literally present
  printf '%s\n' "$block" | grep -qxF '    paths:'
  # the ENTRY must be a real list item at its own indent — `-x` refuses any
  # commented-out spelling
  printf '%s\n' "$block" | grep -qxF "      - '**'"
  # and no negation may claw scope back out from under the catch-all — in EITHER
  # YAML quoting. `- "!.github/**"` is as legal and as effective as the
  # single-quoted spelling, and a guard that knows only one of them is
  # spelling-specific where it means to be a superset check.
  lacks "$collapsed" "- '!"
  lacks "$collapsed" '- "!'
}

# --- the c4/v1 worked example: three places, one string ----------------------

@test "the C4 worked example, its expected output, and the fixture all name the blessed broker (#1060)" {
  # tests/extract-declared-containers.bats already diffs the contract's
  # example-output against the parser's output on the fixture, so a drift there
  # is caught — but it is caught as a JSON diff on an unrelated-looking test.
  # Pinning the string in all three places localizes a messaging regression to
  # this file, where the reason for the value is written down.
  local mermaid expected fixture
  mermaid="$(extract "$ARCH" '<!-- c4\/v1:example:start -->' '<!-- c4\/v1:example:end -->')"
  [ -n "$mermaid" ]
  # the end-anchor pin this file's `extract` docstring demands: these anchors are
  # MACHINERY (awk in tests/extract-declared-containers.bats consumes them), so a
  # rename is a plausible edit — and an unpinned rename would widen the haystack
  # to EOF, where the needle below would still be found somewhere in the file
  ends_with "$mermaid" '<!-- c4/v1:example:end -->'
  contains "$mermaid" 'ContainerQueue(events, "Event Bus", "NATS JetStream")'
  expected="$(extract "$ARCH" '<!-- c4\/v1:example-output:start -->' '<!-- c4\/v1:example-output:end -->')"
  [ -n "$expected" ]
  ends_with "$expected" '<!-- c4/v1:example-output:end -->'
  contains "$expected" '"technology": "NATS JetStream"'
  fixture="$(collapse < "$C4_FIXTURE")"
  [ -n "$fixture" ]
  contains "$fixture" 'ContainerQueue(events, "Event Bus", "NATS JetStream")'
}

# --- the two deliberate survivors --------------------------------------------

@test "the Go reviewer keeps its FACTUAL broker-client timeout defaults (#1060 deliberately unchanged)" {
  local body
  body="$(collapse < "$GO_REVIEWER")"
  [ -n "$body" ]
  # these are observed client defaults found in target repos, not a family
  # position — a sweep that deleted them would delete true information and
  # weaken the reviewer's false-positive guard
  contains "$body" "kafka-go's dialer and \`WriteTimeout\` are 10s"
  contains "$body" 'nats.go dials at 2s'
}

@test "the C4 exclusions fixture keeps its EXTERNAL third-party queue (#1060 deliberately unchanged)" {
  local body
  body="$(collapse < "$C4_EXCLUSIONS")"
  [ -n "$body" ]
  # an _Ext queue is somebody else's system; the family's messaging position
  # says nothing about what a third party runs, and the fixture needs a
  # recognisable external technology to exercise the exclusion path
  contains "$body" 'ContainerQueue_Ext(ext_q, "External Queue", "Kafka")'
}
