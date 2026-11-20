#!/usr/bin/env bats
#
# Acceptance cases for the product-document renderer (#3204, epic #3195) — the
# `cli`-tooled test_cases[] of its story-spec, one test per `tc-*` id:
#
#   tc-happy-render-both              #3234
#   tc-happy-machine-block-stripped   #3235
#   tc-happy-appendix-links           #3236
#   tc-corner-registry-with-title     #3237
#   tc-corner-typographic-text        #3238
#   tc-corner-no-remote-plain-text    #3239
#   tc-corner-not-git-draft           #3240
#   tc-corner-uncommitted-draft       #3241
#   tc-corner-spaces-in-paths         #3242
#   tc-error-mermaid-refused          #3243
#   tc-error-toolchain-missing        #3244
#   tc-error-failed-render-keeps-old  #3245
#   tc-error-title-conflict           #3246
#
# The use case: timo-platform-builder renders an invented product document,
# docs/product/Depot Übersicht.md („Depot-Planung Nord“, with the persona
# registry as its appendix), into a PDF and an ePub he can send to a colleague
# unedited, each traceable to its commit. What runs for real: pandoc, Typst,
# pdftotext and unzip over a fixture repo with the remote
# https://github.com/example-org/depot-product. The default gate's
# tests/product-render-document.bats covers the same criteria clause by clause.

bats_require_minimum_version 1.5.0
load ../../assertions
load ../../product-render-fixture

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  render_setup "$REPO_ROOT"
}

@test "tc-happy-render-both" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$(cd "$R" && pwd -P)/dist/product/Depot Übersicht.pdf" ]
  [ "${lines[1]}" = "$(cd "$R" && pwd -P)/dist/product/Depot Übersicht.epub" ]
  [ "$(head -c 4 "$PDF")" = "%PDF" ]
  local text
  text="$(pdf_text "$PDF")"
  contains "$text" "„Depot-Planung Nord“"
  contains "$text" "DEPOT-PRODUCT"
  lacks "$text" "DRAFT"
  contains "$text" "depot-product · $(fx_git rev-parse --short HEAD)"
  # the body says „Depot-Planung Nord“ too: the ePub's title pins the block's
  [ "$(epub_title "$EPUB")" = "„Depot-Planung Nord“" ]
}

@test "tc-happy-machine-block-stripped" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local text needle
  for text in "$(pdf_text "$PDF")" "$(epub_text "$EPUB")"; do
    for needle in prose_sha256 'charter:prose:start' '"schema"'; do
      lacks "$text" "$needle"
    done
  done
}

@test "tc-happy-appendix-links" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  matches "$(pdf_text "$PDF")" 'Direction changes.*Dana plans the next'
  run epub_text "$EPUB"
  contains "$output" 'href="ch002.xhtml#appendix-1-dana-dispatcher"'
  contains "$output" "href=\"https://github.com/example-org/depot-product/blob/$(fx_git rev-parse HEAD)/docs/explanation/philosophy.md\""
  run pdf_text "$PDF"
  contains "$output" "docs/explanation/philosophy.md"
}

@test "tc-corner-registry-with-title" {
  make_repo
  render_in "$R" --title "depot-product — Personas" docs/personas.md
  [ "$status" -eq 0 ]
  local text
  for text in "$(pdf_text "$OUT/personas.pdf")" "$(epub_text "$OUT/personas.epub")"; do
    contains "$text" "depot-product — Personas"
    lacks "$text" "personas:prose:start"
    lacks "$text" "prose_sha256"
  done
}

@test "tc-corner-typographic-text" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local text needle
  for text in "$(pdf_text "$PDF")" "$(epub_text "$EPUB")"; do
    for needle in "Übergabe" "„Depot-Planung Nord“" "— persona: dana-dispatcher" "…"; do
      contains "$text" "$needle"
    done
  done
}

@test "tc-corner-no-remote-plain-text" {
  make_repo --no-remote
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  run pdf_text "$PDF"
  contains "$output" "docs/explanation/philosophy.md"
  run epub_text "$EPUB"
  contains "$output" "(docs/explanation/philosophy.md)"
  lacks "$output" "https://"
}

@test "tc-corner-not-git-draft" {
  mkdir -p "$R"
  cp "$FIXTURES/personas.md" "$R/personas.md"
  render_in "$R" --title "Depot Personas" personas.md
  [ "$status" -eq 0 ]
  run pdf_text "$OUT/personas.pdf"
  contains "$output" "DRAFT"
  contains "$output" "Depot Repo · uncommitted"
}

@test "tc-corner-uncommitted-draft" {
  make_repo
  printf '\nOne more line, not yet committed.\n' >> "$R/$MAIN"
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  run pdf_text "$PDF"
  contains "$output" "DRAFT"
}

@test "tc-corner-spaces-in-paths" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  ends_with "${lines[0]}" "dist/product/Depot Übersicht.pdf"
  ends_with "${lines[1]}" "dist/product/Depot Übersicht.epub"
  [ -f "${lines[0]}" ]
  [ -f "${lines[1]}" ]
}

@test "tc-error-mermaid-refused" {
  make_repo
  # line 14 of the document is the mermaid fence
  head -n 13 "$FIXTURES/Depot Übersicht.md" > "$R/$MAIN"
  printf '```mermaid\ngraph TD; Depot-->Route\n```\n' >> "$R/$MAIN"
  render_in "$R" "$MAIN"
  [ "$status" -eq 4 ]
  contains "$stderr" "docs/product/Depot Übersicht.md:14:"
  [ "$(listing "$OUT")" = "absent" ]
}

@test "tc-error-toolchain-missing" {
  make_repo
  local stub p
  # pandoc missing
  stub="$BATS_TEST_TMPDIR/no-pandoc"
  p="$(toolchain_path "$stub")"
  ln -s "$(command -v typst)" "$stub/typst"
  render_toolchain "$p"
  assert_brew_refusal
  # typst missing
  stub="$BATS_TEST_TMPDIR/no-typst"
  p="$(toolchain_path "$stub")"
  ln -s "$(command -v pandoc)" "$stub/pandoc"
  render_toolchain "$p"
  assert_brew_refusal
  # typst older than MIN_TYPST
  stub="$BATS_TEST_TMPDIR/old-typst"
  p="$(toolchain_path "$stub")"
  ln -s "$(command -v pandoc)" "$stub/pandoc"
  printf '#!/bin/sh\necho "typst 0.10.0 (stub)"\n' > "$stub/typst"
  chmod +x "$stub/typst"
  render_toolchain "$p"
  assert_brew_refusal
}

@test "tc-error-failed-render-keeps-old" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local before
  before="$(listing "$OUT")"
  local stub="$BATS_TEST_TMPDIR/failing-bin" real
  real="$(command -v typst)"
  mkdir -p "$stub"
  printf '#!/bin/sh\nif [ "$1" = "--version" ]; then exec "%s" --version; fi\n' "$real" > "$stub/typst"
  printf 'echo "error: the stub typst refused to compile" >&2\nexit 1\n' >> "$stub/typst"
  chmod +x "$stub/typst"
  render_toolchain "$stub:$PATH"
  [ "$status" -eq 5 ]
  contains "$stderr" "the stub typst refused to compile"
  [ "$(listing "$OUT")" = "$before" ]
}

@test "tc-error-title-conflict" {
  make_repo
  render_in "$R" --title Other "$MAIN"
  [ "$status" -eq 2 ]
  [ ! -e "$OUT" ]
}
