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
# what the suite saw while it ran: its niceness, and the slot registry
ps -o nice= -p $$ | tr -d ' ' > "$BATS_TEST_TMPDIR/stub-nice"
ls "${STUB_LS_DIR:-${GATE_SLOTS_DIR:-}}" > "$BATS_TEST_TMPDIR/stub-slots" 2>/dev/null
echo $$ > "$BATS_TEST_TMPDIR/stub-pid"
# the gate is the grandparent: gate -> the suite's subshell -> (nice exec) stub
ps -o ppid= -p "$PPID" | tr -d ' ' > "$BATS_TEST_TMPDIR/stub-gate-pid"
cat "$TAPFIX"
[[ -n "${STUB_SLEEP:-}" ]] && sleep "$STUB_SLEEP"
exit "${STUB_EXIT:-0}"
EOF
  chmod +x "$STUB"

  # The slot registry (#1798) is injected per test: the real one is shared by
  # every gate on the host — including the gate that may be running THIS suite,
  # whose own slot would otherwise halve every jobs assertion below.
  export GATE_SLOTS_DIR="$BATS_TEST_TMPDIR/slots"
  LIVE_PIDS=()

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

teardown() {
  (( ${#LIVE_PIDS[@]} )) && kill "${LIVE_PIDS[@]}" 2>/dev/null
  return 0
}

# Print the PID of a running process for the teardown to kill — the CALLER
# records it in LIVE_PIDS, since `$(spawn_live)` runs in a subshell. Spawned
# inside that substitution so it is not this shell's job (no "Terminated" noise
# when teardown kills it); its fds are closed so neither the substitution nor
# bats (fd 3) waits on it.
spawn_live() {
  (sleep 300 </dev/null >/dev/null 2>&1 3>&- & echo $!)
}

# Register one "other live gate": a real, running process (so its PID is alive)
# whose slot records its true start time — exactly what a live gate writes.
live_slot() {
  mkdir -p "$GATE_SLOTS_DIR"
  local p; p="$(spawn_live)"
  LIVE_PIDS+=("$p")    # spawn_live ran in a subshell: record the PID here
  TZ=UTC LC_ALL=C ps -o lstart= -p "$p" > "$GATE_SLOTS_DIR/$p"
}

# A slot whose gate is gone: its PID names no running process.
dead_pid() {
  sleep 0 3>&- &
  local p=$!
  wait "$p"
  echo "$p"
}

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

@test "usage: no TAP temp file (unusable TMPDIR) exits 2, not the bats-missing 127" {
  run_gate TMPDIR="$BATS_TEST_TMPDIR/no-such-dir" GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4
  [ "$status" -eq 2 ]
  contains "$stderr" "could not create a TAP temp file"
}

@test "usage: no exit-code temp file (unusable TMPDIR, --tap-out given) exits 2" {
  run --separate-stderr env GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 TMPDIR="$BATS_TEST_TMPDIR/no-such-dir" \
    zsh "$S" --tests-dir "$TESTS_DIR" --tap-out "$BATS_TEST_TMPDIR/out.tap"
  [ "$status" -eq 2 ]
  contains "$stderr" "could not create an exit-code temp file"
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

# ---- shared CPU budget across concurrent gates (#1798) ----------------------
# The CPU count (GATE_NPROC) and the slot registry (GATE_SLOTS_DIR) are injected;
# "other live gates" are real sleeping processes with correctly-stamped slots,
# so no second gate ever runs.

@test "shared budget: no other live gate -> jobs = CPU count, summary keys unchanged" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=6 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.mode=="parallel" and .jobs==6'
  grep -q -- '--jobs 6' "$ARGV"
  # the machine summary is exactly today's — no field added or dropped
  echo "$output" | jq -e 'keys == (["exit","jobs","mode","not_ok","ok","tap","total","tree"])'
  # a lone gate prints no sharing note
  run ! grep -q 'other live gate' <<< "$stderr"
}

@test "shared budget: the gate holds its own slot while the suite runs, and removes it on a normal exit" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=6 STUB_EXIT=0
  [ "$status" -eq 0 ]
  # the stub saw exactly one slot (the gate's own) while it ran ...
  [ "$(wc -l < "$BATS_TEST_TMPDIR/stub-slots" | tr -d ' ')" -eq 1 ]
  grep -qE '^[0-9]+$' "$BATS_TEST_TMPDIR/stub-slots"
  # ... and none is left behind
  [ -z "$(ls -A "$GATE_SLOTS_DIR")" ]
}

@test "shared budget: a red suite still removes the gate's own slot" {
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=6 STUB_EXIT=1
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$GATE_SLOTS_DIR")" ]
}

@test "shared budget: 3 other live gates on 10 CPUs -> jobs = floor(10/4) = 2, reported in the summary" {
  live_slot; live_slot; live_slot
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=10 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.mode=="parallel" and .jobs==2'
  grep -q -- '--jobs 2' "$ARGV"
  contains "$stderr" "3 other live gate(s)"
  # live gates' slots are theirs — never pruned
  [ "$(ls "$GATE_SLOTS_DIR" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "shared budget: 1 other live gate on 7 CPUs -> jobs = floor(7/2) = 3 (floor, not round)" {
  live_slot
  # a non-UTC zone for the gate: its slot comparison must not depend on TZ
  run_gate TZ=Pacific/Auckland GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=7 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.jobs==3'
  grep -q -- '--jobs 3' "$ARGV"
}

@test "shared budget: more live gates than CPUs -> jobs floored to 1, sequential, and the gate never waits" {
  live_slot; live_slot; live_slot; live_slot; live_slot
  SECONDS=0
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=2 STUB_EXIT=0
  [ "$SECONDS" -lt 10 ]
  [ "$status" -eq 0 ]
  # it ran the suite at once, at a share of one job — no slot to wait for
  [ "$(calls)" -eq 1 ]
  echo "$output" | jq -e '.jobs==1 and .mode=="sequential" and .ok==3'
  run ! grep -q -- '--jobs' "$ARGV"
}

@test "shared budget: a one-job share on a multi-core host without GNU parallel is still DEGRADED" {
  live_slot; live_slot; live_slot
  run_gate GATE_PARALLEL_BIN="no-such-parallel-xyz" GATE_NPROC=2 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.jobs==1 and .mode=="sequential-degraded"'
  # the slowdown is the CPU count's, not the one-job share's
  contains "$stderr" "2x slower on this 2-core machine"
}

@test "shared budget: an orphaned slot (dead PID) is NOT counted and is removed" {
  mkdir -p "$GATE_SLOTS_DIR"
  local dead; dead="$(dead_pid)"
  echo "Thu Jan  1 00:00:00 1970" > "$GATE_SLOTS_DIR/$dead"
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=8 STUB_EXIT=0
  [ "$status" -eq 0 ]
  # counting the orphan would halve the share to 4
  echo "$output" | jq -e '.jobs==8'
  [ ! -e "$GATE_SLOTS_DIR/$dead" ]
}

@test "shared budget: a slot whose PID was REUSED (start time differs) is an orphan too" {
  mkdir -p "$GATE_SLOTS_DIR"
  local p; p="$(spawn_live)"
  LIVE_PIDS+=("$p")
  # a live PID, but not the process that wrote this slot
  echo "Thu Jan  1 00:00:00 1970" > "$GATE_SLOTS_DIR/$p"
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=8 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.jobs==8'
  [ ! -e "$GATE_SLOTS_DIR/$p" ]
}

@test "shared budget: a live gate beside an orphan counts once — the orphan is pruned, the live slot kept" {
  live_slot
  local live="${LIVE_PIDS[0]}" dead; dead="$(dead_pid)"
  echo "Thu Jan  1 00:00:00 1970" > "$GATE_SLOTS_DIR/$dead"
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=8 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.jobs==4'
  [ -e "$GATE_SLOTS_DIR/$live" ]
  [ ! -e "$GATE_SLOTS_DIR/$dead" ]
}

@test "shared budget: a non-PID file in the registry is neither counted nor removed" {
  mkdir -p "$GATE_SLOTS_DIR"
  echo x > "$GATE_SLOTS_DIR/README"
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=8 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.jobs==8'
  [ -e "$GATE_SLOTS_DIR/README" ]
}

@test "shared budget: an unusable registry is not fatal — all CPUs, unshared, said on stderr" {
  echo "not a dir" > "$BATS_TEST_TMPDIR/slotfile"
  run_gate GATE_SLOTS_DIR="$BATS_TEST_TMPDIR/slotfile" GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=6 STUB_EXIT=0
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.jobs==6 and .ok==3'
  contains "$stderr" "slot registry unusable"
}

@test "shared budget: the suite runs under nice (10 above the gate's own niceness, capped at 19)" {
  local base; base="$(ps -o nice= -p $$ | tr -d ' ')"
  local want=$(( base + 10 )); (( want > 19 )) && want=19
  run_gate GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_EXIT=0
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/stub-nice")" -eq "$want" ]
}

# Start a gate in the background whose suite blocks, wait until the suite runs,
# send $1, and leave $gate_rc / $gate_pid / $suite_pid for the caller to assert.
signal_gate() {
  env -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_SLEEP=60 \
    zsh "$S" --tests-dir "$TESTS_DIR" >/dev/null 2>&1 3>&- &
  gate_pid=$!
  local i
  for i in $(seq 1 100); do
    [ -s "$BATS_TEST_TMPDIR/stub-pid" ] && break
    sleep 0.1
  done
  suite_pid="$(cat "$BATS_TEST_TMPDIR/stub-pid")"
  [ -e "$GATE_SLOTS_DIR/$gate_pid" ]     # registered while the suite runs
  kill -"$1" "$gate_pid"
  gate_rc=0
  wait "$gate_pid" || gate_rc=$?
  # the suite was forwarded the signal; give it a moment to go
  for i in $(seq 1 50); do
    kill -0 "$suite_pid" 2>/dev/null || break
    sleep 0.1
  done
}

@test "shared budget: SIGTERM removes the gate's own slot at once and stops its suite" {
  SECONDS=0
  signal_gate TERM
  [ "$gate_rc" -eq 143 ]
  [ ! -e "$GATE_SLOTS_DIR/$gate_pid" ]
  run ! kill -0 "$suite_pid"
  # at once — not after the 60 s suite would have finished by itself
  [ "$SECONDS" -lt 30 ]
}

@test "shared budget: SIGINT removes the gate's own slot at once and stops its suite" {
  SECONDS=0
  signal_gate INT
  [ "$gate_rc" -eq 130 ]
  [ ! -e "$GATE_SLOTS_DIR/$gate_pid" ]
  run ! kill -0 "$suite_pid"
  [ "$SECONDS" -lt 30 ]
}

@test "shared budget: SIGHUP removes the gate's own slot at once and stops its suite" {
  SECONDS=0
  signal_gate HUP
  [ "$gate_rc" -eq 129 ]
  [ ! -e "$GATE_SLOTS_DIR/$gate_pid" ]
  run ! kill -0 "$suite_pid"
  [ "$SECONDS" -lt 30 ]
}

@test "shared budget: the default registry is TMPDIR's per-user run-gate-slots.<uid>" {
  local tmp="$BATS_TEST_TMPDIR/tmp"
  GATE_SLOTS_DIR="$tmp/run-gate-slots.$(id -u)"
  live_slot
  run --separate-stderr env -u GATE_SLOTS_DIR -u GATE_NPROC -u GATE_PARALLEL_BIN TMPDIR="$tmp" \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=8 STUB_EXIT=0 \
    zsh "$S" --tests-dir "$TESTS_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.jobs==4'
  contains "$stderr" "1 other live gate(s)"
}

@test "shared budget: with TMPDIR unset the registry falls back to /tmp/run-gate-slots.<uid>" {
  run --separate-stderr env -u GATE_SLOTS_DIR -u TMPDIR -u GATE_NPROC -u GATE_PARALLEL_BIN \
    GATE_BATS_BIN="$STUB" CALLS="$CALLS" ARGV="$ARGV" TAPFIX="$TAPFIX" \
    STUB_LS_DIR="/tmp/run-gate-slots.$(id -u)" \
    GATE_PARALLEL_BIN="$PAR_GNU" GATE_NPROC=4 STUB_EXIT=0 \
    zsh "$S" --tests-dir "$TESTS_DIR"
  [ "$status" -eq 0 ]
  # the gate's own slot was in /tmp's registry while its suite ran
  grep -qx "$(cat "$BATS_TEST_TMPDIR/stub-gate-pid")" "$BATS_TEST_TMPDIR/stub-slots"
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
