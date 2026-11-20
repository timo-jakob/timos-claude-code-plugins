#!/usr/bin/env bats
#
# The product-document renderer (#3204, task 3 of #3195):
# product/scripts/render-document.zsh turns one product Markdown document into a
# PDF (pandoc + Typst) and an ePub (pandoc), always both or neither, in
# <repo-root>/dist/product/.
#
# Every case runs the real toolchain: pandoc and Typst render, pdftotext reads
# the PDF back, unzip reads the ePub. The script-tests workflow installs all
# three at pinned versions, so nothing here skips. The fixture repo is built in
# setup() from tests/fixtures/product-render/ (tests/product-render-fixture.bash).
# The suite also pins the CI install steps, define-personas' render step and the
# ARCHITECTURE.md statement of the renderer, each scoped to its own section.

bats_require_minimum_version 1.5.0

load assertions
load product-render-fixture

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  render_setup "$REPO_ROOT"
  WORKFLOW="$REPO_ROOT/.github/workflows/script-tests.yml"
  SKILL="$REPO_ROOT/product/skills/define-personas/SKILL.md"
  SECTION="$(sed -n '/^### The `product` plugin — outside the language\/topic model/,/^##/p' \
               "$REPO_ROOT/ARCHITECTURE.md" | tr -s '[:space:]' ' ')"
}

# --- what a render writes ---------------------------------------------------

@test "renders both files and prints both paths, the PDF first" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$(cd "$R" && pwd -P)/dist/product/Depot Übersicht.pdf" ]
  [ "${lines[1]}" = "$(cd "$R" && pwd -P)/dist/product/Depot Übersicht.epub" ]
  [ "$(head -c 4 "$PDF")" = "%PDF" ]
  run unzip -p "$EPUB" mimetype
  [ "$output" = "application/epub+zip" ]
}

@test "the machine block and the sentinels never reach either output" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local text needle
  for text in "$(pdf_text "$PDF")" "$(epub_text "$EPUB")"; do
    for needle in prose_sha256 'charter:prose:start' 'charter:prose:end' 'personas:prose:start' \
                  '"schema"' 'machine-readable'; do
      lacks "$text" "$needle"
    done
  done
}

@test "cover carries title, repo name, date and version line, and no DRAFT when committed" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local text sha
  text="$(pdf_text "$PDF")"
  sha="$(fx_git rev-parse --short HEAD)"
  contains "$text" "„Depot-Planung Nord“"
  contains "$text" "DEPOT-PRODUCT"
  contains "$text" "$(date +%Y-%m-%d)"
  contains "$text" "Version DC-2026-11-1 · $sha"
  lacks "$text" "DRAFT"
  # the body says „Depot-Planung Nord“ too: the ePub's title pins the block's
  [ "$(epub_title "$EPUB")" = "„Depot-Planung Nord“" ]
  run epub_text "$EPUB"
  contains "$output" "depot-product · Version DC-2026-11-1 · $sha"
  lacks "$output" "DRAFT"
}

@test "cover says DRAFT when the source has uncommitted changes" {
  make_repo
  printf '\nOne more line, not yet committed.\n' >> "$R/$MAIN"
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  run pdf_text "$PDF"
  contains "$output" "DRAFT"
  run epub_text "$EPUB"
  contains "$output" "DRAFT"
}

@test "cover says DRAFT when only an appendix has uncommitted changes" {
  make_repo
  printf '\nA new persona note.\n' >> "$R/docs/personas.md"
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  run pdf_text "$PDF"
  contains "$output" "DRAFT"
}

@test "footer carries the source commit's short SHA and date on every page" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local sha day pages stamps
  sha="$(fx_git rev-parse --short HEAD)"
  day="$(fx_git log -1 --format=%cs)"
  pages="$(pdfinfo "$PDF" | sed -n 's/^Pages: *//p')"
  stamps="$(pdf_text "$PDF" | grep -c "depot-product · $sha · $day")"
  [ "$pages" -ge 4 ]
  [ "$stamps" -eq "$pages" ]
}

@test "appendix files follow the main document and a link into one resolves inside the output" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local text
  text="$(pdf_text "$PDF")"
  matches "$text" 'Direction changes.*Dana plans the next'
  # the appendix's own heading identifier, prefixed so it cannot collide
  run epub_text "$EPUB"
  contains "$output" 'href="ch002.xhtml#appendix-1-dana-dispatcher"'
  contains "$output" 'id="appendix-1-dana-dispatcher"'
  lacks "$output" 'href="../personas.md'
}

@test "a link to another repo file is an absolute URL on the remote and shows its repo-relative path" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local sha
  sha="$(fx_git rev-parse HEAD)"
  run epub_text "$EPUB"
  contains "$output" "href=\"https://github.com/example-org/depot-product/blob/$sha/docs/explanation/philosophy.md\""
  run pdf_text "$PDF"
  contains "$output" "philosophy page (docs/explanation/philosophy.md)"
}

@test "a link to another repo file is plain text, still showing its path, when there is no remote" {
  make_repo --no-remote
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  run epub_text "$EPUB"
  lacks "$output" "philosophy.md\""
  lacks "$output" "https://"
  contains "$output" "(docs/explanation/philosophy.md)"
  run pdf_text "$PDF"
  contains "$output" "philosophy page (docs/explanation/philosophy.md)"
}

@test "an scp-style remote becomes an https URL" {
  make_repo --no-remote
  fx_git remote add origin git@github.com:example-org/depot-product.git
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  run epub_text "$EPUB"
  contains "$output" 'href="https://github.com/example-org/depot-product/blob/'
}

@test "a GitHub alert renders as a callout in both outputs" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  run pdf_text "$PDF"
  contains "$output" "IMPORTANT"
  contains "$output" "Übergabe before Lieferkette"
  run epub_text "$EPUB"
  contains "$output" 'class="callout important"'
}

@test "umlauts and typographic quotes survive into the PDF text and the ePub" {
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

@test "spaces in the repo path and the document name" {
  make_repo
  render_in "$R/docs/product" "Depot Übersicht.md"
  [ "$status" -eq 0 ]
  ends_with "${lines[0]}" "Depot Repo/dist/product/Depot Übersicht.pdf"
  ends_with "${lines[1]}" "Depot Repo/dist/product/Depot Übersicht.epub"
  [ -f "${lines[0]}" ]
  [ -f "${lines[1]}" ]
}

@test "two renders of the same committed source produce the same PDF text and the same ePub file list" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local first_text first_list
  first_text="$(pdf_text "$PDF")"
  first_list="$(unzip -Z1 "$EPUB")"
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  [ "$(pdf_text "$PDF")" = "$first_text" ]
  [ "$(unzip -Z1 "$EPUB")" = "$first_list" ]
}

@test "not a git repo: DRAFT, footer says uncommitted, output under the current directory, exit 0" {
  mkdir -p "$R"
  cp "$FIXTURES/personas.md" "$R/personas.md"
  render_in "$R" --title "Depot Personas" personas.md
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(cd "$R" && pwd -P)/dist/product/personas.pdf" ]
  run pdf_text "$OUT/personas.pdf"
  contains "$output" "DRAFT"
  contains "$output" "Depot Repo · uncommitted"
  contains "$output" "Depot Personas"
}

@test "the registry renders with --title and --appendix flags when it has no title of its own" {
  make_repo
  render_in "$R" --title "depot-product — Personas" --appendix "$MAIN" docs/personas.md
  [ "$status" -eq 0 ]
  run pdf_text "$OUT/personas.pdf"
  contains "$output" "depot-product — Personas"
  matches "$output" 'Dana plans the next.*Depot Übersicht'
  lacks "$output" "personas:prose:start"
}

@test "without a title from the block or a flag, the first heading is the title" {
  make_repo
  printf '# Lieferkette Süd\n\nPlain text.\n' > "$R/docs/plain.md"
  render_in "$R" docs/plain.md
  [ "$status" -eq 0 ]
  [ "$(epub_title "$OUT/plain.epub")" = "Lieferkette Süd" ]
}

@test "in a linked worktree without a remote, the repo name is the main work tree's directory" {
  make_repo --no-remote
  local wt="$BATS_TEST_TMPDIR/wt-elsewhere"
  fx_git worktree add -q "$wt"
  render_in "$wt" "$MAIN"
  [ "$status" -eq 0 ]
  local sha
  sha="$(fx_git rev-parse --short HEAD)"
  run pdf_text "$wt/dist/product/Depot Übersicht.pdf"
  contains "$output" "Depot Repo · $sha"
  lacks "$output" "wt-elsewhere"
}

@test "a <details> that is not the machine block keeps its content in both outputs" {
  make_repo
  printf '\n<details>\n<summary>Rejected alternatives</summary>\n\nA Kanban wall was weighed and dropped.\n\n</details>\n' \
    >> "$R/$MAIN"
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local text
  for text in "$(pdf_text "$PDF")" "$(epub_text "$EPUB")"; do
    contains "$text" "Rejected alternatives"
    contains "$text" "A Kanban wall was weighed and dropped."
    lacks "$text" "prose_sha256"
  done
}

# --- refusals and failures --------------------------------------------------

@test "--help prints the usage line on stdout and exits 0" {
  run --separate-stderr "$ZSH_BIN" "$RENDER" --help
  [ "$status" -eq 0 ]
  [ "$output" = "usage: render-document.zsh [--title <text>] [--appendix <path>]... <document.md>" ]
}

@test "title flag with a block that already has a title is exit 2 and writes nothing" {
  make_repo
  render_in "$R" --title Other "$MAIN"
  [ "$status" -eq 2 ]
  contains "$stderr" "already has a title"
  [ ! -e "$OUT" ]
}

@test "appendix flag with a block that already lists appendices is exit 2 and writes nothing" {
  make_repo
  render_in "$R" --appendix docs/personas.md "$MAIN"
  [ "$status" -eq 2 ]
  contains "$stderr" "already lists appendices"
  [ ! -e "$OUT" ]
}

@test "a machine block that is not valid JSON is exit 2 and writes nothing" {
  make_repo
  sed -i.bak 's/"appendices": \["docs\/personas.md"\],/"appendices": ["docs\/personas.md"],,/' "$R/$MAIN"
  rm -f "$R/$MAIN.bak"
  render_in "$R" "$MAIN"
  [ "$status" -eq 2 ]
  contains "$stderr" "the machine block is not valid JSON"
  [ "$output" = "" ]
  [ ! -e "$OUT" ]
}

@test "usage errors are exit 2: no document, a missing document, a missing appendix, an unknown flag" {
  make_repo
  render_in "$R"
  [ "$status" -eq 2 ]
  render_in "$R" docs/nowhere.md
  [ "$status" -eq 2 ]
  contains "$stderr" "no such document"
  render_in "$R" --appendix docs/nowhere.md docs/personas.md
  [ "$status" -eq 2 ]
  contains "$stderr" "no such appendix"
  render_in "$R" --paper a5 "$MAIN"
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown flag"
  [ ! -e "$OUT" ]
}

@test "a mermaid block is refused with exit 4, naming file and line, and dist/product/ is unchanged" {
  make_repo
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
  local before
  before="$(listing "$OUT")"
  printf '\n```mermaid\ngraph TD; A-->B\n```\n' >> "$R/docs/personas.md"
  local line
  line="$(grep -n '^```mermaid' "$R/docs/personas.md" | cut -d: -f1)"
  render_in "$R" "$MAIN"
  [ "$status" -eq 4 ]
  contains "$stderr" "docs/personas.md:$line:"
  contains "$stderr" "mermaid"
  [ "$(listing "$OUT")" = "$before" ]
}

@test "a mermaid fence quoted inside another fence is not a diagram" {
  make_repo
  printf '\n````markdown\n```mermaid\ngraph TD; A-->B\n```\n````\n' >> "$R/docs/personas.md"
  render_in "$R" "$MAIN"
  [ "$status" -eq 0 ]
}

@test "pandoc missing is exit 3, stderr ends with the brew line, nothing written" {
  make_repo
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  local p
  p="$(toolchain_path "$stub")"
  ln -s "$(command -v typst)" "$stub/typst"
  render_toolchain "$p"
  [ "$status" -eq 3 ]
  assert_brew_refusal
  contains "$stderr" "pandoc is not installed"
}

@test "typst missing is exit 3, stderr ends with the brew line, nothing written" {
  make_repo
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  local p
  p="$(toolchain_path "$stub")"
  ln -s "$(command -v pandoc)" "$stub/pandoc"
  render_toolchain "$p"
  assert_brew_refusal
  contains "$stderr" "typst is not installed"
}

@test "typst older than MIN_TYPST is exit 3, stderr ends with the brew line, nothing written" {
  make_repo
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  local p
  p="$(toolchain_path "$stub")"
  ln -s "$(command -v pandoc)" "$stub/pandoc"
  printf '#!/bin/sh\necho "typst 0.10.0 (stub)"\n' > "$stub/typst"
  chmod +x "$stub/typst"
  render_toolchain "$p"
  assert_brew_refusal
  contains "$stderr" "typst 0.10.0 is older than"
}

@test "pandoc older than MIN_PANDOC is exit 3, stderr ends with the brew line, nothing written" {
  make_repo
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  local p
  p="$(toolchain_path "$stub")"
  ln -s "$(command -v typst)" "$stub/typst"
  printf '#!/bin/sh\necho "pandoc 3.1.2"\n' > "$stub/pandoc"
  chmod +x "$stub/pandoc"
  render_toolchain "$p"
  assert_brew_refusal
  contains "$stderr" "pandoc 3.1.2 is older than"
}

@test "a failing render is exit 5 with the tool's stderr, leaves an earlier output untouched and adds nothing" {
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
  printf '\nA change after the first render.\n' >> "$R/$MAIN"
  render_toolchain "$stub:$PATH"
  [ "$status" -eq 5 ]
  contains "$stderr" "the stub typst refused to compile"
  [ "$output" = "" ]
  [ "$(listing "$OUT")" = "$before" ]
}

# --- the pins: constants, CI, define-personas, ARCHITECTURE.md ---------------

# step_body <name> — the run block of the named step of script-tests.yml
step_body() {
  awk -v name="$1" '
    !on && $0 == "      - name: " name { on = 1; next }
    on && /^      - name: / { exit }
    on { print }
  ' "$WORKFLOW"
}

# pin_of <step name> <VAR> — the value the step sets for VAR in its env block
pin_of() {
  step_body "$1" | sed -nE "s/^ +$2: *\"?([0-9][0-9.a-z~+-]*)\"? *$/\1/p"
}

@test "script-tests installs pandoc, Typst and poppler at pinned versions in both install steps" {
  local step var
  for step in 'Install test dependencies (Linux)' 'Install test dependencies (macOS)'; do
    for var in PANDOC_VERSION TYPST_VERSION POPPLER_VERSION; do
      run pin_of "$step" "$var"
      matches "$output" '^[0-9]+\.[0-9][0-9.a-z~+-]*$'
      contains "$(step_body "$step")" "\${$var}"
    done
  done
  # the ubuntu leg runs the suite; the macOS leg stays deactivated (#1407, #1408)
  run grep -E '^        os: \[' "$WORKFLOW"
  [ "$output" = "        os: [ubuntu-latest]" ]
}

@test "the CI pins are at or above MIN_PANDOC and MIN_TYPST" {
  local min_pandoc min_typst step
  min_pandoc="$(sed -nE 's/^MIN_PANDOC=([0-9.]+)$/\1/p' "$RENDER")"
  min_typst="$(sed -nE 's/^MIN_TYPST=([0-9.]+)$/\1/p' "$RENDER")"
  [ -n "$min_pandoc" ]
  [ -n "$min_typst" ]
  for step in 'Install test dependencies (Linux)' 'Install test dependencies (macOS)'; do
    [ "$(printf '%s\n%s\n' "$min_pandoc" "$(pin_of "$step" PANDOC_VERSION)" | sort -V | sed -n 1p)" = "$min_pandoc" ]
    [ "$(printf '%s\n%s\n' "$min_typst" "$(pin_of "$step" TYPST_VERSION)" | sort -V | sed -n 1p)" = "$min_typst" ]
  done
}

@test "define-personas renders the registry after its write and reports both paths" {
  local step
  step="$(sed -n '/^## Step 3 — render the registry/,/^## /p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$step" 'render-document.zsh" --title "<repo name> — Personas" docs/personas.md'
  contains "$step" "both paths"
  contains "$step" "dist/product/"
  contains "$step" ".gitignore"
  contains "$step" "never as success"
  contains "$step" '`<repo name>` is the `name` part of the `owner/name` Step 1 passes as `repo`'
  contains "$step" 'writes `dist/product/personas.pdf` and `dist/product/personas.epub` and prints both absolute paths, the PDF first.'
  contains "$step" '**`dist/product/` is build output.**'
  contains "$step" 'when `git check-ignore -q dist/product/` says it is not already ignored'
  lacks "$step" 'check-ignore -q dist/ '
  contains "$step" 'never committed by this skill'
}

@test "ARCHITECTURE.md states the renderer: interface, exits, output, callouts and fonts" {
  contains "$SECTION" 'render-document.zsh [--title <text>] [--appendix <path>]... <document.md>'
  contains "$SECTION" '<repo-root>/dist/product/'
  contains "$SECTION" 'always both or neither'
  contains "$SECTION" '`brew install pandoc typst`'
  contains "$SECTION" 'exit 4'
  contains "$SECTION" 'exit 5'
  contains "$SECTION" 'GitHub alert'
  contains "$SECTION" "Typst's built-in fonts"
}

@test "the renderer's files stay inside product/ and name no other plugin's directory" {
  local f
  for f in "$RENDER" "$REPO_ROOT"/product/templates/*; do
    run grep -nE '(^|[^a-z-])development(-[a-z]+)?/' "$f"
    [ "$status" -eq 1 ]
  done
}
