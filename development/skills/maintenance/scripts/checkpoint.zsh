#!/usr/bin/env zsh
# checkpoint.zsh — session-surviving run-state store for the maintenance
# orchestrator (#517/#534).
#
# Why: a full maintenance run is long (detect → gather → payload → dispatch →
# per-stage PR cycles) and all orchestrator state used to live only in the
# conversation — an API/token interruption lost the run. This store persists
# each completed phase's state so a NEW session can resume instead of
# re-running detection. It lives in the target repo's
#   $(git rev-parse --git-common-dir)/claude-maintenance/
# which is repo-scoped, outside the working tree (never dirties it, nothing
# to gitignore), shared across all worktrees of the repo, and survives
# session death — /tmp artifacts and session scratchpads don't. Copy run
# artifacts (findings/payload JSON) into `dir` for the same reason.
#
# Phase names are free-form strings — the phase contract stays in SKILL.md;
# this script is a dumb, atomic key-value store keyed by phase.
#
# Usage:
#   checkpoint.zsh save   [--repo <path>] --phase <name> --data <file|->
#   checkpoint.zsh load   [--repo <path>] [--phase <name>]
#   checkpoint.zsh status [--repo <path>]
#   checkpoint.zsh clear  [--repo <path>]
#   checkpoint.zsh dir    [--repo <path>]
#
#   save    merge one phase's JSON (file, or stdin with `-`) into
#           checkpoint.json — atomic (temp + mv); creates the store on first
#           save; sets last_completed_phase
#   load    print the whole checkpoint, or one phase's data with --phase
#   status  one-line summary (last phase, updated, age, phase list)
#   clear   remove the store entirely; idempotent
#   dir     print the store directory (creating it) — for artifact copies
#
# Exit codes:
#   0  ok
#   2  usage error
#   1  real error (not a git repository, invalid JSON, jq/write failure)
#   3  no checkpoint (load/status on an empty store, load of a missing phase)

emulate -L zsh
# Deliberately NOT err_exit: explicit error handling only. A `$([[ ... ]] &&
# ...)` substitution or a SIGPIPE'd pipeline under set -e has already killed
# sibling scripts mid-run (#530) — this one owns every exit path.
setopt nounset pipefail

usage() {
  print -u2 -- "usage: checkpoint.zsh <save|load|status|clear|dir> [--repo <path>] [--phase <name>] [--data <file|->]"
  exit 2
}

(( $# >= 1 )) || usage
local sub="$1"; shift
local repo="" phase="" data=""
while (( $# > 0 )); do
  case "$1" in
  --repo) repo="$2"; shift 2 ;;
  --phase) phase="$2"; shift 2 ;;
  --data) data="$2"; shift 2 ;;
  *) print -u2 -- "checkpoint.zsh: unknown arg: $1"; exit 2 ;;
  esac
done
[[ -n "$repo" ]] || repo="$PWD"

local git_common
if ! git_common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)"; then
  print -u2 -- "checkpoint.zsh: not a git repository: $repo"
  exit 1
fi
# --git-common-dir is relative (".git") when cwd is the repo root — anchor it.
[[ "$git_common" == /* ]] || git_common="$repo/$git_common"
local ckdir="$git_common/claude-maintenance"
local ckfile="$ckdir/checkpoint.json"

case "$sub" in

dir)
  mkdir -p "$ckdir" || exit 1
  print -- "$ckdir"
  ;;

save)
  [[ -n "$phase" && -n "$data" ]] || usage
  local datafile="$data" stdin_tmp=""
  if [[ "$data" == "-" ]]; then
    stdin_tmp="$(mktemp "${TMPDIR:-/tmp}/checkpoint-data.XXXXXXXX")" || exit 1
    cat > "$stdin_tmp"
    datafile="$stdin_tmp"
  fi
  if [[ ! -f "$datafile" ]]; then
    print -u2 -- "checkpoint.zsh: data file not found: $datafile"
    [[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"
    exit 1
  fi
  if ! jq empty < "$datafile" 2>/dev/null; then
    print -u2 -- "checkpoint.zsh: --data is not valid JSON: $datafile"
    [[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"
    exit 1
  fi
  mkdir -p "$ckdir" || exit 1
  local base="{}"
  [[ -f "$ckfile" ]] && base="$(<"$ckfile")"
  local now epoch tmp
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s)"
  tmp="$(mktemp "$ckdir/.checkpoint.XXXXXXXX")" || exit 1
  if ! print -r -- "$base" | jq \
      --arg phase "$phase" --arg now "$now" --argjson epoch "$epoch" \
      --slurpfile d "$datafile" '
        .schema = 1
        | .started_at = (.started_at // $now)
        | .updated_at = $now
        | .updated_epoch = $epoch
        | .phases = (.phases // {})
        | .phases[$phase] = {completed_at: $now, data: $d[0]}
        | .last_completed_phase = $phase
      ' > "$tmp"; then
    rm -f "$tmp"
    [[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"
    print -u2 -- "checkpoint.zsh: failed to update $ckfile"
    exit 1
  fi
  mv "$tmp" "$ckfile" || { rm -f "$tmp"; exit 1; }
  [[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"
  print -- "saved: ${phase} -> ${ckfile}"
  ;;

load)
  if [[ ! -f "$ckfile" ]]; then
    print -u2 -- "checkpoint.zsh: no checkpoint for $repo"
    exit 3
  fi
  if [[ -n "$phase" ]]; then
    # jq -e exits nonzero when the result is null — a phase never saved.
    if ! jq -e --arg p "$phase" '.phases[$p].data' < "$ckfile"; then
      print -u2 -- "checkpoint.zsh: no phase '$phase' in checkpoint"
      exit 3
    fi
  else
    cat "$ckfile"
  fi
  ;;

status)
  if [[ ! -f "$ckfile" ]]; then
    print -- "no checkpoint for $repo"
    exit 3
  fi
  local last updated uepoch phases age
  last="$(jq -r '.last_completed_phase // "?"' < "$ckfile")"
  updated="$(jq -r '.updated_at // "?"' < "$ckfile")"
  uepoch="$(jq -r '.updated_epoch // 0' < "$ckfile")"
  phases="$(jq -r '.phases | keys | join(",")' < "$ckfile")"
  age=$(( $(date +%s) - uepoch ))
  print -- "checkpoint: last=${last} updated=${updated} age=${age}s phases=${phases} (${ckfile})"
  ;;

clear)
  rm -rf "$ckdir"
  print -- "cleared: $ckdir"
  ;;

*)
  usage
  ;;
esac
