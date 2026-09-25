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
#   * it parallelises via bats' `--jobs` (GNU parallel) at its share of the CPUs
#     (below), so the same full suite finishes in a fraction of the sequential
#     wall-clock.
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
# minimize-options policy) — and SHARED across concurrent gates (#1798). Several
# sessions each claiming every core drove a 10-core host to load 70–130 and
# surfaced timing races, yet serialising gates is not an option. So each live
# gate holds one slot in a per-user registry directory, and a gate's job count is
#   jobs = max(1, floor(getconf _NPROCESSORS_ONLN / live gates, itself included))
# fixed once at start. A gate NEVER waits for a slot — it starts at whatever
# share it computed. A slot is a file named by the gate's PID holding that
# process's start time; an entry whose PID is gone (or was reused by another
# process — the start time no longer matches) is an orphan: not counted, removed.
# A gate removes its own slot on exit, and on SIGTERM/SIGINT/SIGHUP, which it
# also forwards to the suite it started. The suite runs under `nice` so
# interactive work stays responsive. An unusable registry is not fatal: the gate
# takes every core, as before the registry existed, and says so on stderr.
#
# Usage:
#   run-gate.zsh [--tests-dir DIR] [--tap-out FILE]
#     --tests-dir DIR   directory of .bats files to run (default: tests)
#     --tap-out FILE    where to tee the TAP stream (default: a mktemp file)
#
# Output:
#   stdout — ONE JSON summary object (machine-readable), e.g.
#     {"mode":"parallel","jobs":10,"ok":1220,"not_ok":0,"total":1220,
#      "exit":0,"tap":"/tmp/run-gate.XXXX.tap","tree":"<40-hex or empty>"}
#     mode is one of: "parallel" | "sequential" | "sequential-degraded".
#     `tree` is the working-tree identity (git-tree-id.zsh) captured at the run —
#     empty outside a git repo. On a GREEN run the caller passes it to the review
#     loop's --gate-attest so the loop skips its own byte-identical re-run of this
#     same tree (#981 gate attestation). It is a plain field; NEVER read it as
#     the pass/fail signal — `exit` is the gate verdict, `tree` only says which
#     tree was gated.
#   stderr — the live TAP stream, a human count line, and (degraded) the warning.
#
# Exit codes:
#   run-gate.zsh EXITS WITH THE SUITE'S REAL EXIT CODE (0 green, non-zero red),
#   so it drops in as a --test-cmd. Its own errors are distinct:
#     2    usage error (bad flag, missing/unwritable path, no temp file)
#     127  the bats binary is not found
#     129/130/143  the gate got SIGHUP/SIGINT/SIGTERM: its slot is removed and
#          its suite TERMed — the run is not a verdict
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
#   GATE_NPROC         overrides the derived CPU count the job share is taken
#                      from (test job derivation without depending on the host's
#                      core count).
#   GATE_SLOTS_DIR     overrides the slot registry directory (default:
#                      ${TMPDIR:-/tmp}/run-gate-slots.$UID), so a test can
#                      register "other live gates" without running any.

emulate -L zsh
setopt nounset pipefail
# The suite runs as a background job (below); zsh's default BG_NICE would add
# its own +5 on top of the explicit `nice -n 10`.
setopt no_bg_nice

local self_dir="${0:A:h}"

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

# --- cleanup: our slot, the rc file, and the suite on a signal ---------------
# Set BEFORE the slot exists, so no window leaves a slot behind. zsh defers a
# trap until a FOREGROUND child exits, so the suite runs as a background job the
# script `wait`s on (below) — that is what lets a signal act immediately.
local slot="" slot_tmp="" rc_file=""
cleanup() { local f; for f in "$slot" "$slot_tmp" "$rc_file"; do [[ -n "$f" ]] && rm -f -- "$f" 2>/dev/null; done; return 0 }
# TERM every descendant, collected in full BEFORE any is signalled: a killed
# parent's children re-parent away and could no longer be found. Always TERM,
# whatever the gate received — a background job starts with SIGINT ignored, so
# forwarding an INT would leave the suite running.
signal_suite() {
  local -a queue=($$) tree=()
  local p c
  while (( ${#queue} )); do
    p=${queue[1]}; shift queue
    for c in ${(f)"$(pgrep -P "$p" 2>/dev/null)"}; do
      [[ "$c" == <-> ]] && { tree+=($c); queue+=($c) }
    done
  done
  (( ${#tree} )) && kill -TERM -- "${tree[@]}" 2>/dev/null
}
on_signal() { trap - EXIT; signal_suite; cleanup; exit "$1" }
trap 'cleanup' EXIT
trap 'on_signal 143' TERM
trap 'on_signal 130' INT
trap 'on_signal 129' HUP

# --- job count: this gate's share of the cores, floor 1, no knob -------------
local cpus="${GATE_NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
[[ "$cpus" == <-> ]] || cpus=1     # non-numeric -> 1
(( cpus < 1 )) && cpus=1

# A process's start time — the half of a slot's identity that survives PID reuse.
# UTC, so gates with different TZ settings print one process's start identically.
start_time() { TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null }

# Register first, then count: two gates starting together each see the other.
# The slot is written under a name the <-> glob never matches and renamed into
# place, so no gate ever reads it half-written (empty) and prunes it as an orphan.
local slots_dir="${GATE_SLOTS_DIR:-${TMPDIR:-/tmp}/run-gate-slots.$UID}"
local others=0 me_start entry
me_start="$(start_time $$)"
slot_tmp="$slots_dir/.$$"
if [[ -n "$me_start" ]] && mkdir -p -m 700 -- "$slots_dir" 2>/dev/null \
   && print -r -- "$me_start" 2>/dev/null >| "$slot_tmp" \
   && slot="$slots_dir/$$" && mv -f -- "$slot_tmp" "$slot" 2>/dev/null; then
  for entry in "$slots_dir"/<->(N); do
    [[ "${entry:t}" == "$$" ]] && continue
    if [[ -n "$(start_time "${entry:t}")" && "$(start_time "${entry:t}")" == "$(<"$entry")" ]]; then
      (( others++ ))
    else
      rm -f -- "$entry"    # orphan: its gate is gone (or its PID was reused)
    fi
  done
else
  print -u2 -- "run-gate: slot registry unusable ('$slots_dir') — taking all ${cpus} cores, unshared (#1798)"
fi
local jobs=$(( cpus / (others + 1) ))
(( jobs < 1 )) && jobs=1
(( others > 0 )) && print -u2 -- "run-gate: ${others} other live gate(s) — sharing ${cpus} cores, jobs=${jobs} (#1798)"

# --- parallel? decide the mode -----------------------------------------------
# GNU-ness probe, not a bare `command -v`: a non-GNU `parallel` (moreutils)
# exists on PATH but breaks `bats --jobs`, so it must NOT count as present.
local parallel_bin="${GATE_PARALLEL_BIN:-parallel}"
local have_parallel=0
if command -v "$parallel_bin" >/dev/null 2>&1 \
   && "$parallel_bin" --version </dev/null 2>/dev/null | grep -i 'GNU parallel' >/dev/null; then
  have_parallel=1
fi

# Mode matrix, decided cores-first so a 1-core host is plain `sequential` (the
# optimum — nothing to parallelise) and NEVER the loud `sequential-degraded`
# nag: only a MULTI-core host with no GNU parallel is genuinely degraded. A share
# of one job on a multi-core host with GNU parallel is plain `sequential` too.
local mode bats_args=()
if (( cpus <= 1 )); then
  mode="sequential"
elif (( ! have_parallel )); then
  # multi-core but GNU parallel absent: run sequentially, at identical rigor,
  # but LOUDLY — this is the only case the calling skill relays to the user.
  mode="sequential-degraded"
  print -u2 -- "############################################################"
  print -u2 -- "DEGRADED: GNU parallel not found — running the full bats suite"
  print -u2 -- "SEQUENTIALLY. Expect a multiple-times-longer gate (roughly"
  print -u2 -- "${cpus}x slower on this ${cpus}-core machine). Rigor is UNCHANGED"
  print -u2 -- "— the whole suite still runs. Fix: brew install parallel"
  print -u2 -- "############################################################"
elif (( jobs > 1 )); then
  mode="parallel"
  bats_args=(--jobs "$jobs")
else
  mode="sequential"
fi

# --- working-tree identity for gate attestation (#981) -----------------------
# Captured BEFORE the run — the tree being gated. The suite is read-only, so the
# identity is stable across the run; empty outside a git repo / when git-tree-id
# can't compute one (the caller then simply gets no attestation to pass, so the
# loop falls back to running its own gate — fail-closed). Never fatal to the gate.
# Degradation is allowed, silence is not: if the helper is missing/non-exec the
# optimization is permanently dead, so say so once (on stderr) rather than
# emitting a silent empty tree forever.
local tree=""
if [[ -x "${self_dir}/git-tree-id.zsh" ]]; then
  tree="$("${self_dir}/git-tree-id.zsh" . 2>/dev/null)" || tree=""
else
  print -u2 -- "run-gate: git-tree-id.zsh not found/executable next to run-gate — gate attestation unavailable (#981)"
fi

# --- run the suite EXACTLY ONCE, tee TAP, keep bats' REAL exit ----------------
if [[ -z "$tap_out" ]]; then
  # NB: the X's MUST be trailing — BSD/macOS mktemp rejects a mid-string
  # template (e.g. run-gate.XXXXXX.tap), unlike GNU mktemp.
  tap_out="$(mktemp "${TMPDIR:-/tmp}/run-gate-tap.XXXXXX")" \
    || die_usage "could not create a TAP temp file"
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
# live progress, leaving OUR stdout clean for the single JSON summary. The suite
# is a background job so a signal's trap runs at once (see cleanup above); a
# background pipeline's `wait` status is tee's, so bats' REAL exit — never tee's
# — travels through $rc_file instead. A missing one (the subshell itself died)
# reads red, never green.
rc_file="$(mktemp "${TMPDIR:-/tmp}/run-gate-rc.XXXXXX")" \
  || die_usage "could not create an exit-code temp file"
{ nice -n 10 "$bats_bin" "${bats_args[@]}" "$tests_dir"; print -r -- $? >| "$rc_file" } \
  | tee "$tap_out" >&2 &
wait
local rc="$(<"$rc_file")"
[[ "$rc" == <-> ]] || rc=1

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
# The attestation is a GREEN-run identity: a RED run (incl. the zero-tests guard
# above forcing rc=1) must be UNATTESTABLE, so no caller — however careless —
# can pass a red run's tree and skip the suite on a tree that was never proven
# green (the #974 "silence is not evidence" rule, enforced at the source rather
# than trusting SKILL.md prose). And a shape guard keeps a stray non-hex value
# (a stub / future edit) from corrupting the machine-readable summary — `tree`
# is either 40 hex chars or the empty string.
[[ "$rc" -eq 0 ]] || tree=""
# 40 hex (SHA-1) or 64 hex (SHA-256 repos) — else blank it, so a stray value
# never corrupts the JSON summary. Exact-match by the loop is length-agnostic.
[[ "$tree" =~ '^([0-9a-f]{40}|[0-9a-f]{64})$' ]] || tree=""
printf '{"mode":"%s","jobs":%d,"ok":%d,"not_ok":%d,"total":%d,"exit":%d,"tap":"%s","tree":"%s"}\n' \
  "$mode" "$jobs" "$ok" "$not_ok" "$total" "$rc" "$tap_json" "$tree"

exit $rc
