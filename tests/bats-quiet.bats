#!/usr/bin/env bats
#
# Behavioural tests for bats-quiet.zsh (#2059): the quiet wrapper the
# resolve-issue conductor uses for TARGETED bats runs. What these pin down:
#   * bats runs EXACTLY ONCE, as `bats --tap <args…>`;
#   * bats' stdout AND stderr go only to the mktemp log, never to the terminal;
#   * stdout is exactly `N/M passed`, every `not ok` line in TAP order, then
#     `log: <path>` — on green and red alike, with no passing test named;
#   * the wrapper exits with bats' REAL status, and a zero-test run that bats
#     calls green is forced to exit 1;
#   * a missing bats binary exits 127, and no arguments exits 2 — both with an
#     empty stdout and no log file.
#
# `bats` is stubbed via BATS_QUIET_BIN: the stub records each call and its argv,
# emits a canned TAP fixture on stdout and a marker on stderr, and exits a
# chosen code. TMPDIR points at a per-test directory, so "no log file" is a
# count of bats-quiet-tap.* files there.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/bats-quiet.zsh"

  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  export CALLS="$BATS_TEST_TMPDIR/calls"     # one line appended per bats call
  export ARGV="$BATS_TEST_TMPDIR/argv"       # argv of the last bats call
  export TAPFIX="$BATS_TEST_TMPDIR/tap.fix"  # canned TAP the stub emits

  STUB="$BATS_TEST_TMPDIR/bats-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "call" >> "$CALLS"
printf '%s\n' "$*" > "$ARGV"
cat "$TAPFIX"
echo "stub-stderr-marker" >&2
exit "${STUB_EXIT:-0}"
EOF
  chmod +x "$STUB"
  export BATS_QUIET_BIN="$STUB"
}

# The log files the wrapper left in TMPDIR, one per line.
_logs() {
  find "$TMPDIR" -name 'bats-quiet-tap.*' -type f
}

_calls() {
  if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi
}

@test "green: one bats --tap call, N/M passed then the log line, full TAP in the log" {
  printf '%s\n' '1..3' 'ok 1 first' 'ok 2 second # skip not today' 'ok 3 third' > "$TAPFIX"
  run --separate-stderr "$S" tests/run-gate.bats -f 'zero tests'
  [ "$status" -eq 0 ]
  [ "$(_calls)" -eq 1 ]
  [ "$(cat "$ARGV")" = "--tap tests/run-gate.bats -f zero tests" ]
  local log; log="$(_logs)"
  [ "$(printf '%s\n' "$log" | wc -l | tr -d ' ')" -eq 1 ]
  starts_with "$log" "$TMPDIR/bats-quiet-tap."
  [ "$output" = "$(printf '3/3 passed\nlog: %s' "$log")" ]
  # bats' stdout AND stderr went to the log, and nowhere else
  [ -z "$stderr" ]
  [ "$(cat "$log")" = "$(printf '%s\n' "$(cat "$TAPFIX")" 'stub-stderr-marker')" ]
}

@test "red: bats' exit passes through, each not ok line listed in order, no passing name on stdout" {
  printf '%s\n' '1..4' 'ok 1 alpha passes' 'not ok 2 beta breaks' \
    '# (in test file tests/x.bats, line 9)' 'ok 3 gamma passes' 'not ok 4 delta breaks' > "$TAPFIX"
  STUB_EXIT=1 run --separate-stderr "$S" tests/x.bats
  [ "$status" -eq 1 ]
  [ "$(_calls)" -eq 1 ]
  local log; log="$(_logs)"
  [ "$output" = "$(printf '2/4 passed\nnot ok 2 beta breaks\nnot ok 4 delta breaks\nlog: %s' "$log")" ]
  lacks "$output" "alpha"
  lacks "$output" "gamma"
  lacks "$output" "# (in test file"
  [ -z "$stderr" ]
  [ "$(cat "$log")" = "$(printf '%s\n' "$(cat "$TAPFIX")" 'stub-stderr-marker')" ]
}

@test "red: an unusual bats exit code is passed through unchanged, not normalised" {
  printf '%s\n' '1..1' 'not ok 1 only' > "$TAPFIX"
  STUB_EXIT=5 run --separate-stderr "$S" tests/x.bats
  [ "$status" -eq 5 ]
  starts_with "$output" "0/1 passed"
}

@test "zero tests while bats exits 0: forced to exit 1 with the refusing message" {
  printf '%s\n' '1..0' > "$TAPFIX"
  run --separate-stderr "$S" tests/empty.bats
  [ "$status" -eq 1 ]
  [ "$stderr" = "bats-quiet: 0 tests ran; refusing to report green (forcing exit 1)." ]
  [ "$output" = "$(printf '0/0 passed\nlog: %s' "$(_logs)")" ]
}

@test "zero tests while bats exits non-zero: bats' own status stands, no forcing message" {
  printf '%s\n' '1..0' > "$TAPFIX"
  STUB_EXIT=3 run --separate-stderr "$S" tests/empty.bats
  [ "$status" -eq 3 ]
  [ -z "$stderr" ]
}

@test "bats missing: exit 127, the install hint on stderr, empty stdout, no log file" {
  export BATS_QUIET_BIN="$BATS_TEST_TMPDIR/no-such-bats"
  run -127 --separate-stderr "$S" tests/x.bats
  [ "$status" -eq 127 ]
  [ -z "$output" ]
  [ "$stderr" = "bats-quiet: bats binary not found ('$BATS_TEST_TMPDIR/no-such-bats'). Install it (brew install bats-core)." ]
  [ -z "$(_logs)" ]
}

@test "no arguments: exit 2, a usage line on stderr, empty stdout, no log file, bats never called" {
  run --separate-stderr "$S"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  starts_with "$stderr" "usage: bats-quiet.zsh"
  [ -z "$(_logs)" ]
  [ "$(_calls)" -eq 0 ]
}

@test "an argument that would override --tap: exit 2 naming it, empty stdout, no log file, bats never called" {
  local a
  for a in -p --pretty -F --formatter --formatter=junit -c --count -h --help -v --version; do
    rm -f "$CALLS"
    run --separate-stderr "$S" tests/x.bats "$a"
    [ "$status" -eq 2 ] || { echo "status $status for $a" >&2; return 1; }
    [ -z "$output" ]
    [ "$stderr" = "bats-quiet: '$a' is not allowed (the wrapper forces --tap)" ]
    [ -z "$(_logs)" ]
    [ "$(_calls)" -eq 0 ]
  done
}
