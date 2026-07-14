#!/usr/bin/env bats
#
# Integration tests for the bootstrap docs-machinery templates (#766, epic
# #745) — render the REAL templates the way SKILL.md §3h instructs and prove
# the seeded tree is coherent: every nav entry resolves to a rendered page
# (the strict-build precondition, checked via the shipped nav->chapters
# script), surface stubs and nav lines stay in lockstep, and the templated
# copy of docs-nav-to-chapters.zsh cannot drift from the repo's own.

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
)

render_docs() { # render_docs <interfaces-csv-or-empty> [extra stub relpaths...]
  local ifaces="$1"; shift
  local -a flags=(--templates "$TEMPLATES" --out "$OUT"
    --project-name "Demo Project" --project-slug "owner/demo-repo")
  [ -n "$ifaces" ] && flags+=(--acceptance-interfaces "$ifaces")
  zsh "$RENDER" "${flags[@]}" "${DOCS_BASE_SET[@]}" "$@"
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
  ! grep -q "use-the-rest-api" "$OUT/common/mkdocs.yml"
  ! grep -q "use-the-web-ui" "$OUT/common/mkdocs.yml"
  ! grep -q "use-the-rest-api" "$OUT/common/docs/index.md"
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
  ! grep -q "use-the-" "$OUT/common/mkdocs.yml"
  ! grep -q "use-the-" "$OUT/common/docs/index.md"
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
  ! grep -q "^# --- " "$OUT/common/docs/index.md"
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

@test "docs templates: shipped pre-commit/yamllint configs tolerate the seeded mkdocs.yml (#777)" {
  # The seeded mkdocs.yml carries MkDocs' custom YAML tags (check-yaml's safe
  # loader can't construct them) and a >120-char provenance-marker line
  # (stamped at adoption). The shipped configs must exempt it, or docs
  # adoption fails the target repo's own pre-commit.
  grep -A8 "id: check-yaml" "$TEMPLATES/common/.pre-commit-config.yaml.tmpl" \
    | grep -q 'exclude: \^mkdocs\\.yml\$'
  grep -A6 "ignore: |" "$TEMPLATES/common/.yamllint" | grep -qE "^[[:space:]]+mkdocs\.yml"
  # Templates themselves stay yamllint-clean: no one-space inline comments in
  # the docs workflows (yamllint wants two before a trailing comment).
  ! grep -nE '[^ #] # ' "$TEMPLATES/common/.github/workflows/docs.yml.tmpl" \
      "$TEMPLATES/common/.github/workflows/docs-deploy.yml.tmpl" \
      "$TEMPLATES/common/.github/workflows/docs-publish.yml.tmpl"
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
  ! grep -q "superpowers" <<<"$chapters"
  # …and the nav<->files lockstep still holds for the published pages.
  assert_nav_files_exist
}
