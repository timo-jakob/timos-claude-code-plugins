#!/usr/bin/env bats
#
# Behavioral tests for ensure-coverage-precondition.zsh (#602): the pre-push
# guard that stops a push flow from running the whole test suite just to produce
# a coverage report for a diff with zero covered-language lines. It is a pure
# check — no tests run, nothing mutated:
#
#   • no covered-language files in the diff  → exit 0 (report not required)
#   • covered-language files + report on disk → exit 0 (floor applies, ready)
#   • covered-language files + report missing → exit 1 (caller must build it)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/scripts/ensure-coverage-precondition.zsh"

  SANDBOX="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$SANDBOX"
  git -C "$SANDBOX" init -q -b main
  git -C "$SANDBOX" config user.email t@t
  git -C "$SANDBOX" config user.name t
  # Base commit on main: a package with one module + a doc.
  mkdir -p "$SANDBOX/src/pkg"
  echo "x = 1" > "$SANDBOX/src/pkg/mod.py"
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit -qm base
  cd "$SANDBOX"   # the guard resolves the diff + report paths against cwd
}

# run the guard inside the sandbox, always comparing against local `main`.
guard() { run zsh "$S" --compare-branch main "$@"; }

@test "python: docs/config-only diff → exit 0, no report required" {
  git -C "$SANDBOX" checkout -q -b docs
  echo "more" >> "$SANDBOX/README.md"
  git -C "$SANDBOX" commit -qam "doc change"

  guard --lang python
  [ "$status" -eq 0 ]
  [[ "$output" == *"no covered-language files"* ]]
  [[ "$output" == *"no test run needed"* ]]
}

@test "python: .py diff with coverage.xml present → exit 0" {
  git -C "$SANDBOX" checkout -q -b feat
  echo "y = 2" >> "$SANDBOX/src/pkg/mod.py"
  git -C "$SANDBOX" commit -qam "py change"
  : > "$SANDBOX/coverage.xml"

  guard --lang python
  [ "$status" -eq 0 ]
  [[ "$output" == *"coverage.xml found"* ]]
}

@test "python: .py diff with coverage.xml MISSING → exit 1 + remedy" {
  git -C "$SANDBOX" checkout -q -b feat
  echo "y = 2" >> "$SANDBOX/src/pkg/mod.py"
  git -C "$SANDBOX" commit -qam "py change"

  guard --lang python
  [ "$status" -eq 1 ]
  [[ "$output" == *"coverage.xml is missing"* ]]
  [[ "$output" == *"pytest --cov"* ]]
}

@test "python: nested .py file is detected (pathspec spans subdirs)" {
  git -C "$SANDBOX" checkout -q -b deep
  mkdir -p "$SANDBOX/a/b/c"
  echo "z = 3" > "$SANDBOX/a/b/c/deep.py"
  git -C "$SANDBOX" add -A && git -C "$SANDBOX" commit -qm "nested py"

  guard --lang python          # no coverage.xml → must demand it
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing"* ]]
}

@test "java: only build.gradle.kts changed → exit 0 (.kts is not coverable source)" {
  echo "// base" > "$SANDBOX/build.gradle.kts"
  git -C "$SANDBOX" add -A && git -C "$SANDBOX" commit -qm "add kts"
  git -C "$SANDBOX" checkout -q -b bump
  echo "// dep bump" >> "$SANDBOX/build.gradle.kts"
  git -C "$SANDBOX" commit -qam "kts-only change"

  guard --lang java
  [ "$status" -eq 0 ]
  [[ "$output" == *"no covered-language files"* ]]
}

@test "java: a .kt source change → exit 1 (floor applies, report missing)" {
  git -C "$SANDBOX" checkout -q -b ktsrc
  echo "class A" > "$SANDBOX/A.kt"
  git -C "$SANDBOX" add -A && git -C "$SANDBOX" commit -qm "kt source"

  guard --lang java
  [ "$status" -eq 1 ]
  [[ "$output" == *"jacoco"* ]]
  [[ "$output" == *"gradlew"* ]]
}

@test "swift: a .swift change with coverage.lcov present → exit 0" {
  git -C "$SANDBOX" checkout -q -b sw
  echo "let x = 1" > "$SANDBOX/S.swift"
  git -C "$SANDBOX" add -A && git -C "$SANDBOX" commit -qm "swift"
  : > "$SANDBOX/coverage.lcov"

  guard --lang swift
  [ "$status" -eq 0 ]
  [[ "$output" == *"coverage.lcov found"* ]]
}

@test "--report override is honoured for the presence check" {
  git -C "$SANDBOX" checkout -q -b feat
  echo "y = 2" >> "$SANDBOX/src/pkg/mod.py"
  git -C "$SANDBOX" commit -qam "py change"
  mkdir -p "$SANDBOX/out"
  : > "$SANDBOX/out/cov.xml"

  guard --lang python --report out/cov.xml
  [ "$status" -eq 0 ]
  [[ "$output" == *"out/cov.xml found"* ]]
}

@test "missing --lang is a usage error (exit 2)" {
  guard
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "unknown --lang is a usage error (exit 2)" {
  guard --lang ruby
  [ "$status" -eq 2 ]
}

@test "a bare trailing value-flag is a clean usage error, not an infinite loop" {
  # `shift 2` past $# would spin forever; the guard must exit 2 instead. A
  # portable watchdog (no macOS `timeout`) kills a regression at ~5s so it fails
  # the assertion rather than hanging the suite.
  run bash -c '
    zsh "$1" --lang python --report & p=$!
    for _ in $(seq 1 50); do kill -0 $p 2>/dev/null || break; sleep 0.1; done
    if kill -0 $p 2>/dev/null; then kill -9 $p 2>/dev/null; wait $p 2>/dev/null; exit 111; fi
    wait $p; exit $?
  ' _ "$S"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing value for --report"* ]]
}

@test "an unresolvable compare ref fails loudly (exit 2), not a false pass" {
  git -C "$SANDBOX" checkout -q -b feat
  echo "y = 2" >> "$SANDBOX/src/pkg/mod.py"
  git -C "$SANDBOX" commit -qam "py change"

  run zsh "$S" --lang python --compare-branch origin/nonexistent
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not resolve"* ]]
}

@test "python: a pure .py DELETION needs no report (exit 0)" {
  git -C "$SANDBOX" checkout -q -b rm
  git -C "$SANDBOX" rm -q src/pkg/mod.py
  git -C "$SANDBOX" commit -qm "delete module"

  guard --lang python          # no coverage.xml on disk
  [ "$status" -eq 0 ]
  [[ "$output" == *"no covered-language files"* ]]
}
