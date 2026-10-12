#!/usr/bin/env bats
#
# The docs' SVG diagrams and the workflows booklet built from them.
#
# Each diagram is a Mermaid source (`docs/**/diagrams/<name>.mmd`) rendered by
# scripts/render-diagrams.zsh to the `<name>.svg` beside it, and both are
# committed. The SVG is what the site, manual.pdf/.epub and the workflows
# booklet embed — so what these tests guard is that the committed SVGs are ones
# the PDF path can actually print, and that every build passes the settings
# that make them print:
#
#   - rsvg-convert (pandoc's SVG-to-PDF step) drops <foreignObject> HTML labels
#     and collapses the leading space Mermaid puts on each word's <tspan>, so a
#     diagram must have neither problem;
#   - pandoc/extra has no system fonts, so both docs workflows and the booklet
#     script must hand it scripts/pandoc/fonts.conf, rebase each page's
#     relative image paths, and include figures.tex.
#
# They do NOT render or build anything — that needs docker and two large
# images; the docs workflow is the end-to-end check.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO_ROOT/.github/workflows/docs.yml"
  PUBLISH="$REPO_ROOT/.github/workflows/docs-publish.yml"
  BOOKLET="$REPO_ROOT/scripts/build-workflows-booklet.zsh"
  RENDER="$REPO_ROOT/scripts/render-diagrams.zsh"
  CONFIG="$REPO_ROOT/scripts/mermaid/config.json"
}

# Tracked diagram files of one extension, repo-relative, one per line. A sweep
# over what git tracks, not a fixed list, so a new diagram is covered the moment
# it is added.
tracked_diagrams() {
  git -C "$REPO_ROOT" ls-files "docs/**/diagrams/*.$1"
}

@test "workflow diagrams: there are diagrams to check" {
  # The sweeps below pass vacuously on an empty set; this keeps them honest.
  [ "$(tracked_diagrams mmd | grep -c .)" -ge 1 ]
}

@test "workflow diagrams: every Mermaid source has its rendered SVG, and every SVG its source" {
  local f missing=""
  while IFS= read -r f; do
    [ -f "$REPO_ROOT/${f%.mmd}.svg" ] || missing+=" ${f%.mmd}.svg"
  done < <(tracked_diagrams mmd)
  while IFS= read -r f; do
    [ -f "$REPO_ROOT/${f%.svg}.mmd" ] || missing+=" ${f%.svg}.mmd"
  done < <(tracked_diagrams svg)
  [ -z "$missing" ] || { echo "unpaired:$missing"; false; }
}

@test "workflow diagrams: no SVG carries a <foreignObject> label the PDF would drop" {
  local f bad=""
  while IFS= read -r f; do
    if grep -q '<foreignObject' "$REPO_ROOT/$f"; then bad+=" $f"; fi
  done < <(tracked_diagrams svg)
  [ -z "$bad" ] || { echo "re-render with scripts/render-diagrams.zsh:$bad"; false; }
}

@test "workflow diagrams: every SVG <text> preserves whitespace, so words keep their spaces in the PDF" {
  local f all kept bad=""
  while IFS= read -r f; do
    all="$(grep -o '<text ' "$REPO_ROOT/$f" | grep -c . || true)"
    kept="$(grep -o '<text xml:space="preserve" ' "$REPO_ROOT/$f" | grep -c . || true)"
    [ "$all" -ge 1 ] && [ "$all" -eq "$kept" ] || bad+=" $f($kept/$all)"
  done < <(tracked_diagrams svg)
  [ -z "$bad" ] || { echo "re-render with scripts/render-diagrams.zsh:$bad"; false; }
}

@test "workflow diagrams: every SVG is embedded by a docs page, and every embedded SVG exists" {
  local f name pages unused="" dangling="" ref dir
  pages="$(git -C "$REPO_ROOT" ls-files 'docs/*.md' 'docs/**/*.md' | grep -v '^docs/superpowers/')"
  while IFS= read -r f; do
    name="diagrams/$(basename "$f")"
    # shellcheck disable=SC2086
    grep -qF "]($name)" $(printf "$REPO_ROOT/%s " $pages) || unused+=" $f"
  done < <(tracked_diagrams svg)
  while IFS= read -r f; do
    dir="$(dirname "$f")"
    while IFS= read -r ref; do
      [ -f "$REPO_ROOT/$dir/$ref" ] || dangling+=" $f->$ref"
    done < <(grep -oE '\]\(diagrams/[^)<>]+\.svg\)' "$REPO_ROOT/$f" | sed -E 's/^\]\(//; s/\)$//')
  done <<<"$pages"
  [ -z "$unused" ] || { echo "not embedded anywhere:$unused"; false; }
  [ -z "$dangling" ] || { echo "embedded but missing:$dangling"; false; }
}

@test "workflow diagrams: the Mermaid config keeps labels as SVG text" {
  # htmlLabels is what decides <text> versus <foreignObject>; flowcharts read
  # their own copy of the flag, so both must be off.
  [ "$(jq -r '.htmlLabels' "$CONFIG")" = "false" ]
  [ "$(jq -r '.flowchart.htmlLabels' "$CONFIG")" = "false" ]
  contains "$(cat "$RENDER")" 'scripts/mermaid/config.json'
  contains "$(cat "$RENDER")" '<text xml:space="preserve" '
}

@test "workflow diagrams: both docs workflows build the PDF with the diagram settings" {
  local wf body
  for wf in "$GATE" "$PUBLISH"; do
    body="$(cat "$wf")"
    contains "$body" 'FONTCONFIG_FILE=/data/scripts/pandoc/fonts.conf'
    contains "$body" '--include-in-header=scripts/pandoc/figures.tex'
    # once for the PDF, once for the ePub — both embed the same diagrams
    [ "$(grep -c -- '-f markdown+rebase_relative_paths' "$wf")" -eq 2 ]
  done
}

@test "workflow diagrams: the booklet uses the manual's pandoc image and settings" {
  local body image
  body="$(cat "$BOOKLET")"
  image="$(grep -o 'pandoc/[a-z]*:[0-9.]*' "$GATE" | sort -u)"
  [ "$(printf '%s\n' "$image" | grep -c .)" -eq 1 ]
  contains "$body" "IMAGE=\"$image\""
  contains "$body" 'FONTCONFIG_FILE=/data/scripts/pandoc/fonts.conf'
  contains "$body" 'markdown+rebase_relative_paths'
  contains "$body" '--lua-filter=scripts/pandoc/break-long-tokens.lua'
  contains "$body" '--include-in-header=scripts/pandoc/manual-header.tex'
  contains "$body" '--include-in-header=scripts/pandoc/figures.tex'
  contains "$body" '-V fontsize=11pt'
}

@test "workflow diagrams: both docs workflows build the booklet and react to its script" {
  local wf
  for wf in "$GATE" "$PUBLISH"; do
    contains "$(cat "$wf")" 'run: ./scripts/build-workflows-booklet.zsh'
    contains "$(cat "$wf")" '- "scripts/build-workflows-booklet.zsh"'
  done
  contains "$(cat "$PUBLISH")" 'workflows.pdf workflows.epub --clobber'
}

@test "workflow diagrams: the booklet's chapters are the nav's workflow pages, overview first" {
  local chapters
  chapters="$(cd "$REPO_ROOT" && ./scripts/docs-nav-to-chapters.zsh \
    | grep -E '^docs/explanation/(how-the-plugins-work|how-the-family-learns|workflow-[a-z0-9-]+)\.md$')"
  [ "$(printf '%s\n' "$chapters" | head -1)" = "docs/explanation/how-the-plugins-work.md" ]
  [ "$(printf '%s\n' "$chapters" | grep -c .)" -eq 6 ]
  # the same selection the script makes, so the two cannot drift apart
  contains "$(cat "$BOOKLET")" "grep -E '^docs/explanation/(how-the-plugins-work|how-the-family-learns|workflow-[a-z0-9-]+)\\.md\$'"
}
