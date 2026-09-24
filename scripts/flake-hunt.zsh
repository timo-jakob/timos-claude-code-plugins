#!/usr/bin/env zsh
# flake-hunt.zsh — reproduce load-dependent bats failures on demand (#1796).
#
# Why: several sessions share this host, and under that contention the bats gate
# reds on tests the change never touched (epic #1795). Those failures only show
# when the host happens to be busy, so they could neither be listed nor be proven
# fixed. This harness FORCES the contention instead of waiting for it, runs the
# suite (or a named subset) N times under it, and reports every test that failed
# in any iteration. A green hunt proves a flake fixed only when a hunt of the
# unfixed tree reproduced it: MAINTAINING.md states the rule.
#
# Contention, for the whole run:
#   * an oversubscribed `bats --jobs` = CPU count x the job multiplier;
#   * one CPU-burning busy loop per CPU, in the background;
#   * LC_ALL=C, like the gate (two suites sort unpinned and false-red without it).
#
# Every process it starts descends from one of two process groups — the load
# group and the current bats run's group — and all of them are ended (TERM, then
# KILL) on every exit path: normal completion, an error, Ctrl-C (INT), TERM, HUP
# and a closed output pipe (PIPE). That includes the groups GNU parallel starts for each bats job, which
# leave the bats group: the harness samples the process tree below the bats run
# every half second while it runs, and ends every group it saw. (A process that
# is born and orphaned between two samples can still escape; one that lives
# longer cannot.) Separate groups keep a terminal's Ctrl-C from reaching the load
# directly, so the harness's own trap is the one thing that ends it, and it ends
# all of it. A group is only ever signalled while it is still provably the one
# the harness saw: after a PID wrap, the same number can name someone else's.
#
# Not shipped in any plugin: this is a maintainer tool for this repo. When to run
# it, and how to read its result, is stated in MAINTAINING.md (*Hunting
# load-dependent flakes*).
#
# Usage:
#   scripts/flake-hunt.zsh [--iterations N] [--job-multiplier M] [--] [FILE.bats ...]
#     --iterations N       runs of the suite (default 20)
#     --job-multiplier M   bats --jobs = CPU count x M (default 4)
#     FILE.bats ...        the files to run, relative to the current directory
#                          (default: this repo's whole tests/ suite, from any cwd)
#     -h, --help           print this header
#
# Output:
#   stdout — for each test that failed at least once, most failures first:
#              <file>: <test name>: <fails>/<iterations>
#            followed by the TAP diagnostic lines of its FIRST failure. Nothing
#            at all when every test passed in every iteration.
#   stderr — the load/jobs setup, one progress line per iteration, a summary.
#
# Exit codes:
#   0  every iteration ran to completion and no test failed in any of them
#   1  at least one test failed (the report is on stdout)
#   2  usage error (bad flag or value, a named file that does not exist)
#   3  runtime error: bats, GNU parallel or perl missing, the repo root or a work
#      directory unavailable, a load that did not start, or a BROKEN iteration —
#      one that ran zero tests, ran fewer tests than its TAP plan, or exited
#      non-zero with no failing test. A broken run must never read as "nothing
#      flaked".
#   130 / 143 / 129 / 141  interrupted by INT / TERM / HUP / PIPE (after cleanup)
#   Only 0 proves anything clean: every other status leaves stdout without a
#   verdict for the tests that did not run.
#
# Seams (for tests):
#   FLAKE_HUNT_BATS_BIN      the bats binary (a stub can emit canned TAP)
#   FLAKE_HUNT_PARALLEL_BIN  the parallel binary probed for GNU-ness (bats
#                            itself still resolves `parallel` from PATH)
#   FLAKE_HUNT_NPROC         the CPU count (burner count and --jobs base)

emulate -L zsh
setopt nounset pipefail
zmodload zsh/parameter

die_usage() { print -u2 -- "flake-hunt: $1"; exit 2 }
die_runtime() { print -u2 -- "flake-hunt: $1"; exit 3 }

is_posint() { [[ "$1" == <-> && "$1" -gt 0 ]] }

local iterations=20 multiplier=4
local -a targets
while (( $# )); do
  case "$1" in
  --iterations)
    (( $# >= 2 )) && is_posint "$2" || die_usage "--iterations needs a positive integer"
    iterations="$2"; shift 2 ;;
  --job-multiplier)
    (( $# >= 2 )) && is_posint "$2" || die_usage "--job-multiplier needs a positive integer"
    multiplier="$2"; shift 2 ;;
  -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
  --) shift; targets+=("$@"); break ;;
  -*) die_usage "unknown argument: $1" ;;
  *) targets+=("$1"); shift ;;
  esac
done

local f
for f in "${targets[@]}"; do
  [[ -f "$f" ]] || die_usage "not a file: $f"
done
# The whole suite is this repo's tests/, wherever the harness is run from: run
# bats from the repo root so the report names files as tests/<name>.bats.
if (( ! ${#targets} )); then
  cd "${0:A:h:h}" || die_runtime "cannot enter the repo root ${0:A:h:h}"
  targets=(tests)
fi

local bats_bin="${FLAKE_HUNT_BATS_BIN:-bats}"
command -v "$bats_bin" >/dev/null 2>&1 \
  || die_runtime "bats binary not found ('$bats_bin'). Install it (brew install bats-core)."
# bats' --jobs backend is GNU parallel; without it there is no oversubscription,
# so there is nothing to hunt with. Same GNU-ness probe as run-gate.zsh — and,
# like it, `grep >/dev/null` rather than `grep -q`: under pipefail an early-exiting
# `grep -q` can SIGPIPE the producer and fail the probe on a GNU parallel.
local parallel_bin="${FLAKE_HUNT_PARALLEL_BIN:-parallel}"
command -v "$parallel_bin" >/dev/null 2>&1 \
  && "$parallel_bin" --version </dev/null 2>/dev/null | grep -i 'GNU parallel' >/dev/null \
  || die_runtime "GNU parallel not found — bats --jobs needs it. Fix: brew install parallel"
command -v perl >/dev/null 2>&1 \
  || die_runtime "perl not found — the harness needs it to start its process groups"

local nproc="${FLAKE_HUNT_NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
is_posint "$nproc" || nproc=1
local jobs=$(( nproc * multiplier ))

# --- cleanup: every exit path ends both process trees ------------------------
# The process groups of group $1 and of everything below it. GNU parallel starts
# each bats job as the leader of its OWN group, so signalling the bats group
# alone would leave those jobs to parallel's TERM handling — and orphaned once
# the KILL takes parallel. Walk the tree while the parents are still alive.
tree_groups() {
  ps -A -o pid=,ppid=,pgid= 2>/dev/null | awk -v root="$1" '
    { pid[NR] = $1; ppid[NR] = $2; pgid[NR] = $3 }
    END {
      for (i = 1; i <= NR; i++) if (pgid[i] == root) in_tree[pid[i]] = 1
      do {
        grew = 0
        for (i = 1; i <= NR; i++)
          if (!(pid[i] in in_tree) && (ppid[i] in in_tree)) { in_tree[pid[i]] = 1; grew = 1 }
      } while (grew)
      print root; seen[root] = 1
      for (i = 1; i <= NR; i++)
        if ((pid[i] in in_tree) && !(pgid[i] in seen)) { seen[pgid[i]] = 1; print pgid[i] }
    }'
}
# True while any process of the groups named in $@ is alive. Zombies do not
# count: the group leader is our own child and stays one until it is reaped.
groups_alive() {
  ps -A -o pgid=,stat= 2>/dev/null | awk -v list=" $* " \
    'index(list, " " $1 " ") && $2 !~ /^Z/ { found = 1 } END { exit !found }'
}
# True while our background job whose leader is pid $1 has not exited. Asked of
# the shell's own job table, never of `ps`: once the shell reaps the leader its
# pid is free, and a reused pid must not keep the hunt waiting on a stranger.
job_alive() {
  local st
  for st in "${(@v)jobstates}"; do [[ "$st" == *:"$1"=* ]] && return 0; done
  return 1
}
# Each group id the harness has seen, with its leader's start time then (empty
# when the leader had already exited). A group is ours to signal only while that
# still holds: the leader unchanged, or no process with that pid at all (a pid
# cannot be reused while a group of that number still has members). A different
# process now holding the pid means the number was reused: leave it alone.
# The record is (re)written each time the harness proves a group its own — at
# its launch, or found below a group that is still ours — never kept from an
# earlier sighting: a long hunt wraps the pid space, and its own later group may
# reuse a number it already recorded.
local -A group_start
note_group() {
  group_start[$1]="$(ps -o lstart= -p "$1" 2>/dev/null)"
}
ours() {
  local now
  now="$(ps -o lstart= -p "$1" 2>/dev/null)"
  [[ -z "$now" || "$now" == "${group_start[$1]-}" ]]
}
# Set `walked` to group $1 and every group below it now, noting each — but only
# while $1 is still ours: walking a reused number would enumerate a stranger's
# tree. Never call it inside $(…): the notes would be lost with the subshell.
local -a walked
walk_groups() {
  local g
  walked=()
  ours "$1" || return 0
  # the root itself keeps its launch record: it passed `ours` above, possibly only
  # because its pid is free, so re-recording it could adopt a stranger's start
  for g in ${(f)"$(tree_groups "$1")"}; do
    [[ "$g" == "$1" ]] || note_group "$g"
    walked+=("$g")
  done
}
# End group $1, the groups below it now, and any groups named after it (ones
# sampled earlier, whose parents may since have exited) — each only while ours.
end_group() {
  local pg="$1" n=0 g
  [[ -n "$pg" ]] || return 0
  local -a groups mine
  walk_groups "$pg"
  groups=("${walked[@]}" "${@:2}")
  for g in "${(u)groups[@]}"; do ours "$g" && mine+=("$g"); done
  for g in "${mine[@]}"; do kill -TERM -- "-$g" 2>/dev/null; done
  # TERM is honoured by a busy loop, bats and parallel; KILL what is left after ~2s.
  while (( ${#mine} )) && groups_alive "${mine[@]}" && (( n++ < 20 )); do sleep 0.1; done
  walk_groups "$pg"
  groups=("${mine[@]}" "${walked[@]}")
  for g in "${(u)groups[@]}"; do ours "$g" && kill -KILL -- "-$g" 2>/dev/null; done
  wait "$pg" 2>/dev/null
  return 0
}
local work="" load_pg="" bats_pg="" cleaned=0 pending=0
local -a seen_groups
cleanup() {
  (( cleaned )) && return 0
  cleaned=1
  # A second Ctrl-C while cleanup waits must not cut it short before the KILL.
  trap '' INT TERM HUP
  end_group "$bats_pg" "${seen_groups[@]}"
  end_group "$load_pg"
  [[ -n "$work" ]] && rm -rf -- "$work"
  return 0
}
# Traps are set at top level only: `emulate -L` turns LOCAL_TRAPS on, so a trap
# set inside a function would be undone when it returns.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 141' PIPE

work="$(mktemp -d "${TMPDIR:-/tmp}/flake-hunt.XXXXXX")" \
  || die_runtime "could not create a work directory"

# `perl -e "$setpgrp" -- CMD… &` starts CMD as the leader of a new process group,
# so its pid ($!) is the group id. perl, because a non-interactive zsh cannot
# switch job control on. Always launch it as a plain command, never through a
# shell function: a backgrounded function runs in a forked subshell, and $! would
# then be that subshell's pid rather than the group's.
#
# Each launch only RECORDS a signal that lands between the fork and saving $!,
# and acts on it once the new group is recorded: acting at once would end the
# harness with a group that cleanup cannot yet reach, and ignoring it would lose
# the Ctrl-C. (Inline, not a function: see the LOCAL_TRAPS note above.)
local setpgrp='setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!\n"'

trap 'pending=130' INT; trap 'pending=143' TERM; trap 'pending=129' HUP; trap 'pending=141' PIPE
perl -e "$setpgrp" -- zsh -fc 'repeat $1 { { while :; do :; done } & }; wait' flake-hunt-load "$nproc" &
load_pg=$!
note_group "$load_pg"
trap 'cleanup; exit 130' INT; trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP; trap 'cleanup; exit 141' PIPE
(( pending )) && { cleanup; exit $pending }
# Iteration 1 must not start before the contention does: wait (up to ~10s) until
# the group holds its leader and all $nproc burners.
local waited=0
until ps -A -o pgid= 2>/dev/null | awk -v g="$load_pg" -v want=$(( nproc + 1 )) \
    '$1 == g { n++ } END { exit !(n >= want) }'; do
  (( waited++ < 100 )) || die_runtime "the load group $load_pg did not start its $nproc burners"
  sleep 0.1
done
print -u2 -- "flake-hunt: load process group $load_pg ($nproc burners); bats --jobs $jobs;" \
  "$iterations iterations over: ${targets[*]}"

# --- parse one iteration's TAP ----------------------------------------------
# One "F<TAB>file<TAB>name" record per `not ok`, followed by one "D<TAB>line" per
# diagnostic line of that test. The file comes from bats' own diagnostic
# "(in test file <path>, line N)"; failing that, it is the single named file, or
# "unknown file" when several were named.
parse_tap() {
  local fallback="unknown file"
  (( ${#targets} == 1 )) && [[ -f "${targets[1]}" ]] && fallback="${targets[1]}"
  awk -v fallback="$fallback" '
    function flush() {
      if (name == "") return
      print "F\t" (file == "" ? fallback : file) "\t" name
      for (i = 1; i <= nd; i++) print "D\t" diag[i]
      name = ""; nd = 0; file = ""
    }
    /^(not )?ok [0-9]+/ {
      flush()
      if ($0 ~ /^not ok /) {
        name = $0; sub(/^not ok [0-9]+ /, "", name)
        # one key per test: a failure by timeout and one by assertion are the same
        # test, so drop a trailing TAP directive ("# timeout after 20s", "# TODO")
        sub(/ # (timeout after [0-9]+s|[Tt][Oo][Dd][Oo]|[Ss][Kk][Ii][Pp]).*$/, "", name)
      }
      next
    }
    /^#/ && name != "" {
      diag[++nd] = $0
      if (file == "" && match($0, /in test file [^,]+, line/)) {
        file = substr($0, RSTART + 13, RLENGTH - 19)
      }
      next
    }
    { flush() }
    END { flush() }
  ' "$1"
}

# A broken iteration stops the hunt: its missing tests have no verdict.
broken() {
  print -u2 -- "flake-hunt: iteration $1 is broken ($2) — refusing to report; bats stderr:"
  head -20 "$work/$1.err" >&2
  exit 3
}

# --- the iterations -----------------------------------------------------------
local -A fails first
local -a order
local i rc total not_ok plan tap line rest key keep
for (( i = 1; i <= iterations; i++ )); do
  tap="$work/$i.tap"
  trap 'pending=130' INT; trap 'pending=143' TERM; trap 'pending=129' HUP; trap 'pending=141' PIPE
  perl -e "$setpgrp" -- env LC_ALL=C "$bats_bin" --jobs "$jobs" --tap "${targets[@]}" >"$tap" 2>"$work/$i.err" &
  bats_pg=$!
  note_group "$bats_pg"
  trap 'cleanup; exit 130' INT; trap 'cleanup; exit 143' TERM
  trap 'cleanup; exit 129' HUP; trap 'cleanup; exit 141' PIPE
  (( pending )) && { cleanup; exit $pending }
  # Sample the groups below the run while it lives: once bats and GNU parallel
  # have exited, a leftover in a per-job group has no parent left to find it by.
  seen_groups=()
  while job_alive "$bats_pg"; do
    walk_groups "$bats_pg"
    seen_groups+=("${walked[@]}")
    seen_groups=("${(u)seen_groups[@]}")
    sleep 0.5
  done
  wait "$bats_pg"; rc=$?
  # the leader is gone; end anything it left behind, in its tree or seen below it
  end_group "$bats_pg" "${seen_groups[@]}"
  bats_pg=""
  seen_groups=()
  total=$(grep -cE '^(not )?ok [0-9]+' "$tap"); total=${total:-0}
  not_ok=$(grep -cE '^not ok [0-9]+' "$tap"); not_ok=${not_ok:-0}
  plan=$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' "$tap" | sed -n 1p)
  (( total == 0 )) && broken "$i" "it ran ZERO tests, bats exit $rc"
  [[ -n "$plan" && "$plan" != "$total" ]] && broken "$i" "it ran $total of $plan planned tests, bats exit $rc"
  (( rc != 0 && not_ok == 0 )) && broken "$i" "bats exited $rc with no failing test"
  print -u2 -- "flake-hunt: iteration $i/$iterations: $not_ok not ok of $total (bats exit $rc)"
  # keep="" while a record's diagnostics belong to a test already seen: only
  # its FIRST failure's diagnostics are reported.
  keep=""
  while IFS= read -r line; do
    rest="${line#?$'\t'}"
    case "$line" in
    F$'\t'*)
      key="${rest%%$'\t'*}: ${rest#*$'\t'}"
      if (( ${+fails[$key]} )); then
        keep=""
      else
        order+=("$key"); fails[$key]=0; first[$key]=""; keep="$key"
      fi
      fails[$key]=$(( ${fails[$key]} + 1 )) ;;
    D$'\t'*)
      [[ -n "$keep" ]] && first[$keep]+="$rest"$'\n' ;;
    esac
  done < <(parse_tap "$tap")
done

# --- the report ---------------------------------------------------------------
# End the contention first: nothing needs it any more, and a reader that closes
# the pipe early (`| head`) must not strand it.
cleanup
if (( ! ${#order} )); then
  print -u2 -- "flake-hunt: no test failed in $iterations iterations"
  exit 0
fi
local k
local ranked
ranked="$(for k in "${order[@]}"; do printf '%d\t%s\n' "${fails[$k]}" "$k"; done \
  | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2)"
for k in ${(f)ranked}; do
  key="${k#*$'\t'}"
  print -r -- "$key: ${fails[$key]}/$iterations"
  print -rn -- "${first[$key]}"
done
print -u2 -- "flake-hunt: ${#order} test(s) failed at least once in $iterations iterations"
exit 1
