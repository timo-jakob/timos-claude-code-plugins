#!/usr/bin/env bats
#
# The PDF manual's layout assets. manual.pdf is built by pandoc +
# xelatex, which does not wrap what it cannot break: a long path in a table cell
# printed on top of the neighbouring column, a long code line ran off the page,
# and a character with no glyph (≥, ↔, ⚠) was dropped silently. The fix is two
# assets under scripts/pandoc/ that BOTH docs workflows must pass to the PDF
# build — the PR gate (docs.yml) and the publish job (docs-publish.yml).
#
# These tests are the wiring guard: they assert the assets exist and that
# neither workflow can quietly stop using them, or drift onto a different pandoc
# image. They do NOT build a PDF — that needs docker + a 1.6 GB image, and the
# workflows themselves are the end-to-end check.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FILTER="scripts/pandoc/break-long-tokens.lua"
  HEADER="scripts/pandoc/manual-header.tex"
  GATE="$REPO_ROOT/.github/workflows/docs.yml"
  PUBLISH="$REPO_ROOT/.github/workflows/docs-publish.yml"
}

@test "manual layout: both pandoc assets exist" {
  [ -f "$REPO_ROOT/$FILTER" ]
  [ -f "$REPO_ROOT/$HEADER" ]
}

@test "manual layout: the PR gate passes both assets to the PDF build" {
  contains "$(cat "$GATE")" "--lua-filter=$FILTER"
  contains "$(cat "$GATE")" "--include-in-header=$HEADER"
}

@test "manual layout: the publish job passes both assets to the PDF build" {
  contains "$(cat "$PUBLISH")" "--lua-filter=$FILTER"
  contains "$(cat "$PUBLISH")" "--include-in-header=$HEADER"
}

@test "manual layout: both workflows build with the same pandoc image" {
  # pandoc/latex does not carry fvextra, which manual-header.tex needs to wrap
  # code blocks — so the image is part of the contract, not an incidental pin.
  local gate_images publish_images
  gate_images="$(grep -o 'pandoc/[a-z]*:[0-9.]*' "$GATE" | sort -u)"
  publish_images="$(grep -o 'pandoc/[a-z]*:[0-9.]*' "$PUBLISH" | sort -u)"
  [ -n "$gate_images" ]
  [ "$gate_images" = "$publish_images" ]
  # sort -u collapsed them, so one line means one image across both workflows
  [ "$(printf '%s\n' "$gate_images" | wc -l | tr -d ' ')" = "1" ]
  contains "$gate_images" "pandoc/extra:"
}

@test "manual layout: the header sets the page to A4 with printed-manual margins" {
  # pandoc's template sets neither papersize nor geometry, so without this line
  # the manual silently reverts to the article class's US-letter default: a
  # 121 mm column on 216 mm paper. The margins ARE the manual's page design —
  # pin them, so a reformat is a deliberate edit to this test rather than a
  # side effect of an unrelated header change.
  local header
  header="$(cat "$REPO_ROOT/$HEADER")"
  contains "$header" "{geometry}"
  contains "$header" "a4paper"
  contains "$header" "left=25mm"
  contains "$header" "right=25mm"
  contains "$header" "top=25mm"
  contains "$header" "bottom=30mm"
}

@test "manual layout: both workflows set the 11pt body size" {
  # fontsize is a document-class option, so it cannot live in the header with
  # the rest of the page setup. It pairs WITH the geometry above: 25 mm margins
  # on A4 leave a 160 mm column, which runs to ~100 characters a line at the
  # class's 10 pt default. Lose this flag and the page above turns unreadable
  # without anything failing.
  contains "$(cat "$GATE")" "-V fontsize=11pt"
  contains "$(cat "$PUBLISH")" "-V fontsize=11pt"
}

@test "manual layout: the bootstrap templates ship the same pandoc assets" {
  # A bootstrapped repo builds its manual with ITS copy of these files, so a fix
  # applied here and not there ships a manual this repo has already outgrown.
  local template_dir
  template_dir="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/pandoc"
  [ -d "$template_dir" ]
  diff "$REPO_ROOT/$HEADER" "$template_dir/manual-header.tex"
  diff "$REPO_ROOT/$FILTER" "$template_dir/break-long-tokens.lua"
}

@test "manual layout: the PR gate fails on a character the PDF has no glyph for" {
  # The drop is silent in xelatex; without this step it stays silent in CI too.
  contains "$(cat "$GATE")" "Missing character"
  contains "$(cat "$GATE")" "pandoc-pdf.log"
}

@test "manual layout: every character the docs use has a fallback or a font" {
  # The header maps the characters that Latin Modern lacks. This test pins the
  # ones already found, so removing a mapping without removing its usage reds
  # the suite rather than silently dropping the character from the PDF again.
  local codepoint
  for codepoint in 2194 2260 2265 26A0 FE0F 1F3D7 1F4A1 1F4D6 1F4DA 1F527 1F916; do
    contains "$(cat "$REPO_ROOT/$HEADER")" "\\DeclareUnicodeFallback{\"$codepoint}"
  done
}

@test "manual layout: the filter only rewrites LaTeX output" {
  # The ePub is built from the same chapters WITHOUT the filter, and HTML wraps
  # long tokens on its own — but the guard belongs in the filter, so passing it
  # to a non-LaTeX writer stays a no-op.
  local filter_body
  filter_body="$(cat "$REPO_ROOT/$FILTER")"
  contains "$filter_body" 'FORMAT:match("latex")'
}

@test "manual layout: the docs workflows react to a change in the assets" {
  # A path-conditional workflow that does not list scripts/pandoc/ would skip
  # its own gate on the PR that changes these files.
  contains "$(cat "$GATE")" '"scripts/pandoc/**"'
  contains "$(cat "$PUBLISH")" '"scripts/pandoc/**"'
}
