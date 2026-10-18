#!/usr/bin/env bats
#
# sole-go-leftovers.zsh — what an existing sole-Go repo still carries of the CI
# its gate replaced (#2617). A re-run never deletes a file (#2126 owns removal),
# so bootstrap's Step 5 report quotes this list, and the drift detector (#2618)
# reuses it. The repo is only ever read.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  # a git hook or `rebase --exec` exports these; the fixtures are plain dirs, but
  # detect-stack.sh probes git in them
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LEFTOVERS="$REPO_ROOT/development/skills/bootstrap/scripts/sole-go-leftovers.zsh"
  FX="$BATS_TEST_TMPDIR/repo"
}

# a Go repo recording `primary: go`, plus any extra languages' marker files
go_fixture() {
  mkdir -p "$FX/.github/workflows"
  printf 'module example.com/demo\n\ngo 1.25\n' > "$FX/go.mod"
  printf 'package main\n\nfunc main() {}\n' > "$FX/main.go"
  printf 'primary: go\n' > "$FX/.maintenance.yml"
}

# an old-shape quality workflow: the folded jobs plus the Docker lane
old_quality() {
  printf 'on: pull_request\njobs:\n  test-and-coverage:\n    runs-on: x\n  sonarcloud:\n    needs: test-and-coverage\n  trivy-fs:\n    runs-on: x\n  license-fs:\n    runs-on: x\n  image:\n    runs-on: x\n  semgrep:\n    runs-on: x\n  pre-commit:\n    runs-on: x\n' \
    > "$FX/.github/workflows/quality-$1.yml"
  printf 'on: pull_request\njobs:\n  test-and-coverage:\n    runs-on: x\n  semgrep:\n    runs-on: x\n  image:\n    runs-on: x\n' \
    > "$FX/.github/workflows/quality-$1-noop.yml"
}

tree_digest() {
  (cd "$FX" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum)
}

@test "#2617: a sole-Go repo's leftover files are listed by deploy path, then its folded jobs as <file>#<job>" {
  go_fixture
  old_quality public
  printf 'name: gitleaks\n' > "$FX/.github/workflows/gitleaks.yml"
  printf 'name: docs\n' > "$FX/.github/workflows/docs.yml"
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --visibility public --docker false
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' .github/workflows/docs.yml .github/workflows/gitleaks.yml \
    .github/workflows/quality-public-noop.yml .github/workflows/quality-public.yml \
    '.github/workflows/quality-public-noop.yml#semgrep' '.github/workflows/quality-public-noop.yml#test-and-coverage' \
    '.github/workflows/quality-public.yml#license-fs' '.github/workflows/quality-public.yml#pre-commit' \
    '.github/workflows/quality-public.yml#semgrep' '.github/workflows/quality-public.yml#sonarcloud' \
    '.github/workflows/quality-public.yml#test-and-coverage' '.github/workflows/quality-public.yml#trivy-fs')" ] ||
    { printf 'got:\n%s\n' "$output"; return 1; }
}

@test "#2617: with a Dockerfile the quality files are not leftovers, but their folded jobs still are" {
  go_fixture
  old_quality private
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --visibility private --docker true
  [ "$status" -eq 0 ]
  lacks "$output" $'.github/workflows/quality-private.yml\n'
  contains "$output" '.github/workflows/quality-private.yml#sonarcloud'
  contains "$output" '.github/workflows/quality-private-noop.yml#test-and-coverage'
  lacks "$output" '#image'
}

@test "#2617: a sonarqube job is a folded job too" {
  go_fixture
  printf 'jobs:\n  sonarqube:\n    runs-on: x\n  image:\n    runs-on: x\n' > "$FX/.github/workflows/quality-private.yml"
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --visibility private --docker true
  [ "$status" -eq 0 ]
  [ "$output" = '.github/workflows/quality-private.yml#sonarqube' ]
}

@test "#2617: on a Go+Swift repo the noop's test-and-coverage is not a leftover" {
  go_fixture
  mkdir -p "$FX/Sources/App"
  printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "App")\n' > "$FX/Package.swift"
  printf 'print("hi")\n' > "$FX/Sources/App/main.swift"
  old_quality public
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --visibility public --docker false
  [ "$status" -eq 0 ]
  lacks "$output" '.github/workflows/quality-public-noop.yml#test-and-coverage'
  contains "$output" '.github/workflows/quality-public-noop.yml#semgrep'
  contains "$output" '.github/workflows/quality-public.yml#test-and-coverage'
}

@test "#2617: a repo that is not sole-Go, or records no primary, prints nothing" {
  go_fixture
  old_quality public
  printf 'name: gitleaks\n' > "$FX/.github/workflows/gitleaks.yml"
  printf 'requests\n' > "$FX/requirements.txt"
  printf 'print(1)\n' > "$FX/app.py"
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --visibility public --docker false
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf 'go+python printed:\n%s\n' "$output"; return 1; }
  rm "$FX/requirements.txt" "$FX/app.py" "$FX/.maintenance.yml"
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --visibility public --docker false
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf 'no primary printed:\n%s\n' "$output"; return 1; }
}

@test "#2617: the repo is left byte-for-byte as it was" {
  go_fixture
  old_quality public
  printf 'name: gitleaks\n' > "$FX/.github/workflows/gitleaks.yml"
  local before
  before="$(tree_digest)"
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --visibility public --docker false
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(tree_digest)" = "$before" ]
}

@test "#2617: a missing or out-of-set flag is a usage error, exit 2" {
  go_fixture
  run --separate-stderr zsh "$LEFTOVERS" --visibility public --docker false
  [ "$status" -eq 2 ]
  contains "$stderr" "--repo is required"
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --docker false
  [ "$status" -eq 2 ]
  contains "$stderr" "--visibility is required"
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --visibility public
  [ "$status" -eq 2 ]
  contains "$stderr" "--docker is required"
  run --separate-stderr zsh "$LEFTOVERS" --repo "$BATS_TEST_TMPDIR/absent" --visibility public --docker false
  [ "$status" -eq 2 ]
  contains "$stderr" "--repo is not a directory"
  run --separate-stderr zsh "$LEFTOVERS" --repo "$FX" --visibility internal --docker false
  [ "$status" -eq 2 ]
  contains "$stderr" "--visibility must be public or private"
}
