#!/usr/bin/env bats
#
# Behavioral tests for the Python coverage-floor hook's worktree guard (#518):
# in a git worktree that reuses the main checkout's venv, an editable install
# resolves imports to the MAIN checkout, so coverage.xml records that tree's
# paths and diff-cover counts the worktree's changed lines as 0% covered — a
# false NOT-COVERED verdict blocking the push. The hook must WITHHOLD the
# verdict (fail with the per-worktree-venv remedy) when the report's <source>
# provably belongs to another tree, and judge normally otherwise.
#
# The guard lives inline in the bootstrap template's hook `entry:`; these tests
# extract that entry (folding the YAML `>-` scalar the way YAML does) and drive
# it in a sandbox repo against a stubbed diff-cover.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMPL="$REPO_ROOT/development/skills/bootstrap/templates/common/.pre-commit-config.yaml.tmpl"

  # Fold the `entry: >-` scalar of the Python `coverage-floor` hook (the `$`
  # anchor excludes coverage-floor-swift/-java) into the single command line
  # pre-commit would see.
  ENTRY="$(awk '
    /- id: coverage-floor$/ {hook=1}
    hook && /entry: >-/ {entry=1; next}
    entry && /^ *language:/ {exit}
    entry {sub(/^ +/, ""); printf "%s ", $0}
  ' "$TMPL")"
  ENTRY="${ENTRY//\{\{DEFAULT_BRANCH\}\}/main}"

  SANDBOX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$SANDBOX"
  git -C "$SANDBOX" init -q
  TOP="$(git -C "$SANDBOX" rev-parse --show-toplevel)"   # physical path (macOS /tmp symlinks)

  STUB="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\necho "diff-cover-invoked $*"\n' > "$STUB/diff-cover"
  chmod +x "$STUB/diff-cover"
}

# coverage_xml <source-path> — write a minimal coverage.py-shaped report.
coverage_xml() {
  printf '<?xml version="1.0" ?>\n<coverage>\n  <sources>\n    <source>%s</source>\n  </sources>\n</coverage>\n' \
    "$1" > "$SANDBOX/coverage.xml"
}

run_hook() { run bash -c "cd \"$SANDBOX\" || exit 9; export PATH=\"$STUB:\$PATH\"; $ENTRY"; }

@test "guard: entry extraction sanity — the template still carries the guarded entry" {
  echo "$ENTRY" | grep -q "git rev-parse --show-toplevel"
  echo "$ENTRY" | grep -q -- "diff-cover coverage.xml --compare-branch=origin/main --fail-under=90"
}

@test "#518 foreign absolute <source> -> verdict withheld (exit 1) with the venv remedy, diff-cover never runs" {
  coverage_xml "/somewhere/else/main-checkout"
  run_hook
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not this worktree"
  echo "$output" | grep -q "python -m venv .venv"
  run ! grep -q "diff-cover-invoked" <<<"$output"
}

@test "#518 in-tree <source> -> judged normally (diff-cover runs with the real flags)" {
  coverage_xml "$TOP/src"
  run_hook
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "diff-cover-invoked coverage.xml --compare-branch=origin/main --fail-under=90"
}

@test "#518 <source> equal to the worktree root -> judged normally" {
  coverage_xml "$TOP"
  run_hook
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "diff-cover-invoked"
}

@test "#518 missing coverage.xml -> falls through to diff-cover (which owns its own clear error)" {
  rm -f "$SANDBOX/coverage.xml"
  run_hook
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "diff-cover-invoked"
}

@test "#518 relative <source> -> cannot be judged wrong, proceeds to diff-cover" {
  coverage_xml "."
  run_hook
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "diff-cover-invoked"
}
