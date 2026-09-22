#!/usr/bin/env bats
#
# The philosophy-page pointers (issue #1629, epic #1627). #1628 made
# docs/explanation/philosophy.md the one place the six pillars are worded;
# #1629 pointed the four existing entry points at it — README's "Read more"
# line, docs/explanation/motivation.md (twice), why-per-language-plugins.md
# reason 1, and the CLAUDE.md rule that tells a session to link a pillar
# rather than paraphrase one.
#
# None of that is reachable by an existing gate. `mkdocs build --strict`
# validates the two docs/ pages' links and anchors, but README.md and
# CLAUDE.md sit outside mkdocs' docs_dir and enter no validation at all, and
# a DELETED link cannot dangle — so every pointer this story added could be
# removed with the whole suite and the docs build still green. These tests
# pin each pointer, and pin the anchors CLAUDE.md promises.
#
# Deliberately FILE-SCOPED: it pins the four entry points #1629 names, not a
# repo-wide "nobody restates a pillar" sweep. A closed file list rots (the
# failure mode tests/messaging-position.bats documents when it replaced its
# three-file spot check with a git ls-files sweep), so the sweep belongs with
# the automated link-check in #1631 rather than here.

bats_require_minimum_version 1.5.0

load assertions

# Print one `## ` section: from the line matching $1 up to (but NOT including)
# the next `## ` heading. A plain `sed -n '/x/,/^## /p'` range stops ON that
# heading and prints it, so `{#pillar-5}`'s haystack would end with the
# "The AI owns a self-optimising loop" title and satisfy a pillar-6 assertion
# even after the two anchors were swapped — the mutation this file exists to
# catch. awk exits at the boundary instead, so each haystack holds one pillar.
section_of() {
  _assert_args "$#" "${2-}" || return 2
  awk -v pat="$2" 'index($0, pat) {f = 1; print; next} f && /^## / {exit} f' "$1"
}

# Collapse every run of whitespace to one space, so a needle spanning a line
# break still matches. Prose needles that are line-scoped (`grep -qF`) pass
# only because of where the source happens to wrap today, and a routine
# markdownlint re-flow then reds them with a message pointing at the rule
# rather than at the wrapping. This is `tests/prose-lockstep.bash`'s
# normalisation, minus its emphasis-stripping — these needles carry backticks
# and asterisks deliberately.
flow() {
  # one argument, checked explicitly: assertions.bash's `_assert_args` is
  # hard-coded to a two-argument (haystack, needle) shape, so reusing it here
  # would reject every call. Same guard shape as prose-lockstep.bash's own
  # helpers — a dropped argument is a usage error (2), never a silent pass.
  [ "$#" -eq 1 ] || { printf 'philosophy-pointers: flow needs exactly one string\n' >&2; return 2; }
  printf '%s' "$1" | tr -s '[:space:]' ' '
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PHILOSOPHY="$REPO_ROOT/docs/explanation/philosophy.md"
  README="$REPO_ROOT/README.md"
  CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
  MOTIVATION="$REPO_ROOT/docs/explanation/motivation.md"
  WHY="$REPO_ROOT/docs/explanation/why-per-language-plugins.md"
}

# --- the target the four pointers name ---------------------------------------

@test "#1629 link integrity: every pointer's target page exists" {
  # the mechanical guard against a pointer that reads fine and resolves to
  # nothing — README.md and CLAUDE.md get no link validation from any gate
  [ -f "$PHILOSOPHY" ]
}

@test "#1629 philosophy.md defines each of the six anchors CLAUDE.md promises, exactly once" {
  # CLAUDE.md advertises the range #pillar-1 … #pillar-6. mkdocs validates only
  # the anchors something LINKS (four of the six today), so the other two are
  # checked by nothing; a duplicate id would silently shadow one.
  local n
  # grep -oE, not -c: `-c` counts matching LINES, so two anchors on one heading
  # would read as 1 and pass while the rendered page shadows an id. The ERE
  # form also avoids `\+`, a GNU-only BRE extension that BSD grep (macOS, this
  # repo's primary platform) reads as a literal plus.
  n="$(grep -oE '^## .*\{#pillar-[0-9]+\}' "$PHILOSOPHY" | wc -l | tr -d ' ')"
  [ "$n" -eq 6 ]
  local i
  for i in 1 2 3 4 5 6; do
    local hits
    hits="$(grep -oF "{#pillar-$i}" "$PHILOSOPHY" | wc -l | tr -d ' ')"
    [ "$hits" -eq 1 ]
  done
}

# --- README ------------------------------------------------------------------

@test "#1629 README's Read-more line points at the philosophy page" {
  # README is outside mkdocs' docs_dir, so a retarget or a deletion here is
  # invisible to the docs build and to every other suite
  grep -Fq '[The six pillars](docs/explanation/philosophy.md)' "$README"
}

# --- CLAUDE.md ---------------------------------------------------------------

@test "#1629 CLAUDE.md carries the pillars rule, anchored on its body" {
  # anchor on the BODY clauses, not the heading alone, so deleting the rule
  # while keeping the heading fails — the idiom of
  # tests/claude-md-architecture-pointer.bats
  # the two prose clauses go through the flowed SECTION, not a line-scoped
  # grep: needled at the line's wrap, 'state once, link' leaves the word
  # carrying the rule's universality unpinned, so "state once, link only where
  # it is convenient" would pass; and either clause reds spuriously on a
  # re-flow, the hazard flow() exists to remove
  local section
  section="$(flow "$(section_of "$CLAUDE_MD" '## Pillars are stated once')")"
  [ -n "$section" ]
  # pin the pointer's link text AND target together, as the README test does:
  # a bare path needle is met by the heading and the backticked link text
  # alone, so a retargeted or de-linked pointer passed (#1658). Changing the
  # link text is therefore a deliberate pin change, not a false red
  contains "$section" '[`docs/explanation/philosophy.md`](docs/explanation/philosophy.md)'
  contains "$section" 'state once, link everywhere (#1432)'
  contains "$section" "do not paraphrase the pillar's wording"
}

@test "#1629 CLAUDE.md gives a link form for OUTSIDE docs/, not only the two relative ones" {
  # the rule names skills, agents and issues, where no relative path resolves;
  # without the absolute form it dictates a dead link from three of the four
  # contexts it addresses
  local section
  section="$(flow "$(section_of "$CLAUDE_MD" '## Pillars are stated once')")"
  [ -n "$section" ]
  # one needle per bullet, so deleting any single form reds — including the
  # docs/explanation/ one, which is the form BOTH in-scope docs pages use
  # PAIR each form with its context. Bare form needles prove only that a
  # string appears somewhere in the section, so swapping the payloads of the
  # docs/explanation/ and repo-root bullets leaves all of them matching while
  # the rule dictates a dead link from both of the contexts it serves most.
  contains "$section" 'from a page in `docs/explanation/`: `philosophy.md#pillar-N`'
  contains "$section" '`../explanation/philosophy.md#pillar-N` from a bucket subdirectory'
  contains "$section" 'explanation/philosophy.md#pillar-N` from `docs/index.md`'
  contains "$section" 'this file): `docs/explanation/philosophy.md#pillar-N`'
  contains "$section" 'https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/docs/explanation/philosophy.md'
  # the absolute form carries no followable anchor, so the rule must say to
  # name the pillar in prose instead — without this the bullet contradicts the
  # section's own "link that anchor" mandate
  contains "$section" 'name the pillar in the surrounding prose'
}

@test "#1630 CLAUDE.md pairs the plugin-file context with the published-site URL" {
  # PAIR the context with its form inside ONE list item. Two `contains` checks
  # against the whole flowed section pass a swap of the plugin-file and issue
  # bullets' payloads, because both strings are still somewhere in the section.
  # So split the RAW section into list items first — flow() erases the line
  # starts the split depends on — then flow each item on its own, so a
  # markdownlint re-flow that wraps the phrase cannot red this.
  local raw items n item
  raw="$(section_of "$CLAUDE_MD" '## Pillars are stated once')"
  [ -n "$raw" ]
  items="$(printf '%s\n' "$raw" | awk '
    function close_item() { if (open) print cur; open = 0; cur = "" }
    /^- / { close_item(); open = 1; cur = $0; next }
    /^[[:space:]]*$/ { close_item(); next }
    open { cur = cur " " $0 }
    END { close_item() }
  ' | while IFS= read -r line; do flow "$line"; printf '\n'; done)"
  [ -n "$items" ]
  # exactly one item holds the context: a second bullet adopting the phrase
  # reds here rather than the assertions silently checking the first match
  n="$(printf '%s\n' "$items" | grep -cF 'a skill, an agent or a bootstrap template' || true)"
  [ "$n" -eq 1 ]
  item="$(printf '%s\n' "$items" | grep -F 'a skill, an agent or a bootstrap template')"
  contains "$item" 'https://timo-jakob.github.io/timos-claude-code-plugins/explanation/philosophy/#pillar-N'
  # the bullet's HOW, not only its WHICH URL: without this needle the link-text
  # and line-position clause can be deleted or inverted with the suite green
  contains "$item" "with the pillar's H2 title as link text and the URL ending its line"
  lacks "$item" 'https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/docs/explanation/philosophy.md'
  # the other half of the split: the blob-URL bullet must no longer claim the
  # plugin-file contexts. Reverting it to its pre-#1630 wording ("a skill, an
  # agent, a bootstrap template or a GitHub issue") keeps every needle above
  # green while routing a skill to BOTH forms.
  local blob
  n="$(printf '%s\n' "$items" | grep -cF 'blob/main/docs/explanation/philosophy.md' || true)"
  [ "$n" -eq 1 ]
  blob="$(printf '%s\n' "$items" | grep -F 'blob/main/docs/explanation/philosophy.md')"
  contains "$blob" 'a GitHub issue'
  lacks "$blob" 'a skill'
  lacks "$blob" 'an agent'
  lacks "$blob" 'bootstrap template'
}

@test "#1629 CLAUDE.md's never-restate rule exempts ARCHITECTURE.md's position rationales" {
  # The messaging, browser-UI and identity positions each word pillar 1 in their
  # own rationale, and each of those sentences is pinned clause-by-clause by
  # tests/messaging-position.bats, tests/webui-positions.bats and
  # tests/identity-position.bats. An UNBOUNDED "the only place a pillar is
  # worded" tells a session to delete them and red three suites, so the
  # carve-out is what makes the rule obeyable.
  local section
  section="$(flow "$(section_of "$CLAUDE_MD" '## Pillars are stated once')")"
  [ -n "$section" ]
  # needle the BRANCH, not its topic: 'ARCHITECTURE.md' + 'Rationale' would be
  # satisfied by a reworded sentence saying the opposite
  contains "$section" 'deliberately exempt'
  contains "$section" 'may argue the underlying principle in its own words'
  # the exemptions beyond ARCHITECTURE.md. Without them the ban reads as
  # unscoped, and a compliance sweep would gut README's Why and motivation's
  # Motivation — which word pillar 3's Why nearly verbatim — and rewrite
  # frozen fixtures under tests/fixtures/
  contains "$section" "this repo's own statement of purpose"
  # both halves of the historical exemption — pinning only tests/fixtures/
  # leaves a sweep free to rewrite the dated records, falsifying them
  contains "$section" 'dated records under `docs/superpowers/`'
  contains "$section" 'tests/fixtures/'
  # this file itself quotes pillar wording as needles; without this exemption
  # a compliance sweep would delete the very guards on this rule
  contains "$section" 'a needle in `tests/*.bats` that quotes a pillar'
  contains "$section" 'tests/*-position*.bats'
  # the SUBJECT of the exemption, not just its predicate: the needles above sit
  # either side of the clause that says WHAT is exempt, so reverting it to the
  # marker-specific spelling (which excluded the messaging position's
  # `**Rationale.**` paragraph) left all of them matching
  contains "$section" "a position's own rationale in \`ARCHITECTURE.md\`"
  contains "$section" 'however it is marked'
  # the protected span — the whole remedy for round 1's "no defined subject"
  contains "$section" 'italic one-liner'
  # all three protected spans, plus the prohibition itself: needling only the
  # one-liner lets ", its **Statement** and its **Why**" be deleted — shrinking
  # the ban to one span and stranding two of test 13's lacks needles — and lets
  # "do not reproduce or paraphrase" be softened, both with the suite green
  contains "$section" 'its **Statement** and its **Why** are worded only on the philosophy page'
  # the ban is SCOPED to the contexts the rule names. Unscoped ("anywhere
  # else") it licenses a compliance sweep over the whole repo — see the
  # exemption needles below for what that would have destroyed.
  contains "$section" '**in the contexts above**, do not reproduce or paraphrase them'
  contains "$section" 'The H2 title may be used as link text'
}

# --- motivation.md -----------------------------------------------------------

@test "#1629 motivation.md delegates the convictions to the philosophy page" {
  local body
  body="$(flow "$(cat "$MOTIVATION")")"
  contains "$body" 'stated once, as six pillars, on [the philosophy page](philosophy.md)'
  # the SECOND delegation pointer, in gap entry 6 — its link text has no inner
  # "the", so a needle written for the first one never reached it
  contains "$body" '[philosophy page](philosophy.md) states the family'
  contains "$body" 'it owns that text, so this list does not repeat it'
}

@test "#1629 motivation.md's gap entry 6 links each open pillar to its epic, and its title counts them" {
  # PAIR each pillar with its own epic in ONE needle. Six independent
  # existence checks pass a swap — pillar 2 pointing at #1624 and pillar 6 at
  # #1626 satisfies all six while contradicting philosophy.md's Gap sections,
  # and mkdocs stays green because both anchors and both URLs still resolve.
  # Each pair wraps across two source lines, so the flowed body is required.
  local body
  body="$(flow "$(cat "$MOTIVATION")")"
  contains "$body" '[never asks "how"](philosophy.md#pillar-2) — [#1626](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1626)'
  contains "$body" '[epics and issues are split when too big](philosophy.md#pillar-5) — [#1625](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1625)'
  contains "$body" '[the AI owns a self-optimising loop](philosophy.md#pillar-6) — [#1624](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1624)'
  # The title's count, DERIVED from the pairs rather than needled (#1659). The
  # landing rule drops a pillar's line and corrects the count together; a
  # literal 'Three pillars' needle would red on that correct edit, while no
  # check at all lets a half-done one ship. So count the entry's full pairs —
  # never a bare #pillar-N or [#NNNN] — and match the title's word to them.
  local entry matched pairs pillars title want
  # entry 6 alone: up to (not including) the next numbered entry, the next
  # `## ` heading, or EOF
  entry="$(awk 'f && (/^[0-9]+\. \*\*/ || /^## /) {exit} /^6\. \*\*/ {f = 1} f' "$MOTIVATION")"
  [ -n "$entry" ]
  entry="$(flow "$entry")"
  matched="$(printf '%s' "$entry" | grep -oE '\]\(philosophy\.md#pillar-[1-6]\) — \[#[0-9]+\]\(' || true)"
  pairs="$(printf '%s' "$matched" | grep -c . || true)"
  [ "$pairs" -gt 0 ]
  # the title counts PILLARS, so the pairs must name distinct ones: a second
  # pair for an already-listed pillar plus a title bumped to match would
  # otherwise pass while the page claims one open pillar too many
  pillars="$(printf '%s\n' "$matched" | grep -oE 'pillar-[1-6]' | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  [ "$pillars" -eq "$pairs" ]
  title="$(printf '%s\n' "$entry" | sed -n 's/^6\. \*\*\([^*]*\)\*\*.*/\1/p')"
  # only the two grammatical forms; a digit, a wrong singular/plural pairing or
  # a word outside One–Six maps to 0, which the count (> 0 above) never equals
  case "$title" in
    'One pillar has an open gap epic.') want=1 ;;
    'Two pillars have an open gap epic.') want=2 ;;
    'Three pillars have an open gap epic.') want=3 ;;
    'Four pillars have an open gap epic.') want=4 ;;
    'Five pillars have an open gap epic.') want=5 ;;
    'Six pillars have an open gap epic.') want=6 ;;
    *) want=0 ;;
  esac
  [ "$want" -eq "$pairs" ]
}

@test "#1629 gap entry 6 says what to do when ONE epic lands, not only when all three do" {
  # an all-three-only rule leaves the page asserting an open gap that has
  # closed, on the one page whose stated job is an honest gap list
  local body
  body="$(flow "$(cat "$MOTIVATION")")"
  contains "$body" 'When one of these epics lands'
  # the rule's PRIMARY prescription — without it the clause can be deleted and
  # the remaining needles still match, leaving philosophy.md's per-pillar
  # sections and their honest-limit notes with nothing telling a landed epic
  # to update them
  contains "$body" "updates that pillar's *What enforces it today* and *Gap* parts"
  contains "$body" 'including the honest-limit note above the Gap'
  # the trigger alone survives an inversion ("...nothing here changes"), so
  # pin what the branch actually prescribes
  contains "$body" 'deletes that pillar'"'"'s line here, correcting the count'
  # the rule's other half: without this, deleting the retirement clause leaves
  # an entry that never goes away once all its gaps close
  contains "$body" 'when the last one lands the whole entry goes'
}

@test "#1629 each gap-6 pillar link points at the pillar whose text it names" {
  # validation.anchors proves an anchor EXISTS, never that it is the right one,
  # so swapping #pillar-5 and #pillar-6 here passes every other gate
  local sec
  sec="$(section_of "$PHILOSOPHY" '{#pillar-2}')"
  [ -n "$sec" ]
  contains "$sec" 'Never asks "how"'
  sec="$(section_of "$PHILOSOPHY" '{#pillar-5}')"
  [ -n "$sec" ]
  contains "$sec" 'Epics and issues are split when too big'
  sec="$(section_of "$PHILOSOPHY" '{#pillar-6}')"
  [ -n "$sec" ]
  contains "$sec" 'The AI owns a self-optimising loop'
}

@test "#1629 motivation.md does not itself restate a pillar's wording" {
  # the page asserts of itself that "it owns that text, so this list does not
  # repeat it" — pin the FACT, not just the claim. why-per-language gets this
  # half already; motivation.md is the other docs entry point and had only the
  # positive pins, so pasting pillar text in passed.
  local body
  body="$(flow "$(cat "$MOTIVATION")")"
  # positive control on the same haystack the lacks calls read
  contains "$body" 'Honest list of where the implementation does not yet match'
  lacks "$body" 'one blessed path'
  lacks "$body" 'no options to choose'
  lacks "$body" 'picks one way of doing each thing'
  lacks "$body" 'permanent maintenance cost for the family'
  # pillars 2, 5 and 6 are the ones gap entry 6 actually names, so they are
  # where a restatement would realistically grow — pillar-1 needles alone left
  # them free. Pillar 5's one-liner IS its H2 title, so needle its Statement.
  lacks "$body" 'the family already holds a position and applies it'
  lacks "$body" 'size is a reason to split, never a reason to stop'
  lacks "$body" 'it assesses its own runs, learns from them'
  # NOT the H2 titles: CLAUDE.md permits a pillar's title as link text and gap
  # entry 6 uses all three that way, so needling those would red on shipped,
  # permitted content.
}

# --- why-per-language-plugins.md ---------------------------------------------

@test "#1629 why-per-language reason 1 links pillar 1 from the word opinionated" {
  # reverting this to a bare word leaves nothing for mkdocs to validate, so the
  # entry point silently stops pointing at the philosophy page
  local body
  body="$(flow "$(cat "$WHY")")"
  contains "$body" '[opinionated](philosophy.md#pillar-1) because *I* am'
}

@test "#1629 pillar 1 is the anchor whose statement is the blessed-path one" {
  # guards the retarget case: #pillar-3 also exists, so a wrong-but-live anchor
  # keeps every other gate green while the sentence cites the wrong pillar
  local sec
  sec="$(section_of "$PHILOSOPHY" '{#pillar-1}')"
  [ -n "$sec" ]
  contains "$sec" 'one blessed path'
}

@test "#1629 why-per-language no longer restates pillar 1's wording" {
  # the negative half, with a positive control first so a wrong path cannot
  # pass vacuously (the shape tests/messaging-position.bats uses)
  local body
  body="$(flow "$(cat "$WHY")")"
  # positive control on the SAME haystack the lacks calls read, so narrowing
  # $body later cannot leave them passing vacuously
  contains "$body" 'These plugins are'
  # CLAUDE.md defines "the pillar's wording" as three things — the italic
  # one-liner, the Statement and the Why — so guard one needle from each,
  # QUOTED FROM philosophy.md. A needle that quotes nothing protects nothing:
  # 'permanent maintenance and expertise cost' (this test's first cut) is
  # ARCHITECTURE.md's phrasing, which the carve-out exempts, so pasting
  # philosophy.md's actual Why here passed.
  lacks "$body" 'one blessed path'
  lacks "$body" 'no options to choose'
  lacks "$body" 'permanent maintenance cost for the family'
  lacks "$body" 'picks one way of doing each thing'
}
