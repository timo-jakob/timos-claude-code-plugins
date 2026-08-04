#!/usr/bin/env bats
#
# The family's browser-UI positions (#1059, epic #1058).
#
# ARCHITECTURE.md's "Browser UI" section is the authoritative record of three
# positions — SPA shell + micro-frontends, React + TypeScript as the single
# default, and a `mount(el, ctx)` / `unmount(el)` contract over an
# import-map-resolved ES module with Module Federation rejected. Several other
# places restate or annotate them for a different audience: the 2026-07-10
# spec (its rewritten §2, the §1/§6/§8/§9 annotations, and the banner that
# claims exactly that footprint), docs/reference/plugins.md (users),
# docs/explanation/motivation.md (the gap list), bootstrap's SKILL.md §3k (the
# executable skill), and four dated 2026-07-11 specs whose Angular / #685
# content is superseded by a banner rather than rewritten.
#
# WHY THIS FILE EXISTS: the defect #1059 repairs is a *silent* one — the repo
# and the family architecture disagreed while each side stayed internally
# consistent, so nothing went red. A position nobody asserts can be softened,
# reversed, or deleted with the suite green, which is exactly how the drift got
# in. So each site is pinned clause-by-clause, and the §2 rewrite is pinned
# NEGATIVELY too: its acceptance criterion is the *absence* of the reversed
# content (a framework decision table, a tie-break rule, Module Federation as
# blessed), which no positive assertion can express.
#
# THREE WAYS A DOC-ASSERTION SUITE LIES TO ITSELF, and what is done about each:
#
#   1. A renamed START anchor collapses the range to nothing. Then every
#      `lacks` passes vacuously. Guarded: each haystack is asserted non-empty.
#   2. A renamed END anchor is worse and less obvious — `sed -n '/a/,/b/p'`
#      prints to EOF when `b` never matches, so the haystack silently WIDENS.
#      `[ -n ]` still passes, positives can be satisfied by unrelated prose,
#      and negatives start scanning the whole file.
#      Guarded: `extract` prints through the end line and trims the trailing
#      space, so a test asserts the haystack ENDS WITH that line. `ends_with`
#      is load-bearing here and a substring `contains` is NOT good enough:
#      `#### X` contains `### X`, so a mere heading demotion would satisfy a
#      `contains` pin on a range that had already run to EOF.
#      EVERY extraction carries that pin except three, each for a stated
#      reason: plugins.md's `## development-react` section and `banner_of`,
#      whose end anchor is the GENERIC next heading of the same level (`^## `),
#      and §9, which is the file's last section and runs to EOF by design. A
#      generic anchor cannot be renamed out of existence — it fails only if the
#      file has no further heading at that level at all, in which case the
#      "widened" range is the rest of the file and there is nothing after it to
#      contaminate the haystack. (§3k's anchor is generic too, but a pin is
#      cheap there and it is kept — stricter than required is fine; weaker is
#      not.) `banner_of` additionally starts at line 1 rather than `/^# /`,
#      because sed RE-OPENS a range every time the start address matches again,
#      and a column-0 `# ` inside an unindented code fence would otherwise
#      append arbitrary chunks to a banner.
#   3. A `lacks` needle that never matched anything is a permanent pass. Since
#      these needles are transcribed from content this story DELETED, nothing
#      in the working tree can demonstrate they discriminate. Guarded: the
#      deleted §2, §8 and motivation-gap text are committed under
#      tests/fixtures/webui/, and one companion test asserts that EVERY
#      deletion-transcribed needle IS present there. (`lacks` needles that are
#      single robust TOKENS — `development-angular`, `Angular`, `#685` — are a
#      different thing and need no fixture: they do not reproduce any deleted
#      wording, so they cannot be mis-transcribed, and they red on a
#      re-introduction however it is phrased. Prefer a token to a phrase
#      wherever the range genuinely cannot contain it.)
#
# Needles are scoped to the restatement sites listed above, never a repo-wide
# grep: other dated design specs still name Angular historically, and a
# repo-wide sweep would red on them.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  SPEC_OLD="$REPO_ROOT/docs/superpowers/specs/2026-07-10-webui-plugin-family-design.md"
  SPEC_MFE="$REPO_ROOT/docs/superpowers/specs/2026-07-27-mfe-app-family-design.md"
  SPEC_DIR="$REPO_ROOT/docs/superpowers/specs"
  PLUGINS_MD="$REPO_ROOT/docs/reference/plugins.md"
  MOTIVATION="$REPO_ROOT/docs/explanation/motivation.md"
  BOOTSTRAP_SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  FIXTURES="$REPO_ROOT/tests/fixtures/webui"
}

# Collapse a document region to one line: strip blockquote markers, collapse
# whitespace, trim the trailing space `tr` leaves behind. The marker strip must
# precede the collapse — a leading `> ` on a continuation line otherwise lands
# mid-needle and no wrapped claim in a banner could ever match. The trim is
# what makes `ends_with` usable as the end-anchor pin.
collapse() {
  sed 's/^>[[:space:]]\{0,1\}//' | tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

# Extract FILE's section from START to END (both sed BRE addresses, neither
# containing a `/`), collapsed. sed prints the END line itself, which is what
# the `ends_with` pins below rely on.
extract() {
  sed -n "/$2/,/$3/p" "$1" | collapse
}

# --- the authoritative record ------------------------------------------------

ARCH_END='### Cross-repo Claude: the big-picture problem'

arch_section() {
  extract "$ARCH" '^### Browser UI' '^### Cross-repo Claude'
}

@test "ARCHITECTURE records position 1 — SPA shell + micro-frontends — with its rationale (#1059)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**Every browser UI is a SPA shell; substantial UI splits into micro-frontends.**'
  # the default shape, and the one deliberate exception — a bare "micro-frontends"
  # claim would survive dropping either
  contains "$section" 'The **default** remote shape is a **route-owned page**'
  contains "$section" 'A **canvas widget**'
  # the rationale is half the deliverable: a position without it cannot be argued with
  contains "$section" 'one deployable per bounded context, independently releasable'
}

@test "ARCHITECTURE records position 2 — React + TypeScript default, Angular not scaffolded (#1059)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**React + TypeScript is the default for any browser UI.**'
  contains "$section" 'Angular is **not** scaffolded.'
  # the carve-out that keeps the position honest rather than absolute
  contains "$section" 'An existing Angular asset may participate by exporting the same contract'
  contains "$section" 'one framework, one blessed path'
}

@test "ARCHITECTURE records position 3 — the mount contract, federation rejected for BOTH shapes (#1059)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**The MFE contract is an exported `mount(el, ctx)` / `unmount(el)` pair over an import-map-resolved ES module.**'
  contains "$section" '**Module Federation is rejected.**'
  # BOTH shapes, not just the canvas one the preceding sentences discuss — the
  # design doc §2.3 rejects it for both, and a shape-scoped reading would leave
  # federation arguable under route ownership
  contains "$section" 'for **both shapes**'
  # the reason the canvas case does not rescue federation
  contains "$section" '**import maps already solve it natively**'
  # rejected-as-unearned, NOT rejected-as-coupling: the sloppier argument is wrong
  contains "$section" 'modern federation can be configured to share nothing'
}

@test "ARCHITECTURE records the rejected alternatives with their reasons (#1059)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" '**custom elements** were the other serious contender'
  contains "$section" '`customElements.define` is a process-global registration that throws on a duplicate tag name'
  contains "$section" 'the context-passing ergonomics are a secondary cost'
}

@test "the ARCHITECTURE section points at a design doc that exists, and never at a second framework topic (#1059)" {
  local section
  section="$(arch_section)"
  [ -n "$section" ]
  ends_with "$section" "$ARCH_END"
  contains "$section" 'docs/superpowers/specs/2026-07-27-mfe-app-family-design.md'
  [ -f "$SPEC_MFE" ]
  # the position is "no development-angular"; naming one here would be the
  # widening this section exists to prevent
  lacks "$section" 'development-angular'
}

# --- the superseded spec: banner, and every section the banner claims ---------

spec2_section() {
  extract "$SPEC_OLD" '^## 2\. Plugin decomposition' '^## 3\.'
}

@test "the 2026-07-10 spec's banner names its own footprint accurately (#1059)" {
  local banner
  banner="$(extract "$SPEC_OLD" '^# WebUI plugin family' '^## 1\.')"
  [ -n "$banner" ]
  ends_with "$banner" '## 1. Context and goals'
  contains "$banner" '**§2 superseded (2026-07-27), rewritten (#1059).**'
  # The banner is the routing note an auditor trusts, so it must not under-claim
  # the edit's footprint — §6 was edited too, and saying otherwise would route a
  # reader away from the one section whose Angular residue this story removed.
  # Every section it names carries its own test below, so the claim and the
  # annotations cannot drift apart.
  contains "$banner" "§6's frontend test-stack row drops its Angular entry"
  contains "$banner" '**§§3–5 and §7 are unaffected.**'
}

@test "spec §1 records that the two-framework plan was replaced, not merely dropped (#1059)" {
  local section
  section="$(extract "$SPEC_OLD" '^## 1\. Context and goals' '^## 2\.')"
  [ -n "$section" ]
  ends_with "$section" '## 2. Plugin decomposition'
  contains "$section" 'This document originally proposed *two* framework topics chosen by a recommendation heuristic'
  contains "$section" '§2 records the single-default position that replaced it'
}

@test "spec §2 states the surviving decomposition — one framework topic, no development-angular (#1059)" {
  local section
  section="$(spec2_section)"
  [ -n "$section" ]
  ends_with "$section" '## 3. Contract flow — versioned spec artifact, consumer generates'
  contains "$section" '**This section was rewritten by #1059.**'
  contains "$section" 'There is no `development-angular`.'
  contains "$section" 'Framework choice: a single default, not a recommendation heuristic'
  contains "$section" 'Bootstrap asks nothing about the framework.'
  # the surviving half of the binding bullet, whose Angular half was struck
  contains "$section" '**Framework binding for generated API clients:** React Query hooks'
  # the bootstrap question is two-way (shell or remote) — the 2026-07-27 design
  # says there is deliberately no third archetype, and page-vs-widget is a
  # variant inside the remote shape rather than a scaffold choice
  contains "$section" '**shell or remote**'
}

@test "spec §2 no longer presents a framework table, a tie-break, or a blessed Module Federation (#1059)" {
  local section
  section="$(spec2_section)"
  [ -n "$section" ]
  # positive anchors FIRST. A purely-negative test is satisfied by an empty or
  # truncated haystack, and `[ -n ]` cannot tell a real §2 from two orphaned
  # heading lines — so prove the haystack is the real section, and that it ends
  # where it should, before asserting what it does not contain.
  ends_with "$section" '## 3. Contract flow — versioned spec artifact, consumer generates'
  contains "$section" 'There is no `development-angular`.'
  # #1059's acceptance criterion is a NEGATIVE one. Each needle is unique to the
  # reversed content and cannot occur in the corrective framing, so a restored
  # §2 — via a bad merge, a revert, or an editor reading the 2026-07-10 date as
  # authoritative — reds this test rather than passing silently. The companion
  # fixture test below proves each needle actually matched the reversed §2.
  lacks "$section" '| Signal | Points to |'
  lacks "$section" 'Angular for internal business apps'
  lacks "$section" 'Build order: React first, Angular second'
  lacks "$section" 'Amended 2026-07-22'
  lacks "$section" '### development-angular / development-react'
  # the third plugin in the decomposition code block
  lacks "$section" 'development-angular ← topic'
  # the struck half of the framework-binding bullet
  lacks "$section" 'Angular `HttpClient`-based client vs. React Query hooks'
  # the third clause of the criterion: Module Federation as BLESSED. A bare
  # `lacks 'Module Federation'` cannot express it — the corrective banner names
  # the mechanism to say it is reversed — so the needle is taken from the
  # blessing prose itself.
  lacks "$section" '(Module Federation host/remote repo shapes)'
}

@test "spec §6's frontend test stack no longer carries an Angular harness (#1059)" {
  # the banner now claims §6 was edited, so §6 owes an assertion of its own —
  # otherwise a restored `TestBed` would make the banner's claim true about a
  # change that had been reverted, with nothing red
  local section
  section="$(extract "$SPEC_OLD" '^## 6\.' '^## 7\.')"
  [ -n "$section" ]
  ends_with "$section" '## 7. Composition repo — a new repo type'
  contains "$section" '| Frontend | Unit/component (vitest + testing-library) +'
  # the robust token, not the specific harness name `TestBed`: the positive pin
  # above is only a PREFIX of the row, so a restoration worded as
  # "(vitest + testing-library) + Karma/Jasmine for Angular" would satisfy it —
  # and a `TestBed` needle would miss that wording entirely. §6 names only
  # vitest/testing-library, MSW, schemathesis, testcontainers and Playwright, so
  # the token cannot occur here unless an Angular harness comes back.
  lacks "$section" 'Angular'
}

@test "spec §8's epic map no longer sequences an Angular topic or a federation-shaped follow-up (#1059)" {
  local section
  section="$(extract "$SPEC_OLD" '^## 8\. Epic map' '^## 9\.')"
  [ -n "$section" ]
  ends_with "$section" '## 9. Considered and rejected'
  contains "$section" 'built to the 2026-07-27 contract'
  contains "$section" 'the Module-Federation-shaped follow-up this list used to name is superseded'
  lacks "$section" '**`development-angular`** + the bootstrap recommendation heuristic'
}

@test "spec §9 records the rejected mechanisms and points at their reasoning (#1059)" {
  # §9 is the last section, so the range runs to EOF by design — there is no end
  # anchor to pin and no widening to guard against. Note the `$` LINE address
  # rather than `extract`'s `/regex/` end: `/$/` would match the very next line
  # and truncate the section to its heading.
  local section
  section="$(sed -n '/^## 9\. Considered and rejected/,$p' "$SPEC_OLD" | collapse)"
  [ -n "$section" ]
  contains "$section" 'Moot since #1059: there is one framework topic.'
  contains "$section" '**Module Federation as the micro-frontend mechanism, and custom elements as the alternative contract**'
  contains "$section" '2026-07-27-mfe-app-family-design.md'
}

@test "every deletion-transcribed negative needle is proven to discriminate (#1059)" {
  # Without this, the negative tests enforce their criteria only if every needle
  # was transcribed character-for-character from content that no longer exists in
  # the tree. One wrong character — a different dash, a reworded table header —
  # makes that assertion a permanent pass, and the criterion is silently
  # unenforced from the day it lands. The fixtures are the deleted regions,
  # extracted from origin/main at the time this story landed.
  local reversed2 reversed8 reversed_motivation
  reversed2="$(collapse < "$FIXTURES/spec-2-pre-1059.md")"
  [ -n "$reversed2" ]
  contains "$reversed2" '| Signal | Points to |'
  contains "$reversed2" 'Angular for internal business apps'
  contains "$reversed2" 'Build order: React first, Angular second'
  contains "$reversed2" 'Amended 2026-07-22'
  contains "$reversed2" '### development-angular / development-react'
  contains "$reversed2" 'development-angular ← topic'
  contains "$reversed2" 'Angular `HttpClient`-based client vs. React Query hooks'
  contains "$reversed2" '(Module Federation host/remote repo shapes)'

  reversed8="$(collapse < "$FIXTURES/spec-8-pre-1059.md")"
  [ -n "$reversed8" ]
  contains "$reversed8" '**`development-angular`** + the bootstrap recommendation heuristic'

  reversed_motivation="$(collapse < "$FIXTURES/motivation-parity-pre-1059.md")"
  [ -n "$reversed_motivation" ]
  contains "$reversed_motivation" 'JavaScript / Angular'
}

# --- the user-facing restatements --------------------------------------------

@test "plugins.md's development-react section restates all three positions for users (#1059)" {
  # the end anchor is the GENERIC next H2, which cannot be renamed out of
  # existence — hence no end pin here (see failure mode 2 in the header)
  local section
  section="$(extract "$PLUGINS_MD" '^## development-react' '^## ')"
  [ -n "$section" ]
  contains "$section" '**Why React and only React.**'
  contains "$section" '**React + TypeScript is the default for any browser UI**'
  contains "$section" 'there is no `development-angular`'
  contains "$section" 'bootstrap asks no Angular-vs-React question'
  contains "$section" '**micro-frontends behind a SPA shell**'
  contains "$section" '`mount(el, ctx)` / `unmount(el)`'
  contains "$section" '**Module Federation is rejected**'
  # docs/ pages link across the repo boundary as ABSOLUTE GitHub URLs (the docs
  # machinery rule); ARCHITECTURE.md uses a relative one. Pin the form actually
  # used here so the two conventions cannot be swapped.
  contains "$section" 'https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/docs/superpowers/specs/2026-07-27-mfe-app-family-design.md'
}

@test "motivation.md separates the Angular position from the parity SEQUENCING gaps (#1059)" {
  # anchored on content, not on list numbering: this gap list is actively
  # maintained, and an item inserted above would renumber a numeric end anchor
  # out of existence — running the range to EOF
  local item
  item="$(extract "$MOTIVATION" '\*\*Maintenance language parity\.\*\*' 'macOS + Homebrew lock-in')"
  [ -n "$item" ]
  ends_with "$item" "4. **macOS + Homebrew lock-in.** \`/development:bootstrap\`'s automation"
  # the distinction is the whole point: "not yet implemented" is sequencing,
  # Angular is a standing position. Collapsing them — as the reversed framing
  # did by listing Angular among the pending languages — is the drift this
  # sentence exists to prevent, and this list is where a routine parity update
  # would re-introduce it.
  contains "$item" 'Those gaps are intentional sequencing'
  contains "$item" 'Angular is a different case entirely'
  contains "$item" 'not** a sequencing gap but a standing position'
  contains "$item" 'It is not waiting its turn.'
  lacks "$item" 'JavaScript / Angular'
}

@test "bootstrap SKILL.md §3k states the single-binding consequence of the React default (#1059)" {
  local section
  section="$(extract "$BOOTSTRAP_SKILL" '^### 3k\.' '^### ')"
  [ -n "$section" ]
  ends_with "$section" '### Idempotency rules (apply for every file write)'
  contains "$section" 'single browser-UI default (#1059)'
  contains "$section" 'no second binding to own'
  # §3k is the executable-skill restatement: an Angular `HttpClient` binding
  # re-introduced here would scaffold the reversed position into target repos
  lacks "$section" 'Angular'
}

# --- the four superseded 2026-07-11 specs ------------------------------------
#
# Bannering these is one of the story's deliverables: each still states the
# reversed two-framework plan in its body, and the banner is the only thing
# telling a reader not to act on it. Each test pins the clauses unique to its
# banner, so a deleted or hollowed-out banner reds rather than passing.

banner_of() {
  # line-1 start address: `/^# /` would RE-OPEN the range on any later column-0
  # `# ` line (a shell comment in an unindented code fence), appending arbitrary
  # chunks to the haystack. The end anchor is the generic next H2, so no end pin.
  sed -n '1,/^## /p' "$SPEC_DIR/$1" | collapse
}

@test "the 2026-07-11 development-javascript epic spec carries its #1059 banner (#1059)" {
  local banner
  banner="$(banner_of '2026-07-11-development-javascript-epic-design.md')"
  [ -n "$banner" ]
  contains "$banner" '**Angular references superseded (#1059).**'
  contains "$banner" 'Angular is #685, React is #686'
  # the full clause, not a generic `there is no` prefix: this banner's sibling
  # already contains "there is no second binding to own", so the short form
  # would survive the Angular-topic clause being softened or dropped
  contains "$banner" 'there is no `development-angular`'
  contains "$banner" 'the JS/TS language-layer decisions it settles are unaffected'
  contains "$banner" '2026-07-27-mfe-app-family-design.md'
}

@test "the 2026-07-11 contract-consumer spec carries its #1059 banner (#1059)" {
  # this banner is the SOURCE of the sentence bootstrap SKILL.md §3k restates;
  # without a test the derived copy would be pinned while its origin was not
  local banner
  banner="$(banner_of '2026-07-11-development-javascript-contract-consumer-design.md')"
  [ -n "$banner" ]
  contains "$banner" '**Angular references superseded (#1059).**'
  contains "$banner" 'there is no second binding to own'
  contains "$banner" 'The contract-consumer machinery itself is unaffected'
  contains "$banner" '2026-07-27-mfe-app-family-design.md'
}

@test "the 2026-07-11 split-frontend spec's banner carries the substitution rule and the Angular branch (#1059)" {
  # two clauses found nowhere else, both load-bearing: without the substitution
  # the epic loses its only UI-bootstrap prerequisite, and without the branch a
  # detected Angular frontend has no defined outcome at all
  local banner
  banner="$(banner_of '2026-07-11-split-frontend-epic-design.md')"
  [ -n "$banner" ]
  contains "$banner" '**Angular references superseded (#1059).**'
  contains "$banner" 'appears as a surviving prerequisite, read'
  contains "$banner" 'the framework bootstrap step is skipped'
  contains "$banner" 'reading what a repo already is, not scaffolding a second framework'
  contains "$banner" '2026-07-27-mfe-app-family-design.md'
}

@test "the split-frontend Dependencies section states the Angular outcome, not a dead #685 prerequisite (#1059)" {
  # the banner's two rules would resolve a surviving "an Angular frontend needs
  # #685" in opposite directions, so the clause itself is corrected in place
  local deps
  deps="$(extract "$SPEC_DIR/2026-07-11-split-frontend-epic-design.md" '^\*\*Blocked by #682\.\*\*' '^## Sequencing')"
  [ -n "$deps" ]
  ends_with "$deps" '## Sequencing'
  contains "$deps" 'skips the framework bootstrap step entirely'
  contains "$deps" 'so it needs no framework topic at all'
  # the robust token rather than the deleted clause's exact wording: this
  # document deliberately KEEPS #685 in its isolation table and Sequencing list,
  # so the realistic regression is an editor reconciling Dependencies with them
  # by re-adding a #685 bullet beside the #686 one — which any phrase-shaped
  # needle would miss. The corrected range names only #683, #686, #684(a) and
  # #583, so this passes today and reds on a restoration however it is worded.
  lacks "$deps" '#685'
}

@test "the 2026-07-11 composition deploy-test spec carries its #1059 banner (#1059)" {
  local banner
  banner="$(banner_of '2026-07-11-composition-deploy-test-epics-design.md')"
  [ -n "$banner" ]
  contains "$banner" '**Angular references superseded (#1059).**'
  contains "$banner" 'the one remaining framework topic'
  contains "$banner" '2026-07-27-mfe-app-family-design.md'
}
