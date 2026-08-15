#!/usr/bin/env bats
#
# The `persona_derivations` story-spec field and the corner-case derivation it
# records (#1361, slice 1 of epic #1266).
#
# WHY THIS FILE EXISTS: the whole deliverable of #1361 is PROSE — a field added
# to ARCHITECTURE.md's *Story-spec contract* and a derivation section added to
# `development/agents/issue-refiner.md`. There is no script to test, so without a
# pinning suite the entire slice can be softened, half-deleted or reverted by an
# unrelated PR with the suite green. Same rationale, and same idiom, as
# tests/identity-position.bats, tests/messaging-position.bats,
# tests/deployment-position.bats and tests/webui-positions.bats.
#
# WHAT IS PINNED, and why each clause individually rather than one
# "section mentions persona_derivations" check (which would survive deleting any
# one of them):
#   * the contract row and its five sub-fields, plus the two properties the
#     contract calls deliberate — OPTIONAL and NEVER VALIDATED. Those two are what
#     make the field additive rather than a story-spec/v2; a later slice quietly
#     promoting it to required is the regression this catches.
#   * the closed `slice` and `target` vocabularies, checked as ONE transcription
#     against the producer agent — the tests/review-loop-budget-consistency.bats
#     idiom — so a rename in one file cannot drift from the other.
#   * the ADVISORY nature of the underivable-gap rule, and its silence
#     conditions. An earlier draft made this gap a blocking `resolved_objections`
#     entry with waiver bookkeeping and a once-per-session bound; it produced a
#     CRITICAL in four consecutive review rounds, because it asked a per-turn PURE
#     FUNCTION — one that never receives its own prior output — to behave
#     statefully. It is now a `recommendations` entry and nothing more. These pins
#     exist so that design cannot creep back in.
#   * the single-producer rule, which is the reason story-readiness.md's field
#     enumeration names the field only to EXCLUDE it. Not "omits" — the gate's
#     enumeration does mention it, as an explicit negative, and a test below pins
#     that mention; the omits-framing invited an editor to delete the pinned
#     parenthetical to make the gate match the prose.
#   * all three worked JSON examples, PARSED and checked for internal consistency.
#     That is not decoration: the pre-review draft of this change shipped an
#     example attributing a derivation to a persona absent from its own
#     `personas[]`, and the agent example IS the model's copy-template.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` — the standing
# rule from #1189. Line numbers rot across unrelated merges; these tokens do not.
#
# ON THE END ADDRESS: the extractors use the GENERIC next-heading address, and a
# companion `ends_with` names the heading that follows TODAY. A specific end
# address catches a renamed or deleted anchor but NOT an inserted one — a new
# section slipped in between would be swallowed into the range while the haystack
# still ended correctly, silently widening every assertion here.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  REFINER="$REPO_ROOT/development/agents/issue-refiner.md"
  GATE="$REPO_ROOT/development/agents/story-readiness.md"
  WALK="$REPO_ROOT/development/skills/refine-issue/docs/END-TO-END-WALKTHROUGH.md"
}

# The sections' sed addresses, as constants rather than transcribed per test.
DERIV_START='^### `persona_derivations` — a record, not a mechanism'
CORNER_START='^## Corner cases from `data_traits`'
SECTION_END_3='^### '
SECTION_END_2='^## '

# Collapse a document region to one line: strip blockquote markers, collapse
# whitespace, trim the trailing space `tr` leaves behind. Same helper shape as
# the other position suites; the trim is what makes `ends_with` usable.
collapse() {
  sed 's/^>[[:space:]]\{0,1\}//' | tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

# Extract FILE's region from START to END, collapsed, FIRST MATCH ONLY.
#
# Deliberately awk, not `sed -n "/s/,/e/p"`: a sed range RE-TRIGGERS, so if the
# START address ever matches twice — and #1362/#1363 are documented to edit these
# very sections, so a sibling heading is a realistic near-term state — sed prints
# both regions, `collapse` folds them into one line, and every `contains` here
# could then be satisfied by text from the second region while `ends_with` pins
# only the last one's terminator. Both green, neither testing the named section.
#
# The END line IS printed, which is what the `ends_with` boundary pins rely on.
#
# Scope of the typed exit 2, stated precisely because the earlier draft of this
# comment overclaimed it: only the ARGUMENT and READABILITY guards are typed
# (wrong arity, an empty START or END anchor, an unreadable file). A START address
# that matches nothing still yields empty output at status 0. That is safe as the
# file stands — every call site asserts with `contains`/`ends_with`, which fail on
# an empty haystack — but it is NOT protection for a future `lacks`, which would
# pass vacuously. Add one only alongside a non-empty check.
#
# Patterns go through the environment, not `awk -v`, for the same reason
# json_after does it: `-v` applies escape-sequence processing to the value, so an
# anchor containing `\.`, `\|` or `\[` would be silently de-escaped and the regex
# quietly widened. No constant needs escaping today; keeping both helpers on one
# seam is what stops the next one from being written the unsafe way.
extract() {
  # Same typed guards as file_has: a dropped argument leaves an EMPTY regex,
  # which matches every line, so the range would open on line 1 and the haystack
  # would be some arbitrary two-line slice at status 0.
  [ "$#" -eq 3 ] || return 2
  [ -n "${2-}" ] || return 2
  [ -n "${3-}" ] || return 2
  [ -r "$1" ] || return 2
  # awk's status is captured BEFORE collapsing: a pipeline returns its last
  # command's status and bats runs no `pipefail`, so piping straight into
  # collapse would swallow an awk failure (a future anchor that is not a
  # compilable ERE aborts awk) and surface it as a `contains` mismatch against an
  # empty haystack — "the prose was deleted" rather than "the anchor is
  # malformed", opposite fixes.
  local out
  out=$(S="$2" E="$3" awk '
    BEGIN { s = ENVIRON["S"]; e = ENVIRON["E"] }
    fin                     { next }
    !inr && $0 ~ s          { inr = 1; print; next }
    inr                     { print; if ($0 ~ e) { fin = 1; inr = 0 } }
  ' "$1") || return 2
  printf '%s\n' "$out" | collapse
}

# FILE contains the literal (single-line) string $2. Used instead of
# `run cat "$FILE"` + `contains` for WHOLE-file checks: `contains` is a
# `${1#*"$2"}` parameter expansion, which is pathologically slow on a
# 280 KB-plus ARCHITECTURE.md under the bash 3.2 macOS ships — slow enough to
# hang the suite rather than fail it. `contains` stays correct (and fast) on the
# small extracted sections above. Same helper as tests/identity-position.bats;
# the explicit empty-needle guard matters because `grep -qF ''` matches every
# non-empty file and would turn the assertion into an unconditional pass.
file_has() {
  [ "$#" -eq 2 ] || return 2
  [ -n "${2-}" ] || return 2
  # Explicitly typed BEFORE grep: grep returns 2 for an unreadable file and 1 for
  # a genuine absence, and propagating both unchanged makes "the pinned prose was
  # deleted" indistinguishable from "ARCHITECTURE.md moved" — opposite fixes.
  [ -r "$1" ] || { printf 'file_has: not readable: %s\n' "$1" >&2; return 2; }
  grep -qF -e "$2" -- "$1"
}

# The FIRST fenced ```json block following the given heading regex in FILE, with
# the fences stripped — i.e. the JSON itself, ready for jq. First-only is
# load-bearing: a sed range would re-trigger on every later fence and emit all of
# them concatenated, which is not valid JSON and would fail every parse pin here
# for a reason unrelated to what they test.
# Bounded to the heading's own section, and LOUD on failure. Both matter:
#   * unbounded, awk would scan to EOF and emit some LATER section's json block
#     if this one lost its fence — the JSON still parses, so every consistency
#     pin below would silently validate a region the test does not name;
#   * exiting 0 having matched nothing writes a zero-byte file, and the failure
#     then surfaces only as `jq -e` exit 4, which reads like malformed JSON when
#     the real cause is a renamed heading — opposite fixes.
# The pattern goes through the environment rather than `awk -v`, which applies
# escape-sequence processing to its value and would silently mangle a heading
# containing `\.`, `\|` or `\[`.
json_after() {
  # The arity guard matters MORE here than in extract: a dropped `$2` leaves an
  # empty regex, `$0 ~ ""` is true on line 1, and the helper would then emit the
  # file's FIRST json block instead of erroring. That block still parses, so a
  # `jq -e` pin would silently validate a region the test does not name — the
  # exact hazard the section bound below exists to prevent.
  [ "$#" -eq 2 ] || return 2
  [ -n "${2-}" ] || return 2
  [ -r "$1" ] || return 2
  START="$2" awk '
    BEGIN                          { start = ENVIRON["START"] }
    !seen && $0 ~ start            { seen = 1; next }
    seen && !inblock && /^#+ /     { exit 3 }
    seen && !inblock && /^```json$/ { inblock = 1; next }
    seen &&  inblock && /^```$/    { exit }
    seen &&  inblock               { printed = 1; print }
    END {
      if (!seen)    { print "json_after: heading not found: " start > "/dev/stderr"; exit 3 }
      if (!printed) { print "json_after: no json block in that section"  > "/dev/stderr"; exit 3 }
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# The contract row and the deliberate properties
# ---------------------------------------------------------------------------

@test "contract: the story-spec field table carries a persona_derivations row naming all five sub-fields" {
  file_has "$ARCH" '| `persona_derivations` | object[] |'
  file_has "$ARCH" '`slice` (`corner-cases` \| `ux` \| `consistency`)'
  file_has "$ARCH" '`persona` (a `personas/v1` id, or `null`)'
  file_has "$ARCH" '`basis` (the persona field it came from, with the shape that made it a corner'
  file_has "$ARCH" '`target` (`test_cases` \| `acceptance_criteria`)'
  file_has "$ARCH" '`ref` (a `test_cases[].id`, or the `acceptance_criteria` string verbatim)'
}

@test "contract: the row still marks the field OPTIONAL, so it stays additive rather than a v2" {
  file_has "$ARCH" '**Optional (#1361)**'
  file_has "$ARCH" '`[]` or absent when nothing was derived'
}

@test "contract: the subsection still says the field is optional and a consumer may ignore it" {
  run -0 extract "$ARCH" "$DERIV_START" "$SECTION_END_3"
  contains "$output" '**It is optional.**'
  contains "$output" 'a consumer that ignores the field is still correct'
}

@test "contract: the subsection still says NOTHING validates it — an audit record, never a gate" {
  run -0 extract "$ARCH" "$DERIV_START" "$SECTION_END_3"
  contains "$output" '**Nothing validates it.**'
  contains "$output" 'It is an audit record, never a gate.'
}

@test "contract: the substance binds in the fields that already bind, not in this one" {
  run -0 extract "$ARCH" "$DERIV_START" "$SECTION_END_3"
  contains "$output" 'a derived corner case is a `test_cases[]` entry'
  contains "$output" 'a derived UI/UX consequence is an `acceptance_criteria[]` entry'
}

@test "contract: exactly one producer — the gate leaves the field absent, deliberately" {
  run -0 extract "$ARCH" "$DERIV_START" "$SECTION_END_3"
  contains "$output" '**One producer, not two.**'
  contains "$output" 'only `issue-refiner` populates this field'
  # "names it only to EXCLUDE it", not "does not list it": the gate's enumeration
  # does mention the field, as an explicit negative, and the test below pins that
  # mention — so the earlier wording invited an editor to delete the pinned
  # parenthetical to make the gate match this paragraph.
  contains "$output" 'enumeration names it only to **exclude** it'
  contains "$output" 'That exclusion is deliberate and explicit'
}

@test "contract: the gate's own field enumeration records the omission rather than leaving it ambiguous" {
  # Needles must not span a line break: file_has is grep -F, which matches
  # within a single line. Prefer the collapsed `extract` + `contains` when a
  # clause genuinely wraps.
  file_has "$GATE" '**no** `persona_derivations`'
  file_has "$GATE" 'derives from a persona, so your proposed block leaves that'
  # ABSENT, not empty — the distinction is the single-producer consequence, and
  # the needle above stops one line short of it, so flipping the doc to "empty
  # rather than absent" would leave that needle intact.
  file_has "$GATE" 'field absent rather than empty'
}

# The parenthesis and the pronoun are the defect round 2 found: an unclosed `(`
# left "Populate it" bound to persona_derivations, licensing the exact opposite
# of the rule the preceding clause states.
@test "contract: the gate's field list closes its parenthesis and re-anchors the pronoun" {
  file_has "$GATE" '**no** `persona_derivations`).'
  file_has "$GATE" 'Populate `story_spec` for a `READY`'
}

# The gate-side half of "Nothing validates it". Losing this paragraph flips the
# field from an audit record into a gate that can fail a story on an orphaned
# ref — the promotion this whole suite exists to catch, previously unpinned.
@test "contract: the gate's validate branch exempts persona_derivations from both failure modes" {
  file_has "$GATE" '**`persona_derivations[]` is exempt from both**'
  file_has "$GATE" 'is **not** staleness and'
  # The bare 'An existing block may' prefix is NOT enough on its own: it survives
  # rewriting the clause to "An existing block may NOT carry the field", which is
  # exactly the audit-record-back-into-a-gate regression this test exists to
  # catch. The sentence wraps, so the affirmative half is pinned as its own
  # single-line needle (file_has is line-oriented grep -F).
  file_has "$GATE" 'An existing block may'
  file_has "$GATE" 'legitimately carry the field even though your own proposed block omits it'
  # Pins the CONTRADICTION half too: the test claims BOTH failure modes, and the
  # staleness half alone (above) left the contradiction clause deletable.
  file_has "$GATE" '**not** a contradiction, and never affects the verdict'
}

# Check 4 is where the exemption is APPLIED, and it is a second statement of the
# same rule in the same file. Pinning only the validate branch above let the two
# drift: a model reading check 4 alone would fail a story on an orphaned ref.
@test "contract: check 4's exception list names persona_derivations, not just persona references" {
  file_has "$GATE" '**Two things are exempt.**'
  # The count and the non-failure are not enough on their own: both survive a
  # rewrite in which the SECOND exempt thing is something other than this field,
  # which is the same audit-record-back-into-a-gate promotion, at the site where
  # the exemption is enforced rather than merely stated. Name the field.
  file_has "$GATE" 'And **`persona_derivations[]`** (#1361)'
  file_has "$GATE" 'never fails this check either'
}


@test "contract: the staged rollout is stated — corner-cases ships, ux and consistency are reserved" {
  run -0 extract "$ARCH" "$DERIV_START" "$SECTION_END_3"
  contains "$output" '**Staged rollout.**'
  contains "$output" '#1361 ships the `corner-cases` slice only'
  contains "$output" '`ux` and `consistency` are reserved for #1362 and #1363'
}

@test "contract: the subsection ends where it does today, so an inserted section reds loudly" {
  run -0 extract "$ARCH" "$DERIV_START" "$SECTION_END_3"
  ends_with "$output" '### Provenance and staleness (shared with `personas/v1`)'
}

# ---------------------------------------------------------------------------
# Vocabulary parity — ONE transcription, checked against the producer
# ---------------------------------------------------------------------------

# These pin the enum IN ITS OWN CONTEXT, never as bare tokens. A bare-token loop
# (`file_has "$ARCH" ux`) is worse than no test: `ux` is a substring of
# "auxiliary" and "linux", `consistency` is an ordinary English word, and
# `test_cases`/`acceptance_criteria` are pre-existing story-spec field names
# occurring throughout both files — so such a loop passes unconditionally and
# would stay green with the whole vocabulary deleted. That is exactly the drift
# these tests exist to catch, so the needle must carry the delimiters.
@test "parity: the contract and the producer transcribe the same slice vocabulary" {
  file_has "$ARCH" '`slice` (`corner-cases` \| `ux` \| `consistency`)'
  file_has "$REFINER" '`slice` (`corner-cases` | `ux` | `consistency`)'
}

@test "parity: the contract and the producer transcribe the same target vocabulary" {
  file_has "$ARCH" '`target` (`test_cases` \| `acceptance_criteria`)'
  file_has "$REFINER" '`target` (`test_cases` | `acceptance_criteria`)'
}

@test "producer: a ref must resolve inside the same block" {
  file_has "$REFINER" 'Every `ref` must resolve to an entry'
  file_has "$REFINER" 'never record a derivation for something you did not'
}

@test "producer: nothing derived means an empty array, not an absent field" {
  file_has "$REFINER" 'Emit `[]` when you derived nothing'
}

@test "contract: the subsection states that a ref points into the same block" {
  run -0 extract "$ARCH" "$DERIV_START" "$SECTION_END_3"
  contains "$output" 'Its `ref` points *into the same block*'
}

@test "parity: the producer states the slice-1 boundary, so #1362/#1363 must edit it deliberately" {
  file_has "$REFINER" '`corner-cases` is the only `slice`'
  file_has "$REFINER" '`ux` and `consistency` arrive with #1362 and #1363.'
}

# ---------------------------------------------------------------------------
# The derivation rules
# ---------------------------------------------------------------------------

# The seven derivation tests below extract CORNER_START -> SECTION_END_3, and
# `extract` prints to EOF at status 0 when its END address never matches. That
# heading is the LAST `###` in issue-refiner.md, and it sits in the section
# #1362/#1363 are documented to edit — so without this boundary pin, deleting or
# promoting it silently widens all seven haystacks to the rest of the file
# (including the `## Output` JSON copy-template) with every test still green.
# Mirrors the companion pins on the ARCHITECTURE subsection and the advisory range.
@test "derivation: the rules region ends where it does today, so a lost end anchor reds loudly" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  ends_with "$output" '### When you cannot derive one — say so, advisory only (#1361)'
}

@test "derivation: the section exists and is scoped to registry-resolving personas" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  contains "$output" 'For each persona in the drafted `personas[]` that resolves against the registry'
  # The `kind`-reading requirement the whole negative/adversarial split rests on.
  contains "$output" '**together with its `kind`**'
}

# The kind token must be IN the needle: pinning the two descriptions alone would
# stay green if the labels were swapped, which is precisely "file an attack as a
# typo" — the thing the third needle only names.
@test "derivation: negative and adversarial stay distinct — an attack is never filed as a typo" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  contains "$output" '**`negative`** — problematic but *innocent*'
  contains "$output" '**`adversarial`** — *deliberate*'
  contains "$output" 'never file an attack as a typo'
  # The THIRD bullet too: without it the section reads as "derive only from
  # negative and adversarial personas", which contradicts all three worked
  # examples — every one derives from dana-dispatcher, an `end-user`.
  contains "$output" '**the other three kinds** — `end-user`, `operator`, `api-consumer` —'
  contains "$output" 'contribute their traits without a malice reading'
}

@test "derivation: the payload is pushed along the shape's edge, not merely the example reused" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  contains "$output" '**Build the payload from the `shape`, anchored on the `example`.**'
  contains "$output" 'push it along the edge the `shape` names'
  contains "$output" 'a derived case that merely reuses it usually exercises no edge'
  # The carve-out must name the KIND: pinning "is often already" alone would stay
  # green after swapping adversarial for negative, which would license verbatim
  # reuse for the innocent-mistake kind and withhold it from the attack kind.
  contains "$output" 'an `adversarial` persona'"'"'s `example` is often already'
  contains "$output" 'the attack payload, which is why the escape clause below exists'
  # That needle is a POINTER to a clause nothing else pinned: deleting the
  # carve-out left the suite green and the pinned sentence dangling. Pin the
  # clause itself, plus the never-foo/bar floor it closes on — the only thing in
  # this section stopping a regression to placeholder payloads.
  contains "$output" 'Only when the shape'"'"'s edge is *already present in the example*'
  contains "$output" 'does the verbatim value stand on its own. Either way, never `foo`/`bar`.'
}

# The DIRECTION is the point: pinning only the two subject phrases would stay
# green if the mapping were swapped, which is the regression that makes the agent
# file attacks as typos.
@test "derivation: corner vs error has a stated default, and the mapping points the right way" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  contains "$output" 'an `adversarial`-derived case is `"error"`'
  contains "$output" '**every other kind** — `negative`, `end-user`, `operator`, `api-consumer` — defaults to `"corner"`'
  contains "$output" 'the story does not state the expected outcome'
}

@test "derivation: the story-explicit branch survives alongside the persona-kind default" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  contains "$output" '`"error"` when the story states the input is rejected'
  contains "$output" '`"corner"` when it states the input is accepted and handled'
}

@test "derivation: one case per edge-naming trait, per resolving persona, is the aim" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  # Through the qualifier: stopping at "names an edge" leaves ", per resolving
  # persona." deletable, which silently turns a per-persona rule into a global
  # one (fewer derived cases on a multi-persona story) while this test's own
  # title still claims the property. `collapse` folds the wrap, so one needle.
  # One phrase for the third axis, transcribed identically here and in the
  # landing rule below, so #1362/#1363 cannot drift one without reddening this.
  contains "$output" 'Aim for one derived case per trait whose `shape` names an edge, per resolving persona, per classified surface the trait'"'"'s `field` actually flows through'
  # The third axis is load-bearing: without it the aim sentence reads as a cap of
  # one test_cases[] entry per trait, which the landing rule below contradicts
  # and which would fail check 5 on a multi-surface story.
  contains "$output" 'the count has three axes, not'
}

# Per-surface, but QUALIFIED: `interface_surfaces` is an array and check 5 wants
# every classified surface covered, yet an unqualified "one case per surface"
# would order a case on a surface the trait's field never reaches — an invented,
# unexecutable test that then spins out as a real test-case issue. The needle
# pins the qualifier, not just the per-surface phrase.
@test "derivation: a derived case must land in test_cases[], in EACH surface's tooling" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  contains "$output" 'Land each derived case as a `test_cases[]` entry in **each classified surface'"'"'s**'
  contains "$output" 'through which the trait'"'"'s `field` actually flows'
  contains "$output" 'check 5 requires every classified surface to carry its own coverage'
  contains "$output" 'a `curl` case **and** a `playwright` one'
}

# The negative branch of the same rule. Unpinned, the whole carve-out could be
# deleted — restoring the unqualified "one case per classified surface" reading —
# with the suite green.
@test "derivation: a trait the surface never carries is not fabricated" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  contains "$output" 'Where a trait **cannot** be exercised from a classified'
  contains "$output" 'do **not** invent a case for it'
  contains "$output" 'A fabricated case on a surface the input never reaches is unexecutable'
  # The test is field flow, NOT persona kind: without this, an api-consumer trait
  # whose field does reach the UI would be skipped by kind.
  contains "$output" '**The test is always whether that `field` flows through that surface, never the persona'"'"'s `kind`**'
}

# Skipping a derivation must not silently lower check 5's bar: an uncovered
# classified surface is a BLOCKER (resolved_objections, resolved: false), the
# opposite routing from the deliberately-advisory underivable-gap rule below.
# Without this pin the carve-out could be reworded back to a bare recommendation,
# which the gate would then fail at re-gate.
@test "derivation: an uncovered classified surface is a blocker, not a recommendation" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_3"
  contains "$output" '**Not deriving a case never lowers the bar for that surface.**'
  contains "$output" 'cover it from the **non-persona** evidence you already'
  contains "$output" 'that gap is a **blocker**'
  # The prose must stay IN the source list: without it this rule contradicts the
  # file's own no-evidence fallback, and a greenfield repo (no spec, no
  # acceptance tests) would be filed as a blocker instead of drafted from prose.
  contains "$output" 'from the story prose'
  contains "$output" 'A greenfield repo with no spec and no acceptance tests is'
  # The AFFIRMATIVE mechanism too, not just the negative half: without it the
  # routing could be re-pointed at `questions` only while "never a bare
  # recommendations note" still held.
  contains "$output" 'append it to `resolved_objections` as a'
  contains "$output" '`resolved: false` entry with a matching question'
  contains "$output" 'never a bare `recommendations` note'
}
# The advisory rule that REPLACED the blocking objection machine. The earlier
# design made the gap a resolved_objections entry with waiver bookkeeping and a
# once-per-session bound; it produced a CRITICAL in four consecutive review
# rounds because it asked a per-turn PURE FUNCTION to behave statefully. These
# pins exist to stop that design creeping back in.
@test "advisory: an underivable gap is a recommendation, never a blocking objection" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_2"
  contains "$output" 'Corner-case derivation is **advisory**'
  contains "$output" 'say so in a **`recommendations`** entry'
  contains "$output" 'It is deliberately **not** a `resolved_objections` entry'
}

# WHAT the advisory is was pinned above; WHEN it fires was not. Rewording the
# trigger to the colloquial "when you derived no *corner* case" leaves every
# other advisory pin green while changing behaviour on an adversarial-only turn
# — the agent would claim it derived nothing having just derived an `error` case.
# The THIRD condition (a non-empty `data_traits[]` on at least one resolving
# persona) is what stops this rule and the silence rule below from both firing on
# a pure-observer story — the prose says so in those words.
@test "advisory: the trigger is stated over the mechanism, and all four conditions are named" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_2"
  # The leading clause is what stops the rule firing on the diagnosis-only first
  # turn, where proposed_story_spec is null: without it a model can bind
  # `personas[]` to the EXISTING block in its input and claim it "came up empty"
  # on a turn where derivation was never attempted.
  contains "$output" 'When **you emit a non-null'
  contains "$output" '`proposed_story_spec` this turn**'
  contains "$output" 'it is surface-touching, its `personas[]`'
  contains "$output" '**at least one resolving persona carries a non-empty'
  contains "$output" '`data_traits[]`**'
  contains "$output" '**`persona_derivations[]` is empty**'
  contains "$output" 'stated over the mechanism rather than the colloquial name'
  contains "$output" 'All four conditions must hold, and the leading clause gates them'
  contains "$output" 'Read every condition against the block **you are emitting**'
}

@test "advisory: it never blocks convergence and needs no cross-turn memory" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_2"
  contains "$output" 'never blocks convergence, never needs a waiver'
  contains "$output" 'never requires you to remember anything'
}

@test "advisory: the rationale names the pure-function reason the blocking design failed" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_2"
  contains "$output" 'would have no state to read'
}

@test "advisory: it stays silent when there is nothing to enumerate from" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_2"
  contains "$output" 'Say nothing at all when there is nothing to enumerate from'
  contains "$output" '`interface_surfaces: []`'
  contains "$output" '`personas: []`'
  contains "$output" 'every resolving persona carrying `data_traits: []`'
}

@test "advisory: an unresolvable id routes to define-personas, per id" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_2"
  contains "$output" '/development:define-personas'
  contains "$output" 'that is a persona problem, not a missing-test-case problem'
  # 'per id' is the test's own title claim and was previously unasserted; the
  # truncated 'including on a turn that' survives any completion, including one
  # that inverts the rule, so it is extended through its object.
  contains "$output" 'it applies per id'
  contains "$output" 'including on a turn that derived cases from the personas that did resolve'
}

@test "advisory: the corner-case section ends where it does today" {
  run -0 extract "$REFINER" "$CORNER_START" "$SECTION_END_2"
  ends_with "$output" '## Output — one JSON object only'
}

# ---------------------------------------------------------------------------
# The worked examples — parsed, and internally consistent
# ---------------------------------------------------------------------------

@test "example: ARCHITECTURE's story-spec block parses as JSON" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e . "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

@test "example: ARCHITECTURE's block declares persona_derivations (anti-vacuity control)" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e '.persona_derivations | length > 0' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

# The block declares TWO surfaces, and the producer rule pinned above demands a
# case in each classified surface's tooling. Without these two pins, deleting the
# playwright-tooled derivation leaves every other assertion green and the
# canonical schema illustration modelling the exact mistake its own prose forbids
# ("one case in whichever surface came first"). The interface_surfaces pin is the
# anti-vacuity control: reducing the example to one surface must red too.
@test "example: ARCHITECTURE's derived refs span BOTH classified surfaces' tooling" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  # `IN($r[])`, NOT `[.id] | inside($r)`: jq's `inside` is SUBSTRING containment
  # for strings, and this example's ids are prefix siblings
  # (tc-corner-unicode-site / tc-corner-unicode-site-ui). Under `inside`, deleting
  # the curl-side derivation left the test green — the `-ui` ref alone matched
  # both cases — so the property held in only one of its two mutation directions.
  run jq -e '[.persona_derivations[] | select(.target == "test_cases") | .ref] as $r | [.test_cases[] | select(.id | IN($r[])) | .tooling] | unique | length == 2' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

@test "example: ARCHITECTURE's block still declares the two surfaces those derivations span" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e '.interface_surfaces | sort == ["rest", "web-ui"]' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

# The sibling examples both pin the full kind set; the canonical schema
# illustration did not, so thinning its test_cases (or flipping a kind) could
# leave it contradicting the check-5 rule the same document states.
@test "example: ARCHITECTURE's block covers happy/corner/error" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e '["happy","corner","error"] - [.test_cases[].kind] | length == 0' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

@test "example: every ARCHITECTURE derivation carries all five sub-fields" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e 'all(.persona_derivations[]; has("slice") and has("persona") and has("basis") and has("target") and has("ref"))' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

@test "example: every ARCHITECTURE derivation persona is declared in the same block's personas[]" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e '[.persona_derivations[] | select(.persona != null) | .persona] - .personas | length == 0' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

# Resolution alone is not the property: every ref test checks only that a ref
# points at SOME id, and the slice tests check only the literal `corner-cases`.
# Nothing tied the two together, so repointing the refs at the happy cases kept
# the whole suite green while the canonical copy-template attributed a
# corner-case derivation to the happy path — the opposite of what the prose it
# illustrates teaches. Asserted in all three worked examples.
@test "example: ARCHITECTURE's corner-cases derivations ref a corner or error case, never happy" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e '[.persona_derivations[] | select(.slice == "corner-cases" and .target == "test_cases") | .ref] as $r | [.test_cases[] | select(.id | IN($r[]))] | length > 0 and all(.[]; .kind == "corner" or .kind == "error")' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

@test "example: every ARCHITECTURE test_cases ref resolves to an id in the same block" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e '[.persona_derivations[] | select(.target == "test_cases") | .ref] - [.test_cases[].id] | length == 0' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

# Vacuously true today — the slice-1 example targets only `test_cases`, and
# adding an acceptance_criteria-targeted derivation would push the example past
# this slice's corner-cases-only boundary. Kept as the forward guard for #1362 /
# #1363, which introduce those targets; the closed-vocabulary pin below is what
# stops a typo from making its `test_cases` sibling vacuous in the same way.
@test "example: every ARCHITECTURE acceptance_criteria ref resolves in the same block" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e '[.persona_derivations[] | select(.target == "acceptance_criteria") | .ref] - .acceptance_criteria | length == 0' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

# Without these two, a typo'd `"target": "test_case"` passes every ref test
# vacuously — `select(.target == …)` simply matches nothing.
@test "example: every ARCHITECTURE derivation target is drawn from the closed vocabulary" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e 'all(.persona_derivations[]; .target == "test_cases" or .target == "acceptance_criteria")' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

@test "example: the ARCHITECTURE derivations are all corner-cases today (the slice-1 boundary)" {
  json_after "$ARCH" '^### The `story-spec/v1` block' > "$BATS_TEST_TMPDIR/arch.json"
  run jq -e 'all(.persona_derivations[]; .slice == "corner-cases")' "$BATS_TEST_TMPDIR/arch.json"
  [ "$status" -eq 0 ]
}

@test "example: the producer agent's copy-template parses as JSON" {
  json_after "$REFINER" '^## Output — one JSON object only' > "$BATS_TEST_TMPDIR/refiner.json"
  run jq -e . "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
}

@test "example: the producer's template declares derivations (anti-vacuity control)" {
  json_after "$REFINER" '^## Output — one JSON object only' > "$BATS_TEST_TMPDIR/refiner.json"
  run jq -e '.proposed_story_spec.persona_derivations | length > 0' "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
}

@test "example: every producer derivation persona is declared in the template's personas[]" {
  json_after "$REFINER" '^## Output — one JSON object only' > "$BATS_TEST_TMPDIR/refiner.json"
  run jq -e '[.proposed_story_spec.persona_derivations[] | select(.persona != null) | .persona] - .proposed_story_spec.personas | length == 0' "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
}

@test "example: the producer template's corner-cases derivation refs a corner or error case, never happy" {
  json_after "$REFINER" '^## Output — one JSON object only' > "$BATS_TEST_TMPDIR/refiner.json"
  run jq -e '[.proposed_story_spec.persona_derivations[] | select(.slice == "corner-cases" and .target == "test_cases") | .ref] as $r | [.proposed_story_spec.test_cases[] | select(.id | IN($r[]))] | length > 0 and all(.[]; .kind == "corner" or .kind == "error")' "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
}

@test "example: every producer derivation ref resolves to a test case in the template" {
  json_after "$REFINER" '^## Output — one JSON object only' > "$BATS_TEST_TMPDIR/refiner.json"
  run jq -e '[.proposed_story_spec.persona_derivations[] | select(.target == "test_cases") | .ref] - [.proposed_story_spec.test_cases[].id] | length == 0' "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
  # Vacuously true today (the slice-1 template targets only test_cases) and kept
  # as the forward guard for #1362/#1363 — but load-bearing NOW as the other half
  # of the partition: without it, retargeting the entry to acceptance_criteria
  # while leaving a test-case id as its ref empties the select above and ships a
  # copy-template whose ref resolves nowhere.
  run jq -e '[.proposed_story_spec.persona_derivations[] | select(.target == "acceptance_criteria") | .ref] - .proposed_story_spec.acceptance_criteria | length == 0' "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
}

@test "example: the producer's derivations are all corner-cases today (the slice-1 boundary)" {
  json_after "$REFINER" '^## Output — one JSON object only' > "$BATS_TEST_TMPDIR/refiner.json"
  run jq -e 'all(.proposed_story_spec.persona_derivations[]; .slice == "corner-cases")' "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
}

# The anti-vacuity control for the producer's ref test, mirroring the ARCH side:
# a typo'd `target` makes every `select(.target == …)` match nothing, so the ref
# assertions pass while checking zero refs.
@test "example: every producer derivation target is drawn from the closed vocabulary" {
  json_after "$REFINER" '^## Output — one JSON object only' > "$BATS_TEST_TMPDIR/refiner.json"
  run jq -e 'all(.proposed_story_spec.persona_derivations[]; .target == "test_cases" or .target == "acceptance_criteria")' "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
}

@test "example: every producer derivation carries all five sub-fields" {
  json_after "$REFINER" '^## Output — one JSON object only' > "$BATS_TEST_TMPDIR/refiner.json"
  run jq -e 'all(.proposed_story_spec.persona_derivations[]; has("slice") and has("persona") and has("basis") and has("target") and has("ref"))' "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
}

# The walkthrough is the THIRD worked example of the field (added while fixing an
# earlier round), and it is the one a human reads to learn the contract.
@test "example: the walkthrough's story-spec block parses as JSON" {
  json_after "$WALK" '^## Stage 2 — guided refinement' > "$BATS_TEST_TMPDIR/walk.json"
  run jq -e . "$BATS_TEST_TMPDIR/walk.json"
  [ "$status" -eq 0 ]
}

# The walkthrough carries the SAME anti-vacuity control as the other two worked
# examples — do not delete it as redundant. Emptying the block's
# `persona_derivations` to `[]` (keeping the key) leaves most of the walkthrough
# tests green: every set difference over an empty array is empty and `all` over an
# empty stream is true. Only this control and the corner-refs test's `length > 0`
# clause red on that mutation, and this one is the direct, precisely-named signal
# — it survives if that test's `select` is ever narrowed. The field the slice
# exists to demonstrate would otherwise vanish from the document a human reads,
# with the suite still green.
@test "example: the walkthrough's block declares persona_derivations (anti-vacuity control)" {
  json_after "$WALK" '^## Stage 2 — guided refinement' > "$BATS_TEST_TMPDIR/walk.json"
  run jq -e '.persona_derivations | length > 0' "$BATS_TEST_TMPDIR/walk.json"
  [ "$status" -eq 0 ]
}

@test "example: the walkthrough's corner-cases derivation refs a corner or error case, never happy" {
  json_after "$WALK" '^## Stage 2 — guided refinement' > "$BATS_TEST_TMPDIR/walk.json"
  run jq -e '[.persona_derivations[] | select(.slice == "corner-cases" and .target == "test_cases") | .ref] as $r | [.test_cases[] | select(.id | IN($r[]))] | length > 0 and all(.[]; .kind == "corner" or .kind == "error")' "$BATS_TEST_TMPDIR/walk.json"
  [ "$status" -eq 0 ]
}

@test "example: the walkthrough's derivation ref and persona resolve in its own block" {
  json_after "$WALK" '^## Stage 2 — guided refinement' > "$BATS_TEST_TMPDIR/walk.json"
  run jq -e '[.persona_derivations[] | select(.target == "test_cases") | .ref] - [.test_cases[].id] | length == 0' "$BATS_TEST_TMPDIR/walk.json"
  [ "$status" -eq 0 ]
  # The acceptance_criteria branch too, so the two targets partition every
  # derivation: without it, retargeting the entry to acceptance_criteria while
  # leaving a test-case id as its ref passes the vocabulary pin AND makes the
  # test_cases select match nothing, so both checks go vacuous at once.
  run jq -e '[.persona_derivations[] | select(.target == "acceptance_criteria") | .ref] - .acceptance_criteria | length == 0' "$BATS_TEST_TMPDIR/walk.json"
  [ "$status" -eq 0 ]
  run jq -e '[.persona_derivations[] | select(.persona != null) | .persona] - .personas | length == 0' "$BATS_TEST_TMPDIR/walk.json"
  [ "$status" -eq 0 ]
}

# Completes the pin matrix: all three worked examples now carry the same eight
# checks (parse, anti-vacuity, five sub-fields, persona resolution, both ref
# branches, closed vocabulary, slice-1 boundary). Without this one, deleting
# `basis` from the walkthrough — the field its own prose sells — reds nothing.
@test "example: every walkthrough derivation carries all five sub-fields" {
  json_after "$WALK" '^## Stage 2 — guided refinement' > "$BATS_TEST_TMPDIR/walk.json"
  run jq -e 'all(.persona_derivations[]; has("slice") and has("persona") and has("basis") and has("target") and has("ref"))' "$BATS_TEST_TMPDIR/walk.json"
  [ "$status" -eq 0 ]
}

@test "example: the walkthrough's derivation uses the closed vocabularies and the slice-1 value" {
  json_after "$WALK" '^## Stage 2 — guided refinement' > "$BATS_TEST_TMPDIR/walk.json"
  run jq -e 'all(.persona_derivations[]; .slice == "corner-cases" and (.target == "test_cases" or .target == "acceptance_criteria"))' "$BATS_TEST_TMPDIR/walk.json"
  [ "$status" -eq 0 ]
}

@test "example: the walkthrough covers happy, corner AND error, as its own Stage 1 gate demanded" {
  json_after "$WALK" '^## Stage 2 — guided refinement' > "$BATS_TEST_TMPDIR/walk.json"
  run jq -e '(["happy","corner","error"] - [.test_cases[].kind]) | length == 0' "$BATS_TEST_TMPDIR/walk.json"
  [ "$status" -eq 0 ]
}

# Set difference, never `index(...) and index(...) != null`: jq's `and` yields
# only true/false, never null, so that form is unconditionally true and the
# assertion can never fail. Mutation-checked — deleting the error case reds this.
@test "example: the producer's template covers happy, corner AND error, as the surface rule requires" {
  json_after "$REFINER" '^## Output — one JSON object only' > "$BATS_TEST_TMPDIR/refiner.json"
  run jq -e '(["happy","corner","error"] - [.proposed_story_spec.test_cases[].kind]) | length == 0' "$BATS_TEST_TMPDIR/refiner.json"
  [ "$status" -eq 0 ]
}
