#!/usr/bin/env bats
#
# Behavioral tests for the Python-version detection in detect-stack.sh and
# verify-python-state.sh. Regression net for #271: a no-match `requires-python`
# grep used to trip `set -euo pipefail` and abort before the 3.12 fallback, so
# any Python project without a `requires-python` pin crashed detection.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DETECT="$REPO_ROOT/development/skills/bootstrap/scripts/detect-stack.sh"
  VERIFY="$REPO_ROOT/development/skills/maintenance/scripts/verify-python-state.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q
}

@test "detect-stack: pyproject WITHOUT requires-python -> exit 0, python 3.12 fallback" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .python_version <<<"$out")" = "3.12" ]
  [ "$(jq -r '.languages | index("python")' <<<"$out")" != "null" ]
}

@test "detect-stack: pyproject WITH requires-python -> parsed version" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\nrequires-python = ">=3.13"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .python_version <<<"$out")" = "3.13" ]
}

@test "detect-stack: no pyproject -> exit 0, python not detected" {
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("python")' <<<"$out")" = "null" ]
}

@test "verify-python-state: pyproject WITHOUT requires-python -> exit 0 (no crash)" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  bash "$VERIFY" "$WORK" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}

@test "verify-python-state: Dockerfile without a python FROM -> exit 0 (no crash)" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  printf 'FROM alpine:3.20\n' > Dockerfile
  bash "$VERIFY" "$WORK" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}
