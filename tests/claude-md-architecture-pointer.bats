#!/usr/bin/env bats
#
# The CLAUDE.md architecture pointer (issue #794, epic #746). Both this repo's
# CLAUDE.md and the bootstrap CLAUDE.md.tmpl must point agents at
# docs/architecture/ before a structural change, and require keeping it true in
# the same PR. The pointer is DIRECTORY-level — it never names an individual
# c4-context.md / c4-container.md file — so it cannot dangle before the diagrams
# (children (b) #791 seeding / (f) #795 this repo's dogfood) land: the directory
# already exists in both trees today. These tests assert the pointer's presence,
# its two rules, its directory-level-ness, and that every docs/architecture/
# path it names resolves in the tree (the mechanical guard against a dangling
# pointer ever being reintroduced).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMPL="$REPO_ROOT/development/skills/bootstrap/templates/common/CLAUDE.md.tmpl"
  REPO_CLAUDE="$REPO_ROOT/CLAUDE.md"
  SCRIPT="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  REAL_TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  OUT="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUT"
}

@test "CLAUDE.md.tmpl names docs/architecture/ and states both rules (#794)" {
  grep -Fq 'docs/architecture/' "$TMPL"
  # the read-before-structural-change rule — anchor to the body enumeration, not
  # the section heading (which also contains "before structural changes"), so
  # deleting the rule body while keeping the heading fails this test
  grep -Eqi 'adding, removing, or renaming' "$TMPL"
  # the keep-true-in-the-same-PR rule
  grep -Eqi 'same PR' "$TMPL"
}

@test "this repo's CLAUDE.md names docs/architecture/ and states both rules (#794)" {
  grep -Fq 'docs/architecture/' "$REPO_CLAUDE"
  grep -Eqi 'adding, removing, or renaming' "$REPO_CLAUDE"
  grep -Eqi 'same PR' "$REPO_CLAUDE"
}

@test "the pointer is directory-level — no individual c4-*.md file named (#794)" {
  # naming a c4-*.md file would dangle before children (b) #791 / (f) #795 land;
  # the pointer must stay at the always-present directory
  run ! grep -Eq 'c4-[a-z]+\.md' "$TMPL"
  run ! grep -Eq 'c4-[a-z]+\.md' "$REPO_CLAUDE"
}

@test "link integrity (template): docs/architecture/ resolves in the templates tree (#794)" {
  # a rendered target repo receives templates/common/docs/architecture/ — the
  # path the template's pointer names must resolve to a non-empty directory
  local dir="$REAL_TEMPLATES/common/docs/architecture"
  [ -d "$dir" ]
  [ -n "$(ls -A "$dir")" ]
}

@test "link integrity (this repo): docs/architecture/ resolves and is non-empty (#794)" {
  local dir="$REPO_ROOT/docs/architecture"
  [ -d "$dir" ]
  [ -n "$(ls -A "$dir")" ]
}

@test "a bootstrap render of CLAUDE.md.tmpl produces the architecture section unconditionally (#794)" {
  # render with a representative flag set; the pointer has no C4-conditional
  # block, so the section survives for any flag combination
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --project-name demo --project-slug o/demo --languages "python" \
    common/CLAUDE.md.tmpl
  [ "$status" -eq 0 ]
  local rendered="$OUT/common/CLAUDE.md"
  [ -f "$rendered" ]
  grep -Fq 'docs/architecture/' "$rendered"
  grep -Eqi 'adding, removing, or renaming' "$rendered"
  grep -Eqi 'same PR' "$rendered"
  # no uppercase placeholder survives, and no c4-*.md file is named
  run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$rendered"
  run ! grep -Eq 'c4-[a-z]+\.md' "$rendered"
}

@test "the rendered docs/architecture/ path resolves in a full rendered tree (#794)" {
  # render BOTH the pointer and the docs/architecture/ index the pointer targets,
  # then assert the named directory exists in the rendered output — the end-to-end
  # link-integrity guarantee a real bootstrap gives a target repo
  run zsh "$SCRIPT" --templates "$REAL_TEMPLATES" --out "$OUT" \
    --project-name demo --project-slug o/demo --languages "python" \
    common/CLAUDE.md.tmpl common/docs/architecture/index.md.tmpl
  [ "$status" -eq 0 ]
  [ -d "$OUT/common/docs/architecture" ]
  [ -f "$OUT/common/docs/architecture/index.md" ]
}
