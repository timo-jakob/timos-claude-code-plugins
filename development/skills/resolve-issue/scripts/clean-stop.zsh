#!/usr/bin/env zsh
# clean-stop.zsh — the durable state of an unattended run that stopped cleanly
# (#2579, epic #2582): where its review-loop work-dir lives, the marker that
# makes it resumable, and the check an attended `--resume` runs before it uses
# that state.
#
# Why: an unattended run that cannot converge must neither ship nor block the
# night, and it must not throw its rounds away either. Its work-dir therefore
# lives OUTSIDE every checkout, at a path any later session can derive:
#
#   $HOME/.claude/resolve-issue/<repo-slug>/<N>/
#     work-dir/          the loop's --work-dir
#     status.json        the loop's --status-file
#     clean-stop.json    the marker, written at the clean stop
#     stopped-run-ids    the stopped run's review-loop id ledger, set aside by read
#     checkpoint.json    checkpoint.zsh's marker (#2920), which a clean stop
#                        supersedes: write deletes it, with its kept states
#
# <repo-slug> is the user-level telemetry sink's own slug (telemetry-sink-lib.zsh
# tlm_repo_slug of tlm_derive_repo), so every worktree and clone of one repo
# names one directory, exactly as they name one telemetry file.
#
# Usage:
#   clean-stop.zsh dir   --repo-dir DIR --issue N
#       Print {base, work_dir, status_file, marker} for issue N. Creates nothing.
#   clean-stop.zsh write --repo-dir DIR --issue N --branch NAME --run-id ID
#                        [--cap-reached]
#       Write the marker beside the work-dir and print it. The status file and
#       the work-dir are the ones `dir` names, and must exist. Only a
#       BUDGET_EXHAUSTED or ESCALATE_NO_CONVERGENCE status stops cleanly; the
#       failing conditions are build-escalation.zsh's convergence verdict, plus
#       `cap` with --cap-reached (record-grant.zsh exit 3: no headroom under the
#       automatic cap). A passing verdict without --cap-reached was a grant, not
#       a stop, and is refused. A written marker supersedes a checkpoint
#       (#2920): checkpoint.json and its kept states are deleted.
#   clean-stop.zsh read  --repo-dir DIR --issue N --mode attended|unattended
#       The `--resume` check: print the marker when the session is attended and
#       a well-formed marker exists. Refused in mode unattended (exit 4) and when
#       no marker exists (exit 3). On success it first moves the work-dir's
#       `.telemetry-run-ids` ledger aside, appending it to `stopped-run-ids` in
#       the durable directory: the stopped run already listed those review-loop
#       ids in its own record, so the resumed run's ledger starts empty and its
#       record never claims them again. This happens at read, not write,
#       because the stopped run emits its record after the marker is written.
#       When a checkpoint marker is kept beside it anyway, read says so on
#       stderr and deletes it: the clean stop is the later, deliberate terminal
#       and carries strictly more state (#2920).
#   clean-stop.zsh clear --repo-dir DIR --issue N
#       Remove issue N's durable directory (a resumed run that opened its PR, or
#       an unattended run starting fresh). Absent is not an error.
#
# The marker (clean-stop/v1):
#   {schema, issue, branch, work_dir, status_file, status, last_round, ceiling,
#    convergence_failures, run_id}
#   `ceiling` is the status JSON's effective_max_rounds (else max_rounds);
#   `convergence_failures` is drawn from too-few-rounds | trend | stuck |
#   critical | cap and is never empty.
#
# Exit codes: 0 ok · 2 usage (including a status that cannot stop cleanly, and a
# passing verdict without --cap-reached) · 3 no marker (read) · 4 resume refused
# in mode unattended (read) · 1 internal (no HOME, an unreadable or malformed
# status or marker, a failed write)

emulate -L zsh
setopt nounset pipefail

local self_dir="${0:A:h}"
local usage="usage: clean-stop.zsh dir   --repo-dir DIR --issue N
       clean-stop.zsh write --repo-dir DIR --issue N --branch NAME --run-id ID [--cap-reached]
       clean-stop.zsh read  --repo-dir DIR --issue N --mode attended|unattended
       clean-stop.zsh clear --repo-dir DIR --issue N"

_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || { print -u2 -- "clean-stop: $1 requires a value"; exit 2 }
  [[ -n "$3" && "$3" != --* ]] || {
    print -u2 -- "clean-stop: $1 requires a non-empty value"; exit 2 }
}

(( $# > 0 )) || { print -u2 -- "$usage"; exit 2 }
local cmd="$1"; shift
case "$cmd" in
  dir|write|read|clear) ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  *) print -u2 -- "clean-stop: unknown subcommand: $cmd"; print -u2 -- "$usage"; exit 2 ;;
esac

local repo_dir="" issue="" branch="" run_id="" mode="" cap=0
while (( $# > 0 )); do
  case "$1" in
  --repo-dir) _need_val "$1" $# "${2:-}"; repo_dir="$2"; shift 2 ;;
  --issue) _need_val "$1" $# "${2:-}"; issue="$2"; shift 2 ;;
  --branch) [[ "$cmd" == write ]] || { print -u2 -- "clean-stop: --branch is for write only"; exit 2 }
    _need_val "$1" $# "${2:-}"; branch="$2"; shift 2 ;;
  --run-id) [[ "$cmd" == write ]] || { print -u2 -- "clean-stop: --run-id is for write only"; exit 2 }
    _need_val "$1" $# "${2:-}"; run_id="$2"; shift 2 ;;
  --cap-reached) [[ "$cmd" == write ]] || { print -u2 -- "clean-stop: --cap-reached is for write only"; exit 2 }
    cap=1; shift ;;
  --mode) [[ "$cmd" == read ]] || { print -u2 -- "clean-stop: --mode is for read only"; exit 2 }
    _need_val "$1" $# "${2:-}"; mode="$2"; shift 2 ;;
  -*) print -u2 -- "clean-stop: unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "clean-stop: unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$repo_dir" && -n "$issue" ]] || { print -u2 -- "$usage"; exit 2 }
[[ "$issue" == <-> && "$issue" != 0* ]] || {
  print -u2 -- "clean-stop: --issue must be an issue number (got: $issue)"; exit 2 }
[[ -d "$repo_dir" ]] || { print -u2 -- "clean-stop: --repo-dir is not a directory: $repo_dir"; exit 2 }
if [[ "$cmd" == write ]]; then
  [[ -n "$branch" && -n "$run_id" ]] || { print -u2 -- "clean-stop: write needs --branch and --run-id"; exit 2 }
fi
if [[ "$cmd" == read ]]; then
  [[ "$mode" == attended || "$mode" == unattended ]] || {
    print -u2 -- "clean-stop: read needs --mode attended|unattended"; exit 2 }
fi

command -v jq >/dev/null 2>&1 || { print -u2 -- "clean-stop: jq not found on PATH"; exit 1 }
source "${self_dir}/../../../scripts/telemetry/telemetry-sink-lib.zsh" || {
  print -u2 -- "clean-stop: cannot load telemetry-sink-lib.zsh"; exit 1 }
[[ -n "${HOME:-}" ]] || { print -u2 -- "clean-stop: HOME is unset, so there is no durable directory"; exit 1 }

local slug="" base=""
slug=$(tlm_repo_slug "$(tlm_derive_repo "$repo_dir")") || slug=""
[[ -n "$slug" ]] || { print -u2 -- "clean-stop: could not derive the repo slug for $repo_dir"; exit 1 }
base="$HOME/.claude/resolve-issue/$slug/$issue"
local wd="$base/work-dir" sf="$base/status.json" marker="$base/clean-stop.json"
local ledger="$base/work-dir/.telemetry-run-ids" stopped_ids="$base/stopped-run-ids"
local checkpoint="$base/checkpoint.json"

case "$cmd" in
dir)
  jq -nc --arg b "$base" --arg w "$wd" --arg s "$sf" --arg m "$marker" \
    '{base:$b, work_dir:$w, status_file:$s, marker:$m}'
  ;;

write)
  [[ -d "$wd" ]] || { print -u2 -- "clean-stop: the durable work-dir does not exist: $wd"; exit 1 }
  [[ -s "$sf" ]] || { print -u2 -- "clean-stop: the durable status file is missing or empty: $sf"; exit 1 }
  local st=""
  st=$(jq -r '.status // ""' "$sf" 2>/dev/null) || {
    print -u2 -- "clean-stop: the status file is not JSON: $sf"; exit 1 }
  [[ "$st" == BUDGET_EXHAUSTED || "$st" == ESCALATE_NO_CONVERGENCE ]] || {
    print -u2 -- "clean-stop: only BUDGET_EXHAUSTED or ESCALATE_NO_CONVERGENCE stops cleanly (got: ${st:-<none>}); take the escalation terminal"
    exit 2 }
  local verdict=""
  verdict=$(zsh "${self_dir}/build-escalation.zsh" --status "$sf" --format verdict) || {
    print -u2 -- "clean-stop: could not read the convergence verdict from $sf"; exit 1 }
  local failures=""
  failures=$(jq -c --argjson cap "$cap" '.failures + (if $cap == 1 then ["cap"] else [] end)' <<< "$verdict") || {
    print -u2 -- "clean-stop: could not read the verdict's failures"; exit 1 }
  [[ "$failures" != "[]" ]] || {
    print -u2 -- "clean-stop: the convergence verdict passes, so this exit takes the automatic grant, not a clean stop (pass --cap-reached when record-grant.zsh refused it with exit 3)"
    exit 2 }
  local doc=""
  doc=$(jq -c --argjson n "$issue" --arg b "$branch" --arg w "$wd" --arg s "$sf" \
          --argjson f "$failures" --arg r "$run_id" '
    {schema: "clean-stop/v1", issue: $n, branch: $b, work_dir: $w, status_file: $s,
     status: .status, last_round: (.rounds // 0),
     ceiling: (.effective_max_rounds // .max_rounds // 0),
     convergence_failures: $f, run_id: $r}' "$sf") || {
    print -u2 -- "clean-stop: could not build the marker"; exit 1 }
  local tmp="$marker.tmp.$$"
  { print -r -- "$doc" > "$tmp" && mv -f -- "$tmp" "$marker" } 2>/dev/null || {
    rm -f -- "$tmp"; print -u2 -- "clean-stop: could not write the marker: $marker"; exit 1 }
  # the clean stop supersedes the run's checkpoint (#2920), so the two markers
  # never coexist
  rm -rf -- "$checkpoint" "$base"/checkpoint-r*(N/) || {
    print -u2 -- "clean-stop: could not delete the superseded checkpoint in $base"; exit 1 }
  print -r -- "$doc"
  ;;

read)
  [[ "$mode" == attended ]] || {
    print -u2 -- "clean-stop: --resume is for an attended session only — an unattended run never resumes a clean stop"
    exit 4 }
  [[ -e "$marker" ]] || {
    print -u2 -- "clean-stop: no clean stop is kept for issue #$issue ($marker) — re-run without --resume to start fresh"
    exit 3 }
  jq -e -s 'length == 1 and (.[0] | type == "object" and .schema == "clean-stop/v1"
             and (.work_dir | type == "string") and (.status_file | type == "string")
             and (.branch | type == "string") and (.convergence_failures | type == "array"))' \
    "$marker" >/dev/null 2>&1 || {
    print -u2 -- "clean-stop: the marker is malformed: $marker"; exit 1 }
  if [[ -e "$checkpoint" ]]; then
    print -u2 -- "clean-stop: a checkpoint is also kept for issue #$issue — resuming from the clean stop, which supersedes it; the checkpoint is deleted"
    rm -rf -- "$checkpoint" "$base"/checkpoint-r*(N/) || {
      print -u2 -- "clean-stop: could not delete the superseded checkpoint in $base"; exit 1 }
  fi
  if [[ -e "$ledger" ]]; then
    { cat -- "$ledger" >> "$stopped_ids" && rm -f -- "$ledger" } 2>/dev/null || {
      print -u2 -- "clean-stop: could not set the stopped run's review-loop id ledger aside: $ledger"; exit 1 }
  fi
  jq -c '.' "$marker"
  ;;

clear)
  [[ -e "$base" ]] || exit 0
  rm -rf -- "$base" || { print -u2 -- "clean-stop: could not remove $base"; exit 1 }
  ;;
esac
