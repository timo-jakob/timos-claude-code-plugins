#!/usr/bin/env bats
#
# The family's decision-rights contract (#2899, epic #2898).
#
# ARCHITECTURE.md's "Decision rights" section is the authoritative record of
# which questions reach a human: the three question kinds (intent, gap,
# implementation) with who answers each, the tie-break that sends a question
# doubtfully implementation to the other kind, and the Decisions-taken record a decision
# taken instead of a question leaves behind. Every later child of #2898 links
# this section, so softening it would soften all of them at once — each clause
# is pinned on its own, because a section-level "mentions gap" check survives
# deleting any one of them.
#
# ANCHOR FORM: headings and quoted tokens only, never `path:line` — the rule the
# other position suites follow. Line numbers rot across unrelated merges.
#
# ON THE END ADDRESS: the extractor ends at the GENERIC `^## `, and the
# `ends_with` pin names the heading that follows today, so a section inserted
# after this one reds loudly instead of being swallowed into the range — the
# idiom tests/messaging-position.bats and its siblings use.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  PHILOSOPHY="$REPO_ROOT/docs/explanation/philosophy.md"
}

SECTION_START='^## Decision rights'
SECTION_END='^## '
ARCH_END='## Maximizing autonomy'
SECTION_TITLE='Decision rights — question taxonomy and the Decisions-taken record (#2899)'

# Collapse a region to one line, whitespace squeezed and the trailing space
# trimmed, so a pinned sentence matches across a re-wrap.
collapse() {
  tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//'
}

# The section, line by line — the table-row pins below read single lines.
raw_section() {
  sed -n "/$SECTION_START/,/$SECTION_END/p" "$ARCH"
}

section() {
  raw_section | collapse
}

# The lines of one ### subsection of the section, from its heading to the next
# ### or ## heading. awk reads the file itself rather than a pipe, so an early
# stop can never race a producer (tests/early-exit-reader-guard.bats).
subsection() {
  awk -v h="### $1" '
    /^## / { in_sec = ($0 ~ /^## Decision rights/) }
    /^##/ { on = (in_sec && $0 == h); next }
    on { print }' "$ARCH"
}

@test "the section exists under its title and ends where the next section begins" {
  local s
  s="$(section)"
  [ -n "$s" ]
  starts_with "$s" "## $SECTION_TITLE"
  ends_with "$s" "$ARCH_END"
}

@test "it links pillar 2 in the repo-root form, at the anchor whose heading it names" {
  contains "$(section)" '[Never asks "how"](docs/explanation/philosophy.md#pillar-2)'
  grep -qxF '## Never asks "how" {#pillar-2}' "$PHILOSOPHY"
}

@test "it does not restate pillar 2's one-liner, Statement or Why" {
  # Needles QUOTED FROM philosophy.md, one or more from each of the three parts
  # CLAUDE.md calls the pillar's wording. The positive control proves each still
  # occurs there, so a reworded pillar cannot leave a needle that quotes nothing.
  local s p needle
  s="$(section)"
  p="$(collapse < "$PHILOSOPHY")"
  for needle in \
    "the family's architecture positions decide" \
    'already holds a position and applies it' \
    'never *how* to build it' \
    'turns every run into a design review' \
    'Deciding once, in writing'; do
    contains "$p" "$needle"
    lacks "$s" "$needle"
  done
}

@test "the opening paragraph binds every component that asks, and its appliers link here" {
  contains "$(section)" 'Every component of the family that can put a question to a human — the readiness gate, the issue refiner, the resolve-issue and refine-issue conductors — sorts each candidate question into one of three kinds before it asks.'
  contains "$(section)" 'and the agents and skills that apply it link here rather than restate it'
}

@test "there are exactly three question kinds" {
  local rows
  rows="$(subsection 'The three question kinds' | grep -c '^| `')"
  [ "$rows" -eq 3 ]
}

@test "intent is asked, and covers scope, risk acceptance and anything irreversible" {
  local row
  row="$(subsection 'The three question kinds' | grep '^| `intent` |')"
  contains "$row" 'What to build, scope, priority, non-functional targets, personas'
  contains "$row" 'risk acceptance (security, cost, data loss)'
  contains "$row" 'anything irreversible or outward-facing'
  contains "$row" '**Asked.** The human answers; in refine-issue only, subject to its auto-accept rules (*Runtime setting: `refine_auto_accept_threshold`*; #2900).'
}

@test "gap is asked, and carries the document change that closes it" {
  local row
  row="$(subsection 'The three question kinds' | grep '^| `gap` |')"
  contains "$row" '**Silence:** something the work needs on which the architecture positions, the functional or non-functional requirements and the persona registry are silent, and which established practice does not settle.'
  contains "$row" '**Contradiction:** any case where those documents contradict each other, whatever established practice says.'
  contains "$row" '**Asked**, under the same auto-accept rules as `intent`, and the question carries a proposed document change that closes the gap, which lands in the story PR (#2901).'
}

@test "implementation is never asked: Claude decides and records it" {
  local row
  row="$(subsection 'The three question kinds' | grep '^| `implementation` |')"
  contains "$row" 'Anything the positions plus established practice decide, whether or not the tooling — linters, formatters, tests, review panels, CI — can verify it.'
  contains "$row" '**Never asked.** Claude decides, and records the decision in the *Decisions taken* record below.'
}

@test "the tie-break: implementation only when neither intent nor gap; in doubt, the other kind" {
  local t
  t="$(subsection 'The tie-break' | collapse)"
  contains "$t" 'A question is `implementation` only when it is neither `intent` nor `gap` under the definitions above.'
  contains "$t" 'When in doubt between `implementation` and either other kind, it is the other kind; when in doubt between `intent` and `gap`, it is `gap`, since its document change keeps the answer from being asked twice.'
}

@test "the tie-break's rationale names the asymmetry it rests on" {
  local t
  t="$(subsection 'The tie-break' | collapse)"
  contains "$t" 'the two mistakes do not cost the same'
  contains "$t" 'A gap misfiled as implementation is decided silently on ground no document covers'
}

@test "the Decisions-taken record has exactly its four fields" {
  local r
  r="$(subsection 'The Decisions-taken record')"
  contains "$(collapse <<< "$r")" 'Each entry carries four fields:'
  contains "$r" '| question | The question that would otherwise have been asked. |'
  contains "$r" '| choice | What Claude chose. |'
  contains "$r" '| evidence | The position, requirement or established practice the choice rests on, cited by its section or file. |'
  contains "$r" '| how to overrule | What a human does to reverse the choice after the fact. |'
  [ "$(grep -cE '^\| (question|choice|evidence|how to overrule) \|' <<< "$r")" -eq 4 ]
  # header and separator aside, the field table holds no other row
  [ "$(grep -c '^| ' <<< "$r")" -eq 5 ]
}

@test "the record is complete: nothing decided in place of a question is left out" {
  local r
  r="$(subsection 'The Decisions-taken record' | collapse)"
  contains "$r" 'When Claude decides a question instead of asking it, it writes one entry per decision to a **Decisions taken** list.'
  contains "$r" 'Nothing Claude decides in place of a question — an auto-accepted answer included — is left out of it.'
}

@test "the record lives in a fixed section of the issue body or the PR body" {
  local r
  r="$(subsection 'The Decisions-taken record' | collapse)"
  contains "$r" 'The list lives in a fixed section, a `## Decisions taken` heading:'
  contains "$r" 'in the **issue body** when the decision is taken before implementation (refinement, the readiness gate)'
  contains "$r" 'in the **PR body** when it is taken during implementation'
  contains "$r" 'The section is append-only: a run that decided something adds its entries to the existing section and never removes an earlier run'"'"'s entries; a run that decided nothing adds no section and removes none.'
}

@test "pillar 2's What-enforces-it list names the section and this suite" {
  local list
  list="$(awk '
    /\{#pillar-2\}/ { p = 1; next }
    p && /^## / { exit }
    p && /^### What enforces it today/ { on = 1; next }
    on && /^### / { exit }
    on { print }' "$PHILOSOPHY" | collapse)"
  [ -n "$list" ]
  contains "$list" "*$SECTION_TITLE*"
  contains "$list" '[`tests/decision-rights-position.bats`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/tests/decision-rights-position.bats)'
  [ -f "$BATS_TEST_FILENAME" ]
}
