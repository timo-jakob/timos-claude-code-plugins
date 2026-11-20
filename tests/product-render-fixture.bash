# Shared fixture for the renderer's suites (#3204): tests/product-render-document.bats
# and its acceptance cases, tests/acceptance/cli/product-render-document.bats.
#
# Every document is invented (tests/fixtures/product-render/). A fixture repo is
# built under $BATS_TEST_TMPDIR in a directory whose name holds a space, with
# the main document at docs/product/Depot Übersicht.md and the persona registry
# at docs/personas.md, which the main document's machine block lists as its
# appendix.

# render_setup <repo root of this checkout> — sets the paths every case reads
# shellcheck disable=SC2034  # PDF, EPUB and the rest are read by the suites
render_setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repo's init/add/commit would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  RENDER="$1/product/scripts/render-document.zsh"
  FIXTURES="$1/tests/fixtures/product-render"
  ZSH_BIN="$(command -v zsh)"
  R="$BATS_TEST_TMPDIR/Depot Repo"
  MAIN="docs/product/Depot Übersicht.md"
  OUT="$R/dist/product"
  PDF="$OUT/Depot Übersicht.pdf"
  EPUB="$OUT/Depot Übersicht.epub"
}

# fx_git <args>… — git in the fixture repo, never signing, never the host's hooks
fx_git() {
  git -C "$R" -c user.email=builder@example.invalid -c user.name="Fixture Builder" \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

# make_repo [--no-remote] — the fixture repo, committed, with a remote unless told not to
make_repo() {
  mkdir -p "$R/docs/product"
  cp "$FIXTURES/Depot Übersicht.md" "$R/$MAIN"
  cp "$FIXTURES/personas.md" "$R/docs/personas.md"
  fx_git init -q
  fx_git add -A
  fx_git commit -qm "the depot overview"
  if [ "${1-}" != "--no-remote" ]; then
    fx_git remote add origin https://github.com/example-org/depot-product.git
  fi
}

# render_in <dir> <args>… — run the renderer from <dir>, stderr kept apart
render_in() {
  local dir="$1"
  shift
  cd "$dir" || return 1
  run --separate-stderr "$ZSH_BIN" "$RENDER" "$@"
  cd - >/dev/null || return 1
}

# pdf_text <pdf> — the PDF's text, UTF-8
pdf_text() {
  pdftotext -enc UTF-8 "$1" -
}

# epub_text <epub> — every XHTML file of the ePub, concatenated
epub_text() {
  unzip -p "$1" '*.xhtml'
}

# epub_title <epub> — the ePub's main title, its package's first dc:title
epub_title() {
  unzip -p "$1" '*.opf' | sed -nE 's/.*<dc:title[^>]*>([^<]*)<\/dc:title>.*/\1/p' | sed -n 1p
}

# listing <dir> — name and checksum of every file in <dir>, hidden ones included
listing() {
  if [ -d "$1" ]; then
    (cd "$1" && find . -type f -exec cksum {} + | sort)
  else
    printf 'absent\n'
  fi
}

# toolchain_path <stub dir> — the stub directory, then HIDE_BIN, then the base
# system directories: a host pandoc in /usr/bin (the ubuntu leg's .deb) is
# shadowed by HIDE_BIN, a Homebrew one is simply not on the path
toolchain_path() {
  HIDE_BIN="$BATS_TEST_TMPDIR/hide-bin"
  mkdir -p "$HIDE_BIN" "$1"
  printf '#!/bin/sh\nexit 127\n' > "$HIDE_BIN/pandoc"
  printf '#!/bin/sh\nexit 127\n' > "$HIDE_BIN/typst"
  chmod +x "$HIDE_BIN/pandoc" "$HIDE_BIN/typst"
  printf '%s' "$1:$HIDE_BIN:/usr/bin:/bin"
}

# render_toolchain <PATH> — render the fixture under that PATH
render_toolchain() {
  cd "$R" || return 1
  run --separate-stderr env PATH="$1" "$ZSH_BIN" "$RENDER" "$MAIN"
  cd - >/dev/null || return 1
}

# assert_brew_refusal — the toolchain refusal: exit 3, the brew line last,
# nothing written
# shellcheck disable=SC2154  # status and stderr are set by bats' `run`
assert_brew_refusal() {
  [ "$status" -eq 3 ]
  [ "${stderr##*$'\n'}" = "brew install pandoc typst" ]
  [ ! -e "$OUT" ]
}
