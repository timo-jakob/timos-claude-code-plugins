#!/usr/bin/env bats
#
# Behavioral tests for the bootstrapped `coverage-floor` pre-push hook (#713).
#
# The bug: the hook guarded run/skip with `files: \.py$`, but on a brand-new
# branch push git reports the remote ref as all-zeros, so pre-commit diffs
# against the empty tree and EVERY .py counts as "added" — the filter over-fires
# and the hook demands a vacuous coverage.xml for a non-Python change. The fix
# moves the guard into the entry, keyed on the same origin/<default>...HEAD diff
# CI uses. These tests render the REAL template and run its extracted entry.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  OUT="$BATS_TEST_TMPDIR/out"
  # Render the python pre-commit config and pull out the coverage-floor entry.
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" --default-branch main \
    --languages python common/.pre-commit-config.yaml.tmpl >/dev/null
  CFG="$OUT/common/.pre-commit-config.yaml"
  ENTRY="$(awk '
    /^      - id: coverage-floor$/ { inhook=1 }
    inhook && /^        entry: >-/ { inentry=1; next }
    inentry {
      if ($0 ~ /^        [a-z_]+:/) { inentry=0; inhook=0 }
      else { line=$0; sub(/^ +/,"",line); printf "%s ", line }
    }
  ' "$CFG")"

  # A fake diff-cover on PATH: touching the marker proves the guard fell THROUGH
  # to the real coverage check instead of short-circuiting.
  STUB="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB"
  MARKER="$BATS_TEST_TMPDIR/diff-cover-ran"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$MARKER" > "$STUB/diff-cover"
  chmod +x "$STUB/diff-cover"

  # A repo with an origin/main ref and a feature branch forked off it.
  WORK="$BATS_TEST_TMPDIR/repo"; mkdir -p "$WORK"; cd "$WORK"
  git init -q -b main
  git config user.email t@e.x; git config user.name t
  printf 'FROM python:3.14-slim\n' > Dockerfile
  printf 'print("hi")\n' > app.py
  git add -A; git commit -qm init
  git update-ref refs/remotes/origin/main main   # simulate the fetched remote
  git switch -qc feat/x                            # a brand-new branch
}

run_entry() { PATH="$STUB:$PATH" run bash -c "$ENTRY"; }

@test "coverage-floor #713: entry carries the origin/main...HEAD diff guard, no files: filter" {
  grep -q 'git diff --name-only --diff-filter=d "$base...HEAD" -- "\*.py"' "$CFG"
  grep -q 'always_run: true' "$CFG"
  ! grep -qE '^        files: ' "$CFG"
}

@test "coverage-floor #713: new-branch Dockerfile-only push -> hook no-ops (exit 0), no diff-cover" {
  printf 'FROM python:3.14-slim@sha256:abc\n' > Dockerfile   # non-.py change only
  git commit -qam "bump base image"
  run_entry
  [ "$status" -eq 0 ]
  [ ! -f "$MARKER" ]   # guard short-circuited before diff-cover — the #713 fix
}

@test "coverage-floor #713: new-branch push touching .py -> guard passes through to diff-cover" {
  printf 'print("new feature")\n' > feature.py
  git add -A; git commit -qm "add feature"
  run_entry
  [ -f "$MARKER" ]     # diff has .py -> the floor still applies (unchanged)
}

@test "coverage-floor #713: deletion-only .py change -> still no-ops (nothing to cover)" {
  git rm -q app.py; git commit -qm "remove app.py"
  run_entry
  [ "$status" -eq 0 ]
  [ ! -f "$MARKER" ]   # --diff-filter=d drops deletions: no new coverable lines
}
