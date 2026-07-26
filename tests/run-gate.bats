#!/usr/bin/env bats
#
# Behavioural tests for run-gate.zsh (#980): the single blessed bats-gate
# runner for /development:resolve-issue. What these pin down:
#   * the suite runs EXACTLY ONCE per invocation (no double-run for counting),
#     across the green, red AND degraded paths;
#   * ok/not-ok counts come from the TAP and are correct (asserted with jq on
#     the machine-readable stdout summary, not a substring grep);
#   * STREAM SEPARATION: the JSON summary is the sole thing on stdout, while the
#     TAP mirror and the DEGRADED warning go to stderr;
#   * run-gate exits with the suite's REAL exit code (green 0, red non-zero),
#     and a run that reports ZERO tests is FORCED to a non-zero (red) exit;
#   * job count is derived from the CPU count (getconf), floored/guarded, and
#     passed to bats as --jobs;
#   * GNU parallel absent (or a non-GNU `parallel`, e.g. moreutils) ->
#     sequential-degraded: real exit, a LOUD stderr warning, and the machine
#     marker — while a 1-core host is plain `sequential`, never degraded.
#
# `bats` is stubbed via GATE_BATS_BIN (fast, deterministic; the stub records
# each call, emits a canned TAP fixture, exits a chosen code). `parallel`
# GNU-ness is forced via GATE_PARALLEL_BIN (a stub whose --version prints "GNU
# parallel" = present; a non-GNU stub or a missing name = absent), and the core
# count via GATE_NPROC — so the tests never depend on the host.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/run-gate.zsh"

  TESTS_DIR="$BATS_TEST_TMPDIR/tests"; mkdir -p "$TESTS_DIR"

  CALLS="$BATS_TEST_TMPDIR/calls"      # one line appended per bats invocation
  ARGV="$BATS_TEST_TMPDIR/argv"        # argv of the last bats invocation
  TAPFIX="$BATS_TEST_TMPDIR/tap.fix"   # canned TAP the stub emits

  STUB="$BATS_TEST_TMPDIR/bats-stub.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "call" >> "$CALLS"
printf '%s\n' "$*" > "$ARGV"
cat "$TAPFIX"
exit "${STUB_EXIT:-0}"
EOF
  chmod +x "$STUB"

  # A "GNU parallel present" seam target: its --version says so.
  PAR_GNU="$BATS_TEST_TMPDIR/parallel-gnu"
  cat > "$PAR_GNU" <<'EOF'
#!/usr/bin/env bash
echo "GNU parallel 20260722"
EOF
  chmod +x "$PAR_GNU"

  # A NON-GNU `parallel` (moreutils-style): exists, but --version is not GNU.
  PAR_NONGNU="$BATS_TEST_TMPDIR/parallel-moreutils"
  cat > "$PAR_NONGNU" <<'EOF'
#!/usr/bin/env bash
echo "parallel from moreutils 0.68"
EOF
  chmod +x "$PAR_NONGNU"

  # default: a green 3-ok TAP
  cat > "$TAPFIX" <<'EOF'
1..3
ok 1 first
ok 2 second
ok 3 third
EOF
}

# run-gate with stdout/stderr SEPARATED ($output=stdout JSON, $stderr=TAP+warn).
# `env -u` clears any ambient GATE_* the host shell exported, so the unset-derivation
# test is honest; a caller re-setting them via "$@" still wins (env is left-to-right).
run_gate() {  # extra env pairs precede the fixed ones
  run --separate-stderr env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    "$@" \
    zsh "$S" --tests-dir "$TESTS_DIR"
}

calls() { wc -l < "$CALLS" | tr -d ' '; }

# ---- usage / preconditions --------------------------------------------------

@test "usage: unknown flag exits 2" {
  run env GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    zsh "$S" --bogus
  [ "$status" -eq 2 ]
}

@test "usage: missing tests dir exits 2" {
  run env GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    zsh "$S" --tests-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
}

@test "usage: unwritable --tap-out exits 2 (not a misread red suite)" {
  run env GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 \
    zsh "$S" --tests-dir "$TESTS_DIR" --tap-out "$BATS_TEST_TMPDIR/nodir/x.tap"
  [ "$status" -eq 2 ]
}

@test "missing bats binary exits 127 — fail-fast, with the install hint and no summary" {
  # `run -127` (not a bare `run` + status check): 127 is the EXPECTED exit here,
  # and declaring it inline is what tells bats the "command not found" is
  # deliberate rather than a typo'd command — otherwise every full-suite run
  # ends in a BW01 advisory block, training the reader to skim past warnings.
  run -127 --separate-stderr env GATE_BATS_BIN="$BATS_TEST_TMPDIR/no-such-bats" \
    zsh "$S" --tests-dir "$TESTS_DIR"
  # Status alone would NOT pin the contract: 127 is what the shell itself
  # returns for a not-found command, so deleting the `command -v` guard and
  # falling through to invoking $bats_bin would still exit 127 and keep this
  # test green. Assert what the guard is FOR — the actionable message, and a
  # fail-fast that emits no summary for a suite that never ran.
  contains "$stderr" "bats binary not found"
  contains "$stderr" "brew install bats-core"
  [ -z "$output" ]
}

@test "--help exits 0 and prints the usage header, not code" {
  run env GATE_BATS_BIN="$STUB" zsh "$S" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'run-gate.zsh'
  # must NOT leak the code that follows the header
  run ! grep -q 'emulate -L zsh' <<< "$output"
}

# ---- green: single run, correct counts, clean stdout ------------------------

@test "green: exit 0, jq counts correct, bats invoked exactly ONCE, stdout is pure JSON" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_EXIT=0
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  # $output is stdout ONLY (separated) and must be a single well-formed JSON obj
  echo "$output" | jq -e '.mode=="parallel" and .ok==3 and .not_ok==0 and .total==3 and .exit==0 and .jobs==4'
  # the default (mktemp) tap path is a real file holding the TAP
  local tapf; tapf="$(echo "$output" | jq -r '.tap')"
  [ -f "$tapf" ]
  grep -q '^ok 1 first' "$tapf"
}

@test "green: TAP + human line go to STDERR, never stdout" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_EXIT=0
  # save captures — a later `run !` clobbers $output/$stderr
  local out="$output" err="$stderr"
  # stdout carries no TAP lines
  run ! grep -qE '^ok |^1\.\.' <<< "$out"
  # stderr carries the mirrored TAP (live progress) AND the human count line
  echo "$err" | grep -q '^ok 1 first'
  echo "$err" | grep -q '^1\.\.3'
  echo "$err" | grep -q 'run-gate: mode=parallel'
}

# ---- red: real exit propagated ----------------------------------------------

@test "red: propagates bats' real non-zero exit, not-ok counted, single run" {
  cat > "$TAPFIX" <<'EOF'
1..3
ok 1 first
not ok 2 second
ok 3 third
EOF
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_EXIT=1
  [ "$status" -eq 1 ]
  [ "$(calls)" -eq 1 ]
  echo "$output" | jq -e '.ok==2 and .not_ok==1 and .total==3 and .exit==1'
}

@test "red: a distinctive exit code is passed through verbatim" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_EXIT=7
  [ "$status" -eq 7 ]
  echo "$output" | jq -e '.exit==7'
}

# ---- zero tests must never read green ---------------------------------------

@test "zero tests (1..0) with a green bats exit is FORCED to a non-zero exit" {
  cat > "$TAPFIX" <<'EOF'
1..0
EOF
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_EXIT=0
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.total==0'
  echo "$stderr" | grep -qi '0 tests ran'
}

# ---- job derivation ---------------------------------------------------------

@test "parallel mode: GATE_NPROC jobs passed to bats as --jobs" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=6 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.mode=="parallel" and .jobs==6'
  grep -q -- '--jobs 6' "$ARGV"
}

@test "job derivation: unset GATE_NPROC derives jobs from getconf (>=1)" {
  local expected; expected="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --argjson n "$expected" '.jobs==$n and .jobs>=1'
}

@test "job derivation: GATE_NPROC=0 is floored to 1 -> sequential, no --jobs" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=0 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.jobs==1 and .mode=="sequential"'
  run ! grep -q -- '--jobs' "$ARGV"
}

@test "job derivation: non-numeric GATE_NPROC -> jobs=1, sequential" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=abc STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.jobs==1 and .mode=="sequential"'
}

@test "1 core with GNU parallel present: sequential (not degraded), no --jobs" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=1 STUB_EXIT=0
  local out="$output" err="$stderr"
  [ "$status" -eq 0 ]
  echo "$out" | jq -e '.mode=="sequential"'
  run ! grep -q -- '--jobs' "$ARGV"
  # a 1-core host must NOT emit the degraded nag
  run ! grep -q 'DEGRADED' <<< "$err"
}

# ---- degraded mode (GNU parallel absent / non-GNU) --------------------------

@test "GNU parallel absent (multi-core): sequential-degraded marker, real exit, single run, no --jobs" {
  run_gate GATE_PARALLEL_BIN="no-such-parallel-xyz" GATE_NPROC=8 STUB_EXIT=0
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  echo "$output" | jq -e '.mode=="sequential-degraded"'
  run ! grep -q -- '--jobs' "$ARGV"
}

@test "non-GNU parallel (moreutils) does NOT count as present -> sequential-degraded" {
  run_gate GATE_PARALLEL_BIN="$PAR_NONGNU" GATE_NPROC=8 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.mode=="sequential-degraded"'
}

@test "degraded: the LOUD warning + brew fix are on STDERR (not stdout)" {
  run_gate GATE_PARALLEL_BIN="no-such-parallel-xyz" GATE_NPROC=8 STUB_EXIT=0
  local out="$output" err="$stderr"
  echo "$err" | grep -q 'DEGRADED'
  echo "$err" | grep -q 'brew install parallel'
  # the machine marker is on stdout, the warning is not
  run ! grep -q 'DEGRADED' <<< "$out"
  echo "$out" | jq -e '.mode=="sequential-degraded"'
}

@test "degraded still fails closed: a red suite -> non-zero exit" {
  run_gate GATE_PARALLEL_BIN="no-such-parallel-xyz" GATE_NPROC=8 STUB_EXIT=1
  [ "$status" -eq 1 ]
  [ "$(calls)" -eq 1 ]
  echo "$output" | jq -e '.mode=="sequential-degraded" and .exit==1'
}

# ---- --tap-out --------------------------------------------------------------

@test "default --tests-dir 'tests' resolves relative to CWD" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/tests"
  cd "$BATS_TEST_TMPDIR/proj"
  run --separate-stderr env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_EXIT=0 \
    zsh "$S"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.total==3'
}

@test "--tap-out: summary tap field equals the supplied path and the file holds the TAP" {
  local tap="$BATS_TEST_TMPDIR/out.tap"
  run --separate-stderr env \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_EXIT=0 \
    zsh "$S" --tests-dir "$TESTS_DIR" --tap-out "$tap"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg t "$tap" '.tap==$t'
  grep -q '^ok 1 first' "$tap"
}

# ---- gate attestation: the `tree` field (#981) ------------------------------
# run-gate captures the working-tree identity so a GREEN caller can hand it to
# the review loop's --gate-attest and skip the byte-identical duplicate re-run.

# a git repo fixture with a tests/ dir; $proj set for the caller to `cd` into.
mk_gitproj() {
  proj="$BATS_TEST_TMPDIR/gitproj"
  mkdir -p "$proj/tests"
  git -C "$proj" init -q
  git -C "$proj" config user.email t@example.com
  git -C "$proj" config user.name tester
  echo base > "$proj/f.txt"
  git -C "$proj" add -A && git -C "$proj" commit -qm base
}

@test "tree is EXACTLY git-tree-id's identity for the working tree (not just 40-hex-shaped)" {
  mk_gitproj
  local TID="$REPO_ROOT/development/skills/resolve-issue/scripts/git-tree-id.zsh"
  local want; want="$(zsh "$TID" "$proj")"
  [ -n "$want" ]
  cd "$proj"
  run --separate-stderr env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    zsh "$S" --tests-dir tests
  [ "$status" -eq 0 ]
  # the attestation must be the ACTUAL identity the loop will re-compute, else
  # exact-match never fires (or false-fires): assert equality, not just shape
  [ "$(echo "$output" | jq -r '.tree')" = "$want" ]
}

@test "tree tracks the working tree: an untracked change makes run-gate report a different tree" {
  mk_gitproj
  cd "$proj"
  run --separate-stderr env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    zsh "$S" --tests-dir tests
  local before; before="$(echo "$output" | jq -r '.tree')"
  echo dirty > "$proj/new-untracked.txt"
  run --separate-stderr env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    zsh "$S" --tests-dir tests
  local after; after="$(echo "$output" | jq -r '.tree')"
  [ -n "$before" ]
  [ "$before" != "$after" ]
}

@test "a RED run is UNATTESTABLE: tree is blanked even in a git repo" {
  mk_gitproj
  cd "$proj"
  run --separate-stderr env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    STUB_EXIT=1 \
    zsh "$S" --tests-dir tests
  [ "$status" -eq 1 ]
  # a failed gate must not yield a matchable attestation, regardless of caller care
  [ "$(echo "$output" | jq -r '.tree')" = "" ]
}

@test "the zero-tests forced-red also blanks tree (no attestation on a 1..0 run)" {
  mk_gitproj
  cat > "$TAPFIX" <<'EOF'
1..0
EOF
  cd "$proj"
  run --separate-stderr env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    zsh "$S" --tests-dir tests
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.tree')" = "" ]
}

@test "tree is the empty string outside a git repo (attestation simply unavailable, never fatal)" {
  local proj="$BATS_TEST_TMPDIR/nonrepo"
  mkdir -p "$proj/tests"
  cd "$proj"
  run --separate-stderr env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    zsh "$S" --tests-dir tests
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.tree')" = "" ]
}

@test "git-tree-id.zsh missing next to run-gate: tree empty, LOUD stderr note, gate still runs (non-fatal)" {
  # copy run-gate.zsh into an isolated dir WITHOUT git-tree-id.zsh beside it, so
  # self_dir/git-tree-id.zsh is absent — the degradation branch (#981).
  local isolated="$BATS_TEST_TMPDIR/isolated"
  mkdir -p "$isolated/tests"
  cp "$S" "$isolated/run-gate.zsh"
  # a real git repo, so tree WOULD be computable were the helper present —
  # proving the empty tree is the missing helper, not a missing repo
  git -C "$isolated" init -q
  git -C "$isolated" config user.email t@example.com
  git -C "$isolated" config user.name tester
  echo x > "$isolated/f.txt"; git -C "$isolated" add -A && git -C "$isolated" commit -qm base
  cd "$isolated"
  run --separate-stderr env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    zsh "$isolated/run-gate.zsh" --tests-dir tests
  [ "$status" -eq 0 ]                                    # non-fatal: the gate verdict is untouched
  [ "$(echo "$output" | jq -r '.tree')" = "" ]          # no attestation
  contains "$stderr" "gate attestation unavailable"   # degradation is LOUD, not silent
}
