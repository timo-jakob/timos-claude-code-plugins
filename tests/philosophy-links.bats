#!/usr/bin/env bats
#
# PROPAGATION INVARIANT — the philosophy page's links resolve (#1631, epic #1627).
#
# THE RULE, in both directions:
#
#   1. OUT OF THE DOCS — every absolute repo link on a tracked docs page
#      (`github.com/timo-jakob/timos-claude-code-plugins/blob/main/<path>`, and
#      `tree/main/<dir>`) resolves to a tracked path via `git ls-files`.
#   2. INTO THE PAGE — every `…/explanation/philosophy/#pillar-N` citation in a
#      shipped plugin file (`development*/**`, the files an install carries
#      without `docs/`) resolves to exactly one `{#pillar-N}` id in
#      `docs/explanation/philosophy.md`.
#
# WHY THIS SWEEP EXISTS. The philosophy page promises, pillar by pillar, *what
# enforces it today*, and it keeps that promise by linking real mechanisms — test
# files, scripts, skill and agent files. Nothing else in the repo can catch one
# of those links going dead: `mkdocs build --strict` validates relative
# intra-docs links only (absolute repo URLs never enter its validation), and no
# link checker runs in pre-commit, CI or `tests/`. A renamed test file is exactly
# how such a claim rots, so it needs a test. The red this file raises when a
# mechanism the page cites moves or is renamed IS the page's docs-impact signal:
# no review-panel doc roster exists, and none is created.
#
# The docs-side anchors (`philosophy.md#pillar-N` from other docs pages) are out
# of scope on purpose — `mkdocs build --strict` validates those, and duplicating
# it here would be a second owner of one fact.
#
# PROSE-PLUS-CODE PAIRING. MAINTAINING.md's pattern asks for a non-vacuity
# control on a prose site AND a code site. No code site states a link, so the
# pairing is met by the two file kinds this invariant actually has — a docs page
# and a shipped `SKILL.md` — each read by its own extractor, and each mutated by
# its own control below.
#
# Offline by construction: every figure is derived from the repo's own state,
# never from the published site.

bats_require_minimum_version 1.5.0

load assertions

# An absolute repo link pinned to `main`, up to the first character that ends a
# path in markdown: `)`, `#`, `?`, whitespace, a quote, a backtick or an angle
# bracket. Stopping at `#` and `?` is what strips a fragment or query.
LINK_ERE='github\.com/timo-jakob/timos-claude-code-plugins/(blob|tree)/main/[^]#?)[:space:]"'"'"'`<>]*'
LINK_PREFIX_ERE='github\.com/timo-jakob/timos-claude-code-plugins/(blob|tree)/main/'

# A citation into the page. The digit is required, so the literal-`N` form the
# repo's own CLAUDE.md uses to DESCRIBE the rule is out of roster by
# construction (it also lies outside `development*/**`).
CITE_ERE='explanation/philosophy/#pillar-[0-9]+'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # The one authoritative site: it owns the `{#pillar-N}` ids the citations
  # resolve against, and the evidence links the page promises.
  PAGE="$REPO_ROOT/docs/explanation/philosophy.md"
}

# ---------------------------------------------------------------------------
# Direction 1 — repo-path links out of the docs
# ---------------------------------------------------------------------------

# The docs pages carrying at least one repo link, repo-relative, one per line.
#
# DERIVED, never transcribed: `git ls-files docs` filtered to `*.md` rather than
# a pathspec glob, because git's non-`:(glob)` `**/` requires a real directory
# separator and would silently drop the top-level pages — `docs/index.md` among
# them, the largest carrier. `docs/superpowers/` is excluded because plans and
# specs are a historical record (the same exclusion the other rosters make); it
# carries no such link today, so the exclusion is a stated decision, not a fix.
link_pages() {
  local rel
  while IFS= read -r rel; do
    if grep -qE "$LINK_PREFIX_ERE" "$REPO_ROOT/$rel"; then
      printf '%s\n' "$rel"
    fi
  # LC_ALL=C so the roster's order is reproducible across CI legs.
  done < <(git -C "$REPO_ROOT" ls-files docs | grep -E '\.md$' | grep -v '^docs/superpowers/' | LC_ALL=C sort)
  return 0
}

# Every repo link in one page, as `<kind> <path>` per occurrence — `kind` is
# `blob` or `tree`, `path` the remainder after `/main/`.
repo_links() {
  [ "$#" -eq 1 ] || { printf 'repo_links: needs exactly one file\n' >&2; return 2; }
  [ -f "$1" ] && [ -r "$1" ] || { printf 'repo_links: unreadable site %s\n' "$1" >&2; return 2; }
  grep -oE "$LINK_ERE" "$1" | sed -E "s#^${LINK_PREFIX_ERE}#\\1 #"
  return 0
}

# One `<page>:<path>` per link that does NOT resolve to a tracked path; empty
# output when the invariant holds. The page is named as it was passed, so the
# non-vacuity controls can run this same code over a temp copy while
# `git ls-files` still answers from REPO_ROOT.
#
# `:(literal)` so a path is never read as a pathspec pattern. A `blob` link must
# name a tracked path (`--error-unmatch`); a `tree` link must name a directory
# holding at least one tracked file.
repo_link_gaps() {
  local f kind path
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] || { printf 'repo_link_gaps: unreadable site %s\n' "$f" >&2; return 2; }
    while IFS=' ' read -r kind path; do
      [ -n "$kind" ] || continue
      case "$kind" in
        blob)
          if ! git -C "$REPO_ROOT" ls-files --error-unmatch -- ":(literal)$path" > /dev/null 2>&1; then
            printf '%s:%s\n' "$f" "$path"
          fi
          ;;
        tree)
          path="${path%/}"
          if [ -z "$path" ] || [ -z "$(git -C "$REPO_ROOT" ls-files -- ":(literal)$path/")" ]; then
            printf '%s:%s\n' "$f" "$path"
          fi
          ;;
      esac
    done < <(repo_links "$f")
  done
  return 0
}

# ---------------------------------------------------------------------------
# Direction 2 — citations into the page
# ---------------------------------------------------------------------------

# The shipped plugin files carrying at least one citation, repo-relative.
# Path-scoped to `development*/**` on purpose: those are the only files whose
# link to the page mkdocs cannot validate.
citing_files() {
  local rel
  while IFS= read -r rel; do
    if grep -qE 'explanation/philosophy/#pillar-[0-9]' "$REPO_ROOT/$rel"; then
      printf '%s\n' "$rel"
    fi
  done < <(git -C "$REPO_ROOT" ls-files 'development*/**' | LC_ALL=C sort)
  return 0
}

# Usage: citation_gaps <page> <file>... — one `<file>:pillar-N` per citation
# whose `{#pillar-N}` id does not occur EXACTLY once on the page.
citation_gaps() {
  local page f n c
  [ "$#" -ge 2 ] || { printf 'citation_gaps: needs a page and at least one file\n' >&2; return 2; }
  page="$1"
  shift
  [ -f "$page" ] && [ -r "$page" ] || { printf 'citation_gaps: unreadable page %s\n' "$page" >&2; return 2; }
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] || { printf 'citation_gaps: unreadable site %s\n' "$f" >&2; return 2; }
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      # `grep -c` prints 0 and exits 1 on no match; the `|| true` keeps the 0.
      c="$(grep -cF "{#pillar-$n}" "$page" || true)"
      if [ "$c" != 1 ]; then
        printf '%s:pillar-%s\n' "$f" "$n"
      fi
    done < <(grep -oE "$CITE_ERE" "$f" | sed 's/.*#pillar-//')
  done
  return 0
}

# ---------------------------------------------------------------------------
# The page shape the anchors resolve against
# ---------------------------------------------------------------------------

@test "the philosophy page carries six pillar ids, 1 to 6, once each (#1631)" {
  # Cheap, and it makes a direction-2 red distinguishable from a page whose ids
  # were lost wholesale.
  local n i c
  [ -f "$PAGE" ]
  n="$(grep -cE '^## .*\{#pillar-[1-6]\}$' "$PAGE" || true)"
  [ "$n" -eq 6 ]
  for i in 1 2 3 4 5 6; do
    c="$(grep -cF "{#pillar-$i}" "$PAGE" || true)"
    [ "$c" -eq 1 ]
  done
}

# ---------------------------------------------------------------------------
# Direction 1 tests
# ---------------------------------------------------------------------------

@test "the derived docs-link roster is not empty or shrunken (#1631)" {
  # The canary the derivation needs: a broken filter or a regression to a
  # subdirectory-only glob would turn the sweep into a silent no-op.
  local pages page_links
  pages="$(link_pages)"
  [ -n "$pages" ]
  # Positive pairing: the authoritative site is on its own roster by name…
  matches "$pages" '(^|[[:space:]])docs/explanation/philosophy\.md($|[[:space:]])'
  # …and so is the top-level docs/index.md, so a derivation that stopped
  # reaching top-level pages reds here instead of shrinking the roster quietly.
  matches "$pages" '(^|[[:space:]])docs/index\.md($|[[:space:]])'
  # Every pillar's "what enforces it today" links at least one path outside
  # docs/, so six is the floor; the exact count lives in the tripwire.
  page_links="$(repo_links "$PAGE" | awk 'NF{c++} END{print c+0}')"
  [ "$page_links" -ge 6 ]
}

@test "every repo link on a docs page resolves to a tracked path (#1631)" {
  local rel
  local -a pages=()
  while IFS= read -r rel; do
    pages+=("$REPO_ROOT/$rel")
  done < <(link_pages)
  [ "${#pages[@]}" -ge 1 ]
  run repo_link_gaps "${pages[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Direction 2 tests
# ---------------------------------------------------------------------------

@test "every shipped-plugin citation resolves to exactly one pillar id (#1631)" {
  local rel cites
  local -a files=()
  while IFS= read -r rel; do
    files+=("$REPO_ROOT/$rel")
  done < <(citing_files)
  # Floors: at least one citing file and one citation, or the sweep is a no-op.
  [ "${#files[@]}" -ge 1 ]
  cites="$(cat "${files[@]}" | grep -oE "$CITE_ERE" | awk 'END{print NR}')"
  [ "$cites" -ge 1 ]
  run citation_gaps "$PAGE" "${files[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Roster tripwire
# ---------------------------------------------------------------------------

@test "ROSTER TRIPWIRE: MAINTAINING.md records this invariant's five derived figures (#1631)" {
  # A derived sweep answers "do the links I found resolve?" but never "did a
  # page or citation appear or vanish?". So the figures are written down in the
  # pattern's own table, and this ties each one to the derivation: adding or
  # removing a page, a link, a distinct path, a citing file or a citation reds
  # here until MAINTAINING.md is updated in the same PR.
  local table row rel pages_n links_n paths_n files_n cites_n
  local -a pages=() files=()
  table="$(sed -n '/^| Invariant | Authoritative site |/,/^$/p' "$REPO_ROOT/MAINTAINING.md")"
  [ -n "$table" ]
  # Read the ROW, not the table: a sibling row's figure could equal one of
  # these and satisfy a table-wide needle. `awk`, not `grep`, which exits 1 on
  # no match and would abort before `[ -n "$row" ]` could report it.
  row="$(awk '/Philosophy-page links/' <<< "$table")"
  [ -n "$row" ]
  while IFS= read -r rel; do
    pages+=("$REPO_ROOT/$rel")
  done < <(link_pages)
  while IFS= read -r rel; do
    files+=("$REPO_ROOT/$rel")
  done < <(citing_files)
  pages_n="${#pages[@]}"
  links_n="$(for rel in "${pages[@]}"; do repo_links "$rel"; done | awk 'NF{c++} END{print c+0}')"
  paths_n="$(for rel in "${pages[@]}"; do repo_links "$rel"; done | awk 'NF{print $2}' | LC_ALL=C sort -u | awk 'END{print NR}')"
  files_n="${#files[@]}"
  cites_n="$(cat "${files[@]}" | grep -oE "$CITE_ERE" | awk 'END{print NR}')"
  # FIVE figures, because each moves independently: a new page, a new link on
  # an existing page, a link to a path already linked elsewhere (moves links
  # but not paths), a new citing file, a second citation in an existing file.
  matches "$row" "(^|[^0-9])${pages_n} pages"
  matches "$row" "(^|[^0-9])${links_n} links"
  matches "$row" "(^|[^0-9])${paths_n} distinct paths"
  matches "$row" "(^|[^0-9])${files_n} files"
  matches "$row" "(^|[^0-9])${cites_n} citations"
  # …and the sweep and the authoritative site are named IN THE ROW, so a reader
  # of the table can find the code rather than trusting the row.
  contains "$row" 'tests/philosophy-links.bats'
  contains "$row" 'docs/explanation/philosophy.md'
}

# ---------------------------------------------------------------------------
# Non-vacuity controls — one per gap kind
# ---------------------------------------------------------------------------

@test "NON-VACUITY: direction 1 reds on a dead blob path on the philosophy page (#1631)" {
  # MUTATION (recorded here so this control cannot rot into a tautology): in a
  # copy of docs/explanation/philosophy.md, one evidence link's path is renamed
  # to a file that does not exist — `blob/main/tests/webui-positions.bats` ->
  # `blob/main/tests/webui-positions-gone.bats`. That is the drift itself: a
  # test file the page cites was renamed and the page was not.
  local mut="$BATS_TEST_TMPDIR/philosophy.md"
  [ -f "$PAGE" ]
  sed 's#blob/main/tests/webui-positions\.bats#blob/main/tests/webui-positions-gone.bats#' "$PAGE" > "$mut"
  # exactly 1 = "files differ"; `cmp` exits 2 when it cannot READ one of them,
  # which a `-ne 0` test would accept as "the mutation bit".
  run cmp -s "$PAGE" "$mut"
  [ "$status" -eq 1 ]
  run repo_link_gaps "$mut"
  # status 0 = the sweep RAN. Without it, the readability guard's own
  # diagnostic embeds $mut and could satisfy a looser needle.
  [ "$status" -eq 0 ]
  contains "$output" "$mut:tests/webui-positions-gone.bats"
}

@test "NON-VACUITY: direction 1 reds on a dead tree directory on a second docs page (#1631)" {
  # MUTATION (recorded): in a copy of docs/explanation/why-per-language-plugins.md,
  # the directory link `tree/main/development/skills/maintenance/scripts` is
  # rewritten to `…/scripts-gone`. This exercises the `tree` arm, which the
  # blob control above cannot reach, on a page other than the authoritative one.
  local src="$REPO_ROOT/docs/explanation/why-per-language-plugins.md"
  local mut="$BATS_TEST_TMPDIR/why-per-language-plugins.md"
  [ -f "$src" ]
  sed 's#tree/main/development/skills/maintenance/scripts#&-gone#' "$src" > "$mut"
  run cmp -s "$src" "$mut"
  [ "$status" -eq 1 ]
  run repo_link_gaps "$mut"
  [ "$status" -eq 0 ]
  contains "$output" "$mut:development/skills/maintenance/scripts-gone"
}

@test "NON-VACUITY: direction 2 reds on a dead anchor in a shipped plugin file (#1631)" {
  # MUTATION (recorded): in a copy of development/skills/refine-issue/SKILL.md,
  # its `#pillar-5` citation is rewritten to `#pillar-9` — an id the page does
  # not carry. The shipped-SKILL.md file kind, read by the citation extractor.
  #
  # The arm's other gap kind is a DUPLICATED id: a copy of the page with a second
  # `## Dup {#pillar-5}` heading appended, against which the real file's
  # `#pillar-5` citation must red too — "exactly one", not merely "present".
  local src="$REPO_ROOT/development/skills/refine-issue/SKILL.md"
  local mut="$BATS_TEST_TMPDIR/SKILL.md"
  local dup="$BATS_TEST_TMPDIR/philosophy-dup.md"
  [ -f "$src" ]
  sed 's|explanation/philosophy/#pillar-5|explanation/philosophy/#pillar-9|' "$src" > "$mut"
  run cmp -s "$src" "$mut"
  [ "$status" -eq 1 ]
  run citation_gaps "$PAGE" "$mut"
  [ "$status" -eq 0 ]
  contains "$output" "$mut:pillar-9"
  { cat "$PAGE"; printf '\n## Dup {#pillar-5}\n'; } > "$dup"
  run citation_gaps "$dup" "$src"
  [ "$status" -eq 0 ]
  contains "$output" "$src:pillar-5"
}

@test "FAIL CLOSED: an unreadable site is a typed failure, never a clean sweep (#1631)" {
  # The rosters are derived and re-opened later, so a renamed or absent site is
  # a real path to a green sweep of nothing. Each entry point is pinned, each
  # needling its OWN prefix so a case cannot pass on a sibling's arm.
  local gone="$BATS_TEST_TMPDIR/renamed-away.md"
  [ ! -e "$gone" ]
  run repo_links "$gone"
  [ "$status" -eq 2 ]
  contains "$output" 'repo_links: unreadable site'
  run repo_link_gaps "$gone"
  [ "$status" -eq 2 ]
  contains "$output" 'repo_link_gaps: unreadable site'
  # direction 2 fails closed on an unreadable PAGE, and on an unreadable
  # citing file behind a readable one
  run citation_gaps "$gone" "$REPO_ROOT/development/skills/refine-issue/SKILL.md"
  [ "$status" -eq 2 ]
  contains "$output" 'citation_gaps: unreadable page'
  run citation_gaps "$PAGE" "$gone"
  [ "$status" -eq 2 ]
  contains "$output" 'citation_gaps: unreadable site'
}
