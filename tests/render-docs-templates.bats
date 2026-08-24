#!/usr/bin/env bats
#
# Integration tests for the bootstrap docs-machinery templates (#766, epic
# #745) — render the REAL templates the way SKILL.md §3h instructs and prove
# the seeded tree is coherent: every nav entry resolves to a rendered page
# (the strict-build precondition, checked via the shipped nav->chapters
# script), surface stubs and nav lines stay in lockstep, and the templated
# copy of docs-nav-to-chapters.zsh cannot drift from the repo's own.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
}

# The §3h base set (everything except the per-surface how-to stubs).
DOCS_BASE_SET=(
  common/mkdocs.yml.tmpl
  common/docs/index.md.tmpl
  common/docs/tutorials/index.md.tmpl
  common/docs/tutorials/getting-started.md.tmpl
  common/docs/how-to/index.md.tmpl
  common/docs/reference/index.md.tmpl
  common/docs/explanation/index.md.tmpl
  common/docs/architecture/index.md.tmpl
  common/.github/workflows/docs.yml.tmpl
  common/.github/workflows/docs-deploy.yml.tmpl
  common/.github/workflows/docs-publish.yml.tmpl
  common/Dockerfile.docs
  common/requirements-docs.txt
  common/scripts/docs-nav-to-chapters.zsh
  common/scripts/pandoc/break-long-tokens.lua
  common/scripts/pandoc/manual-header.tex
)

render_docs() { # render_docs <interfaces-csv-or-empty> [extra stub relpaths...]
  local ifaces="$1"; shift
  local -a flags=(--templates "$TEMPLATES" --out "$OUT"
    --project-name "Demo Project" --project-slug "owner/demo-repo")
  [ -n "$ifaces" ] && flags+=(--acceptance-interfaces "$ifaces")
  zsh "$RENDER" "${flags[@]}" "${DOCS_BASE_SET[@]}" "$@" || return
  # §3h also SEEDS the two C4 pages the nav now references (#791) — render + seed
  # are one step, so the nav<->files lockstep the asserts below check holds.
  local seed="$REPO_ROOT/development/skills/bootstrap/scripts/seed-c4-diagrams.zsh"
  local dj="$BATS_TEST_TMPDIR/detect-docs.json"
  printf '%s' '{"languages":["python"],"language_meta":{"python":{"version":"3.12"}},"containers":[{"name":"demo","source":"dockerfile","evidence":"./Dockerfile"}],"detection_confidence":"complete","interfaces":[{"interface":"cli","evidence":"x"}]}' > "$dj"
  zsh "$seed" --project-name "Demo Project" --detect-json "$dj" --out "$OUT/common"
}

# Assert every nav entry of the rendered mkdocs.yml exists as a rendered file —
# the mkdocs --strict "nav references a missing page" half, without needing
# mkdocs installed. Uses the template's own nav->chapters script.
assert_nav_files_exist() {
  local chapters
  chapters="$(zsh "$OUT/common/scripts/docs-nav-to-chapters.zsh" "$OUT/common/mkdocs.yml")"
  [ -n "$chapters" ]
  local page
  while IFS= read -r page; do
    [ -f "$OUT/common/$page" ] || {
      echo "nav entry has no rendered page: $page" >&2
      return 1
    }
  done <<<"$chapters"
}

# Assert the inverse: every rendered docs page appears in the nav — the
# mkdocs --strict "page omitted from nav" half.
assert_no_orphan_pages() {
  local chapters f rel
  chapters="$(zsh "$OUT/common/scripts/docs-nav-to-chapters.zsh" "$OUT/common/mkdocs.yml")"
  while IFS= read -r f; do
    rel="${f#"$OUT/common/"}"
    grep -qx "$rel" <<<"$chapters" || {
      echo "rendered page missing from nav: $rel" >&2
      return 1
    }
  done < <(find "$OUT/common/docs" -name '*.md' -type f)
}

@test "docs templates: the seeded C4 pages are registered in the docs/index.md MOC (#791)" {
  run render_docs "cli" common/docs/how-to/use-the-cli.md.tmpl
  [ "$status" -eq 0 ]
  grep -Fq 'architecture/c4-context.md' "$OUT/common/docs/index.md"
  grep -Fq 'architecture/c4-container.md' "$OUT/common/docs/index.md"
}

@test "docs templates: cli-only render seeds a coherent tree (nav <-> files in lockstep)" {
  run render_docs "cli" common/docs/how-to/use-the-cli.md.tmpl
  [ "$status" -eq 0 ]
  [ -f "$OUT/common/mkdocs.yml" ]
  [ -f "$OUT/common/docs/index.md" ]
  [ -f "$OUT/common/docs/how-to/use-the-cli.md" ]
  [ ! -f "$OUT/common/docs/how-to/use-the-rest-api.md" ]
  assert_nav_files_exist
  assert_no_orphan_pages
  # The nav and the MOC both dropped the undetected surfaces.
  run ! grep -q "use-the-rest-api" "$OUT/common/mkdocs.yml"
  run ! grep -q "use-the-web-ui" "$OUT/common/mkdocs.yml"
  run ! grep -q "use-the-rest-api" "$OUT/common/docs/index.md"
}

@test "docs templates: all-surfaces render seeds every stub and its nav/MOC entries" {
  run render_docs "cli, rest, web-ui" \
    common/docs/how-to/use-the-cli.md.tmpl \
    common/docs/how-to/use-the-rest-api.md.tmpl \
    common/docs/how-to/use-the-web-ui.md.tmpl
  [ "$status" -eq 0 ]
  for stub in use-the-cli use-the-rest-api use-the-web-ui; do
    [ -f "$OUT/common/docs/how-to/${stub}.md" ]
    grep -q "$stub" "$OUT/common/mkdocs.yml"
    grep -q "$stub" "$OUT/common/docs/index.md"
    grep -q "$stub" "$OUT/common/docs/how-to/index.md"
  done
  assert_nav_files_exist
  assert_no_orphan_pages
}

@test "docs templates: no-interface render still seeds the tree, with no surface stubs" {
  run render_docs ""
  [ "$status" -eq 0 ]
  [ -f "$OUT/common/docs/index.md" ]
  run ! grep -q "use-the-" "$OUT/common/mkdocs.yml"
  run ! grep -q "use-the-" "$OUT/common/docs/index.md"
  assert_nav_files_exist
  assert_no_orphan_pages
}

@test "docs templates: substitution lands (project name, Pages URL, default branch)" {
  run render_docs "cli" common/docs/how-to/use-the-cli.md.tmpl
  [ "$status" -eq 0 ]
  grep -q "site_name: Demo Project" "$OUT/common/mkdocs.yml"
  grep -q "site_url: https://owner.github.io/demo-repo/" "$OUT/common/mkdocs.yml"
  grep -q "branches: \[main\]" "$OUT/common/.github/workflows/docs-deploy.yml"
  # Rendered markdown carries no heading-style marker pollution.
  run ! grep -q "^# --- " "$OUT/common/docs/index.md"
}

@test "docs templates: all three docs workflows are path-conditional on the docs surface" {
  run render_docs ""
  [ "$status" -eq 0 ]
  for wf in docs.yml docs-deploy.yml docs-publish.yml; do
    grep -q "paths:" "$OUT/common/.github/workflows/$wf"
    grep -q '"docs/\*\*"' "$OUT/common/.github/workflows/$wf"
  done
}

@test "docs templates: templated nav->chapters script is byte-identical to the repo's (no drift)" {
  diff "$REPO_ROOT/scripts/docs-nav-to-chapters.zsh" \
    "$TEMPLATES/common/scripts/docs-nav-to-chapters.zsh"
}

@test "docs templates: templated pandoc layout assets are byte-identical to the repo's (no drift)" {
  # Same rule as the nav->chapters script above: this repo dogfoods the assets it
  # ships, so a fix applied to one copy and not the other means every downstream
  # manual keeps the defect the fix was for.
  diff "$REPO_ROOT/scripts/pandoc/break-long-tokens.lua" \
    "$TEMPLATES/common/scripts/pandoc/break-long-tokens.lua"
  diff "$REPO_ROOT/scripts/pandoc/manual-header.tex" \
    "$TEMPLATES/common/scripts/pandoc/manual-header.tex"
}

@test "docs templates: both shipped docs workflows pass the layout assets to the PDF build" {
  # The assets are inert unless pandoc is told about them, so the seeded repo has
  # the files AND the flags, or it has the glitch.
  run render_docs ""
  [ "$status" -eq 0 ]
  local wf
  for wf in docs.yml docs-publish.yml; do
    grep -q -- "--lua-filter=scripts/pandoc/break-long-tokens.lua" \
      "$OUT/common/.github/workflows/$wf"
    grep -q -- "--include-in-header=scripts/pandoc/manual-header.tex" \
      "$OUT/common/.github/workflows/$wf"
    # pandoc/latex carries no fvextra, which manual-header.tex needs
    grep -q "pandoc/extra:" "$OUT/common/.github/workflows/$wf"
    run ! grep -q "pandoc/latex:" "$OUT/common/.github/workflows/$wf"
  done
}

@test "docs templates: the shipped PR gate fails on a character the PDF has no glyph for" {
  # xelatex drops an unmapped character silently; the seeded gate must not.
  run render_docs ""
  [ "$status" -eq 0 ]
  grep -q "Missing character" "$OUT/common/.github/workflows/docs.yml"
  grep -q "pandoc-pdf.log" "$OUT/common/.github/workflows/docs.yml"
}

@test "docs templates: the shipped PR gate's reference step matches the repo's byte for byte" {
  # #1542: the site and the manual slugify a heading differently, so an in-page
  # link can resolve on one and dangle in the other while both builds exit 0.
  # Same parity rule as the layout assets — a gate this repo has and the shipped
  # stack lacks means every seeded repo keeps the defect.
  #
  # Held as byte-identity rather than a needle list: the step carries no
  # placeholders, so whatever tests/manual-pdf-anchors.bats pins about the repo's
  # copy (the trigger, the positive control, the missing-log precondition, the
  # verdict's own exit) holds for the shipped one too — in this round and in
  # every later one. Two hand-written assertion sets would drift; this cannot.
  run render_docs ""
  [ "$status" -eq 0 ]
  local q='.jobs.pdf-epub.steps[] | select(.name == "Fail on references the PDF cannot resolve") | .run'
  yq -r "$q" "$OUT/common/.github/workflows/docs.yml" > "$BATS_TEST_TMPDIR/gate-shipped.txt"
  yq -r "$q" "$REPO_ROOT/.github/workflows/docs.yml" > "$BATS_TEST_TMPDIR/gate-repo.txt"
  # a renamed or deleted step yields an empty body, which must not pass as a match
  [ -s "$BATS_TEST_TMPDIR/gate-shipped.txt" ]
  diff "$BATS_TEST_TMPDIR/gate-repo.txt" "$BATS_TEST_TMPDIR/gate-shipped.txt"
}

@test "docs templates: the shipped build step captures pandoc's diagnostics into the log" {
  # Both shipped log gates read pandoc-pdf.log; drop the 2>&1 and it holds stdout
  # alone, so the glyph gate and the reference gate become permanent no-ops in
  # every seeded repo. The build step DOES carry placeholders, so it is pinned by
  # needle rather than by identity.
  run render_docs ""
  [ "$status" -eq 0 ]
  local body="$BATS_TEST_TMPDIR/build-step.txt"
  yq -r '.jobs.pdf-epub.steps[] | select(.name == "Build manual.pdf + manual.epub with pandoc") | .run' \
    "$OUT/common/.github/workflows/docs.yml" > "$body"
  grep -qF '2>&1 | tee pandoc-pdf.log' "$body"
}

@test "docs templates: the shipped workflows name exactly one pandoc image" {
  # The positive control is only a control while it runs the image that builds
  # the manual, and the tag is a hand-maintained pin repeated in each workflow.
  # Collapsed across BOTH files, as tests/manual-pdf-layout.bats does for this
  # repo's copies: a per-file check passes when docs.yml is bumped and
  # docs-publish.yml is not, leaving every seeded repo gating PRs on one image
  # while publishing a manual built by another.
  run render_docs ""
  [ "$status" -eq 0 ]
  local images
  images="$(grep -ho 'pandoc/[a-z]*:[0-9.]*' \
    "$OUT/common/.github/workflows/docs.yml" \
    "$OUT/common/.github/workflows/docs-publish.yml" | sort -u)"
  [ -n "$images" ]
  [ "$(printf '%s\n' "$images" | wc -l | tr -d ' ')" = "1" ]
}

@test "docs templates: the target-repo how-to names all three registration points" {
  # The seeded stack has three (the nav, the MOC, the bucket's own index) and
  # only the nav is enforced — a page missing from the other two builds green.
  # So this page's prose IS the mechanism: `mkdocs build --strict` validates the
  # nav, never what a page says about the nav, and nothing else in the suite
  # reads this file. Reverting it to "both", or dropping the sentence that says
  # which one is enforced, would otherwise be a silent regression.
  local page="$REPO_ROOT/docs/how-to/write-docs-in-a-target-repo.md"
  grep -Fq 'must appear in **all three**' "$page"
  grep -Fq "the bucket's own \`index.md\`" "$page"
  grep -Fq '**Only the first is enforced.**' "$page"
}

@test "docs templates: the shipped mkdocs config reads explicit heading ids" {
  # attr_list is what makes the {#id} remedy work on the site; without it the id
  # renders as literal text in the heading and the anchor reverts to the slug.
  run render_docs ""
  [ "$status" -eq 0 ]
  local found
  found="$(yq -r '.markdown_extensions[] | select(. == "attr_list")' "$OUT/common/mkdocs.yml")"
  [ "$found" = "attr_list" ]
}

@test "docs templates: the shipped docs workflows react to a change in the layout assets" {
  run render_docs ""
  [ "$status" -eq 0 ]
  local wf
  for wf in docs.yml docs-publish.yml; do
    grep -q '"scripts/pandoc/\*\*"' "$OUT/common/.github/workflows/$wf"
  done
}

@test "docs templates: every workflow action ref is SHA-pinned (#779, target-repo semgrep policy)" {
  # Target repos' semgrep hook rejects mutable tag refs; shipped workflow
  # templates carry full-SHA pins with a version comment (supply-chain policy).
  for wf in docs.yml.tmpl docs-deploy.yml.tmpl docs-publish.yml.tmpl; do
    # every uses: line must carry a 40-hex SHA
    while IFS= read -r line; do
      echo "$line" | grep -qE 'uses: [A-Za-z0-9_./-]+@[0-9a-f]{40}( #| )' || {
        echo "mutable action ref in $wf: $line" >&2
        return 1
      }
    done < <(grep "uses:" "$TEMPLATES/common/.github/workflows/$wf")
  done
}

@test "docs templates: shipped pre-commit/yamllint configs tolerate the seeded mkdocs.yml (#777)" {
  # The seeded mkdocs.yml carries MkDocs' custom YAML tags (check-yaml's safe
  # loader can't construct them) and a >120-char provenance-marker line
  # (stamped at adoption). The shipped configs must exempt it, or docs
  # adoption fails the target repo's own pre-commit.
  grep -A8 "id: check-yaml" "$TEMPLATES/common/.pre-commit-config.yaml.tmpl" \
    | grep -q 'exclude: \^mkdocs\\.yml\$'
  grep -A6 "ignore: |" "$TEMPLATES/common/.yamllint" | grep -qE "^[[:space:]]+mkdocs\.yml"
}

@test "shipped configs enforce the zero-warnings policy Renovate-compatibly (#781)" {
  # yamllint runs --strict (warnings fail the hook) and the comments rule
  # accepts Renovate's one-space `sha # vN` pin style as VALID — a two-space
  # mandate would turn every Renovate pin-update PR red. Both halves are
  # needed: strict without the rule change breaks Renovate; the rule change
  # without strict lets new warning classes accumulate silently.
  grep -A8 "id: yamllint" "$TEMPLATES/common/.pre-commit-config.yaml.tmpl" | grep -q -- "--strict"
  grep -A2 "^  comments:" "$TEMPLATES/common/.yamllint" | grep -q "min-spaces-from-content: 1"
  # This repo holds itself to the same standard.
  grep -A12 "id: yamllint" "$REPO_ROOT/.pre-commit-config.yaml" | grep -q -- "--strict"
  grep -A2 "^  comments:" "$REPO_ROOT/.yamllint" | grep -q "min-spaces-from-content: 1"
}

@test "docs templates: a docs/superpowers page is excluded from the build, not an orphan (#775)" {
  # Every family repo keeps design specs/plans under docs/superpowers/ — the
  # seeded strict build must ignore them (they are neither nav entries nor
  # orphaned pages), or the very first build on a spec-carrying repo fails.
  run render_docs ""
  [ "$status" -eq 0 ]
  mkdir -p "$OUT/common/docs/superpowers/specs"
  printf '# internal design spec\n' > "$OUT/common/docs/superpowers/specs/plan.md"
  grep -q "^exclude_docs:" "$OUT/common/mkdocs.yml"
  grep -qE "^[[:space:]]+superpowers/" "$OUT/common/mkdocs.yml"
  # The nav derives no chapter from the superpowers tree…
  chapters="$(zsh "$OUT/common/scripts/docs-nav-to-chapters.zsh" "$OUT/common/mkdocs.yml")"
  run ! grep -q "superpowers" <<<"$chapters"
  # …and the nav<->files lockstep still holds for the published pages.
  assert_nav_files_exist
}
