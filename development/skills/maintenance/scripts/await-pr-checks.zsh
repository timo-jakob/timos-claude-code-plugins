#!/usr/bin/env zsh
# await-pr-checks.zsh — poll a PR's checks until they SETTLE, then exit 0.
#
# Why (#412): hand-rolled poll loops written as
#   while [ "$pending" -gt 0 ]; do sleep 30; pending=$(...); done
# leak the final `[ ]` test's nonzero status as the loop's (and the background
# command's) exit code — so a perfectly successful "everything settled" poll
# reports as a FAILURE, emitting misleading `failed` notifications on an
# otherwise-green run. This helper makes the contract explicit and correct:
# exit 0 the moment the checks settle — whatever their verdict (the verdict is
# printed for the caller to read) — and reserve nonzero for REAL failures only
# (timeout, gh/auth/network error). Use it instead of hand-rolling a poll loop.
#
# Usage:
#   await-pr-checks.zsh [--repo OWNER/REPO] [--timeout SECS] [--interval SECS]
#                       [--register-grace SECS] <pr>
#
# Defaults: --timeout 1800 (30 min), --interval 30, --register-grace 120.
# Repo defaults to gh's resolution from the current working tree.
#
# Registration grace (#641): right after `gh pr update-branch` or a fresh push,
# the new head SHA has *zero* registered check runs for a short window — and
# `gh pr checks` reports that as "no checks reported", indistinguishable from a
# repo that legitimately runs no CI. Treating the empty set as settled there is
# a FALSE GREEN. So an empty set is treated as *pending* until either a check
# registers or the --register-grace window elapses; only then is it reported as
# the genuinely-checkless verdict. Same flag/semantics as merge-pr-cycle.zsh.
#
# Seam: GH_BIN overrides the `gh` binary (for tests / non-PATH installs).
#
# Exit codes:
#   0  checks settled — prints "settled: N passed, M failed, … — GREEN|NOT-GREEN"
#      (also when the PR legitimately has no checks after the grace: nothing
#      to await)
#   2  usage error
#   3  timed out before the checks settled — a real failure; caller decides
#   1  gh invocation failed (auth / network / unknown) — a real failure
#
# Note: a NOT-GREEN settled result is still exit 0 — a red check is the PR's
# verdict, not a failure of the poll. Read stdout (or run your own
# `gh pr checks`) to branch on green vs red.

emulate -L zsh
# Deliberately NOT err_exit: this script manages its own exit codes, and the
# whole point of #412 is that an expected-nonzero inner command must never leak
# out as the script's result.
setopt nounset pipefail

local repo="" timeout=1800 interval=30 register_grace=120
local -a positional
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) repo="$2"; shift 2 ;;
  --timeout) timeout="$2"; shift 2 ;;
  --interval) interval="$2"; shift 2 ;;
  --register-grace) register_grace="$2"; shift 2 ;;
  --) shift; positional+=("$@"); break ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) positional+=("$1"); shift ;;
  esac
done

if [[ ${#positional[@]} -ne 1 ]]; then
  print -u2 -- "usage: await-pr-checks.zsh [--repo OWNER/REPO] [--timeout SECS] [--interval SECS] [--register-grace SECS] <pr>"
  exit 2
fi
local pr="${positional[1]}"
[[ "$pr" == <-> ]] || { print -u2 -- "pr must be a number, got: $pr"; exit 2; }

local gh="${GH_BIN:-gh}"
command -v "$gh" >/dev/null 2>&1 || { print -u2 -- "gh not found ($gh)"; exit 1; }

local -a repo_args
[[ -n "$repo" ]] && repo_args=(-R "$repo")

local err; err="$(mktemp)"
trap 'rm -f "$err"' EXIT

local deadline=$(( $(date +%s) + timeout ))
local register_deadline=$(( $(date +%s) + register_grace ))
local out rc pending total passed failed other verdict
while :; do
  out="$("$gh" pr checks "$pr" ${repo_args[@]+"${repo_args[@]}"} \
    --json name,state,bucket 2>"$err")"
  rc=$?
  if (( rc != 0 )); then
    # `gh pr checks` exits non-zero with "no checks reported" when the head SHA
    # has zero registered check runs. That is ambiguous: a fresh push/rebase has
    # a window where checks haven't registered yet (a FALSE GREEN if we settle
    # now, #641), vs. a repo that genuinely runs no CI. Keep polling through the
    # register grace; only after it elapses with the set still empty do we
    # conclude the legitimately-checkless case.
    if grep -qi 'no checks reported' "$err"; then
      if (( $(date +%s) >= register_deadline )); then
        print -- "PR #$pr has no checks after ${register_grace}s grace — nothing to await (settled)."
        exit 0
      fi
      if (( $(date +%s) >= deadline )); then
        print -u2 -- "timed out after ${timeout}s with no checks registered on PR #$pr."
        exit 3
      fi
      print -- "waiting: 0 checks registered yet on PR #$pr (grace)…"
      sleep "$interval"
      continue
    fi
    print -u2 -- "gh pr checks failed (rc=$rc):"
    cat "$err" >&2
    exit 1
  fi

  pending=$(print -r -- "$out" | jq '[.[] | select(.bucket == "pending")] | length')
  total=$(print -r -- "$out" | jq 'length')

  if [[ "$pending" -eq 0 ]]; then
    passed=$(print -r -- "$out" | jq '[.[] | select(.bucket == "pass")] | length')
    # A CANCELLED check is NOT a failed check (#522): the Approver gate's
    # approve/approver-gate jobs are cancelled by design on every run (#190),
    # so counting the cancel bucket as failed flips every green Approver PR to
    # NOT-GREEN. Only the fail bucket is a real failure (same rule as
    # merge-pr-cycle.zsh and the root CLAUDE.md); cancels land in "other" so
    # they stay visible on the settled: line.
    failed=$(print -r -- "$out" | jq '[.[] | select(.bucket == "fail")] | length')
    other=$(( total - passed - failed ))
    if [[ "$failed" -eq 0 ]]; then verdict="GREEN"; else verdict="NOT-GREEN"; fi
    print -- "settled: ${passed} passed, ${failed} failed, ${other} other (of ${total}) — ${verdict}"
    exit 0
  fi

  if (( $(date +%s) >= deadline )); then
    print -u2 -- "timed out after ${timeout}s with ${pending} check(s) still pending on PR #$pr."
    exit 3
  fi

  print -- "waiting: ${pending}/${total} check(s) still pending on PR #$pr…"
  sleep "$interval"
done
