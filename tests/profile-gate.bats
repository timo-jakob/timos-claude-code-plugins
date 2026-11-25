#!/usr/bin/env bats
#
# Behavioural tests for profile-gate.zsh (#3004), the gate profiler. What these
# pin down:
#   * the PATH shim counts exactly the processes a test starts — jq twice and
#     git once for tests/fixtures/profile-gate/sample.bats — with bats' own
#     per-test processes subtracted, and the real tools still run;
#   * the report carries, per test: file, name, wall ms, process count and the
#     counts by executable; per file: the totals, the fork estimate and a class;
#   * the shim directory and its logs live in a mktemp dir outside the
#     repository and are removed on exit, and on SIGTERM, SIGINT and SIGHUP;
#   * usage errors exit 2 with an empty stdout, a report that cannot be written
#     exits 1, and a red bats file is recorded, not a profiler failure.
#
# The profiler runs the real bats on small fixture files, so each case takes a
# second or two. Fixture files with tests in them are written with printf, never
# a heredoc, so this file's own parser never sees their test lines.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/profile-gate.zsh"
  SAMPLE="$REPO_ROOT/tests/fixtures/profile-gate/sample.bats"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"; mkdir -p "$TMPDIR"
  OUT="$BATS_TEST_TMPDIR/out"
}

# One fixture bats file: _fixture NAME BODY-LINE... writes one test per call.
_fixture() {
  local f="$BATS_TEST_TMPDIR/$1.bats"; shift
  printf '@test "%s" {\n%s\n}\n' "$1" "$2" >> "$f"
  printf '%s\n' "$f"
}

# The profiler's workdir, from its first stderr line.
_workdir() {
  sed -n 's/^profile-gate: workdir=//p' "$1"
}

@test "sample: jq twice and git once, bats' own processes subtracted, the real tools ran" {
  export SAMPLE_OUT="$BATS_TEST_TMPDIR/sample.out"
  run --separate-stderr "$S" --out "$OUT" "$SAMPLE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -c '[.tests[] | select(.number == 1) | .by_exe]' "$OUT/report.json"
  [ "$output" = '[{"git":1,"jq":2}]' ]
  run jq -r '.tests[] | select(.number == 1) | .processes' "$OUT/report.json"
  [ "$output" = 3 ]
  run jq -c '[.tests[] | select(.number == 2) | .processes, .by_exe]' "$OUT/report.json"
  [ "$output" = '[0,{}]' ]
  # the tools' output is what they print without the shim
  printf '%s\n' 2 ledger-export "$(git --version)" > "$BATS_TEST_TMPDIR/direct.out"
  cmp "$SAMPLE_OUT" "$BATS_TEST_TMPDIR/direct.out"
  run jq -r '.files[0] | "\(.exit) \(.tests) \(.processes) \(.by_exe.jq) \(.by_exe.git)"' "$OUT/report.json"
  [ "$output" = "0 2 3 2 1" ]
  # report.md's row: tests, procs/test, then jq, git, interp and other in that order
  run grep -c "^| $SAMPLE | [0-9.]* | 2 | 1.5 | 2 | 1 | 0 | 0 | " "$OUT/report.md"
  [ "$output" = 1 ]
}

@test "every test row carries file, number, name, wall_ms, processes and by_exe" {
  run --separate-stderr "$S" --out "$OUT" "$SAMPLE"
  [ "$status" -eq 0 ]
  run jq -r '.schema' "$OUT/report.json"
  [ "$output" = gate-profile/v1 ]
  run jq -e --arg f "$SAMPLE" '.tests | length == 2 and all(
      (keys == ["by_exe","file","name","number","processes","wall_ms"])
      and .file == $f and (.wall_ms | type == "number" and . >= 0)
      and (.processes | type == "number"))' "$OUT/report.json"
  [ "$status" -eq 0 ]
  run jq -r '[.tests[].name] | join("|")' "$OUT/report.json"
  [ "$output" = "jq twice and git once|starts nothing" ]
}

@test "the file row carries the totals, the fork estimate and its split, and the measured costs" {
  run --separate-stderr "$S" --out "$OUT" "$SAMPLE"
  [ "$status" -eq 0 ]
  run jq -e '.files[0] | (.processes_per_test == 1.5)
      and (.fork_split_ms | keys == ["git","interpreter","jq","other"])
      and (.fork_split_ms.jq > 0) and (.fork_split_ms.git > 0)
      and (.fork_split_ms.interpreter == 0) and (.fork_split_ms.other == 0)
      and (.fork_ms_est > 0) and (.shim_overhead_ms_est >= 0)
      and (.class | IN("fork-bound","wait-bound","compute-bound"))' "$OUT/report.json"
  [ "$status" -eq 0 ]
  # the estimates are count x the report's own measured costs, so they are exact
  run jq -e '.files[0].fork_split_ms.jq == (2 * .startup_ms.jq * 10 | round / 10)' "$OUT/report.json"
  [ "$status" -eq 0 ]
  run jq -e '.files[0].fork_split_ms.git == (1 * .startup_ms.git * 10 | round / 10)' "$OUT/report.json"
  [ "$status" -eq 0 ]
  run jq -e '.files[0].shim_overhead_ms_est == (.files[0].processes * .shim_ms * 10 | round / 10)' "$OUT/report.json"
  [ "$status" -eq 0 ]
  run jq -e '(.startup_ms | keys == ["awk","bash","git","jq","other","sed","zsh"])
      and (.startup_ms.jq > 0) and (.shim_ms >= 0) and (.jobs == 1)
      and (.unseen | length == 3)' "$OUT/report.json"
  [ "$status" -eq 0 ]
}

@test "zsh, bash and sh are costed as interpreter: zsh at its own start-up cost, sh at bash's" {
  local f; f=$(_fixture interp "one zsh, one bash, one sh" '  zsh -c :; bash -c :; sh -c :')
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -c '.files[0].by_exe' "$OUT/report.json"
  [ "$output" = '{"bash":1,"sh":1,"zsh":1}' ]
  run jq -e '.files[0].fork_split_ms.interpreter == ((.startup_ms.zsh + 2 * .startup_ms.bash) * 10 | round / 10)' "$OUT/report.json"
  [ "$status" -eq 0 ]
}

@test "a process started in setup_file is reported in outside_tests, not on a test" {
  local f="$BATS_TEST_TMPDIR/outside.bats"
  printf 'setup_file() { jq -n 1 >/dev/null; }\n@test "empty" {\n  :\n}\n' > "$f"
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -c '[.files[0].outside_tests, .tests[0].by_exe]' "$OUT/report.json"
  [ "$output" = '[{"jq":1},{}]' ]
}

@test "a test that runs a tool bats also runs keeps its own count after the subtraction" {
  local f; f=$(_fixture dates "one date" '  date >/dev/null')
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -c '.tests[0].by_exe' "$OUT/report.json"
  [ "$output" = '{"date":1}' ]
  run jq -r '.bats_baseline.date' "$OUT/report.json"
  [ "$output" -ge 1 ]
}

@test "an exec by absolute path is not counted, and the file's static references are" {
  local f; f=$(_fixture abs "absolute" '  /usr/bin/true')
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -c '[.tests[0].processes, .files[0].absolute_path_refs]' "$OUT/report.json"
  [ "$output" = '[0,1]' ]
}

@test "sleep is summed into sleep_s, and a file that sleeps for 30% of its time or more is wait-bound" {
  # 2 s slept of a little over 4 s: under half, so a threshold above 50% would
  # not call it wait-bound.
  local f; f=$(_fixture slow "sleeps" '  sleep 2')
  _fixture slow "busy" '  local end=$((SECONDS + 2)); while [ "$SECONDS" -lt "$end" ]; do :; done' >/dev/null
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -r '.files[0] | "\(.sleep_s) \(.class) \(.by_exe.sleep)"' "$OUT/report.json"
  [ "$output" = "2 wait-bound 1" ]
}

@test "a sleep killed early counts for no more than its test's wall time" {
  # 30 s asked for, a fraction of a second slept: uncapped, the file would read
  # wait-bound on the two seconds its other test computes.
  local f; f=$(_fixture killed "placeholder sleep" '  sleep 30 & local p=$!; sleep 0.3; kill "$p"; wait "$p" || true')
  _fixture killed "busy" '  local end=$((SECONDS + 2)); while [ "$SECONDS" -lt "$end" ]; do :; done' >/dev/null
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -r '.files[0] | "\(.by_exe.sleep) \(.sleep_s < 2) \(.class)"' "$OUT/report.json"
  [ "$output" = "2 true compute-bound" ]
}

@test "a file that only computes in the shell is compute-bound" {
  local f; f=$(_fixture busy "busy" '  local end=$((SECONDS + 2)); while [ "$SECONDS" -lt "$end" ]; do :; done')
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -r '.files[0] | "\(.processes) \(.class)"' "$OUT/report.json"
  [ "$output" = "0 compute-bound" ]
}

@test "a file that mostly starts processes is fork-bound" {
  local f; f=$(_fixture forks "forks" '  local i; for i in $(seq 400); do env true; done')
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -r '.files[0] | "\(.by_exe.env) \(.by_exe.true) \(.class)"' "$OUT/report.json"
  [ "$output" = "400 400 fork-bound" ]
}

@test "a file whose fork estimate is under half its time is compute-bound" {
  # 200 jq starts beside 3 s of shell work: the estimate is well over 5% of the
  # time and under 50%.
  local f; f=$(_fixture some "forks and computes" '  local i; for i in $(seq 200); do jq -n 1 >/dev/null; done
  local end=$((SECONDS + 3)); while [ "$SECONDS" -lt "$end" ]; do :; done')
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -r '.files[0] | "\(.by_exe.jq) \(.fork_ms_est >= 0.05 * (.wall_ms - .shim_overhead_ms_est)) \(.class)"' "$OUT/report.json"
  [ "$output" = "200 true compute-bound" ]
}

@test "a red bats file is recorded in its exit, and the profiler still exits 0" {
  local f; f=$(_fixture red "fails" '  false')
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -r '.files[0].exit' "$OUT/report.json"
  [ "$output" -ne 0 ]
  run grep -c '(exit ' "$OUT/report.md"
  [ "$output" = 1 ]
}

@test "--jobs 2 counts the same, files are sorted heaviest first, and --top bounds the table" {
  local f; f=$(_fixture slow "sleeps" '  sleep 1')
  run --separate-stderr "$S" --out "$OUT" --jobs 2 --top 1 "$SAMPLE" "$f"
  [ "$status" -eq 0 ]
  run jq -c '[.jobs, [.files[].file] == [$f, $s]]' --arg f "$f" --arg s "$SAMPLE" "$OUT/report.json"
  [ "$output" = '[2,true]' ]
  run jq -c '[.tests[] | select(.file == $s and .number == 1) | .by_exe]' --arg s "$SAMPLE" "$OUT/report.json"
  [ "$output" = '[{"git":1,"jq":2}]' ]
  # the one row is the heaviest file's
  run grep -c '^| .*\.bats |' "$OUT/report.md"
  [ "$output" = 1 ]
  run grep -c "^| $f | " "$OUT/report.md"
  [ "$output" = 1 ]
  run grep -c '^| File | Wall s | Tests | Procs/test | jq | git | interp | other | Fork est | Sleep s | Class |$' "$OUT/report.md"
  [ "$output" = 1 ]
}

@test "without --top the table holds the 20 heaviest files" {
  local -a fs=(); local i
  for i in $(seq 21); do fs+=("$(_fixture "f$i" "quick" '  :')"); done
  run --separate-stderr "$S" --out "$OUT" --jobs 4 "${fs[@]}"
  [ "$status" -eq 0 ]
  run jq -r '.files | length' "$OUT/report.json"
  [ "$output" = 21 ]
  run grep -c '^| .*\.bats |' "$OUT/report.md"
  [ "$output" = 20 ]
}

@test "the workdir is a mktemp dir under TMPDIR, outside the repository, removed on exit" {
  run --separate-stderr "$S" --out "$OUT" "$SAMPLE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$stderr" > "$BATS_TEST_TMPDIR/err"
  local w; w=$(_workdir "$BATS_TEST_TMPDIR/err")
  [ -n "$w" ]
  case "$w" in "$(cd "$TMPDIR" && pwd -P)"/profile-gate.*) ;; *) false ;; esac
  case "$w" in "$REPO_ROOT"/*) false ;; esac
  [ ! -e "$w" ]
  run ls -A "$TMPDIR"
  [ -z "$output" ]
  run ls -A "$OUT"
  [ "$output" = "$(printf '%s\n' report.json report.md)" ]
}

@test "SIGTERM, SIGINT or SIGHUP mid-run ends the run, removes the workdir, writes no report, exits 143, 130 or 129" {
  local f; f=$(_fixture hang "hangs" '  sleep 30')
  local sig pid i w rc
  for sig in TERM:143 INT:130 HUP:129; do
    "$S" --out "$OUT" "$f" 2> "$BATS_TEST_TMPDIR/err" &
    pid=$!
    i=0
    until grep -q '^profile-gate: \[1/1\]' "$BATS_TEST_TMPDIR/err"; do
      i=$((i + 1)); [ "$i" -lt 200 ]; sleep 0.1
    done
    w=$(_workdir "$BATS_TEST_TMPDIR/err")
    [ -d "$w" ]
    sleep 1
    kill "-${sig%:*}" "$pid"
    rc=0; wait "$pid" || rc=$?
    [ "$rc" -eq "${sig#*:}" ]
    [ ! -e "$w" ]
    [ ! -e "$OUT/report.json" ]
    run pgrep -f "$f"
    [ "$status" -ne 0 ]
  done
}

@test "a report that cannot be written exits 1 with an empty stdout" {
  mkdir -p "$OUT/report.md"
  run --separate-stderr "$S" --out "$OUT" "$SAMPLE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | tail -n 1)" = "profile-gate: cannot write $OUT/report.md" ]
}

@test "usage errors exit 2 with an empty stdout" {
  run --separate-stderr "$S" "$SAMPLE"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr "$S" --out "$OUT"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr "$S" --out "$OUT" "$BATS_TEST_TMPDIR/missing.bats"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr "$S" --out "$OUT" --jobs 0 "$SAMPLE"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr "$S" --out "$OUT" --top x "$SAMPLE"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  run --separate-stderr "$S" --out "$OUT" --bogus "$SAMPLE"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  touch "$BATS_TEST_TMPDIR/file"
  run --separate-stderr "$S" --out "$BATS_TEST_TMPDIR/file/sub" "$SAMPLE"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  [ ! -e "$OUT/report.json" ]
}

@test "--help prints the header and exits 0" {
  run --separate-stderr "$S" --help
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "profile-gate.zsh — attribute the bats gate's time to files, tests and the" ]
}

# A PATH holding only zsh, and jq or bats when asked, so the other is missing.
_bin_without() {
  local b="$BATS_TEST_TMPDIR/bin-$1"; mkdir -p "$b"
  ln -s "$(command -v zsh)" "$b/zsh"
  [ "$1" = jq ] || ln -s "$(command -v jq)" "$b/jq"
  [ "$1" = bats ] || ln -s "$(command -v bats)" "$b/bats"
  printf '%s\n' "$b"
}

@test "bats or jq missing from PATH exits 127 with an empty stdout and no report" {
  local b; b=$(_bin_without bats)
  run -127 --separate-stderr env PATH="$b" "$S" --out "$OUT" "$SAMPLE"
  [ "$status" -eq 127 ]; [ -z "$output" ]
  [ "$stderr" = "profile-gate: bats not found" ]
  b=$(_bin_without jq)
  run -127 --separate-stderr env PATH="$b" "$S" --out "$OUT" "$SAMPLE"
  [ "$status" -eq 127 ]; [ -z "$output" ]
  [ "$stderr" = "profile-gate: jq not found" ]
  [ ! -e "$OUT/report.json" ]
}

@test "a stub that calls back into the shim by absolute path reaches the real tool, with the shim on PATH or not" {
  # the shape of tests/marker-find-stub.bash: the stub captured `command -v`
  # with the shim first on PATH, so it delegates to the shim's own entry. The
  # shim must never resolve back to the stub, whether PATH still holds the shim
  # directory or dropped it; the stub gives up at depth 3 so a regression reds
  # instead of hanging.
  local f; f=$(_fixture stubbed "stub delegates" '  local stub="$BATS_TEST_TMPDIR/stub" real
  mkdir -p "$stub"; real=$(command -v jq)
  printf '"'"'#!/bin/bash\nn=$((${STUB_DEPTH:-0} + 1)); [ "$n" -le 3 ] || exit 99\nSTUB_DEPTH=$n exec "%s" "$@"\n'"'"' "$real" > "$stub/jq"
  chmod +x "$stub/jq"
  run env PATH="$stub:$PATH" jq -n 7
  [ "$status" -eq 0 ]
  [ "$output" = 7 ]
  run env PATH="$stub:/usr/bin:/bin" jq -n 7
  [ "$status" -eq 0 ]
  [ "$output" = 7 ]')
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -r '"\(.files[0].exit) \(.tests[0].by_exe.jq)"' "$OUT/report.json"
  [ "$output" = "0 2" ]
}

@test "--jobs 2 starts the next file as soon as one ends, while another still runs" {
  # A waits for a mark only C writes; with two slots, C can start only once B
  # ends while A still runs. A scheduler that waits for A first fails A.
  export PG_MARK="$BATS_TEST_TMPDIR/mark"
  local a b c
  a=$(_fixture a "waits for c" '  local i=0; while [ ! -e "$PG_MARK" ]; do i=$((i + 1)); [ "$i" -lt 300 ]; sleep 0.1; done')
  b=$(_fixture b "quick" '  :')
  c=$(_fixture c "writes the mark" '  touch "$PG_MARK"')
  run --separate-stderr "$S" --out "$OUT" --jobs 2 "$a" "$b" "$c"
  [ "$status" -eq 0 ]
  run jq -cS '[.files[] | {key: (.file | sub(".*/"; "")), value: .exit}] | from_entries' "$OUT/report.json"
  [ "$output" = '{"a.bats":0,"b.bats":0,"c.bats":0}' ]
}

@test "the shim never resolves to itself: a link a test made to it, and env -i, both reach the real tool" {
  # each call is killed after 10 s, so a shim that execs itself again reds its
  # test instead of hanging the run (an exec keeps the pid)
  local guard='  local p=$! i=0
  while kill -0 "$p" 2>/dev/null; do i=$((i + 1)); [ "$i" -lt 100 ] || kill -9 "$p"; sleep 0.1; done
  wait "$p"
  [ "$(cat "$BATS_TEST_TMPDIR/o")" = 7 ]'
  local f; f=$(_fixture self "a bin dir of links, as PATH" '  local b="$BATS_TEST_TMPDIR/b"; mkdir -p "$b"
  ln -s "$(command -v jq)" "$b/jq"
  env PATH="$b" jq -n 7 > "$BATS_TEST_TMPDIR/o" &
'"$guard")
  _fixture self "env -i with the shim still first on PATH" '  env -i PATH="$PATH" jq -n 7 > "$BATS_TEST_TMPDIR/o" &
'"$guard" >/dev/null
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -c '[.files[0].exit, .tests[0].by_exe.jq]' "$OUT/report.json"
  [ "$output" = '[0,1]' ]
}

@test "processes that overlap past the wall time make the file fork-bound with its share shown as overlap" {
  # 400 short processes started side by side: their summed shim cost (about
  # 4 s) exceeds the file's wall time, so wall less shim overhead is not
  # positive and no share of it means anything.
  local f; f=$(_fixture overlap "side by side" '  local i; for i in $(seq 200); do env true & done; wait')
  run --separate-stderr "$S" --out "$OUT" "$f"
  [ "$status" -eq 0 ]
  run jq -r '.files[0] | "\(.class) \(.shim_overhead_ms_est >= .wall_ms)"' "$OUT/report.json"
  [ "$output" = "fork-bound true" ]
  run grep -c '(overlap) | 0 | fork-bound |$' "$OUT/report.md"
  [ "$output" = 1 ]
}
