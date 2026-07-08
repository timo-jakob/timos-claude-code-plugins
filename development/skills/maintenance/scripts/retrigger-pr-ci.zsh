#!/usr/bin/env zsh
# retrigger-pr-ci.zsh — deterministically (re)trigger CI on an already-open PR
# after a bot re-push, so the new head SHA reliably gets checks (#605).
#
# Why (#605): a push authenticated with a GitHub **App installation token** (the
# Writer / Maintenance App) fires a `pull_request: synchronize` event that
# **does not create workflow runs** — the PR sits with no checks on the new head
# and native auto-merge never fires. The *opening* push is fine (the
# `pull_request: opened` on `gh pr create` runs CI), and a **close + reopen**
# (`pull_request: reopened`) was observed to reliably run CI on the current head
# SHA. So this helper closes that gap for every flow where a bot re-pushes to an
# **open** PR — the maintenance CI-fixer cycle and the open-pr re-push path.
#
# It is **identity-agnostic**: it first watches the PR's current head for checks
# to *register* (the case where the push came from a plain user identity, whose
# `synchronize` DOES run CI — e.g. a worktree `git push` in the maintenance
# fixer cycle). Only if no check registers within the grace window does it
# perform the close+reopen nudge — so a user push is never needlessly toggled,
# and a bot push is always rescued. Pass `--grace 0` to skip the watch and nudge
# immediately (for a caller that KNOWS it pushed as the App, e.g. open-pr).
#
# The nudge preserves auto-merge: if the PR had native auto-merge armed, closing
# it disarms it, so this re-arms it (same merge method) after reopening.
#
# The caller sets identity via the environment (e.g. `GH_TOKEN=$bot_token`); this
# script never mints, prints, or stores a token — it just runs `gh` with whatever
# credentials the caller provides, so close/reopen/re-arm attribute to the bot.
#
# Usage:
#   retrigger-pr-ci.zsh [--repo OWNER/REPO] [--grace SECS] [--interval SECS] <pr>
#
#   --grace SECS      how long to wait for a check to register on the current
#                     head before concluding `synchronize` produced none and the
#                     nudge is needed (default 60). --grace 0 nudges immediately.
#   --interval SECS   poll interval while watching for registration (default 10).
#
# Seam: GH_BIN overrides the `gh` binary (for tests / non-PATH installs).
#
# Exit codes (each prints a single machine-readable `result: <STATE> …` line):
#   0  CI-RUNNING  — a check registered on the current head within the grace
#                    window; `synchronize` already ran CI, so no nudge was done.
#   0  NUDGED      — no check registered; closed+reopened the PR to re-trigger CI
#                    on the current head (and re-armed auto-merge if it was armed).
#   0  NUDGED-REARM-FAILED — CI was re-triggered (reopen succeeded) but re-arming
#                    the auto-merge that closing disarmed failed; re-arm by hand.
#   2  usage error
#   1  gh invocation failed (auth / network / unknown).
#   3  NUDGE-FAILED — the close/reopen dance itself failed (surface + let a human
#                    look); the PR may be left closed, so this is a real failure.

emulate -L zsh
# Deliberately NOT err_exit: this script owns its exit codes, and an
# expected-nonzero inner command (e.g. `gh pr view` transient) must never leak
# out as the script's result — same contract as await-pr-checks.zsh (#412).
setopt nounset pipefail

local repo="" grace=60 interval=10
local -a positional
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) repo="$2"; shift 2 ;;
  --grace) grace="$2"; shift 2 ;;
  --interval) interval="$2"; shift 2 ;;
  --) shift; positional+=("$@"); break ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) positional+=("$1"); shift ;;
  esac
done

if [[ ${#positional[@]} -ne 1 ]]; then
  print -u2 -- "usage: retrigger-pr-ci.zsh [--repo OWNER/REPO] [--grace SECS] [--interval SECS] <pr>"
  exit 2
fi
local pr="${positional[1]}"
[[ "$pr" == <-> ]] || { print -u2 -- "pr must be a number, got: $pr"; exit 2; }
[[ "$grace" == <-> ]] || { print -u2 -- "--grace must be a non-negative integer, got: $grace"; exit 2; }
[[ "$interval" == <-> ]] || { print -u2 -- "--interval must be a non-negative integer, got: $interval"; exit 2; }

local gh="${GH_BIN:-gh}"
command -v "$gh" >/dev/null 2>&1 || { print -u2 -- "gh not found ($gh)"; exit 1; }

local -a repo_args
[[ -n "$repo" ]] && repo_args=(-R "$repo")

local err; err="$(mktemp)"
trap 'rm -f "$err"' EXIT

# --- watch for check registration ----------------------------------------
# Returns 0 if a check registered on the current head within the grace window
# (CI is running — no nudge needed), 1 if the window expired with none, 2 on a
# gh failure. `statusCheckRollup` is always the PR's CURRENT head's check set,
# so a non-empty rollup means CI is running on the head we care about.
_ci_registered() {
  (( grace == 0 )) && return 1   # --grace 0: skip the watch, go straight to nudge
  local deadline=$(( $(date +%s) + grace ))
  local out rc total
  while :; do
    out="$("$gh" pr view "$pr" ${repo_args[@]+"${repo_args[@]}"} \
      --json statusCheckRollup 2>"$err")"
    rc=$?
    if (( rc != 0 )); then
      print -u2 -- "gh pr view failed (rc=$rc):"; cat "$err" >&2
      return 2
    fi
    total="$(print -r -- "$out" | jq '(.statusCheckRollup // []) | length')"
    if [[ "$total" -gt 0 ]]; then return 0; fi
    if (( $(date +%s) >= deadline )); then return 1; fi
    print -u2 -- "waiting: 0 checks registered yet on PR #$pr head (grace)…"
    sleep "$interval"
  done
}

# --- the close+reopen nudge ----------------------------------------------
# Reopening fires `pull_request: reopened`, which runs the pull_request
# workflows on the current head SHA. Closing disarms native auto-merge, so we
# re-arm it (same merge method) when it was armed.
#
# Sets NUDGE_SHA (the head it re-triggered) and NUDGE_REARM_FAILED (1 if the
# auto-merge re-arm failed after a successful reopen — CI IS re-triggered, but
# the caller must re-arm by hand). Called as a plain command (NOT `$(_nudge)`)
# so those assignments survive — a command substitution would run it in a
# subshell and drop them. Returns 0 on a successful close+reopen, 1 on failure.
_nudge() {
  NUDGE_SHA=""; NUDGE_REARM_FAILED=0
  local out rc auto_method
  out="$("$gh" pr view "$pr" ${repo_args[@]+"${repo_args[@]}"} \
    --json autoMergeRequest,headRefOid 2>"$err")"
  rc=$?
  if (( rc != 0 )); then
    print -u2 -- "gh pr view (autoMerge) failed (rc=$rc):"; cat "$err" >&2
    return 1
  fi
  NUDGE_SHA="$(print -r -- "$out" | jq -r '.headRefOid')"
  # mergeMethod is SQUASH|MERGE|REBASE when armed, null when not.
  auto_method="$(print -r -- "$out" | jq -r '.autoMergeRequest.mergeMethod // empty')"

  if ! "$gh" pr close "$pr" ${repo_args[@]+"${repo_args[@]}"} >/dev/null 2>"$err"; then
    print -u2 -- "gh pr close failed:"; cat "$err" >&2
    return 1
  fi
  if ! "$gh" pr reopen "$pr" ${repo_args[@]+"${repo_args[@]}"} >/dev/null 2>"$err"; then
    print -u2 -- "gh pr reopen failed (PR may be left CLOSED — needs a human):"; cat "$err" >&2
    return 1
  fi

  if [[ -n "$auto_method" ]]; then
    # Re-arm the auto-merge that closing disarmed, with the same method. Match
    # the family convention: squash + delete-branch on merge.
    local -a merge_flags
    case "$auto_method" in
      SQUASH) merge_flags=(--squash) ;;
      MERGE) merge_flags=(--merge) ;;
      REBASE) merge_flags=(--rebase) ;;
      *) merge_flags=(--squash) ;;
    esac
    if ! "$gh" pr merge "$pr" ${repo_args[@]+"${repo_args[@]}"} \
        --auto ${merge_flags[@]} --delete-branch >/dev/null 2>"$err"; then
      print -u2 -- "gh pr merge --auto re-arm failed (CI re-triggered, but re-arm auto-merge by hand):"; cat "$err" >&2
      # CI IS re-triggered (the reopen succeeded) — the re-arm is best-effort.
      # Surface it in the stdout verdict (NUDGED-REARM-FAILED) so a caller
      # parsing only stdout isn't misled into thinking auto-merge is armed.
      NUDGE_REARM_FAILED=1
    fi
  fi
  return 0
}

# --- cycle ----------------------------------------------------------------

# Capture the rc directly — `if _ci_registered; then …; fi` would swallow it
# (a false-condition `if` with no `else` yields status 0), losing the gh-error
# (rc=2) signal.
local rc
_ci_registered; rc=$?
if (( rc == 0 )); then
  print -- "result: CI-RUNNING — checks registered on PR #$pr head; synchronize ran CI, no nudge needed."
  exit 0
fi
(( rc == 2 )) && exit 1

# No checks registered — the app-token synchronize produced none. Nudge.
print -u2 -- "no checks registered on PR #$pr head within ${grace}s — closing+reopening to re-trigger CI…"
local NUDGE_SHA="" NUDGE_REARM_FAILED=0
_nudge || { print -- "result: NUDGE-FAILED — the close/reopen dance failed on PR #$pr; check it by hand."; exit 3; }
if (( NUDGE_REARM_FAILED )); then
  print -- "result: NUDGED-REARM-FAILED — closed+reopened PR #$pr to re-trigger CI on ${NUDGE_SHA[1,12]}; re-arm auto-merge by hand."
else
  print -- "result: NUDGED — closed+reopened PR #$pr to re-trigger CI on ${NUDGE_SHA[1,12]}."
fi
exit 0
