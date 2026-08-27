#!/usr/bin/env zsh
# record-grant.zsh — persist a human's round grant as the work-dir's ceiling
# (issue #1576, epic #1431).
#
# Why: `reference/interactive.md` step 5 tells the conductor to resume the loop
# with "ceiling raised by 3". That number lived ONLY in the conductor's memory,
# across a context that compacts — and in session b27006c9 (#1558) it was lost:
# the human granted +3 at round 2 and the loop kept being invoked at the default
# ceiling of 5 for two more rounds. Had round 5 tripped the ceiling, the run
# would have reported BUDGET_EXHAUSTED at 5/5 with the grant already spent,
# asking the human for rounds they had already given. This script makes the
# grant MECHANICAL: it writes the granted ceiling into the work-dir, where
# `resolve-story-loop.zsh --resume` reads it, so a conductor that forgets the
# number cannot resume under the old ceiling.
#
# It is deliberately a SEPARATE script rather than a side effect bolted onto
# build-escalation.zsh: that script is a pure renderer, its two call sites both
# run BEFORE the human answers (the step-1 summary and the escalation comment),
# and a renderer that mutates run state is exactly the hidden coupling that
# produced this bug. One writer, one job, its own tests.
#
# Usage:
#   record-grant.zsh --work-dir DIR --status FILE --add N
#     --work-dir  the loop's work-dir — the granted ceiling is written to
#                 <work-dir>/.max-rounds
#     --status    the loop's status JSON, read for the BASE ceiling
#     --add       how many rounds the human granted (a positive integer). The
#                 delta is EXPLICIT on purpose: the conductor's cumulative
#                 grants counter is stateless prose, so two invocations at the
#                 same count are indistinguishable and no delta can be inferred
#                 from it. This script never reads that counter.
#
# The BASE ceiling is the one ACTUALLY IN FORCE, floored by any grant this
# work-dir already carries:
#   max(existing <work-dir>/.max-rounds when present and valid,
#       .effective_max_rounds                       <- preferred (#1576)
#         ... or .max_rounds + (1 when .closing_sweep_granted else 0)
#             when the status file predates that key)
# so repeat grants COMPOUND (a second +3 on an already-granted 8 yields 11, not
# 8), and a run whose closing sweep was granted its one extra round (#1434) is
# already one past `max_rounds` — which is what step 5's own prose says the
# remainder is measured from. Taking `.max_rounds` alone would silently buy one
# round fewer than the human was told they were getting.
#
# Prints the new ceiling — and nothing else — on stdout.
#
# Exit codes: 0 ok · 2 usage · 1 internal (unreadable status JSON, jq missing,
#             a write that failed)

emulate -L zsh
setopt nounset pipefail

local work_dir="" status_file="" add=""
# A DANGLING value flag (`--add` as the last word — the shape a caller produces
# from an unquoted empty variable) must not reach `shift 2`: zsh refuses the
# shift, returns 1 and leaves the positional parameters UNCHANGED, so with no
# errexit the while loop re-enters the same arm and spins forever, hanging the
# conductor's tool call instead of reporting a usage error. resolve-story-loop.zsh
# guards its own parser the same way, for the same reason.
_need_val() {   # $1 = flag, $2 = remaining argc, $3 = the candidate value
  (( $2 >= 2 )) || { print -u2 -- "record-grant: $1 requires a value"; exit 2 }
  # An EXPLICIT empty value (`--add "$VAR"` with VAR unset) is the same caller
  # mistake wearing quotes, and deserves the same diagnostic rather than the
  # later "is required", which reads as though the flag was never passed.
  [[ -n "$3" ]] || { print -u2 -- "record-grant: $1 requires a value (got an empty one)"; exit 2 }
  # ...and a following FLAG is not a value: `--add --work-dir X` would otherwise
  # silently take `--work-dir` as the delta and fail the shape check with a
  # baffling diagnostic.
  [[ "$3" != --* ]] || { print -u2 -- "record-grant: $1 requires a value (got the flag $3)"; exit 2 }
}
while [[ $# -gt 0 ]]; do
  case "$1" in
  --work-dir) _need_val "$1" $# "${2:-}"; work_dir="$2"; shift 2 ;;
  --status) _need_val "$1" $# "${2:-}"; status_file="$2"; shift 2 ;;
  --add) _need_val "$1" $# "${2:-}"; add="$2"; shift 2 ;;
  -h|--help)
    print -r -- "usage: record-grant.zsh --work-dir DIR --status FILE --add N"
    exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done

local usage="usage: record-grant.zsh --work-dir DIR --status FILE --add N"
[[ -n "$work_dir" ]] || { print -u2 -- "record-grant: --work-dir is required
$usage"; exit 2 }
[[ -n "$status_file" ]] || { print -u2 -- "record-grant: --status is required
$usage"; exit 2 }
[[ -n "$add" ]] || { print -u2 -- "record-grant: --add is required
$usage"; exit 2 }
# The same shape check the loop applies to its own ceiling flag: `<->` accepts
# leading zeros that JSON forbids and arbitrarily long digit strings that
# overflow, so bound the width too and normalise with 10# below.
[[ "$add" == <-> ]] && [[ ${#add} -le 18 ]] && (( 10#$add >= 1 )) || {
  print -u2 -- "record-grant: --add must be a positive integer of at most 18 digits (got: $add)"; exit 2 }
[[ -d "$work_dir" ]] || { print -u2 -- "record-grant: --work-dir is not a directory: $work_dir"; exit 2 }
[[ -s "$status_file" ]] || { print -u2 -- "record-grant: status file missing or empty: $status_file"; exit 1 }

whence -p jq >/dev/null 2>&1 || { print -u2 -- "record-grant: jq is required"; exit 1 }

add=$(( 10#$add ))

# Read every field in ONE jq invocation: two reads of the same path can
# disagree if the file is rewritten between them, and an unguarded second read
# that fails would silently land the grant a round low — the exact undercount
# this header warns about.
#
# One field per LINE with an explicit `-` for absent, never `@tsv` into
# `read`: tab is IFS-whitespace, so `read` collapses a run of them and an
# ABSENT middle field silently shifts every later one into the wrong variable
# — which read `closing_sweep_granted` as empty and quietly dropped the +1.
local status_fields=""
status_fields=$(jq -r '[(.max_rounds // "-"), (.effective_max_rounds // "-"), (.closing_sweep_granted // false)] | .[]' "$status_file" 2>/dev/null) || {
  print -u2 -- "record-grant: invalid status JSON: $status_file"; exit 1 }
local -a status_arr=("${(f)status_fields}")
local base_max="${status_arr[1]:-}" eff_max="${status_arr[2]:-}" granted="${status_arr[3]:-}"

[[ "$base_max" == <-> ]] && [[ ${#base_max} -le 18 ]] || {
  print -u2 -- "record-grant: status JSON has no usable max_rounds (got: ${base_max:-<absent>}) in $status_file"; exit 1 }
base_max=$(( 10#$base_max ))

# The base is the ceiling ACTUALLY IN FORCE, so a grant always adds to what the
# human was just told the run was working under.
#
# `effective_max_rounds` (#1576) is that number directly and is preferred
# whenever the loop emitted it. The `max_rounds + closing_sweep_granted`
# fallback reconstructs it for a status file written before this key existed —
# and only approximately, since it cannot see a grant the sidecar already
# carried. That is why the existing-sidecar floor below still applies to BOTH
# paths: on the fallback path it is the only thing that keeps a second grant
# from recomputing off the command line and buying nothing.
local base=0
if [[ "$eff_max" == <-> ]] && (( ${#eff_max} <= 18 )); then
  base=$(( 10#$eff_max ))
else
  base=$base_max
  # `closing_sweep_granted` is always present since #1434, but an OLDER status
  # file predates the key — `// false` reads that as "no grant", which is the
  # correct reading rather than an error.
  [[ "$granted" == "true" ]] && base=$(( base_max + 1 ))
fi

# An EXISTING sidecar is the base when it is higher, so a second grant on this
# loop compounds instead of recomputing from the command line the first grant
# already left behind. A garbage one is ignored rather than fatal — the same
# fail-quiet direction the loop's own reader takes, and the loop re-diagnoses it
# loudly on the next resume anyway.
local max_rounds_file="$work_dir/.max-rounds"
if [[ -s "$max_rounds_file" ]]; then
  local existing=""
  existing=$(<"$max_rounds_file")
  # Strip only the ENDS, exactly as resolve-story-loop.zsh's reader of this same
  # file does. Collapsing internal whitespace too would repair a multi-token
  # file into a number nobody wrote (`8\n3` -> `83`) — and because the two ends
  # would then disagree about the same bytes, the writer would compound a value
  # the reader refuses.
  existing="${existing#"${existing%%[![:space:]]*}"}"
  existing="${existing%"${existing##*[![:space:]]}"}"
  if [[ "$existing" == <-> ]] && (( ${#existing} <= 18 )); then
    (( 10#$existing > base )) && base=$(( 10#$existing ))
  else
    print -u2 -- "record-grant: ignoring an unreadable ceiling in $max_rounds_file (got: ${existing:-<empty>}) — basing the grant on the status JSON"
  fi
fi

local new_max=$(( base + add ))

# Never echo a ceiling the loop would not honour. The reader clamps anything
# above `max_rounds + MAX_ROUNDS_SIDECAR_SLACK`, so a base inflated by a stale
# or foreign sidecar would otherwise have this script report a number to the
# human that the very next resume silently reduces — a confidently wrong figure
# at exactly the moment the human is deciding whether to grant more. Clamp here
# too, say so, and print what will actually be in force.
#
# The slack is READ from the loop rather than transcribed, so the two cannot
# drift; if it cannot be read, the cap is simply not applied (the reader still
# enforces its own).
local slack=""
slack=$(sed -n 's/^typeset -gr MAX_ROUNDS_SIDECAR_SLACK=\([0-9]*\)$/\1/p' "${0:A:h}/resolve-story-loop.zsh" 2>/dev/null)
if [[ "$slack" == <-> ]] && (( ${#slack} <= 4 )); then
  local cap=$(( base_max + 10#$slack ))
  if (( new_max > cap )); then
    print -u2 -- "record-grant: clamping the new ceiling to the loop's soft cap (would have been $new_max, cap $cap) — raise --max-rounds if the run genuinely earned more"
    new_max=$cap
  fi
else
  # NEVER silent: an unreadable constant (the loop renamed or moved, or its
  # declaration respelled so the anchored regex stops matching) disables the one
  # guard that keeps this script from echoing a ceiling the loop will reduce —
  # the confidently-wrong figure this block exists to prevent.
  print -u2 -- "record-grant: could not read MAX_ROUNDS_SIDECAR_SLACK from ${0:A:h}/resolve-story-loop.zsh — reporting an unclamped ceiling; the loop still enforces its own cap"
fi
# ...and bound the WIDTH too, not just the value: the reader refuses anything
# over 18 digits outright, so an absurd-but-under-cap result would be echoed
# here and then dropped there — the same broken promise the value clamp closes.
(( ${#new_max} <= 18 )) || {
  print -u2 -- "record-grant: refusing to write a ceiling wider than 18 digits (got $new_max) — the loop's reader would refuse it"; exit 1 }

# Write via a temp file in the SAME directory then rename, so a reader on the
# next resume can never see a half-written ceiling.
local tmp="$work_dir/.max-rounds.tmp.$$"
# An interrupt between the write and the rename would otherwise strand the temp
# file in a work-dir whose fresh-run clear now sweeps `.max-rounds.tmp.*` — but
# only on the NEXT fresh run, so clean up here too rather than leaving state the
# current run cannot account for.
# EXIT cleans up; INT/TERM must also STOP. A zsh trap that merely returns lets
# execution resume, so a signal arriving after the rename would still print the
# ceiling and exit 0 — reporting a clean grant on a run that was asked to stop.
trap 'rm -f -- "$tmp" 2>/dev/null' EXIT
trap 'rm -f -- "$tmp" 2>/dev/null; exit 1' INT TERM
print -r -- "$new_max" > "$tmp" || {
  print -u2 -- "record-grant: could not write $tmp"; rm -f -- "$tmp" 2>/dev/null; exit 1 }
mv -- "$tmp" "$max_rounds_file" || {
  print -u2 -- "record-grant: could not install $max_rounds_file"; rm -f -- "$tmp" 2>/dev/null; exit 1 }

print -r -- "$new_max"
