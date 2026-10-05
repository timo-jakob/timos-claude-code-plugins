#!/usr/bin/env zsh
# bats-quiet.zsh — a quiet TARGETED bats run for the resolve-issue conductor (#2059).
#
# Why: a targeted `bats tests/x.bats -f '…'` during implementation or a fix pass
# prints raw TAP straight into the conductor's context — 3.1M chars over the 75
# runs epic #2015 analysed, about 10% of everything the conductor pulled in
# through tool results. `run-gate.zsh` already prints one JSON summary for the
# whole-suite gate; this is its quiet counterpart for a targeted run.
#
# It is NEVER the gate: never a substitute for run-gate.zsh, never the review
# loop's --test-cmd, and never a --gate-attest source. It reports no tree
# identity on purpose.
#
# Usage:
#   bats-quiet.zsh <bats-args…>
#     e.g. bats-quiet.zsh tests/run-gate.bats -f 'zero tests'
#   Runs `bats --tap <bats-args…>` EXACTLY ONCE. `--tap` is always added, and an
#   argument that would override it or replace the run (-p/--pretty,
#   -F/--formatter, -c/--count, -h/--help, -v/--version) is refused with exit 2,
#   so the counts always come from TAP.
#
# Output:
#   The log — bats' stdout AND stderr go only to a file the wrapper creates with
#   mktemp "${TMPDIR:-/tmp}/bats-quiet-tap.XXXXXX", never to the terminal.
#   stdout — plain text, nothing else, on green and red alike:
#     N/M passed          N = `^ok ` TAP lines (skips included), M = N + `^not ok `
#     not ok …            every `^not ok ` TAP line, verbatim, in TAP order
#     log: <path>         the full TAP; read it only on a non-zero exit
#
# Exit codes:
#   bats' REAL exit status (never a pipe's), except:
#     1    a run that reports ZERO tests while bats exits 0 — forced red, the
#          same false-green guard run-gate.zsh has
#     2    usage error (no arguments, a refused argument, or no log file could
#          be created)
#     127  the bats binary is not found
#   The 2 and 127 exits print nothing on stdout and create no log file.
#
# Seam (for tests):
#   BATS_QUIET_BIN  overrides the `bats` binary (a stub can emit canned TAP).

emulate -L zsh
setopt nounset

(( $# > 0 )) || { print -u2 -- "usage: bats-quiet.zsh <bats-args…>  (runs bats --tap <bats-args…> once)"; exit 2 }

# bats honours the LAST formatter flag, so a caller's one would override --tap
# and leave no `ok`/`not ok` line to count (a false red on a green run).
local a
for a in "$@"; do
  case $a in
    -p|--pretty|-F|--formatter|--formatter=*|-c|--count|-h|--help|-v|--version)
      print -u2 -- "bats-quiet: '$a' is not allowed (the wrapper forces --tap)"; exit 2 ;;
  esac
done

local bats_bin="${BATS_QUIET_BIN:-bats}"
command -v "$bats_bin" >/dev/null 2>&1 \
  || { print -u2 -- "bats-quiet: bats binary not found ('$bats_bin'). Install it (brew install bats-core)."; exit 127 }

# NB: the X's MUST be trailing — BSD/macOS mktemp rejects a mid-string template.
local log
log="$(mktemp "${TMPDIR:-/tmp}/bats-quiet-tap.XXXXXX")" \
  || { print -u2 -- "bats-quiet: could not create a log file"; exit 2 }

# No pipe: bats writes straight to the log, so $? is bats' own status.
"$bats_bin" --tap "$@" >| "$log" 2>&1
local rc=$?

# `grep -c` prints 0 (and exits 1) on no match; no errexit is set.
local ok not_ok
ok=$(grep -c '^ok ' "$log" 2>/dev/null); ok=${ok:-0}
not_ok=$(grep -c '^not ok ' "$log" 2>/dev/null); not_ok=${not_ok:-0}

if (( ok + not_ok == 0 && rc == 0 )); then
  print -u2 -- "bats-quiet: 0 tests ran; refusing to report green (forcing exit 1)."
  rc=1
fi

print -r -- "${ok}/$(( ok + not_ok )) passed"
grep '^not ok ' "$log" 2>/dev/null
print -r -- "log: $log"

exit $rc
