#!/usr/bin/env zsh
# run-gate.zsh — the single blessed way a skill runs the bats gate (#980).
#
# Why: the review-loop gate (resolve-issue Step 3 / resolve-story-loop's
# --test-cmd) legitimately runs the WHOLE bats suite once per review round. The
# suite is ~1,220 tests and ran ~4.7 min SEQUENTIALLY; a #976-shaped session ran
# it 12 times (~61 min, ~58% of active wall-clock), and one ad-hoc invocation ran
# it TWICE in a single call just to count `ok` vs `not ok` (~9 min) — also
# violating "read bats' real exit, not the pipe's". This helper fixes both:
#   * it runs the suite EXACTLY ONCE, tees the TAP to a file, and reports the
#     ok/not-ok counts AND bats' real exit code (never a pipe's);
#   * it parallelises via bats' `--jobs` (GNU parallel) at jobs = CPU count, so
#     the same full suite finishes in a fraction of the sequential wall-clock.
#
# Quality guardrail (epic #979): the WHOLE suite still runs every round. The
# speedup is parallelism + never double-running — NEVER subsetting or skipping.
#
# Degradation is allowed, silence is not. GNU `parallel` is bats' `--jobs`
# backend; when it is absent the gate still runs — SEQUENTIALLY, at identical
# rigor — but says so LOUDLY: a prominent stderr warning AND a machine-readable
# `"mode":"sequential-degraded"` marker in the stdout summary, so the calling
# skill can relay the slowdown (and the `brew install parallel` fix) to the user.
#
# Job count is derived from CPUs at runtime — no tuning knob (bats tests are
# process-spawn/I/O heavy, so jobs = cores is the one good default, per the
# minimize-options policy): jobs = getconf _NPROCESSORS_ONLN, floor 1.
#
# Usage:
#   run-gate.zsh [--tests-dir DIR] [--tap-out FILE]
#     --tests-dir DIR   directory of .bats files to run (default: tests)
#     --tap-out FILE    where to tee the TAP stream (default: a mktemp file)
#
# Output:
#   stdout — ONE JSON summary object (machine-readable), e.g.
#     {"mode":"parallel","jobs":10,"ok":1220,"not_ok":0,"total":1220,
#      "exit":0,"tap":"/tmp/run-gate.XXXX.tap"}
#     mode is one of: "parallel" | "sequential" | "sequential-degraded".
#   stderr — the live TAP stream, a human count line, and (degraded) the warning.
#
# Exit codes:
#   run-gate.zsh EXITS WITH THE SUITE'S REAL EXIT CODE (0 green, non-zero red),
#   so it drops in as a --test-cmd. Its own errors are distinct:
#     2    usage error (bad flag, missing/unwritable path)
#     127  the bats binary is not found
#   A run that reports ZERO tests is FORCED to a non-zero exit — a gate that ran
#   no tests must never read green (an empty/wrong --tests-dir is a red gate, not
#   a pass): if bats exited 0 but total==0, run-gate exits 1 with a loud error.
#
# GNU parallel specifically: bats' `--jobs` backend requires GNU parallel. A
# non-GNU `parallel` (e.g. Homebrew moreutils, which conflicts with the GNU
# formula) would make `bats --jobs` abort, so presence is decided by a GNU-ness
# probe (`parallel --version` mentioning "GNU parallel"), not a bare `command -v`
# — otherwise a moreutils machine would false-red on the blessed gate.
#
# Seams (for tests):
#   GATE_BATS_BIN      overrides the `bats` binary (a stub can emit canned TAP).
#   GATE_PARALLEL_BIN  overrides the `parallel` binary probed for GNU-ness. This
#                      is a TEST probe seam, not a "use this parallel" knob (bats
#                      still resolves `parallel` from PATH): point it at a missing
#                      name to force degraded mode, or at a stub whose `--version`
#                      prints "GNU parallel" to force parallel mode.
#   GATE_NPROC         overrides the derived CPU/job count (test job derivation
#                      without depending on the host's core count).

emulate -L zsh
setopt nounset pipefail

die_usage() { print -u2 -- "run-gate: $1"; exit 2 }

local tests_dir="tests" tap_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --tests-dir) (( $# >= 2 )) || die_usage "--tests-dir needs a value"; tests_dir="$2"; shift 2 ;;
  --tap-out)   { (( $# >= 2 )) && [[ -n "$2" ]]; } || die_usage "--tap-out needs a non-empty value"; tap_out="$2"; shift 2 ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  *) die_usage "unknown argument: $1" ;;
  esac
done

local bats_bin="${GATE_BATS_BIN:-bats}"
command -v "$bats_bin" >/dev/null 2>&1 \
  || { print -u2 -- "run-gate: bats binary not found ('$bats_bin'). Install it (brew install bats-core)."; exit 127 }

[[ -d "$tests_dir" ]] || die_usage "tests dir not found: $tests_dir"

# --- job count: cores, floor 1, no knob --------------------------------------
local jobs="${GATE_NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
[[ "$jobs" == <-> ]] || jobs=1     # non-numeric -> 1
(( jobs < 1 )) && jobs=1

# --- parallel? decide the mode -----------------------------------------------
# GNU-ness probe, not a bare `command -v`: a non-GNU `parallel` (moreutils)
# exists on PATH but breaks `bats --jobs`, so it must NOT count as present.
local parallel_bin="${GATE_PARALLEL_BIN:-parallel}"
local have_parallel=0
if command -v "$parallel_bin" >/dev/null 2>&1 \
   && "$parallel_bin" --version </dev/null 2>/dev/null | grep -i 'GNU parallel' >/dev/null; then
  have_parallel=1
fi

# Mode matrix, decided jobs-first so a 1-core host is plain `sequential` (the
# optimum — nothing to parallelise) and NEVER the loud `sequential-degraded`
# nag: only a MULTI-core host with no GNU parallel is genuinely degraded.
local mode bats_args=()
if (( jobs <= 1 )); then
  mode="sequential"
elif (( have_parallel )); then
  mode="parallel"
  bats_args=(--jobs "$jobs")
else
  # multi-core but GNU parallel absent: run sequentially, at identical rigor,
  # but LOUDLY — this is the only case the calling skill relays to the user.
  mode="sequential-degraded"
  print -u2 -- "############################################################"
  print -u2 -- "DEGRADED: GNU parallel not found — running the full bats suite"
  print -u2 -- "SEQUENTIALLY. Expect a multiple-times-longer gate (roughly"
  print -u2 -- "${jobs}x slower on this ${jobs}-core machine). Rigor is UNCHANGED"
  print -u2 -- "— the whole suite still runs. Fix: brew install parallel"
  print -u2 -- "############################################################"
fi

# --- run the suite EXACTLY ONCE, tee TAP, keep bats' REAL exit ----------------
if [[ -z "$tap_out" ]]; then
  # NB: the X's MUST be trailing — BSD/macOS mktemp rejects a mid-string
  # template (e.g. run-gate.XXXXXX.tap), unlike GNU mktemp.
  tap_out="$(mktemp "${TMPDIR:-/tmp}/run-gate-tap.XXXXXX")" \
    || { print -u2 -- "run-gate: could not create a TAP temp file"; exit 127 }
else
  # --tap-out must be a REGULAR file. A device (e.g. /dev/null) is writable but
  # would swallow the TAP so the counts read 0 — misfiring the zero-tests guard
  # into a false RED on a green suite; a FIFO would block the open forever.
  [[ ! -e "$tap_out" || -f "$tap_out" ]] \
    || die_usage "--tap-out must be a regular file: $tap_out"
  # A missing/unwritable directory would otherwise make tee die and bats take
  # SIGPIPE (exit 141), misread as a red suite. Fail fast with the usage
  # taxonomy instead (2>/dev/null FIRST so a failed open is quiet).
  { : 2>/dev/null >| "$tap_out"; } || die_usage "cannot write --tap-out path: $tap_out"
fi

# TAP (bats stdout) is tee'd to the file AND mirrored to stderr so the user sees
# live progress, leaving OUR stdout clean for the single JSON summary. `pipestatus[1]`
# is bats' real exit — never tee's.
"$bats_bin" "${bats_args[@]}" "$tests_dir" | tee "$tap_out" >&2
local rc=${pipestatus[1]}

# --- counts from the TAP (single source, no second run) ----------------------
# `grep -c` already prints 0 (and exits 1) when nothing matches; a `|| echo 0`
# would print a SECOND 0. No errexit is set, so the exit-1 is harmless here.
local ok not_ok total
ok=$(grep -c '^ok ' "$tap_out" 2>/dev/null); ok=${ok:-0}
not_ok=$(grep -c '^not ok ' "$tap_out" 2>/dev/null); not_ok=${not_ok:-0}
total=$(( ok + not_ok ))

# A gate that ran ZERO tests must never read green — an empty or wrong
# --tests-dir is a red gate, not a pass (the elevated false-green class this
# helper exists to prevent). Force a non-zero exit and say why, loudly.
if (( total == 0 && rc == 0 )); then
  print -u2 -- "run-gate: ERROR — 0 tests ran under '${tests_dir}'; refusing to report green (forcing exit 1)."
  rc=1
fi

print -u2 -- "run-gate: mode=${mode} jobs=${jobs} ok=${ok} not_ok=${not_ok} total=${total} exit=${rc}"

# --- machine-readable summary on stdout --------------------------------------
# Escape the tap path (the only free-form field) so a quote/backslash/control
# char in a caller-supplied --tap-out can't produce invalid JSON on the machine
# channel. Order matters: backslash first, then the others.
local tap_json="${tap_out//\\/\\\\}"
tap_json="${tap_json//\"/\\\"}"
tap_json="${tap_json//$'\n'/\\n}"
tap_json="${tap_json//$'\t'/\\t}"
printf '{"mode":"%s","jobs":%d,"ok":%d,"not_ok":%d,"total":%d,"exit":%d,"tap":"%s"}\n' \
  "$mode" "$jobs" "$ok" "$not_ok" "$total" "$rc" "$tap_json"

exit $rc
