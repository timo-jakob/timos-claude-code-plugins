#!/usr/bin/env bats
#
# Behavioural tests for gate-eta.zsh (#2196, epic #2195 child (a)): the
# read-only helper that turns run-gate.zsh's captured stderr into a done/total
# count and a linear time-left estimate. What these pin down:
#   * what it reads: total from the first `1..N` plan line, done as
#     count(^ok ) + count(^not ok ), jobs and the start epoch from the
#     `run-gate: start` line only, wall_s from the count line;
#   * the state order no-plan -> finished -> withheld -> running, and each
#     state's numbers, with the clock pinned through GATE_ETA_NOW;
#   * that the count line ends the gate (#2264): finished even short of the
#     plan, and elapsed fixed at its wall_s in every state;
#   * --started, which serves a TAP-only log and beats the start line;
#   * the human line and the --json object;
#   * exit 0 whenever the log was read, exit 2 (nothing on stdout) otherwise;
#   * that it writes nothing and leaves the log untouched;
#   * end to end, that it reads what the real run-gate.zsh prints.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  G="$REPO_ROOT/development/skills/resolve-issue/scripts/gate-eta.zsh"
  START=1791360000
  NOW=1791360552     # 552 s = 9m12s after START
  LOG="$BATS_TEST_TMPDIR/gate.stderr"
}

# mk_log <total|-> <done> [<epoch> <jobs>]: a captured run-gate stderr — the
# start line when an epoch is given, the plan line unless total is `-`, then
# <done> passing tests.
mk_log() {
  local total="$1" n="$2" i
  {
    if [ -n "${3-}" ]; then
      echo "run-gate: start epoch=$3 mode=parallel scope=full jobs=$4"
    fi
    if [ "$total" != "-" ]; then
      echo "1..$total"
    fi
    for ((i = 1; i <= n; i++)); do echo "ok $i suite test $i"; done
  } > "$LOG"
}

eta() {  # gate-eta with the clock pinned to $NOW (or $AT when set)
  run --separate-stderr env GATE_ETA_NOW="${AT:-$NOW}" zsh "$G" "$@"
}

# ---- running ----------------------------------------------------------------

@test "running: the worked example's human line, exactly" {
  mk_log 1830 412 "$START" 4
  eta --log "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "412/1830 tests, 9m12s elapsed, ~31m40s left (jobs=4)" ]
  [ -z "$stderr" ]
}

@test "running: the worked example's --json object, exactly" {
  mk_log 1830 412 "$START" 4
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:412, total:1830, elapsed_s:552, eta_s:1900, jobs:4, state:"running"}' <<< "$output"
}

@test "running: eta rounds to the nearest second, half up" {
  # 10 of 20 done after 3 s: 3 x 10 / 10 = 3 exactly; 7 of 20 after 5 s:
  # 5 x 13 / 7 = 9.29 -> 9; 6 of 20 after 5 s: 5 x 14 / 6 = 11.67 -> 12;
  # 8 of 20 after 5 s: 5 x 12 / 8 = 7.5 -> 8
  local spec n at want
  for spec in "10 3 3" "7 5 9" "6 5 12" "8 5 8"; do
    read -r n at want <<< "$spec"
    mk_log 20 "$n" "$START" 2
    AT=$((START + at)) eta --log "$LOG" --json
    [ "$status" -eq 0 ]
    jq -e --argjson w "$want" '.state == "running" and .eta_s == $w' <<< "$output"
  done
}

@test "running: a clock behind the start epoch reads as 0 elapsed, never negative" {
  mk_log 20 10 "$START" 2
  AT=$((START - 30)) eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.elapsed_s == 0 and .eta_s == 0 and .state == "running"' <<< "$output"
}

# ---- what it reads ----------------------------------------------------------

@test "plan line: total is the FIRST 1..N, wherever it sits among other lines" {
  {
    echo "run-gate: selected 2 bats file(s) for the diff against origin/main (#1973)"
    echo "run-gate: start epoch=$START mode=parallel scope=selected jobs=3"
    echo "1..40"
    for i in $(seq 1 20); do echo "ok $i t"; done
    echo "1..99"
  } > "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.total == 40 and .done == 20 and .jobs == 3' <<< "$output"
}

@test "done: anchored ^ok and ^not ok only — skips count, diagnostics and indented lines do not" {
  {
    echo "1..10"
    echo "ok 1 a"
    echo "not ok 2 b"
    echo "# (in test file tests/x.bats, line 3)"
    echo "#   ok inside a diagnostic"
    echo "   ok 9 indented, not a TAP line"
    echo "okay 8 not a result"
    echo "ok 3 c # skip no network"
  } > "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.done == 3 and .total == 10' <<< "$output"
}

@test "jobs: read from the start line only — the #1798 contention line is ignored" {
  {
    echo "run-gate: 2 other live gate(s) — sharing 10 cores, jobs=3 (#1798)"
    echo "run-gate: start epoch=$START mode=parallel scope=full jobs=4"
    echo "1..1830"
    for i in $(seq 1 412); do echo "ok $i t"; done
  } > "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.jobs == 4 and .elapsed_s == 552' <<< "$output"
}

# ---- no-plan ----------------------------------------------------------------

@test "no-plan: an empty log is read — state no-plan, everything unknown, exit 0" {
  : > "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:0, total:null, elapsed_s:null, eta_s:null, jobs:null, state:"no-plan"}' <<< "$output"
  eta --log "$LOG"
  [ "$status" -eq 0 ]
  contains "$output" "no plan line"
  contains "$output" "jobs=?"
}

@test "no-plan: a start line with no plan yet reports elapsed, but no total and no ETA" {
  mk_log - 0 "$START" 4
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:0, total:null, elapsed_s:552, eta_s:null, jobs:4, state:"no-plan"}' <<< "$output"
  eta --log "$LOG"
  contains "$output" "no plan line"
  contains "$output" "9m12s elapsed"
}

# ---- withheld ---------------------------------------------------------------

@test "withheld: 12 of 1830 (below ceil(183)) — no ETA stated, the line says so" {
  mk_log 1830 12 "$START" 4
  AT=$((START + 40)) eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:12, total:1830, elapsed_s:40, eta_s:null, jobs:4, state:"withheld"}' <<< "$output"
  AT=$((START + 40)) eta --log "$LOG"
  [ "$status" -eq 0 ]
  contains "$output" "ETA withheld"
  contains "$output" "12/1830 tests"
  lacks "$output" "left"
}

@test "withheld: the threshold is max(5, ceil(10% of total)) — both edges" {
  mk_log 20 4 "$START" 2
  eta --log "$LOG" --json
  jq -e '.state == "withheld"' <<< "$output"
  mk_log 20 5 "$START" 2
  eta --log "$LOG" --json
  jq -e '.state == "running" and (.eta_s | type == "number")' <<< "$output"
  mk_log 1830 182 "$START" 4
  eta --log "$LOG" --json
  jq -e '.state == "withheld"' <<< "$output"
  mk_log 1830 183 "$START" 4
  eta --log "$LOG" --json
  jq -e '.state == "running"' <<< "$output"
}

# ---- finished ---------------------------------------------------------------

@test "finished: done == total with the count line's wall_s — elapsed is that wall_s, rounded" {
  mk_log 1830 1830 "$START" 4
  echo "run-gate: mode=parallel jobs=4 ok=1830 not_ok=0 total=1830 exit=0 wall_s=2463.512" >> "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:1830, total:1830, elapsed_s:2464, eta_s:0, jobs:4, state:"finished"}' <<< "$output"
  eta --log "$LOG"
  contains "$output" "finished"
  contains "$output" "41m04s"
}

@test "finished: no count line means elapsed unknown — never now minus the start" {
  mk_log 1830 1830 "$START" 4
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "finished" and .eta_s == 0 and .elapsed_s == null' <<< "$output"
  eta --log "$LOG"
  contains "$output" "finished"
  contains "$output" "elapsed unknown"
}

@test "finished: a 1..0 plan with no tests is finished — no division by zero" {
  printf '1..0\n' > "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:0, total:0, elapsed_s:null, eta_s:0, jobs:null, state:"finished"}' <<< "$output"
}

@test "finished: more results than the plan reads as finished, never a negative ETA" {
  mk_log 3 4 "$START" 2
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "finished" and .eta_s == 0' <<< "$output"
}

# ---- a gate that ended short of its plan (#2264) ------------------------------

# mk_short <count line|none>: the #2264 log — start line (jobs=2), `1..10`, two
# passes and one failure (a file whose setup failed), then the given line.
mk_short() {
  {
    echo "run-gate: start epoch=$START mode=parallel scope=full jobs=2"
    echo "1..10"
    echo "ok 1 a"
    echo "ok 2 b"
    echo "not ok 3 tests/x.bats"
    if [ "$1" != "none" ]; then echo "$1"; fi
  } > "$LOG"
}
COUNT_LINE="run-gate: mode=parallel jobs=2 ok=2 not_ok=1 total=3 exit=1 wall_s=12.4"

@test "short-ended: the count line settles finished — elapsed is its wall_s, eta 0" {
  mk_short "$COUNT_LINE"
  AT=1791460000 eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  jq -e '. == {done:3, total:10, elapsed_s:12, eta_s:0, jobs:2, state:"finished"}' <<< "$output"
}

@test "short-ended: the human line keeps the finished form, exactly" {
  mk_short "$COUNT_LINE"
  AT=1791460000 eta --log "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "3/10 tests, finished in 0m12s (jobs=2)" ]
  [ -z "$stderr" ]
}

@test "short-ended: every re-run prints the same, whatever the clock says" {
  local j1 h1
  mk_short "$COUNT_LINE"
  AT=$((START + 100)) eta --log "$LOG" --json; j1="$output"
  AT=$((START + 100)) eta --log "$LOG"; h1="$output"
  AT=$((START + 100000100)) eta --log "$LOG" --json
  [ "$output" = "$j1" ]
  AT=$((START + 100000100)) eta --log "$LOG"
  [ "$output" = "$h1" ]
  jq -e '.elapsed_s == 12' <<< "$j1"
}

@test "short-ended: with no count line a short log still reads withheld, then running" {
  mk_short none
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:3, total:10, elapsed_s:552, eta_s:null, jobs:2, state:"withheld"}' <<< "$output"
  local i
  for i in 4 5 6; do echo "ok $i more" >> "$LOG"; done
  eta --log "$LOG" --json
  jq -e '.state == "running" and .done == 6 and .elapsed_s == 552 and (.eta_s | type == "number")' <<< "$output"
}

@test "no-plan with a count line: total null, elapsed fixed at the rounded wall_s" {
  {
    echo "run-gate: start epoch=$START mode=parallel scope=full jobs=2"
    echo "run-gate: mode=parallel jobs=2 ok=0 not_ok=0 total=0 exit=1 wall_s=0.8"
  } > "$LOG"
  local first
  AT=$((START + 99999)) eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:0, total:null, elapsed_s:1, eta_s:null, jobs:2, state:"no-plan"}' <<< "$output"
  first="$output"
  AT=$((START + 5)) eta --log "$LOG" --json
  [ "$output" = "$first" ]
}

@test "TAP-only short log: no count line, so withheld with elapsed from --started" {
  { echo "1..10"; echo "ok 1 a"; echo "ok 2 b"; echo "not ok 3 c"; } > "$LOG"
  eta --log "$LOG" --started "$START" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:3, total:10, elapsed_s:552, eta_s:null, jobs:null, state:"withheld"}' <<< "$output"
}

@test "a count line whose wall_s has no digits is not a count line" {
  mk_short "run-gate: mode=parallel jobs=2 ok=2 not_ok=1 total=3 exit=1 wall_s="
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:3, total:10, elapsed_s:552, eta_s:null, jobs:2, state:"withheld"}' <<< "$output"
}

@test "--help states the finished rule: the count line is present, or done >= total" {
  run zsh "$G" --help
  [ "$status" -eq 0 ]
  contains "$output" "finished  the count line is present, or done >= total"
}

@test "how-to: the finished row says the gate has ended, and the running row names the killed gate" {
  local doc="$REPO_ROOT/docs/how-to/see-how-long-a-gate-has-left.md"
  grep -F '| `finished` |' "$doc" | grep -qF "The gate has ended: its count line is in the log, or every planned test has a result"
  grep -F '| `finished` |' "$doc" | grep -qF "stopped short of its plan"
  grep -F '| `finished` |' "$doc" | grep -qF 'without it, elapsed is `unknown`'
  grep -F '| `running` |' "$doc" | grep -qF "a log with no count line"
  grep -F '| `running` |' "$doc" | grep -qF "A gate that was killed never prints one"
}

# ---- parallel mode releases results one file at a time (#2265) ---------------

@test "how-to intro: parallel mode releases results one file at a time, in list order" {
  local doc="$REPO_ROOT/docs/how-to/see-how-long-a-gate-has-left.md" intro
  intro="$(awk '/^## /{exit} {print}' "$doc")"
  contains "$intro" "In the sequential modes they arrive one test at a time."
  contains "$intro" "In parallel mode"
  contains "$intro" "one file at a time, in list order"
  contains "$intro" "every file listed before"
}

@test "how-to running row: the liveness check is for the sequential modes, a still done is normal in parallel until it outlasts a file" {
  local doc="$REPO_ROOT/docs/how-to/see-how-long-a-gate-has-left.md" row
  row="$(grep -F '| `running` |' "$doc")"
  contains "$row" "A gate that was killed never prints one"
  contains "$row" "In the sequential modes, if \`done\` has not moved between two readings, check that the gate is still alive"
  contains "$row" "In parallel mode, \`done\` standing still is normal while a file listed earlier is still running;"
  contains "$row" "if it stays still for longer than any one file should take, check that the gate is still alive."
  contains "$row" "is a floor on the tests finished"
  contains "$row" "tends to overstate the time left, by less as the run goes on"
}

@test "how-to withheld row: in parallel mode done can stay at 0 until the first file finishes" {
  local doc="$REPO_ROOT/docs/how-to/see-how-long-a-gate-has-left.md" row
  row="$(grep -F '| `withheld` |' "$doc")"
  contains "$row" "In parallel mode \`done\` can stay at 0 until the first listed file finishes"
  contains "$row" "the start line shows the gate has started"
}

@test "the estimate is never called a bound, in the how-to or in --help" {
  local doc="$REPO_ROOT/docs/how-to/see-how-long-a-gate-has-left.md"
  run grep -ciE 'upper bound|lower bound|a bound' "$doc"
  [ "$output" = "0" ]
  run zsh "$G" --help
  [ "$status" -eq 0 ]
  lacks "$output" "bound"
}

@test "--help: the running entry says parallel mode releases results one bats file at a time" {
  run zsh "$G" --help
  [ "$status" -eq 0 ]
  contains "$output" "In parallel mode results arrive one bats file at a time, in list"
  contains "$output" "order, so done is a floor on the tests finished and the estimate"
  contains "$output" "tends to overstate the time left, by less as the run goes on."
}

# ---- TAP-only logs and --started --------------------------------------------

@test "TAP-only log without --started: done/total known, elapsed, ETA and jobs unknown" {
  mk_log 1830 412
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:412, total:1830, elapsed_s:null, eta_s:null, jobs:null, state:"running"}' <<< "$output"
  eta --log "$LOG"
  [ "$output" = "412/1830 tests, unknown elapsed, unknown left (jobs=?)" ]
}

@test "TAP-only log with --started: elapsed and ETA from it, jobs still unknown" {
  mk_log 1830 412
  eta --log "$LOG" --started "$START"
  [ "$status" -eq 0 ]
  [ "$output" = "412/1830 tests, 9m12s elapsed, ~31m40s left (jobs=?)" ]
}

@test "--started takes precedence over the start line" {
  mk_log 1830 412 "$START" 4
  eta --log "$LOG" --started $((START + 252)) --json
  [ "$status" -eq 0 ]
  jq -e '.elapsed_s == 300 and .jobs == 4' <<< "$output"
}

@test "--started never beats the count line: a finished gate keeps its wall_s" {
  mk_short "$COUNT_LINE"
  AT=1791460000 eta --log "$LOG" --started "$START" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:3, total:10, elapsed_s:12, eta_s:0, jobs:2, state:"finished"}' <<< "$output"
}

# ---- the --json contract ----------------------------------------------------

@test "--json: one object, exactly the six keys, integers or null, state from the enum — every state" {
  local f
  : > "$BATS_TEST_TMPDIR/empty"
  mk_log 1830 12 "$START" 4;   cp "$LOG" "$BATS_TEST_TMPDIR/withheld"
  mk_log 1830 412 "$START" 4;  cp "$LOG" "$BATS_TEST_TMPDIR/running"
  mk_log 1830 1830 "$START" 4; cp "$LOG" "$BATS_TEST_TMPDIR/finished"
  for f in empty withheld running finished; do
    eta --log "$BATS_TEST_TMPDIR/$f" --json
    [ "$status" -eq 0 ]
    [ "$(jq -s 'length' <<< "$output")" -eq 1 ]
    jq -e '(keys == ["done","elapsed_s","eta_s","jobs","state","total"])
      and ([.done, .total, .elapsed_s, .eta_s, .jobs]
           | all(. == null or (type == "number" and . == floor)))
      and (.state | IN("running", "finished", "withheld", "no-plan"))' <<< "$output"
  done
}

# ---- exit 2: usage and unreadable logs --------------------------------------

@test "exit 2, nothing on stdout: no --log, an empty --log, a missing value, an unknown flag" {
  mk_log 1830 412 "$START" 4
  eta
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--log FILE is required"
  eta --log
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  eta --log ""
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  eta --log "$LOG" --frobnicate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unknown argument: --frobnicate"
  eta --log "$LOG" --started
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "exit 2, nothing on stdout: a non-integer --started" {
  mk_log 1830 412 "$START" 4
  local bad
  for bad in yesterday 1791360000.5 -5 ""; do
    eta --log "$LOG" --started "$bad"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    contains "$stderr" "--started must be integer epoch seconds"
  done
}

@test "exit 2, nothing on stdout: a missing log, a directory, an unreadable log" {
  eta --log "$BATS_TEST_TMPDIR/no-such.log"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "cannot read log"
  eta --log "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "exit 2, nothing on stdout: a mode-000 log" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 file"
  mk_log 1830 412 "$START" 4
  chmod 000 "$LOG"
  eta --log "$LOG"
  chmod 600 "$LOG"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "cannot read log"
}

@test "exit 2: a non-integer GATE_ETA_NOW is refused, not read as a clock" {
  mk_log 1830 412 "$START" 4
  AT=soon eta --log "$LOG"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "GATE_ETA_NOW must be integer epoch seconds"
}

@test "--help prints the header and exits 0" {
  run zsh "$G" --help
  [ "$status" -eq 0 ]
  contains "$output" "gate-eta.zsh --log FILE"
}

# ---- read-only --------------------------------------------------------------

@test "read-only: the log is byte-identical afterwards and nothing is written beside it" {
  local dir="$BATS_TEST_TMPDIR/ro" before after
  mkdir -p "$dir"
  LOG="$dir/gate.stderr"
  mk_log 1830 412 "$START" 4
  before="$(cksum < "$LOG") $(ls -A "$dir" | tr '\n' ' ')"
  cd "$dir"
  eta --log "$LOG"
  eta --log "$LOG" --json
  after="$(cksum < "$LOG") $(ls -A "$dir" | tr '\n' ' ')"
  [ "$before" = "$after" ]
}

# ---- end to end: what the real run-gate.zsh prints --------------------------

@test "end to end: gate-eta reads the real run-gate.zsh's captured stderr" {
  local stub="$BATS_TEST_TMPDIR/bats-stub" par="$BATS_TEST_TMPDIR/parallel-gnu"
  printf '#!/usr/bin/env bash\nprintf "1..3\\nok 1 a\\nok 2 b\\nok 3 c\\n"\n' > "$stub"
  printf '#!/usr/bin/env bash\necho "GNU parallel 20260722"\n' > "$par"
  chmod +x "$stub" "$par"
  mkdir -p "$BATS_TEST_TMPDIR/tests"
  run --separate-stderr env GATE_BATS_BIN="$stub" GATE_PARALLEL_BIN="$par" GATE_NPROC=4 \
    GATE_SLOTS_DIR="$BATS_TEST_TMPDIR/slots" \
    zsh "$REPO_ROOT/development/skills/resolve-issue/scripts/run-gate.zsh" \
    --tests-dir "$BATS_TEST_TMPDIR/tests"
  [ "$status" -eq 0 ]
  printf '%s\n' "$stderr" > "$LOG"
  local wall; wall="$(jq -r '.wall_s' <<< "$output")"
  run --separate-stderr zsh "$G" --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e --argjson w "$wall" \
    '.state == "finished" and .done == 3 and .total == 3 and .jobs == 4
     and .eta_s == 0 and .elapsed_s == ($w + 0.5 | floor)' <<< "$output"
}
