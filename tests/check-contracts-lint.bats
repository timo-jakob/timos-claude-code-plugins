#!/usr/bin/env bats
#
# #2640 — check-contracts-lint.zsh, the contracts lint stage every language gate
# shares. These cases run the REAL checker from the bootstrap template in a
# fixture repository, with node and npx stubbed, so each exit code, the
# --caller prefix and the pinned Spectral run are exercised without the network.
# tests/render-contracts-templates.bats owns the selector's parity with
# contracts-lint.yml; tests/bootstrap-go-gate.bats owns the Go gate's use of it.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECKER="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/check-contracts-lint.zsh"
  ZSH="$(command -v zsh)"
  STUB="$BATS_TEST_TMPDIR/stub-bin"
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$STUB" "$R/scripts"
  : > "$CALLS"
  export CALLS
  printf '#!/bin/sh\nexit 0\n' > "$STUB/node"
  printf '#!/bin/sh\necho "npx $*" >> "$CALLS"\nexit "${SPECTRAL_RC:-0}"\n' > "$STUB/npx"
  chmod +x "$STUB"/*
  cp "$CHECKER" "$R/scripts/"
  printf 'extends: []\n' > "$R/.spectral.yaml"
}

# A contract spec at <dir>/openapi.yaml.
mkspec() {
  mkdir -p "$R/$1"
  printf 'openapi: 3.1.0\ninfo:\n  title: T\n  version: "1.0.0"\npaths: {}\n' > "$R/$1/openapi.yaml"
}

# The checker as a gate would run it, from the repository root, stubs first on PATH.
lint() {
  (cd "$R" && env PATH="$STUB:$PATH" "$ZSH" scripts/check-contracts-lint.zsh "$@")
}

@test "#2640: exit 0 lints the newest major of each family with the pinned Spectral, every line prefixed with --caller" {
  mkspec contracts/v1
  mkspec contracts/v2
  mkspec contracts/ops/v1
  run --separate-stderr lint --caller python-gate
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [ "$output" = 'python-gate: linting contracts/v2/openapi.yaml contracts/ops/v1/openapi.yaml' ]
  [ -z "$stderr" ]
  grep -qx 'npx --yes @stoplight/spectral-cli@6.15.0 lint --ruleset .spectral.yaml --fail-severity error contracts/v2/openapi.yaml contracts/ops/v1/openapi.yaml' "$CALLS"
}

@test "#2640: without --caller the prefix is the checker's own name" {
  mkspec contracts/v1
  run --separate-stderr lint
  [ "$status" -eq 0 ]
  [ "$output" = 'check-contracts-lint: linting contracts/v1/openapi.yaml' ]
  run --separate-stderr lint --bogus
  [ "$status" -eq 2 ]
  [ "$stderr" = 'check-contracts-lint: unknown argument: --bogus' ]
}

@test "#2640: a Spectral error is exit 1, its reason on stderr under the caller's prefix" {
  mkspec contracts/v1
  run --separate-stderr env SPECTRAL_RC=1 bash -c 'cd "$1" && env PATH="$2:$PATH" "$3" scripts/check-contracts-lint.zsh --caller java-gate' _ "$R" "$STUB" "$ZSH"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'java-gate: FAIL contracts lint — spectral' ]
}

@test "#2640: a newest vN directory without openapi.yaml is exit 1, refused under the caller's prefix, and Spectral never runs" {
  mkspec contracts/v1
  mkdir -p "$R/contracts/v2"
  printf 'openapi: 3.1.0\n' > "$R/contracts/v2/openapi.yml"
  run --separate-stderr lint --caller swift-gate
  [ "$status" -eq 1 ]
  contains "$stderr" 'swift-gate: contracts/v2/ is the newest major of contracts but has no openapi.yaml — refusing to fall back to an older, frozen major.'
  contains "$stderr" 'swift-gate: FAIL contracts lint — the newest contract major has no openapi.yaml'
  [ ! -s "$CALLS" ]
}

@test "#2640: a missing node is exit 1 naming the tool, once there is a spec to lint" {
  local bare="$BATS_TEST_TMPDIR/bare-bin"
  mkdir -p "$bare"
  ln -s "$ZSH" "$bare/zsh"
  mkspec contracts/v1
  run --separate-stderr bash -c 'cd "$1" && PATH="$2" "$3" scripts/check-contracts-lint.zsh --caller javascript-gate' _ "$R" "$bare" "$ZSH"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'javascript-gate: FAIL contracts lint — node is not installed' ]
  lacks "$stderr" 'make setup'
}

@test "#2640: no contracts/vN/openapi.yaml at all is exit 3, silently" {
  run --separate-stderr lint --caller python-gate
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  # a contracts/ tree with no major directory is the same
  mkdir -p "$R/contracts/schemas"
  run --separate-stderr lint --caller python-gate
  [ "$status" -eq 3 ]
  [ ! -s "$CALLS" ]
}

@test "#2640: an unknown argument, a --caller with no value and an empty --caller are each exit 2" {
  mkspec contracts/v1
  run --separate-stderr lint --caller python-gate --out x
  [ "$status" -eq 2 ]
  [ "$stderr" = 'python-gate: unknown argument: --out' ]
  run --separate-stderr lint --caller
  [ "$status" -eq 2 ]
  [ "$stderr" = 'check-contracts-lint: --caller needs a value' ]
  run --separate-stderr lint --caller ''
  [ "$status" -eq 2 ]
  [ "$stderr" = 'check-contracts-lint: --caller needs a value' ]
  [ ! -s "$CALLS" ]
}

@test "#2640: -h and --help print the header comment and exit 0" {
  local flag
  for flag in -h --help; do
    run --separate-stderr lint "$flag"
    [ "$status" -eq 0 ]
    contains "$output" 'check-contracts-lint.zsh — lint this repository'"'"'s newest contract majors'
    contains "$output" 'Exit codes: 0 linted; 1 failed, the reason on stderr; 2 an unknown or malformed argument;'
    # the header only: no code line is printed
    lacks "$output" 'emulate -L zsh'
  done
}

@test "#2640: bootstrap SKILL.md copies both shared checkers on the Go path and stamps them" {
  local skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md" text
  # the copy rule, joined across its wrapped lines
  text="$(tr '\n' ' ' < "$skill" | tr -s ' ')"
  contains "$text" '**Copy** `templates/common/scripts/check-contracts-lint.zsh` → `scripts/check-contracts-lint.zsh` and `templates/common/scripts/check-docs.zsh` → `scripts/check-docs.zsh` (verbatim, no placeholders, `chmod +x`; #2640) — the shared checkers the gate'"'"'s contracts lint and docs stages call with `--caller go-gate`.'
  grep -qxF '| `scripts/check-contracts-lint.zsh` | `common/scripts/check-contracts-lint.zsh` (Go primary only, #2640) |' "$skill"
  grep -qxF '| `scripts/check-docs.zsh` | `common/scripts/check-docs.zsh` (Go primary only, #2640) |' "$skill"
  # both ship executable, as the Go gate runs them through zsh and a consumer may run them directly
  [ -x "$CHECKER" ] && [ -x "$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/check-docs.zsh" ]
}

@test "#2640: the checker hard-codes no gate's name" {
  run ! grep -q 'go-gate' "$CHECKER"
}
