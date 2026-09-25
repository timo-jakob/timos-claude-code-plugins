#!/usr/bin/env bats
#
# Behavioral tests for scripts/flake-hunt.zsh — the load-dependent flake hunt
# (#1796). bats and parallel are stubbed through the script's seams, so no real
# suite runs: the stub bats emits canned TAP chosen per iteration, and records
# what it was invoked with, from where, its own pid (the leader of its process
# group) and what the harness's load group looked like while it ran.

bats_require_minimum_version 1.5.0

load assertions

# A cleanup that misses a process group does not fail, it hangs (waiting on a
# busy loop that never ends): turn that into a red test instead. Generous, since
# each test takes seconds even under a loaded gate.
BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-120}"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HUNT="$REPO_ROOT/scripts/flake-hunt.zsh"
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB" "$BATS_TEST_TMPDIR/tmp"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  # one CPU unless a test is about the load: every burner a test starts is
  # contention for whatever else the gate is running beside it
  export FLAKE_HUNT_NPROC=1

  # A GNU parallel that only answers the probe.
  printf '#!/bin/sh\necho "GNU parallel 20260822"\n' > "$STUB/parallel"
  chmod +x "$STUB/parallel"
  export FLAKE_HUNT_PARALLEL_BIN="$STUB/parallel"

  # The stub bats. Each call is one iteration n: it bumps a counter, records its
  # argv, cwd, LC_ALL and pid, prints $STUB/tap.<n> (else $STUB/tap.default) and
  # exits with $STUB/rc.<n> (else 0 when the TAP has no `not ok`, 1 when it has).
  #   STUB_SLEEP=S    hang for S seconds after printing (the signal tests)
  #   STUB_STRAY=1    leave a `sleep` behind in its own process group
  #   STUB_OWN_PG=1   start a child `sleep` in a NEW process group, as GNU
  #                   parallel does for each bats job
  #   STUB_STUBBORN=1 start a child in a new group that IGNORES TERM, so only
  #                   the harness's KILL step can end it
  #   STUB_IGNORE_TERM=1  the stub itself (and what it starts) ignores TERM, so
  #                   its tree outlives the TERM grace period into the KILL step
  cat > "$STUB/bats" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
[ -n "${STUB_IGNORE_TERM:-}" ] && trap '' TERM
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$d/count"
printf '%s\n' "$*" > "$d/argv"
pwd > "$d/cwd"
printf '%s\n' "${LC_ALL:-unset}" > "$d/lc_all"
echo "$$" > "$d/bats.pid"
# the harness's own load group (perl and env exec, so the harness is this stub's
# parent): its id, how many processes it holds, and how many are running
ps -A -o ppid=,pgid=,command= \
  | awk -v p="$PPID" '$1 == p && /flake-hunt-load/ { print $2 }' > "$d/load.pgid"
ps -A -o pgid=,stat= | awk -v g="$(cat "$d/load.pgid")" \
  '$1 == g { all++; if ($2 ~ /^R/) run++ } END { print all + 0, run + 0 }' > "$d/load.procs"
ls "$TMPDIR" > "$d/tmpdir.during"
# each pid file is written whole (temp + mv), so a reader never sees it empty
if [ -n "${STUB_STRAY:-}" ]; then
  sleep 300 & echo "$!" > "$d/stray.tmp"; mv "$d/stray.tmp" "$d/stray.pid"
fi
if [ -n "${STUB_STUBBORN:-}" ]; then
  perl -e 'setpgrp(0, 0); $SIG{TERM} = "IGNORE"; sleep 300' &
  echo "$!" > "$d/stubborn.tmp"; mv "$d/stubborn.tmp" "$d/stubborn.pid"
fi
if [ -n "${STUB_OWN_PG:-}" ]; then
  perl -e 'setpgrp(0, 0); exec @ARGV' sleep 300 &
  echo "$!" > "$d/own.tmp"; mv "$d/own.tmp" "$d/own.pid"
fi
tap="$d/tap.default"; [ -f "$d/tap.$n" ] && tap="$d/tap.$n"
cat "$tap"
[ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
if [ -f "$d/rc.$n" ]; then exit "$(cat "$d/rc.$n")"; fi
if grep -q '^not ok' "$tap"; then exit 1; fi
exit 0
EOF
  chmod +x "$STUB/bats"
  export FLAKE_HUNT_BATS_BIN="$STUB/bats"

  printf '1..2\nok 1 alpha\nok 2 beta\n' > "$STUB/tap.default"
  A="$BATS_TEST_TMPDIR/a.bats"
  B="$BATS_TEST_TMPDIR/b.bats"
  : > "$A"
  : > "$B"
}

# Whatever a failed test left running: every process whose argv names this
# test's temp dir (the harness and the stub bats both do), every load group one
# of them started, and the strays the stub recorded. Without this, a harness
# whose cleanup regressed outlives its test, holds bats' output pipe open, and
# hangs the whole suite rather than failing one test.
teardown() {
  local pids p g
  for p in "$STUB/stray.pid" "$STUB/own.pid" "$STUB/stubborn.pid"; do
    [ -f "$p" ] && kill -KILL "$(cat "$p")" 2>/dev/null
  done
  # the load group the stub saw: once the harness has exited, nothing else
  # leads here, and a leaked load holds bats' output pipe open
  [ -s "$STUB/load.pgid" ] && kill -KILL -- "-$(cat "$STUB/load.pgid")" 2>/dev/null
  pids="$(pgrep -f -- "$BATS_TEST_TMPDIR" || true)"
  [ -n "$pids" ] || return 0
  # only a load leader's group: one still held before its setpgrp shares the
  # harness's group, which is this test's own, so it is ended by pid below
  for g in $(ps -A -o pid=,ppid=,pgid=,command= | awk -v ps=" $(echo $pids) " \
      'index(ps, " " $2 " ") && $1 == $3 && /flake-hunt-load/ { print $3 }' | sort -u); do
    kill -KILL -- "-$g" 2>/dev/null || true
  done
  for p in $pids; do kill -KILL "$p" 2>/dev/null || true; done
  return 0
}

# The load process group the harness announced on stderr.
load_pg() { sed -nE 's/^flake-hunt: load process group ([0-9]+) .*/\1/p' "$1"; }

# True when no process of group $1 is left (a pid works too).
group_gone() { ! kill -0 -- "-$1" 2>/dev/null; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }

# --- the report ---------------------------------------------------------------

@test "flake-hunt: a test failing in some iterations is reported as <file>: <name>: <fails>/<iterations>" {
  # ...followed by its FIRST failure's diagnostics only
  printf '1..3\nok 1 alpha\nnot ok 2 beta\n# (in test file %s, line 7)\n#   first failure diag\nok 3 gamma\n' \
    "$A" > "$STUB/tap.1"
  printf '1..2\nok 1 alpha\nnot ok 2 beta\n# (in test file %s, line 7)\n#   second failure diag\n' \
    "$A" > "$STUB/tap.3"
  run --separate-stderr zsh "$HUNT" --iterations 3 "$A" "$B"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "$A: beta: 2/3" ]
  [ "${lines[1]}" = "# (in test file $A, line 7)" ]
  [ "${lines[2]}" = "#   first failure diag" ]
  [ "${#lines[@]}" -eq 3 ]
  lacks "$output" "second failure diag"
  contains "$stderr" "iteration 1/3: 1 not ok of 3 (bats exit 1)"
  contains "$stderr" "iteration 2/3: 0 not ok of 2 (bats exit 0)"
  contains "$stderr" "1 test(s) failed at least once in 3 iterations"
}

@test "flake-hunt: tests are ordered by failure count, most first, each keyed by its own file" {
  printf '1..2\nnot ok 1 alpha\n# (in test file %s, line 3)\nnot ok 2 beta\n# (in test file %s, line 9)\n' \
    "$A" "$B" > "$STUB/tap.1"
  printf '1..2\nok 1 alpha\nnot ok 2 beta\n# (in test file %s, line 9)\n' "$B" > "$STUB/tap.2"
  run --separate-stderr zsh "$HUNT" --iterations 2 "$A" "$B"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "$B: beta: 2/2" ]
  [ "${lines[2]}" = "$A: alpha: 1/2" ]
}

@test "flake-hunt: the order is numeric: 10 failures rank above 2" {
  printf '1..2\nnot ok 1 alpha\n# (in test file %s, line 3)\nok 2 beta\n' "$A" > "$STUB/tap.default"
  printf '1..2\nnot ok 1 alpha\n# (in test file %s, line 3)\nnot ok 2 beta\n# (in test file %s, line 9)\n' \
    "$A" "$A" > "$STUB/tap.1"
  cp "$STUB/tap.1" "$STUB/tap.2"
  run --separate-stderr zsh "$HUNT" --iterations 10 "$A"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "$A: alpha: 10/10" ]
  [ "${lines[2]}" = "$A: beta: 2/10" ]
}

@test "flake-hunt: a diagnostic naming no test file falls back to the single named file" {
  printf '1..1\nnot ok 1 alpha\n#   no location here\n' > "$STUB/tap.1"
  run --separate-stderr zsh "$HUNT" --iterations 1 "$A"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "$A: alpha: 1/1" ]
}

@test "flake-hunt: with several files named, a diagnostic naming no test file reports unknown file" {
  printf '1..1\nnot ok 1 alpha\n#   no location here\n' > "$STUB/tap.1"
  run --separate-stderr zsh "$HUNT" --iterations 1 "$A" "$B"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "unknown file: alpha: 1/1" ]
  # and every named file reached bats, not just the first
  [ "$(cat "$STUB/argv")" = "--jobs 4 --tap $A $B" ]
}

@test "flake-hunt: a failure by timeout and one by assertion count as the same test" {
  printf '1..1\nnot ok 1 alpha # timeout after 20s\n# (in test file %s, line 3)\n' "$A" > "$STUB/tap.1"
  printf '1..1\nnot ok 1 alpha\n# (in test file %s, line 3)\n' "$A" > "$STUB/tap.2"
  run --separate-stderr zsh "$HUNT" --iterations 2 "$A"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "$A: alpha: 2/2" ]
  lacks "$output" "timeout after 20s:"
}

@test "flake-hunt: a test file whose path holds a space is attributed by its full path" {
  mkdir -p "$BATS_TEST_TMPDIR/dir with space"
  C="$BATS_TEST_TMPDIR/dir with space/c.bats"
  : > "$C"
  printf '1..1\nnot ok 1 alpha\n# (in test file %s, line 4)\n' "$C" > "$STUB/tap.1"
  run --separate-stderr zsh "$HUNT" --iterations 1 "$A" "$C"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "$C: alpha: 1/1" ]
}

@test "flake-hunt: every test green in every iteration exits 0 with an empty report" {
  run --separate-stderr zsh "$HUNT" --iterations 2 "$A"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  contains "$stderr" "no test failed in 2 iterations"
  [ "$(cat "$STUB/count")" = 2 ]
}

# --- the contention -----------------------------------------------------------

@test "flake-hunt: bats runs oversubscribed (--jobs = CPU count x multiplier) under LC_ALL=C" {
  FLAKE_HUNT_NPROC=2 run --separate-stderr zsh "$HUNT" --iterations 1 --job-multiplier 3 "$A"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/argv")" = "--jobs 6 --tap $A" ]
  [ "$(cat "$STUB/lc_all")" = C ]
}

@test "flake-hunt: the load group holds one running busy loop per CPU before the first iteration starts" {
  FLAKE_HUNT_NPROC=2 run --separate-stderr zsh "$HUNT" --iterations 1 "$A"
  [ "$status" -eq 0 ]
  # the waiting leader plus FLAKE_HUNT_NPROC=2 burners, both of them running
  [ "$(cat "$STUB/load.procs")" = "3 2" ]
}

@test "flake-hunt: with no FLAKE_HUNT_NPROC, the CPU count is the host's" {
  unset FLAKE_HUNT_NPROC
  run --separate-stderr zsh "$HUNT" --iterations 1 --job-multiplier 1 "$A"
  [ "$status" -eq 0 ]
  cpus="$(getconf _NPROCESSORS_ONLN)"
  [ "$(cat "$STUB/argv")" = "--jobs $cpus --tap $A" ]
  contains "$stderr" "($cpus burners)"
}

@test "flake-hunt: an unusable FLAKE_HUNT_NPROC counts as one CPU" {
  FLAKE_HUNT_NPROC=abc run --separate-stderr zsh "$HUNT" --iterations 1 --job-multiplier 3 "$A"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/argv")" = "--jobs 3 --tap $A" ]
}

@test "flake-hunt: with no files named, the whole suite runs from the repo root, whatever the cwd" {
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr zsh "$HUNT" --iterations 1
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/argv")" = "--jobs 4 --tap tests" ]
  [ "$(cat "$STUB/cwd")" = "$REPO_ROOT" ]
}

@test "flake-hunt: with no --iterations, it runs 20" {
  printf '1..0\n' > "$STUB/tap.2"
  run --separate-stderr zsh "$HUNT" "$A"
  [ "$status" -eq 3 ]
  contains "$stderr" "iteration 1/20:"
}

# --- broken iterations: never a clean report -----------------------------------

@test "flake-hunt: an iteration that ran zero tests is broken: exit 3, and the load is still ended" {
  printf '1..0\n' > "$STUB/tap.2"
  run --separate-stderr zsh "$HUNT" --iterations 3 "$A"
  [ "$status" -eq 3 ]
  contains "$stderr" "iteration 2 is broken (it ran ZERO tests"
  [ "$(cat "$STUB/count")" = 2 ]
  pg="$(load_pg <(printf '%s\n' "$stderr"))"
  [ -n "$pg" ]
  group_gone "$pg"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "flake-hunt: an iteration that ran fewer tests than its plan is broken, exit 3" {
  printf '1..3\nok 1 alpha\nok 2 beta\n' > "$STUB/tap.1"
  echo 1 > "$STUB/rc.1"
  run --separate-stderr zsh "$HUNT" --iterations 2 "$A"
  [ "$status" -eq 3 ]
  contains "$stderr" "iteration 1 is broken (it ran 2 of 3 planned tests"
  [ -z "$output" ]
}

@test "flake-hunt: an iteration where bats failed with no failing test is broken, exit 3" {
  echo 1 > "$STUB/rc.1"
  run --separate-stderr zsh "$HUNT" --iterations 2 "$A"
  [ "$status" -eq 3 ]
  contains "$stderr" "iteration 1 is broken (bats exited 1 with no failing test)"
  lacks "$stderr" "no test failed"
}

# --- usage and prerequisites ----------------------------------------------------

@test "flake-hunt: --iterations 0 is a usage error" {
  run --separate-stderr zsh "$HUNT" --iterations 0 "$A"
  [ "$status" -eq 2 ]
  contains "$stderr" "--iterations needs a positive integer"
}

@test "flake-hunt: a non-numeric --job-multiplier is a usage error" {
  run --separate-stderr zsh "$HUNT" --job-multiplier x "$A"
  [ "$status" -eq 2 ]
  contains "$stderr" "--job-multiplier needs a positive integer"
}

@test "flake-hunt: --iterations with no value is a usage error" {
  run --separate-stderr zsh "$HUNT" --iterations
  [ "$status" -eq 2 ]
  contains "$stderr" "--iterations needs a positive integer"
}

@test "flake-hunt: --job-multiplier with no value is a usage error" {
  run --separate-stderr zsh "$HUNT" --job-multiplier
  [ "$status" -eq 2 ]
  contains "$stderr" "--job-multiplier needs a positive integer"
}

@test "flake-hunt: an unknown flag is a usage error" {
  run --separate-stderr zsh "$HUNT" --bogus
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown argument: --bogus"
}

@test "flake-hunt: a named file that does not exist is a usage error, before any run" {
  run --separate-stderr zsh "$HUNT" "$BATS_TEST_TMPDIR/missing.bats"
  [ "$status" -eq 2 ]
  contains "$stderr" "not a file: $BATS_TEST_TMPDIR/missing.bats"
  [ ! -f "$STUB/count" ]
}

@test "flake-hunt: -- ends the flags" {
  run --separate-stderr zsh "$HUNT" --iterations 1 -- "$A"
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/argv")" = "--jobs 4 --tap $A" ]
}

# The help is the header and only the header (#1839): its first and last lines
# with the `# ` stripped, no shebang, no code from below it, no comment prefix
# left in — a lone `#` included, and grep must answer "no match", not fail.
prints_header_only() {
  local rc=0
  [ "${lines[0]}" = "flake-hunt.zsh — reproduce load-dependent bats failures on demand (#1796)." ]
  [ "${lines[${#lines[@]}-1]}" = "  FLAKE_HUNT_NPROC         the CPU count (burner count and --jobs base)" ]
  lacks "$output" '#!/usr/bin/env zsh'
  lacks "$output" '-h|--help)'
  grep -q '^#' <<< "$output" || rc=$?
  [ "$rc" -eq 1 ]
}

@test "flake-hunt: --help prints the usage" {
  run --separate-stderr zsh "$HUNT" --help
  [ "$status" -eq 0 ]
  contains "$output" "--job-multiplier M"
  prints_header_only
}

@test "flake-hunt: -h prints the usage" {
  run --separate-stderr zsh "$HUNT" -h
  [ "$status" -eq 0 ]
  contains "$output" "--job-multiplier M"
  prints_header_only
}

@test "flake-hunt: a work directory that cannot be created exits 3 before any run" {
  TMPDIR="$BATS_TEST_TMPDIR/no-such-dir" run --separate-stderr zsh "$HUNT" --iterations 1 "$A"
  [ "$status" -eq 3 ]
  contains "$stderr" "could not create a work directory"
  [ ! -f "$STUB/count" ]
}

@test "flake-hunt: a load that never starts exits 3 before any iteration runs" {
  # every tool the harness needs, except the zsh its load group execs
  mkdir -p "$BATS_TEST_TMPDIR/nozsh"
  for t in perl ps awk sleep mktemp grep sed rm getconf head cat; do
    ln -s "$(command -v "$t")" "$BATS_TEST_TMPDIR/nozsh/$t"
  done
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/nozsh" "$(command -v zsh)" "$HUNT" --iterations 1 "$A"
  [ "$status" -eq 3 ]
  contains "$stderr" "did not start its 1 burners"
  [ ! -f "$STUB/count" ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "flake-hunt: a missing bats exits 3 before any load starts" {
  FLAKE_HUNT_BATS_BIN="$STUB/nope" run --separate-stderr zsh "$HUNT" "$A"
  [ "$status" -eq 3 ]
  contains "$stderr" "bats binary not found"
  lacks "$stderr" "load process group"
}

@test "flake-hunt: a missing perl exits 3 before any load starts" {
  # bats and parallel come through their seams; grep is all the probes need
  mkdir -p "$BATS_TEST_TMPDIR/nopath"
  ln -s "$(command -v grep)" "$BATS_TEST_TMPDIR/nopath/grep"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/nopath" "$(command -v zsh)" "$HUNT" "$A"
  [ "$status" -eq 3 ]
  contains "$stderr" "perl not found"
  lacks "$stderr" "load process group"
}

@test "flake-hunt: a non-GNU parallel exits 3 before any load starts" {
  printf '#!/bin/sh\necho "parallel (moreutils)"\n' > "$STUB/parallel"
  run --separate-stderr zsh "$HUNT" "$A"
  [ "$status" -eq 3 ]
  contains "$stderr" "GNU parallel not found"
  lacks "$stderr" "load process group"
}

# --- cleanup --------------------------------------------------------------------

@test "flake-hunt: after a normal exit nothing it started is left, a TERM-proof child included" {
  # ...and the work dir is gone
  # the stub lives 1.5s, long enough to be sampled with its children in place
  STUB_SLEEP=1.5 STUB_STRAY=1 STUB_OWN_PG=1 STUB_STUBBORN=1 \
    run --separate-stderr zsh "$HUNT" --iterations 1 "$A"
  [ "$status" -eq 0 ]
  pg="$(load_pg <(printf '%s\n' "$stderr"))"
  [ -n "$pg" ]
  # the announced id is the real load group, seen live from inside the run
  [ "$(cat "$STUB/load.pgid")" = "$pg" ]
  group_gone "$pg"
  pid_gone "$(cat "$STUB/stray.pid")"
  pid_gone "$(cat "$STUB/own.pid")"
  pid_gone "$(cat "$STUB/stubborn.pid")"
  # the work dir existed during the run, and is gone after it
  matches "$(cat "$STUB/tmpdir.during")" '^flake-hunt[.]'
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "flake-hunt: a reader that closes the pipe early does not strand the load" {
  # head takes the first byte of stderr and exits; the harness's next progress
  # line then hits a closed pipe (SIGPIPE), which must still run the cleanup.
  # SIGPIPE is reset to its default, as an interactive shell starts it: bats
  # itself runs with it ignored, which would turn the signal into a mere EPIPE.
  # (The status is written from inside the pipe: bats' own DEBUG trap resets
  # PIPESTATUS before a later command could read it.)
  { perl -e '$SIG{PIPE} = "DEFAULT"; exec @ARGV' zsh "$HUNT" --iterations 3 "$A" \
      && echo 0 > "$BATS_TEST_TMPDIR/hunt.rc" \
      || echo "$?" > "$BATS_TEST_TMPDIR/hunt.rc"; } 2>&1 >/dev/null | head -c 1 >/dev/null
  [ "$(cat "$BATS_TEST_TMPDIR/hunt.rc")" = 141 ]
  [ -s "$STUB/load.pgid" ]
  group_gone "$(cat "$STUB/load.pgid")"
  [ -z "$(ls -A "$TMPDIR")" ]
}

# A ps wrapper, first on PATH, that reports a new start time on every call for
# one process: exactly as if its pid had been reused by a stranger after the
# harness recorded it. Every other call is the real ps. `own.pid` names the
# stub's own-group child by its pid file; `bats` names the stub bats run by its
# command line, which holds from the fork on (perl and env carry the stub's path
# in their argv too), so no sample can come before the fake applies.
fake_reuse_of() {
  local real_ps is_it
  real_ps="$(command -v ps)"
  case "$1" in
  own.pid) is_it="[ \"\$4\" = \"\$(cat '$STUB/own.pid' 2>/dev/null)\" ]" ;;
  bats) is_it="'$real_ps' -o command= -p \"\$4\" 2>/dev/null | grep -F '$STUB/bats' >/dev/null" ;;
  esac
  mkdir -p "$BATS_TEST_TMPDIR/psbin"
  cat > "$BATS_TEST_TMPDIR/psbin/ps" <<EOF
#!/bin/bash
if [ "\$1 \$2 \$3" = "-o lstart= -p" ] && $is_it; then
  echo "reused \$RANDOM\$RANDOM"; exit 0
fi
exec "$real_ps" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/psbin/ps"
  PSPATH="$BATS_TEST_TMPDIR/psbin:$PATH"
}

@test "flake-hunt: a group whose number now belongs to someone else is never signalled" {
  fake_reuse_of own.pid
  PATH="$PSPATH" STUB_SLEEP=1.5 STUB_OWN_PG=1 \
    run --separate-stderr zsh "$HUNT" --iterations 1 "$A"
  [ "$status" -eq 0 ]
  # a group the harness can no longer prove its own survives it (teardown ends it)
  kill -0 "$(cat "$STUB/own.pid")"
}

@test "flake-hunt: a bats group whose number was reused is never walked, so nothing below it is signalled" {
  fake_reuse_of bats
  PATH="$PSPATH" STUB_SLEEP=1.5 STUB_OWN_PG=1 \
    run --separate-stderr zsh "$HUNT" --iterations 1 "$A"
  [ "$status" -eq 0 ]
  # walking a stranger's root would have found, recorded and ended this group
  kill -0 "$(cat "$STUB/own.pid")"
}

# The harness is started in the background with its signals reset to their
# defaults (a non-interactive shell starts background jobs with SIGINT ignored,
# which is not how a terminal starts it) and caught mid-iteration, with the load
# group, the running bats group and a child the bats run started in a group of
# its own (as GNU parallel does) all alive.
start_and_catch_mid_run() {
  local err="$BATS_TEST_TMPDIR/hunt.err" i
  perl -e '$SIG{INT} = $SIG{TERM} = $SIG{HUP} = "DEFAULT"; exec @ARGV' \
    zsh "$HUNT" --iterations 5 "$A" 2>"$err" &
  hunt=$!
  for i in $(seq 100); do [ -s "$STUB/own.pid" ] && break; sleep 0.1; done
  [ -s "$STUB/own.pid" ]
  lpg="$(load_pg "$err")"
  bpg="$(cat "$STUB/bats.pid")"
  own="$(cat "$STUB/own.pid")"
  [ -n "$lpg" ]
  kill -0 -- "-$lpg"
  kill -0 -- "-$bpg"
  kill -0 "$own"
}
interrupt_mid_run() {
  STUB_SLEEP=30 STUB_OWN_PG=1 start_and_catch_mid_run
  kill "-$1" "$hunt"
  wait "$hunt" && rc=0 || rc=$?
}

@test "flake-hunt: Ctrl-C (INT) mid-run ends every group it started, exit 130" {
  interrupt_mid_run INT
  [ "$rc" -eq 130 ]
  group_gone "$lpg"
  group_gone "$bpg"
  pid_gone "$own"
  [ "$(cat "$STUB/count")" = 1 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "flake-hunt: TERM mid-run ends every group it started, exit 143" {
  interrupt_mid_run TERM
  [ "$rc" -eq 143 ]
  group_gone "$lpg"
  group_gone "$bpg"
  pid_gone "$own"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "flake-hunt: HUP mid-run ends every group it started, exit 129" {
  interrupt_mid_run HUP
  [ "$rc" -eq 129 ]
  group_gone "$lpg"
  group_gone "$bpg"
  pid_gone "$own"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "flake-hunt: the KILL step also spares a group whose number now belongs to someone else" {
  # The stub ignores TERM, so its tree (the own-group child included) is still
  # there when the KILL step walks it again after the grace period.
  fake_reuse_of own.pid
  PATH="$PSPATH" STUB_SLEEP=30 STUB_OWN_PG=1 STUB_IGNORE_TERM=1 start_and_catch_mid_run
  kill -TERM "$hunt"
  wait "$hunt" && rc=0 || rc=$?
  [ "$rc" -eq 143 ]
  group_gone "$lpg"
  group_gone "$bpg"
  kill -0 "$own"
}

@test "flake-hunt: a Ctrl-C during cleanup does not cut it short before the KILL" {
  STUB_SLEEP=30 STUB_OWN_PG=1 STUB_STUBBORN=1 start_and_catch_mid_run
  for i in $(seq 100); do [ -s "$STUB/stubborn.pid" ] && break; sleep 0.1; done
  stubborn="$(cat "$STUB/stubborn.pid")"
  kill -TERM "$hunt"
  # cleanup is now waiting out the TERM-proof child's grace period; a Ctrl-C
  # there must not end the harness before its KILL step runs
  sleep 0.5
  kill -INT "$hunt" 2>/dev/null || true
  wait "$hunt" && rc=0 || rc=$?
  [ "$rc" -eq 143 ]
  pid_gone "$stubborn"
  group_gone "$lpg"
  group_gone "$bpg"
  pid_gone "$own"
}

# A PATH-first perl that holds one launch in the window between the harness's
# fork and perl's setpgrp, where the child is still in the harness's own group
# and a group signal cannot reach it (#1838). STUB_PERL_PAUSE=load|bats picks
# the launch: the load group's argv names flake-hunt-load, the bats run's names
# the stub bats. It records its pid (the launch's $!), writes a ready marker,
# then waits (at most 30s) for a release file before exec'ing the real perl.
# While held it ignores TERM, so only the harness's KILL can end it. Every other
# call is the real perl at once.
signal_in_launch_window() {
  local real_perl i
  real_perl="$(command -v perl)"
  mkdir -p "$BATS_TEST_TMPDIR/perlbin"
  cat > "$BATS_TEST_TMPDIR/perlbin/perl" <<EOF
#!/bin/bash
case "\${STUB_PERL_PAUSE:-}:\$*" in
load:*flake-hunt-load*|bats:*'$STUB/bats'*)
  trap '' TERM
  echo "\$\$" > '$STUB/perl.tmp'; mv '$STUB/perl.tmp' '$STUB/perl.pid'
  : > '$STUB/perl.ready'
  for i in \$(seq 300); do [ -e '$STUB/perl.release' ] && break; sleep 0.1; done
  trap - TERM ;;
esac
exec '$real_perl' "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/perlbin/perl"
  STUB_PERL_PAUSE="$1" perl -e '$SIG{INT} = $SIG{TERM} = $SIG{HUP} = "DEFAULT"; exec @ARGV' \
    env PATH="$BATS_TEST_TMPDIR/perlbin:$PATH" zsh "$HUNT" --iterations 1 "$A" 2>/dev/null &
  hunt=$!
  for i in $(seq 100); do [ -e "$STUB/perl.ready" ] && break; sleep 0.1; done
  [ -e "$STUB/perl.ready" ]
  held="$(cat "$STUB/perl.pid")"
  kill "-$2" "$hunt"
  for i in $(seq 100); do pid_gone "$hunt" && break; sleep 0.1; done
  rc=hung
  if pid_gone "$hunt"; then wait "$hunt" && rc=0 || rc=$?; fi
}

@test "flake-hunt: a bats leader already reaped is never signalled by pid" {
  # the harness reads $ZDOTDIR/.zshenv, so a kill() defined there logs every kill
  mkdir -p "$BATS_TEST_TMPDIR/zdot"
  echo 'kill() { print -r -- "$*" >> "$KILL_LOG"; builtin kill "$@"; }' > "$BATS_TEST_TMPDIR/zdot/.zshenv"
  KILL_LOG="$BATS_TEST_TMPDIR/kill.log" ZDOTDIR="$BATS_TEST_TMPDIR/zdot" \
    run --separate-stderr zsh "$HUNT" --iterations 1 "$A"
  [ "$status" -eq 0 ]
  bpid="$(cat "$STUB/bats.pid")"
  # its group was signalled after the reap; its free pid must not be
  grep -qxF -- "-TERM -- -$bpid" "$BATS_TEST_TMPDIR/kill.log"
  run ! grep -qxF -- "-TERM $bpid" "$BATS_TEST_TMPDIR/kill.log"
  run ! grep -qxF -- "-KILL $bpid" "$BATS_TEST_TMPDIR/kill.log"
}

@test "flake-hunt: INT before the load group's setpgrp still ends its leader, exit 130" {
  signal_in_launch_window load INT
  [ "$rc" = 130 ]
  pid_gone "$held"
  group_gone "$held"
}

@test "flake-hunt: TERM before the load group's setpgrp still ends its leader, exit 143" {
  signal_in_launch_window load TERM
  [ "$rc" = 143 ]
  pid_gone "$held"
  group_gone "$held"
}

@test "flake-hunt: HUP before the load group's setpgrp still ends its leader, exit 129" {
  signal_in_launch_window load HUP
  [ "$rc" = 129 ]
  pid_gone "$held"
  group_gone "$held"
}

@test "flake-hunt: INT before a bats run's setpgrp still ends its leader, exit 130" {
  signal_in_launch_window bats INT
  [ "$rc" = 130 ]
  pid_gone "$held"
  group_gone "$held"
}

@test "flake-hunt: TERM before a bats run's setpgrp still ends its leader, exit 143" {
  # the kill() logger of the reaped-leader test: the held leader gets both halves
  mkdir -p "$BATS_TEST_TMPDIR/zdot"
  echo 'kill() { print -r -- "$*" >> "$KILL_LOG"; builtin kill "$@"; }' > "$BATS_TEST_TMPDIR/zdot/.zshenv"
  export KILL_LOG="$BATS_TEST_TMPDIR/kill.log" ZDOTDIR="$BATS_TEST_TMPDIR/zdot"
  signal_in_launch_window bats TERM
  [ "$rc" = 143 ]
  pid_gone "$held"
  group_gone "$held"
  grep -qxF -- "-TERM $held" "$KILL_LOG"
  grep -qxF -- "-KILL $held" "$KILL_LOG"
}

@test "flake-hunt: HUP before a bats run's setpgrp still ends its leader, exit 129" {
  signal_in_launch_window bats HUP
  [ "$rc" = 129 ]
  pid_gone "$held"
  group_gone "$held"
}
