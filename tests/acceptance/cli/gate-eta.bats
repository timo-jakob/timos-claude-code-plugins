#!/usr/bin/env bats
#
# Acceptance cases for "live gate ETA from the run-gate log" (#2196, epic #2195
# child (a)) — the `cli`-tooled test_cases[] of its story-spec, one test per
# `tc-*` id:
#
#   tc-happy-run-gate-start-line         #2202
#   tc-happy-run-gate-summary-wall       #2203
#   tc-happy-running                     #2204
#   tc-happy-running-json                #2205
#   tc-corner-withheld                   #2206
#   tc-corner-threshold-floor            #2207
#   tc-corner-counts-not-ok-and-skips    #2208
#   tc-corner-finished-with-wall         #2209
#   tc-corner-finished-no-wall           #2210
#   tc-corner-zero-plan                  #2211
#   tc-corner-empty-log                  #2212
#   tc-corner-no-start-line              #2213
#   tc-corner-tap-only-started           #2214
#   tc-corner-started-overrides          #2215
#   tc-corner-contention-line-ignored    #2216
#   tc-error-missing-log-file            #2217
#   tc-error-no-log-flag                 #2218
#   tc-error-bad-started                 #2219
#   tc-error-unknown-flag                #2220
#   tc-error-unreadable-log              #2221
#
# and, for "a gate that ended short of its plan reads finished" (#2264):
#
#   tc-happy-short-ended-finished                  #2273
#   tc-happy-short-ended-human-line                #2274
#   tc-corner-rerun-idempotent                     #2275
#   tc-corner-full-finished-unchanged              #2276
#   tc-corner-short-no-count-line-still-running    #2277
#   tc-corner-no-plan-with-count-line              #2278
#   tc-corner-tap-only-short-unchanged             #2279
#   tc-error-truncated-count-line                  #2280
#   tc-error-unreadable-log-unchanged              #2281
#
# and, for "say that parallel mode releases results one file at a time" (#2265):
#
#   tc-happy-help-parallel-running                 #2283
#   tc-corner-parallel-done-still                  #2284
#   tc-corner-parallel-first-file                  #2285
#   tc-error-unknown-flag-before-help              #2286
#
# Its use case: the conductor polls a healthy parallel gate (`mode=parallel ...
# jobs=4`, `1..1830`) and reads 412 results at 9m12s and again at 10m00s. done
# has not moved because an earlier file is still running; gate-eta keeps reading
# it as running, and its --help says why.
#
# Its use case: the same builder reads a gate whose suite stopped short of its
# plan (a file whose setup_file failed: `1..10`, two passes, one `not ok`), and
# whose run-gate count line says `exit=1 wall_s=12.4`. Read at 1791460000, long
# after it ended, that is `3/10 tests, finished in 0m12s (jobs=2)`, never a
# growing ETA.
#
# The use case: timo-platform-builder, mid-round in a resolve-issue run, wants to
# know how many tests the whole-suite gate has done and how long it has left, to
# decide whether to step away or free CPU. The gate's captured stderr reads
# `run-gate: start epoch=1791360000 mode=parallel scope=full jobs=4`, `1..1830`
# and 412 result lines; at 1791360552 that is 412/1830 tests, 9m12s elapsed,
# ~31m40s left (jobs=4).
#
# run-gate.zsh runs against a stub `bats`, so no real suite runs; gate-eta.zsh
# reads fixture logs with its clock pinned through GATE_ETA_NOW. Nothing reaches
# GitHub. The default gate's tests/run-gate.bats and tests/gate-eta.bats cover
# the same criteria.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  RUN_GATE="$SCRIPTS/run-gate.zsh"
  ETA="$SCRIPTS/gate-eta.zsh"
  START=1791360000
  NOW=1791360552
  LOG="$BATS_TEST_TMPDIR/gate-2.stderr"

  # a stub suite for run-gate: 1830 tests, the platform suite's size
  BATS_STUB="$BATS_TEST_TMPDIR/bats-stub"
  printf '#!/usr/bin/env bash\necho 1..1830\nfor i in $(seq 1 1830); do echo "ok $i resolve-issue case $i"; done\n' > "$BATS_STUB"
  PAR_GNU="$BATS_TEST_TMPDIR/parallel-gnu"
  printf '#!/usr/bin/env bash\necho "GNU parallel 20260722"\n' > "$PAR_GNU"
  chmod +x "$BATS_STUB" "$PAR_GNU"
  mkdir -p "$BATS_TEST_TMPDIR/tests"
}

# the platform gate's captured stderr: start line, plan, <done> results
platform_log() {  # <done> [no-start]
  local i
  {
    if [ -z "${2-}" ]; then
      echo "run-gate: start epoch=$START mode=parallel scope=full jobs=4"
    fi
    echo "1..1830"
    for ((i = 1; i <= $1; i++)); do echo "ok $i resolve-issue case $i"; done
  } > "$LOG"
}

run_gate() {
  run --separate-stderr env GATE_BATS_BIN="$BATS_STUB" GATE_PARALLEL_BIN="$PAR_GNU" \
    GATE_NPROC=4 GATE_SLOTS_DIR="$BATS_TEST_TMPDIR/slots" \
    zsh "$RUN_GATE" --tests-dir "$BATS_TEST_TMPDIR/tests"
}

eta() { run --separate-stderr env GATE_ETA_NOW="$NOW" zsh "$ETA" "$@"; }

@test "tc-happy-run-gate-start-line (#2202)" {
  run_gate
  [ "$status" -eq 0 ]
  [ "$(grep -c '^run-gate: start ' <<< "$stderr")" -eq 1 ]
  matches "$(grep '^run-gate: start ' <<< "$stderr")" \
    '^run-gate: start epoch=[0-9]+ mode=parallel scope=full jobs=4$'
  local s p
  s="$(grep -n '^run-gate: start ' <<< "$stderr" | cut -d: -f1)"
  p="$(grep -n '^1\.\.1830$' <<< "$stderr" | cut -d: -f1)"
  [ "$s" -lt "$p" ]
  jq -e '[keys_unsorted[]] == ["mode","jobs","scope","ok","not_ok","total","exit","wall_s","tap","tree","files"]' <<< "$output"
}

@test "tc-happy-run-gate-summary-wall (#2203)" {
  run_gate
  [ "$status" -eq 0 ]
  local line w
  line="$(grep '^run-gate: mode=' <<< "$stderr")"
  matches "$line" '^run-gate: mode=parallel .* exit=0 wall_s=[0-9]+\.[0-9]{3}$'
  w="${line##* wall_s=}"
  jq -e --argjson w "$w" '.wall_s == $w' <<< "$output"
}

@test "tc-happy-running (#2204)" {
  platform_log 412
  eta --log "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "412/1830 tests, 9m12s elapsed, ~31m40s left (jobs=4)" ]
}

@test "tc-happy-running-json (#2205)" {
  platform_log 412
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:412, total:1830, elapsed_s:552, eta_s:1900, jobs:4, state:"running"}' <<< "$output"
}

@test "tc-corner-withheld (#2206)" {
  platform_log 12
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "withheld" and .eta_s == null' <<< "$output"
  eta --log "$LOG"
  [ "$status" -eq 0 ]
  contains "$output" "ETA withheld"
}

@test "tc-corner-threshold-floor (#2207)" {
  local n
  for n in 4 5; do
    {
      echo "run-gate: start epoch=$START mode=parallel scope=selected jobs=2"
      echo "1..20"
      for ((i = 1; i <= n; i++)); do echo "ok $i t$i"; done
    } > "$LOG"
    eta --log "$LOG" --json
    [ "$status" -eq 0 ]
    if [ "$n" -eq 4 ]; then
      jq -e '.state == "withheld" and .eta_s == null' <<< "$output"
    else
      jq -e '.state == "running" and (.eta_s | type == "number")' <<< "$output"
    fi
  done
}

@test "tc-corner-counts-not-ok-and-skips (#2208)" {
  printf '%s\n' "1..10" "ok 1 a" "not ok 2 b" "ok 3 c # skip" "# ok inside a diagnostic" > "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.done == 3' <<< "$output"
}

@test "tc-corner-finished-with-wall (#2209)" {
  platform_log 1830
  echo "run-gate: mode=parallel jobs=4 ok=1830 not_ok=0 total=1830 exit=0 wall_s=2463.512" >> "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "finished" and .eta_s == 0 and .elapsed_s == 2464' <<< "$output"
  eta --log "$LOG"
  contains "$output" "finished"
}

@test "tc-corner-finished-no-wall (#2210)" {
  platform_log 1830
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "finished" and .eta_s == 0 and .elapsed_s == null' <<< "$output"
}

@test "tc-corner-zero-plan (#2211)" {
  printf '1..0\n' > "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "finished" and .done == 0 and .total == 0 and .eta_s == 0' <<< "$output"
}

@test "tc-corner-empty-log (#2212)" {
  : > "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:0, total:null, elapsed_s:null, eta_s:null, jobs:null, state:"no-plan"}' <<< "$output"
  eta --log "$LOG"
  contains "$output" "no plan line"
}

@test "tc-corner-no-start-line (#2213)" {
  platform_log 412 no-start
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "running" and .elapsed_s == null and .eta_s == null and .jobs == null' <<< "$output"
  eta --log "$LOG"
  contains "$output" "unknown elapsed"
  contains "$output" "unknown left"
  contains "$output" "jobs=?"
}

@test "tc-corner-tap-only-started (#2214)" {
  platform_log 412 no-start
  eta --log "$LOG" --started "$START"
  [ "$status" -eq 0 ]
  [ "$output" = "412/1830 tests, 9m12s elapsed, ~31m40s left (jobs=?)" ]
}

@test "tc-corner-started-overrides (#2215)" {
  platform_log 412
  eta --log "$LOG" --started 1791360252 --json
  [ "$status" -eq 0 ]
  jq -e '.elapsed_s == 300' <<< "$output"
}

@test "tc-corner-contention-line-ignored (#2216)" {
  {
    echo "run-gate: start epoch=$START mode=parallel scope=full jobs=4"
    echo "run-gate: 2 other live gate(s) — sharing 10 cores, jobs=3 (#1798)"
    echo "1..1830"
    for ((i = 1; i <= 412; i++)); do echo "ok $i t"; done
  } > "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.jobs == 4' <<< "$output"
}

@test "tc-error-missing-log-file (#2217)" {
  eta --log /nonexistent/gate-2.stderr
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "tc-error-no-log-flag (#2218)" {
  eta --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "tc-error-bad-started (#2219)" {
  platform_log 412
  eta --log "$LOG" --started yesterday
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "tc-error-unknown-flag (#2220)" {
  platform_log 412
  eta --log "$LOG" --frobnicate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "tc-error-unreadable-log (#2221)" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 file"
  platform_log 412
  chmod 000 "$LOG"
  eta --log "$LOG"
  chmod 600 "$LOG"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# ---- #2264: a gate that ended short of its plan ------------------------------

# the #2264 log: start line (jobs=2), `1..10`, ok 1, ok 2, not ok 3, then $1
short_log() {
  {
    echo "run-gate: start epoch=$START mode=parallel scope=full jobs=2"
    echo "1..10"
    echo "ok 1 resolve-issue case 1"
    echo "ok 2 resolve-issue case 2"
    echo "not ok 3 tests/resolve-story-loop-step.bats"
    if [ "$1" != "none" ]; then echo "$1"; fi
  } > "$LOG"
}
SHORT_COUNT="run-gate: mode=parallel jobs=2 ok=2 not_ok=1 total=3 exit=1 wall_s=12.4"
eta_at() { local at="$1"; shift; run --separate-stderr env GATE_ETA_NOW="$at" zsh "$ETA" "$@"; }

@test "tc-happy-short-ended-finished (#2273)" {
  short_log "$SHORT_COUNT"
  eta_at 1791460000 --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:3, total:10, elapsed_s:12, eta_s:0, jobs:2, state:"finished"}' <<< "$output"
}

@test "tc-happy-short-ended-human-line (#2274)" {
  short_log "$SHORT_COUNT"
  eta_at 1791460000 --log "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "3/10 tests, finished in 0m12s (jobs=2)" ]
  [ -z "$stderr" ]
}

@test "tc-corner-rerun-idempotent (#2275)" {
  local j h
  short_log "$SHORT_COUNT"
  eta_at 1791360100 --log "$LOG" --json; j="$output"
  eta_at 1791360100 --log "$LOG"; h="$output"
  eta_at 1891360100 --log "$LOG" --json
  [ "$output" = "$j" ]
  eta_at 1891360100 --log "$LOG"
  [ "$output" = "$h" ]
  jq -e '.elapsed_s == 12' <<< "$j"
}

@test "tc-corner-full-finished-unchanged (#2276)" {
  platform_log 1830
  echo "run-gate: mode=parallel jobs=4 ok=1830 not_ok=0 total=1830 exit=0 wall_s=2463.512" >> "$LOG"
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "finished" and .elapsed_s == 2464 and .eta_s == 0' <<< "$output"
  eta --log "$LOG"
  contains "$output" "41m04s"
}

@test "tc-corner-short-no-count-line-still-running (#2277)" {
  short_log none
  eta_at $((START + 552)) --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "withheld" and .elapsed_s == 552 and .eta_s == null' <<< "$output"
  local i
  for i in 4 5 6; do echo "ok $i resolve-issue case $i" >> "$LOG"; done
  eta_at $((START + 552)) --log "$LOG" --json
  jq -e '.state == "running" and .done == 6 and (.eta_s | type == "number")' <<< "$output"
}

@test "tc-corner-no-plan-with-count-line (#2278)" {
  local first
  {
    echo "run-gate: start epoch=$START mode=parallel scope=full jobs=2"
    echo "run-gate: mode=parallel jobs=2 ok=0 not_ok=0 total=0 exit=1 wall_s=0.8"
  } > "$LOG"
  eta_at 1791460000 --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "no-plan" and .total == null and .elapsed_s == 1 and .eta_s == null' <<< "$output"
  first="$output"
  eta_at 1891460000 --log "$LOG" --json
  [ "$output" = "$first" ]
}

@test "tc-corner-tap-only-short-unchanged (#2279)" {
  { echo "1..10"; echo "ok 1 a"; echo "ok 2 b"; echo "not ok 3 c"; } > "$LOG"
  eta --log "$LOG" --started "$START" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "withheld" and .elapsed_s == 552 and .eta_s == null' <<< "$output"
}

@test "tc-error-truncated-count-line (#2280)" {
  short_log "run-gate: mode=parallel jobs=2 ok=2 not_ok=1 total=3 exit=1 wall_s="
  eta --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "withheld" and .elapsed_s == 552 and .eta_s == null' <<< "$output"
}

@test "tc-error-unreadable-log-unchanged (#2281)" {
  eta --log "$BATS_TEST_TMPDIR/no-such-gate.stderr" --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "cannot read log"
}

# ---- #2265: parallel mode releases results one file at a time ----------------

@test "tc-happy-help-parallel-running (#2283)" {
  run --separate-stderr zsh "$ETA" --help
  [ "$status" -eq 0 ]
  contains "$output" "In parallel mode results arrive one bats file at a time, in list"
}

@test "tc-corner-parallel-done-still (#2284)" {
  platform_log 412
  eta_at $((START + 552)) --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "running" and .done == 412 and .eta_s == 1900' <<< "$output"
  eta_at $((START + 600)) --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '.state == "running" and .done == 412 and .eta_s == 2065' <<< "$output"
}

@test "tc-corner-parallel-first-file (#2285)" {
  platform_log 0
  eta_at $((START + 120)) --log "$LOG" --json
  [ "$status" -eq 0 ]
  jq -e '. == {done:0, total:1830, elapsed_s:120, eta_s:null, jobs:4, state:"withheld"}' <<< "$output"
}

@test "tc-error-unknown-flag-before-help (#2286)" {
  run --separate-stderr zsh "$ETA" --bogus --help
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "gate-eta:"
}
