#!/usr/bin/env bats
#
# development-go inventory parity with docs/reference/plugins.md (issue #1129).
#
# WHY THIS EXISTS: docs/reference/agents.md and commands.md are GENERATED and
# CI-diff-checked by scripts/generate-docs-reference.py --check, but
# docs/reference/plugins.md is hand-written narrative that no generator covers
# and that only one heading-presence test touched (tests/react-topic-marker.bats
# greps for `## development-react` — consolidate here when widening beyond
# development-go). So it drifted: epic #868 shipped 18 Go agents and the
# /development-go:approve skill while plugins.md still documented 12 agents, no
# approve row, and a dispatcher contract the skill does not have. The same
# failure mode had already recurred once for development-javascript (#1104) —
# one mechanical, fully-detectable pattern with nothing standing between it and
# a third occurrence.
#
# These assert BOTH directions, because each catches a different drift: doc-side
# omission (an agent ships undocumented) and doc-side staleness (a row survives
# the agent it names being deleted or renamed).
#
# SCOPE: development-go only, deliberately. A repo-wide version would red on
# development-javascript, whose documented gap is #1104's to close — pinning it
# here would import an unrelated failure. Widening this to the other plugins
# belongs with that fix, not here.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLUGINS_DOC="$REPO_ROOT/docs/reference/plugins.md"
  AGENTS_DIR="$REPO_ROOT/development-go/agents"
  SKILLS_DIR="$REPO_ROOT/development-go/skills"

  # Slice the `## development-go` section out, so a name that appears only in a
  # SIBLING plugin's section can never satisfy an assertion here. Without this
  # every check is a whole-file grep, and `go-approver` would "pass" on a stray
  # mention in the Approver explainer paragraph of another section.
  SECTION="$BATS_TEST_TMPDIR/development-go.section.md"
  _slice_section development-go "$PLUGINS_DOC" > "$SECTION"
}

# The TABLE ROW whose first cell is the given backticked identifier, or empty.
#
# Anchoring on `^| \`name\` |` — not a bare grep for the name — is the whole
# point: #1129's drift included two advisors "named in the prose but with no
# table row", and a loose grep counts that prose sentence as documentation. It
# also keeps the Model-cell check honest, since a prose line has no Model cell
# to disagree with.
_row_for() {
  grep -E "^\|[[:space:]]*\`$1\`[[:space:]]*\|" "$SECTION" | head -1
}

# The Skills-table row whose COMMAND CELL is /development-go:<name>, or empty.
#
# Anchored to the second cell (`^| <label> | `<command>`), not to "the command
# appears somewhere in the row". A row merely *mentioning* another command — an
# agent Focus cell reading "invoked via `/development-go:approve`", say — would
# otherwise satisfy the lookup, and the tests built on this helper then assert
# their needles against the WRONG row: a false red, or a false green if that row
# happens to carry the needles. That is the same loose-match failure this file
# already hit twice (the caveat pin, and a bare `commits` needle).
#
# `([^a-z0-9-]|$)` and NOT `\b`: the word boundary is a GNU grep extension. This
# box's BSD grep happens to accept it, but the suite runs a macos-latest AND an
# ubuntu-latest leg precisely to catch constructs that mean different things on
# each (#292/#293), and no other pattern in tests/ relies on `\b`. Skill and
# agent names are drawn from [a-z0-9-], so the negated class anchors the name
# exactly — `approve` cannot be satisfied by `approver`.
_skill_row_for() {
  grep -E "^\|[^|]*\|[[:space:]]*\`/development-go:$1([^a-z0-9-]|\$)" "$SECTION" | head -1
}

# The body of a `## <heading>` section of a markdown file, terminated by the
# next level-2 heading. Extracted from setup() so the slicer itself is testable
# against a fixture — see the boundedness test below.
_slice_section() {
  awk -v h="## $1" '$0==h{f=1;next} /^## /{f=0} f' "$2"
}

@test "the extracted development-go section is non-empty AND bounded (#1129)" {
  # Guards every other test in this file, at BOTH ends.
  #
  # Non-emptiness alone is not enough: the anchoring guarantee this whole file
  # rests on depends on the awk TERMINATOR (`/^## /{f=0}`) too. Break the
  # terminator and $SECTION silently becomes the rest of the file — every test
  # below still passes while degrading to the whole-file grep the slice exists
  # to prevent. That half fails silently, so pin it explicitly.
  [ -s "$SECTION" ]
  [ "$(grep -c '^## ' "$SECTION")" -eq 0 ]
  # A positive anchor, so a slice starting at the WRONG heading also reds.
  contains "$(cat "$SECTION")" 'Blessed toolchain'
}

@test "_slice_section stops at the next level-2 heading (#1129)" {
  # The boundedness assertion above cannot fail against the LIVE doc today,
  # because `## development-go` is its last `## ` section — so the terminator is
  # currently inert and a regression in it would go unnoticed until someone
  # appends a section. Test the slicer directly against a fixture instead, so
  # the trailing edge is pinned NOW rather than whenever the doc grows.
  fixture="$BATS_TEST_TMPDIR/fixture.md"
  printf '%s\n' \
    '## development-aaa' 'BEFORE-MARKER' \
    '## development-go' 'INSIDE-MARKER' \
    '## development-zzz' 'AFTER-MARKER' > "$fixture"

  sliced="$(_slice_section development-go "$fixture")"
  contains "$sliced" 'INSIDE-MARKER'
  lacks "$sliced" 'BEFORE-MARKER'
  lacks "$sliced" 'AFTER-MARKER'
  lacks "$sliced" '## development-zzz'
}

@test "every shipped development-go agent has a TABLE ROW in plugins.md (#1129)" {
  for f in "$AGENTS_DIR"/*.md; do
    name="$(basename "$f" .md)"
    # A row, not a mention: go-grpc-advisor and go-api-contract-advisor were
    # both named in this section's prose while #1129 was open, and that is
    # precisely what the issue counted as undocumented.
    row="$(_row_for "$name")"
    # Each assertion is a command of its own, never `&&`-joined: errexit catches
    # it on every bash, including the 3.2 that macOS ships.
    [ -n "$row" ]
  done
}

@test "every go-* agent named in plugins.md still exists on disk (#1129)" {
  # The reverse direction: catches a row outliving a deleted/renamed agent.
  #
  # Harvest from FIRST TABLE CELLS only, not from prose. This section is
  # narrative about Go tooling, so a future backticked `go-licenses` / `go-cmp`
  # in a sentence would otherwise red this test claiming a documented agent is
  # missing from disk — a false positive pointing at entirely the wrong thing.
  # Rows are the inventory; that is the direction being tested.
  names="$(grep -oE '^\|[[:space:]]*`go-[a-z0-9-]+`' "$SECTION" | grep -oE 'go-[a-z0-9-]+' | sort -u)"
  [ -n "$names" ]
  for name in $names; do
    [ -f "$AGENTS_DIR/$name.md" ]
  done
}

@test "each agent's Model cell matches its frontmatter model: (#1129)" {
  # The fable/opus split is a real contract this repo edits in bulk:
  # scripts/toggle-fable.zsh (tests/toggle-fable.bats) rewrites `model: fable` →
  # `model: opus` across */agents/*.md without touching any doc, so a stale
  # Model column is a genuine regression. Note a toggled working tree reds this
  # test for the fable agents exactly as it reds
  # `generate-docs-reference.py --check` — restore with `toggle-fable.zsh on`.
  # Anchor on the agent's OWN row: a whole-file grep for `opus` would be
  # satisfied by surrounding prose.
  for f in "$AGENTS_DIR"/*.md; do
    name="$(basename "$f" .md)"
    model="$(grep -m1 '^model:' "$f" | sed 's/^model:[[:space:]]*//')"
    [ -n "$model" ]
    row="$(_row_for "$name")"
    [ -n "$row" ]
    # Tolerant of cell padding: a markdown table re-alignment (`| fable   |`)
    # is not semantic drift and must not red all 18 iterations.
    printf '%s\n' "$row" | grep -Eq "\|[[:space:]]*$model[[:space:]]*\|"
  done
}

@test "every development-go skill has a Skills-table row (#1129)" {
  # This is the assertion that would have caught the missing approve row.
  for d in "$SKILLS_DIR"/*/; do
    [ -f "$d/SKILL.md" ]
    name="$(basename "$d")"
    # Anchored to a table row for the same reason as the agents: the Skills
    # table is the inventory, a passing prose mention is not.
    row="$(_skill_row_for "$name")"
    [ -n "$row" ]
  done
}

@test "every /development-go:* command named in plugins.md has a SKILL.md (#1129)" {
  names="$(grep -oE '/development-go:[a-z0-9-]+' "$SECTION" | sed 's|/development-go:||' | sort -u)"
  [ -n "$names" ]
  for name in $names; do
    [ -f "$SKILLS_DIR/$name/SKILL.md" ]
  done
}

@test "the dispatcher row documents the real two-phase improver_result contract (#1129)" {
  # Pins what this issue CORRECTED: the pre-#1129 row claimed the dispatcher was
  # single-phase and never emitted improver_result. A needle like `coverage`
  # would match that stale wording too, so pin the contract's own terms.
  row="$(_skill_row_for maintenance)"
  [ -n "$row" ]
  contains "$row" 'improver_result'
  contains "$row" 'Phase A'
  contains "$row" 'Phase B'
  # ONE NEEDLE PER BRANCH. A bare 'commits' is satisfied by "commits tests"
  # alone, so deleting the collapse clause would leave it green — and the
  # collapse branch is exactly what the first draft of this row omitted.
  contains "$row" 'commits tests'
  contains "$row" 'commits nothing'
  lacks "$row" 'Single-phase'
}

@test "the approve row keeps its bootstrap-wiring caveat (#1129)" {
  # go-approver hard-fails without .claude/approver-policy.md, and bootstrap
  # ships no Go approver-policy overlay — templates/languages/go/ DOES exist
  # (the Slice F #875 toolchain templates), but only java/python/swift carry an
  # approver-policy-overlay.md.tmpl. Retire this test when the Go overlay lands.
  [ ! -f "$REPO_ROOT/development/skills/bootstrap/templates/languages/go/approver-policy-overlay.md.tmpl" ]
  # The caveat asserts TWO facts; pin both. This is the other half: bootstrap's
  # Approver-capable language enumeration.
  #
  # PARAGRAPH-mode over EVERY such statement, not a fixed line window. bootstrap
  # SKILL.md restates the enumeration in several places (the scope sentence, the
  # §3e resolution rule, the skip notes), and a fixed `grep -A2` window around
  # one of them misses the two most likely regressions: adding `go` to a
  # different restatement, and a re-wrap pushing the word past the window's last
  # line. RS='' also sidesteps the `-m`/`-A` interaction, whose trailing-context
  # behaviour differs between GNU and older BSD grep — the two-lane matrix
  # (#292/#293) exists so an assertion cannot mean different things per leg.
  # Scoped to paragraphs, never the whole file: `go` appears all over SKILL.md.
  caps="$(awk -v RS='' '/Approver-capable/' \
    "$REPO_ROOT/development/skills/bootstrap/SKILL.md")"
  [ -n "$caps" ]
  # Backticks written literally: inside single quotes a backslash is NOT an
  # escape, so '\`go\`' would be a needle containing real backslashes — one that
  # never matches, making the assertion silently vacuous. That exact slip
  # shipped in this test's first draft and was caught only by mutation-testing.
  lacks "$caps" '`go`'

  # Anchored to the APPROVE ROW, not the section. A whole-section grep for
  # `approver-policy.md` is satisfied by the go-approver AGENT row ("reads
  # `.claude/approver-policy.md`"), which describes the agent's own behaviour
  # and must stay regardless — so deleting the caveat would leave the assertion
  # green. That is the exact loose-grep failure mode `_row_for` exists to avoid.
  row="$(_skill_row_for approve)"
  [ -n "$row" ]
  contains "$row" 'approver-policy.md'
  # A needle unique to the CAVEAT, not to the agent's behaviour.
  contains "$row" 'hand-authored'
  # The caveat's FIRST clause needs its own doc-side needle: both needles above
  # live in its second sentence, so deleting "bootstrap doesn't resolve `go` as
  # an Approver-capable language" would otherwise leave this test green. The
  # phrase appears in this row and nowhere else in the section.
  contains "$row" 'Approver-capable language'
}
