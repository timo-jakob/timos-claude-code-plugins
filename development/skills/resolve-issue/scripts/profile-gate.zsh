#!/usr/bin/env zsh
# profile-gate.zsh — attribute the bats gate's time to files, tests and the
# processes each test starts (#3004).
#
# Why: a handful of bats files take most of the gate's test time, and the
# suspected cost is process creation (jq, git, interpreter start-up), not the
# shell itself. Whether to batch a script's jq calls or move it out of zsh is
# decided on data, and this script produces that data. It is a measuring tool,
# never a gate: run-gate.zsh stays the only gate command.
#
# How it counts. A PATH shim directory holds one symlink per executable name
# found on PATH, all pointing at a single bash shim. The shim appends one line
# (the bats file, the test number, the executable name) to a log, then `exec`s
# the real tool: the first file of that name on PATH after the shim directory.
# Every process a test starts through PATH is counted, and its children too,
# because PATH still holds the shim. bash is the shim's interpreter because it
# starts fastest here and, unlike zsh, passes exported bash functions on to the
# tool it execs (bats relies on that).
#
# What it cannot see, reported in the JSON's `unseen` list:
#   * execs by absolute path (`/usr/bin/env`, `/bin/zsh`, a shebang line);
#     `absolute_path_refs` per file is a STATIC count of such references in the
#     bats file itself, not of what ran;
#   * commands found on PATH before the shim directory, such as a test's stub
#     directory prepended to PATH (a stub's interpreter is still counted when
#     its shebang goes through `env`), and every exec under a PATH that drops
#     the shim directory or under `env -i`;
#   * shell builtins and functions, which start no process.
# A profiled test that runs bats itself (run-gate.bats does) is counted in full
# for its file, but the inner run sets its own test numbers, so its processes
# can land on the wrong test row of that file.
#
# bats' own per-test processes (it runs `date`, `mkdir` and `rm` around each
# test) are not the test's. Before the real run the script profiles a one-test
# calibration file, takes its per-test counts as `bats_baseline`, and subtracts
# them from every test (never below zero). Processes started outside any test
# (bats start-up, setup_file, teardown_file) are reported per file as
# `outside_tests`, with bats' own outside processes subtracted too. Some of
# those bats starts once per test before the test has its number (the bash that
# runs the test), so a second, two-test calibration file splits them into a
# fixed part and a part per test, and the part per test is subtracted once for
# each of the file's tests.
#
# Usage:
#   profile-gate.zsh --out DIR [--jobs N] [--top N] FILE.bats [FILE.bats ...]
#     --out DIR  where report.json and report.md are written (created if
#                missing). Everything else — the shim, its logs, the TAP — lives
#                in a mktemp directory under $TMPDIR, never in the repository,
#                and is removed on exit, including on SIGINT/SIGTERM/SIGHUP.
#     --jobs N   bats files profiled at once (default 1: sequential, so
#                contention does not distort the wall times). Each file's own
#                tests always run sequentially. Counts are exact at any N.
#     --top N    rows in report.md's table (default 20); report.json lists all.
#
# Output:
#   report.json (`gate-profile/v1`):
#     {"schema":"gate-profile/v1","jobs":1,
#      "startup_ms":{"zsh":..,"bash":..,"jq":..,"git":..,"sed":..,"awk":..,"other":..},
#      "shim_ms":..,"bats_baseline":{"date":2,..},"unseen":["…"],
#      "files":[{"file":"tests/a.bats","exit":0,"wall_ms":..,"tests":N,
#        "processes":N,"processes_per_test":..,"by_exe":{"jq":..},
#        "outside_tests":{"..":..},"sleep_s":..,"fork_ms_est":..,
#        "fork_split_ms":{"jq":..,"git":..,"interpreter":..,"other":..},
#        "shim_overhead_ms_est":..,"class":"fork-bound","absolute_path_refs":N}],
#      "tests":[{"file":"tests/a.bats","number":1,"name":"…","wall_ms":..,
#        "processes":N,"by_exe":{"jq":2,"git":1}}]}
#     `files` is sorted by wall_ms, heaviest first. `processes` per file counts
#     the tests' processes only; `outside_tests` is separate.
#     fork_ms_est = Σ count × the measured start-up cost of that executable
#     (`other` for one not measured; sh costs as bash). The shim's own cost,
#     shim_ms per process, is estimated apart as shim_overhead_ms_est, and wall
#     times include it.
#     sleep_s is the sleep the file's tests asked for (each `sleep`'s first
#     argument), capped per test at that test's wall time, since a sleep that
#     is killed early or runs beside another never waited that long. A sleep
#     outside any test is not in it.
#     class, on wall_ms less shim_overhead_ms_est: "wait-bound" when sleep_s is
#     at least 30% of it, else "fork-bound" when fork_ms_est is at least 50%,
#     else "compute-bound". Both estimates sum per-process costs, so processes
#     that overlap (a pipeline, a background job) can make shim_overhead_ms_est
#     reach wall_ms: that file is "fork-bound", and report.md shows its share as
#     "overlap", since no share of a non-positive time means anything. It is a pointer for a human's recommendation, not
#     the recommendation itself.
#   report.md: a table of the top N files by wall time.
#   stderr: `profile-gate: workdir=<dir>` first, then one line per file.
#
# Exit codes:
#   0    the report was written (a red bats file is recorded in its `exit`,
#        and is not a profiler failure; its counts and class describe a failed
#        run, so draw no decision from that row)
#   1    internal failure (no shim, calibration failed, a report not written)
#   2    usage error (bad flag, no files, a file that is not a regular file,
#        an unwritable --out)
#   127  bats or jq not found
#   129/130/143  SIGHUP/SIGINT/SIGTERM: the bats runs are ended, the workdir
#        removed, and no report is written

emulate -L zsh
setopt nounset pipefail extendedglob
zmodload -F zsh/datetime p:EPOCHREALTIME
zmodload -F zsh/parameter p:commands
zmodload -F zsh/files b:zf_ln

die_usage() { print -ru2 -- "profile-gate: $1"; exit 2 }
die() { print -ru2 -- "profile-gate: $1"; exit 1 }

local out="" jobs=1 top=20
local -a files=()
while (( $# )); do
  case "$1" in
  --out) { (( $# >= 2 )) && [[ -n "$2" && "$2" != -* ]]; } || die_usage "--out needs a directory"; out="$2"; shift 2 ;;
  --jobs) { (( $# >= 2 )) && [[ "$2" == <1-> ]]; } || die_usage "--jobs needs a positive integer"; jobs=$2; shift 2 ;;
  --top) { (( $# >= 2 )) && [[ "$2" == <1-> ]]; } || die_usage "--top needs a positive integer"; top=$2; shift 2 ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  --) shift; files+=("$@"); break ;;
  -*) die_usage "unknown argument: $1" ;;
  *) files+=("$1"); shift ;;
  esac
done
[[ -n "$out" ]] || die_usage "--out is required"
(( ${#files} )) || die_usage "no bats files given"
local f
for f in "${files[@]}"; do [[ -f "$f" ]] || die_usage "not a regular file: $f"; done
local bats_bin jq_bin
bats_bin=${commands[bats]:-}; [[ -n "$bats_bin" ]] || { print -ru2 -- "profile-gate: bats not found"; exit 127 }
# Inside a bats run, PATH starts with bats' libexec directory, whose `bats`
# expects the launcher in bin/ to have exported its helper functions. Take the
# launcher instead.
[[ "$bats_bin" == */libexec/bats-core/bats && -x "${bats_bin%/libexec/bats-core/bats}/bin/bats" ]] \
  && bats_bin="${bats_bin%/libexec/bats-core/bats}/bin/bats"
jq_bin=${commands[jq]:-};     [[ -n "$jq_bin" ]] || { print -ru2 -- "profile-gate: jq not found"; exit 127 }

mkdir -p -- "$out" 2>/dev/null && [[ -w "$out" ]] || die_usage "--out is not a writable directory: $out"

# An outer bats run (this script's own tests) exports BATS_* into the
# environment; the shim would read them as the profiled test's identity.
unset -m 'BATS_*'

local work="" ; local -a pids=()
cleanup() { [[ -n "$work" && -d "$work" ]] && rm -rf -- "$work" }
# TERM every descendant, collected in full before any is signalled (a killed
# parent's children re-parent away), as run-gate.zsh does. Then wait for the
# runs, so none still writes into the workdir as it is removed.
signal_runs() {
  local -a queue=($$) tree=()
  local p c
  while (( ${#queue} )); do
    p=${queue[1]}; shift queue
    for c in ${(f)"$(pgrep -P "$p" 2>/dev/null)"}; do
      [[ "$c" == <-> ]] && { tree+=($c); queue+=($c) }
    done
  done
  (( ${#tree} )) && kill -TERM -- "${tree[@]}" 2>/dev/null
  for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
}
on_signal() { trap - EXIT; signal_runs; cleanup; exit "$1" }
trap 'cleanup' EXIT
trap 'on_signal 143' TERM
trap 'on_signal 130' INT
trap 'on_signal 129' HUP

work=$(mktemp -d "${TMPDIR:-/tmp}/profile-gate.XXXXXX") || die "cannot create a temp directory"
work=${work:A}
print -ru2 -- "profile-gate: workdir=$work"

# --- the shim -----------------------------------------------------------------
local shim="$work/shim"
mkdir -p "$shim" || die "cannot create the shim directory"
# The shim directory and the profiler's own PATH are written into the shim, so
# it knows both whatever environment a test hands it.
{
  print -r -- '#!/bin/bash'
  print -r -- "S=${(qq)shim} P=${(qq)PATH}"
  cat <<'EOF'
n=${0##*/}
if [ -n "${PROFILE_GATE_LOG:-}" ]; then
  a=; [ "$n" = sleep ] && a=${1:-}
  printf '%s\t%s\t%s\n' "${BATS_TEST_NUMBER:-}" "$n" "$a" >> "$PROFILE_GATE_LOG"
fi
# With the shim directory on PATH, resolve past it only: the entries before it
# were already passed over by the lookup that reached the shim, and one of them
# may be a stub that calls back into the shim by absolute path. The profiler's
# own PATH follows, for a test PATH that holds links to the shim only. With no
# shim entry on PATH (a stub or a link a test made reached the shim by absolute
# path), the profiler's own PATH comes first: it is what the test's `command -v`
# stood for, and no test's stub is on it. A candidate that is this shim again is
# never the real tool.
set -f; IFS=:
case ":$PATH:" in
*":$S:"*) past=; dirs="$PATH:$P" ;;
*) past=1; dirs="$P:$PATH" ;;
esac
for d in $dirs; do
  if [ "$d" = "$S" ]; then past=1; continue; fi
  [ -n "$past" ] || continue
  [ "$d/$n" -ef "$0" ] && continue
  [ -f "$d/$n" ] && [ -x "$d/$n" ] && exec "$d/$n" "$@"
done
printf 'profile-gate shim: %s: not found\n' "$n" >&2
exit 127
EOF
} > "$shim/.profile-gate-shim" || die "cannot write the shim"
chmod +x "$shim/.profile-gate-shim"
local d x
for d in $path; do
  [[ -d "$d" ]] || continue
  for x in "$d"/*(N-*:t); do
    [[ -e "$shim/$x" || -L "$shim/$x" ]] || zf_ln -s .profile-gate-shim "$shim/$x" 2>/dev/null
  done
done

# --- start-up costs, measured on the real tools --------------------------------
# ms per process, the mean of 20 runs.
measure() {
  local i t0=$EPOCHREALTIME
  for i in {1..20}; do "$@" >/dev/null 2>&1 </dev/null; done
  LC_ALL=C printf '%.3f' $(( (EPOCHREALTIME - t0) * 1000.0 / 20 ))
}
local -A cost
local real
for x in zsh bash jq git sed awk true; do
  real=${commands[$x]:-}
  if [[ -z "$real" ]]; then cost[$x]=0; continue; fi
  case $x in
  zsh)  cost[$x]=$(measure "$real" -c :) ;;
  bash) cost[$x]=$(measure "$real" -c :) ;;
  jq)   cost[$x]=$(measure "$real" -n 1) ;;
  git)  cost[$x]=$(measure "$real" --version) ;;
  sed)  cost[$x]=$(measure "$real" -n 1p) ;;
  awk)  cost[$x]=$(measure "$real" 'BEGIN{}') ;;
  true) cost[$x]=$(measure "$real") ;;
  esac
done
local shim_ms
shim_ms=$(LC_ALL=C printf '%.3f' $(( $(PATH="$shim:$PATH" measure "$shim/true") - cost[true] )))
(( shim_ms < 0 )) && shim_ms=0

# --- one bats run under the shim ----------------------------------------------
# run_one IDX FILE: TAP to $work/tap.IDX, log to $work/log.IDX, exit status and
# wall ms to $work/rc.IDX.
run_one() {
  local i=$1 file=$2 t0=$EPOCHREALTIME rc
  : > "$work/log.$i"
  PATH="$shim:$PATH" PROFILE_GATE_LOG="$work/log.$i" LC_ALL=C \
    "$bats_bin" --tap --timing "$file" > "$work/tap.$i" 2>"$work/err.$i"
  rc=$?
  print -r -- "$rc $(LC_ALL=C printf '%.0f' $(( (EPOCHREALTIME - t0) * 1000.0 )))" >| "$work/rc.$i"
}

# Calibration: bats' own processes around one empty test, then around two, so
# what bats starts outside the tests splits into a fixed part and a part per
# test.
print -r -- '@test "calibration" { :; }' > "$work/calibration.bats"
run_one calib "$work/calibration.bats" &
pids=($!); wait $!; pids=()
[[ "$(<$work/rc.calib)" == "0 "* ]] && grep -q '^ok 1 calibration in [0-9]*ms$' "$work/tap.calib" \
  || die "the calibration run failed: $(<$work/err.calib)"
print -rl -- '@test "calibration" { :; }' '@test "calibration two" { :; }' > "$work/calibration2.bats"
run_one calib2 "$work/calibration2.bats" &
pids=($!); wait $!; pids=()
[[ "$(<$work/rc.calib2)" == "0 "* ]] && grep -q '^ok 2 calibration two in [0-9]*ms$' "$work/tap.calib2" \
  || die "the calibration run failed: $(<$work/err.calib2)"

local -i i=0 n=${#files}
local -a live=(); local p
for f in "${files[@]}"; do
  (( i++ ))
  # pids holds the runs still going: drop the ended ones before counting.
  while :; do
    live=(); for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && live+=($p); done
    pids=("${live[@]}")
    (( ${#pids} < jobs )) && break
    sleep 0.2
  done
  print -ru2 -- "profile-gate: [$i/$n] $f"
  run_one $i "$f" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
pids=()

# --- the report ---------------------------------------------------------------
# One JSON line per profiled file, merged below.
logjson() {  # log file -> [{"t":"<number or empty>","n":"<exe>","a":"<arg>"}]
  "$jq_bin" -Rn '[inputs | split("\t") | {t: .[0], n: .[1], a: (.[2] // "")}]' < "$1"
}
tapjson() {  # TAP file -> [{"number":N,"name":"…","wall_ms":N,"ok":bool}]
  "$jq_bin" -Rn '[inputs
    | capture("^(?<nok>not )?ok (?<num>[0-9]+) (?<name>.*) in (?<ms>[0-9]+)ms(?<dir> # .*)?$")?
    | {number: (.num | tonumber), name, wall_ms: (.ms | tonumber), ok: (.nok == null)}]' < "$1"
}
local costs_json
costs_json=$("$jq_bin" -n --arg zsh "${cost[zsh]}" --arg bash "${cost[bash]}" --arg jq "${cost[jq]}" \
  --arg git "${cost[git]}" --arg sed "${cost[sed]}" --arg awk "${cost[awk]}" --arg other "${cost[true]}" \
  '{zsh: ($zsh|tonumber), bash: ($bash|tonumber), jq: ($jq|tonumber), git: ($git|tonumber),
    sed: ($sed|tonumber), awk: ($awk|tonumber), other: ($other|tonumber)}') || die "cannot build the cost table"
logjson "$work/log.calib" > "$work/calib.json" || die "cannot read the calibration log"
logjson "$work/log.calib2" > "$work/calib2.json" || die "cannot read the calibration log"

local rc_line refs
i=0
for f in "${files[@]}"; do
  (( i++ ))
  rc_line=$(<"$work/rc.$i")
  refs=$(grep -cE '(^|[[:space:];|&(`"'\''])/(usr/)?s?bin/[[:alnum:]_]' -- "$f" 2>/dev/null) || refs=0
  logjson "$work/log.$i" > "$work/logj.$i" || die "cannot read the log of $f"
  tapjson "$work/tap.$i" > "$work/tapj.$i" || die "cannot read the TAP of $f"
  "$jq_bin" -n --arg file "$f" --argjson rc "${rc_line% *}" --argjson wall "${rc_line#* }" \
    --argjson refs "$refs" --argjson cost "$costs_json" --argjson shim "$shim_ms" \
    --slurpfile calib "$work/calib.json" --slurpfile calib2 "$work/calib2.json" \
    --slurpfile log "$work/logj.$i" --slurpfile tap "$work/tapj.$i" '
    def counts: group_by(.n) | map({key: .[0].n, value: length}) | from_entries;
    def minus($b): with_entries(.value -= ($b[.key] // 0)) | with_entries(select(.value > 0));
    def total: [.[]] | add // 0;
    ($calib[0] | map(select(.t != "")) | counts) as $base_test
    | ($calib[0] | map(select(.t == "")) | counts) as $base_out
    | ($calib2[0] | map(select(.t == "")) | counts | minus($base_out)) as $per_test_out
    | ($base_out | minus($per_test_out)) as $fixed_out
    | ($log[0]) as $log
    | ($tap[0] | map(. as $t
        | ($log | map(select(.t == ($t.number | tostring))) | counts | minus($base_test)) as $by
        | {file: $file, number: $t.number, name: $t.name, wall_ms: $t.wall_ms,
           processes: ($by | total), by_exe: $by})) as $tests
    | ([$tests[].by_exe | to_entries[]] | group_by(.key)
        | map({key: .[0].key, value: (map(.value) | add)}) | from_entries) as $by_exe
    | ($tap[0] | length) as $ntests
    | ($log | map(select(.t == "")) | counts
        | with_entries(.value -= (($fixed_out[.key] // 0) + ($per_test_out[.key] // 0) * $ntests))
        | with_entries(select(.value > 0))) as $outside
    | ($by_exe | total) as $procs
    | ($by_exe | to_entries | map(
        if .key == "zsh" then {k: "interpreter", ms: (.value * $cost.zsh)}
        elif (.key == "bash" or .key == "sh") then {k: "interpreter", ms: (.value * $cost.bash)}
        elif .key == "jq" then {k: "jq", ms: (.value * $cost.jq)}
        elif .key == "git" then {k: "git", ms: (.value * $cost.git)}
        elif .key == "sed" then {k: "other", ms: (.value * $cost.sed)}
        elif .key == "awk" then {k: "other", ms: (.value * $cost.awk)}
        else {k: "other", ms: (.value * $cost.other)} end)) as $parts
    | ({jq: 0, git: 0, interpreter: 0, other: 0}
        + ($parts | group_by(.k) | map({key: .[0].k, value: (map(.ms) | add)}) | from_entries)
        | map_values(. * 10 | round / 10)) as $split
    | ($split | total | . * 10 | round / 10) as $fork
    | ([$tap[0][] | . as $t
        | [([$log[] | select(.t == ($t.number | tostring) and .n == "sleep") | .a | tonumber? // 0] | add // 0),
           $t.wall_ms / 1000] | min] | add // 0 | . * 1000 | round / 1000) as $sleep
    | ($procs * $shim | . * 10 | round / 10) as $shim_over
    | ($wall - $shim_over) as $net
    | {file: $file, exit: $rc, wall_ms: $wall, tests: ($tests | length), processes: $procs,
       processes_per_test: (if ($tests | length) > 0 then ($procs / ($tests | length) * 10 | round / 10) else 0 end),
       by_exe: $by_exe, outside_tests: $outside, sleep_s: $sleep, fork_ms_est: $fork,
       fork_split_ms: $split, shim_overhead_ms_est: $shim_over,
       class: (if $net <= 0 then "fork-bound"
               elif $sleep * 1000 >= 0.3 * $net then "wait-bound"
               elif $fork >= 0.5 * $net then "fork-bound" else "compute-bound" end),
       absolute_path_refs: $refs, test_rows: $tests}' > "$work/file.$i.json" || die "cannot summarise $f"
done

"$jq_bin" -n --argjson jobs "$jobs" --argjson cost "$costs_json" --argjson shim "$shim_ms" \
  --slurpfile calib "$work/calib.json" '
  ($calib[0] | map(select(.t != "")) | group_by(.n) | map({key: .[0].n, value: length}) | from_entries) as $base
  | [inputs] | sort_by(-.wall_ms) as $files
  | {schema: "gate-profile/v1", jobs: $jobs, startup_ms: $cost, shim_ms: $shim, bats_baseline: $base,
     unseen: ["execs by absolute path (a shebang, /usr/bin/env, /bin/zsh); absolute_path_refs is a static count per bats file",
              "commands found on PATH before the shim directory (a test stub dir prepended to PATH), and execs under a PATH without it or under env -i",
              "shell builtins and functions, which start no process"],
     files: [$files[] | del(.test_rows)],
     tests: [$files[] | .test_rows[]]}' "$work"/file.<->.json > "$out/report.json.tmp" \
  && mv -f "$out/report.json.tmp" "$out/report.json" || die "cannot write $out/report.json"

"$jq_bin" -r --argjson top "$top" '
  def r1: . * 10 | round / 10;
  def pct($a; $b): if $b > 0 then ($a / $b * 100 | round | tostring) + "%" else "overlap" end;
  "# Gate profile",
  "",
  "Start-up cost per process (ms): " + (.startup_ms | to_entries | map("\(.key) \(.value)") | join(", "))
    + "; shim \(.shim_ms). Jobs: \(.jobs).",
  "",
  "| File | Wall s | Tests | Procs/test | jq | git | interp | other | Fork est | Sleep s | Class |",
  "|---|---|---|---|---|---|---|---|---|---|---|",
  (.files[:$top][] |
    (.wall_ms - .shim_overhead_ms_est) as $net |
    "| \(.file) | \(.wall_ms / 1000 | r1) | \(.tests) | \(.processes_per_test) | \(.by_exe.jq // 0) | \(.by_exe.git // 0) | \((.by_exe.zsh // 0) + (.by_exe.bash // 0) + (.by_exe.sh // 0)) | \(.processes - (.by_exe.jq // 0) - (.by_exe.git // 0) - (.by_exe.zsh // 0) - (.by_exe.bash // 0) - (.by_exe.sh // 0)) | \(.fork_ms_est / 1000 | . * 100 | round / 100) s (\(pct(.fork_ms_est; $net))) | \(.sleep_s) | \(.class)\(if .exit != 0 then " (exit \(.exit))" else "" end) |"),
  "",
  "jq, git, interp and other are process counts over the whole file; Fork est is count × start-up cost, as a share of wall time less the shim overhead; `overlap` where that overhead reaches the wall time, because processes ran side by side. Sleep s is the sleep the tests asked for, capped per test at its wall time. A row whose Class carries an exit code failed under the shim, so its counts describe a failed run."
  ' "$out/report.json" > "$out/report.md" || die "cannot write $out/report.md"

print -ru2 -- "profile-gate: report $out/report.json"
exit 0
