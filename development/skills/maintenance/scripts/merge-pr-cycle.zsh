#!/usr/bin/env zsh
# merge-pr-cycle.zsh — drive one PR through the merge cycle *correctly*, so the
# orchestrator never re-derives this subtle dance as inline bash again (#431).
#
# Why (#431): the tick-client-snapper run drove the multi-PR merge phases with
# improvised background loops that carried two real bugs:
#   1. It re-triggered the Approver ~30s after `update-branch`, *before the new
#      SHA's checks had even registered* — `pending=0` on a not-yet-created
#      check set read as "settled", burning the one re-trigger before a valid
#      post-CI review could happen.
#   2. It built push refspecs as `$new:refs/...` in zsh, where `$new:refs`
#      applies the `:r` history modifier and silently mangles the refspec.
# This helper fixes both at the source: it waits for the current head SHA's
# checks to *register* (not just "zero pending on a stale set") before judging
# settled, and it re-triggers the Approver via a `/approve` PR comment — the
# mechanism the gate itself honours (#190) — so there is no empty-commit push
# and no refspec to mangle.
#
# It does NOT merge for you: arm GitHub native auto-merge first
# (`gh pr merge <pr> --auto --squash`) and this helper tells you when the
# counting approval has landed so that armed merge will fire — or when to route
# the PR to a human instead. Reporting the verdict, not forcing the merge,
# keeps the no-self-approve contract (#224) intact.
#
# Usage:
#   merge-pr-cycle.zsh [--repo OWNER/REPO] [--update] [--retrigger]
#                      [--timeout SECS] [--interval SECS]
#                      [--register-grace SECS] <pr>
#
#   --update          bring a BEHIND branch up to date first (gh pr update-branch);
#                     needed under strict "require branches up to date". A no-op
#                     if already up to date.
#   --retrigger       if CI is green but no counting approval exists yet, post a
#                     single `/approve` comment to re-trigger the Approver, then
#                     wait once more for its verdict. At most one re-trigger.
#   --timeout SECS    overall check-settle deadline (default 1800).
#   --interval SECS   poll interval (default 30).
#   --register-grace SECS  how long to wait for *some* check to appear on a
#                     fresh head SHA before concluding the PR has no checks
#                     (default 120). This is the #431-bug-1 guard.
#
# Seam: GH_BIN overrides the `gh` binary (for tests / non-PATH installs).
#
# Exit codes (each prints a single machine-readable `result: <STATE> …` line):
#   0  READY              — green + a counting approval is present; armed
#                           auto-merge will fire (or the caller may merge).
#   2  usage error
#   3  TIMED-OUT          — checks didn't settle before --timeout.
#   1  gh invocation failed (auth / network / unknown).
#   4  AWAITING-APPROVAL  — green, but no counting approval (even after an
#                           optional re-trigger); route to a human.
#   5  CHANGES-REQUESTED  — the Approver (or a reviewer) requested changes;
#                           do NOT spin — surface the rejecting review.
#   6  NOT-GREEN          — a required check failed; the failing check is the
#                           story, an approve verdict would only add noise.

emulate -L zsh
# Deliberately NOT err_exit: this script owns its exit codes, and an
# expected-nonzero inner command (e.g. `gh pr checks` on a red PR) must never
# leak out as the script's result — same contract as await-pr-checks.zsh (#412).
setopt nounset pipefail

local repo="" timeout=1800 interval=30 register_grace=120
local do_update="" do_retrigger=""
local -a positional
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) repo="$2"; shift 2 ;;
  --timeout) timeout="$2"; shift 2 ;;
  --interval) interval="$2"; shift 2 ;;
  --register-grace) register_grace="$2"; shift 2 ;;
  --update) do_update="true"; shift ;;
  --retrigger) do_retrigger="true"; shift ;;
  --) shift; positional+=("$@"); break ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) positional+=("$1"); shift ;;
  esac
done

if [[ ${#positional[@]} -ne 1 ]]; then
  print -u2 -- "usage: merge-pr-cycle.zsh [--repo OWNER/REPO] [--update] [--retrigger] [--timeout SECS] [--interval SECS] [--register-grace SECS] <pr>"
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

# --- helpers --------------------------------------------------------------

# Read the PR's current head SHA. Echoes the SHA; nonzero on gh failure.
_head_sha() {
  "$gh" pr view "$pr" ${repo_args[@]+"${repo_args[@]}"} \
    --json headRefOid --jq .headRefOid 2>"$err"
}

# Read reviewDecision (APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / empty).
_review_decision() {
  "$gh" pr view "$pr" ${repo_args[@]+"${repo_args[@]}"} \
    --json reviewDecision --jq '.reviewDecision // "NONE"' 2>"$err"
}

# Wait for the current head SHA's checks to REGISTER and SETTLE.
# Echoes "GREEN" or "NOT-GREEN" on settle; returns:
#   0 settled (verdict on stdout), 3 timed out, 1 gh error, 7 no checks at all.
# Re-pins to the head SHA each poll: if a rebase lands mid-wait, the wait
# restarts against the new SHA instead of judging a stale set (#431-bug-1).
_await_settle() {
  local deadline=$(( $(date +%s) + timeout ))
  local register_deadline=$(( $(date +%s) + register_grace ))
  local sha out rc pending total passed failed
  local sha_at_start; sha_at_start="$(_head_sha)" || return 1
  while :; do
    sha="$(_head_sha)" || return 1
    if [[ "$sha" != "$sha_at_start" ]]; then
      # A new commit landed (rebase / push): restart the register grace so we
      # don't judge the previous SHA's already-settled checks as this SHA's.
      print -- "head SHA moved ($sha_at_start -> $sha); restarting wait." >&2
      sha_at_start="$sha"
      register_deadline=$(( $(date +%s) + register_grace ))
    fi

    out="$("$gh" pr checks "$pr" ${repo_args[@]+"${repo_args[@]}"} \
      --json name,state,bucket 2>"$err")"
    rc=$?
    if (( rc != 0 )); then
      # "no checks reported" is gh's nonzero for a PR with zero checks. On a
      # fresh SHA that can mean "not registered YET" — keep waiting through the
      # register grace before concluding the PR genuinely has no checks.
      if grep -qi 'no checks reported' "$err"; then
        if (( $(date +%s) >= register_deadline )); then
          return 7
        fi
        print -- "waiting: no checks registered yet on $sha (grace)…"
        sleep "$interval"; continue
      fi
      print -u2 -- "gh pr checks failed (rc=$rc):"; cat "$err" >&2
      return 1
    fi

    total=$(print -r -- "$out" | jq 'length')
    if [[ "$total" -eq 0 ]]; then
      # Empty array (not the "no checks reported" error) — same fresh-SHA race.
      if (( $(date +%s) >= register_deadline )); then return 7; fi
      print -- "waiting: 0 checks registered yet on $sha (grace)…"
      sleep "$interval"; continue
    fi

    pending=$(print -r -- "$out" | jq '[.[] | select(.bucket == "pending")] | length')
    if [[ "$pending" -eq 0 ]]; then
      passed=$(print -r -- "$out" | jq '[.[] | select(.bucket == "pass")] | length')
      # A CANCELLED check is NOT a failed check. The Approver gate's
      # approve/approver-gate jobs are cancelled by design on every run — the
      # pull_request-triggered run is superseded by the check_suite run (#190)
      # — so folding the "cancel" bucket into the failure count flips a green
      # PR to NOT-GREEN on *every* Approver PR and makes the script exit 6
      # before the `/approve` re-trigger below can ever fire (the
      # tick-client-snapper symptom: the helper reported NOT-GREEN while all
      # required contexts were green, and the orchestrator had to hand-roll the
      # gate dance the helper exists to own). Only the "fail" bucket is a real
      # required-check failure; a genuinely-cancelled *required* CI check is
      # caught by branch protection (native auto-merge just won't fire), not by
      # this advisory verdict.
      failed=$(print -r -- "$out" | jq '[.[] | select(.bucket == "fail")] | length')
      if [[ "$failed" -eq 0 ]]; then print -- "GREEN"; else print -- "NOT-GREEN"; fi
      return 0
    fi

    if (( $(date +%s) >= deadline )); then return 3; fi
    print -- "waiting: ${pending}/${total} check(s) still pending on $sha…"
    sleep "$interval"
  done
}

# --- cycle ----------------------------------------------------------------

if [[ -n "$do_update" ]]; then
  # Bring a BEHIND branch up to date. Harmless / fast when already current.
  # A new commit may land here → _await_settle re-pins to it.
  if ! "$gh" pr update-branch "$pr" ${repo_args[@]+"${repo_args[@]}"} >/dev/null 2>"$err"; then
    if grep -qiE 'already up.to.date|not behind|merge conflict' "$err"; then
      grep -qi 'conflict' "$err" && { print -- "result: NOT-GREEN — update-branch hit a merge conflict; needs a human."; exit 6; }
      : # already up to date — fine
    else
      print -u2 -- "gh pr update-branch failed:"; cat "$err" >&2; exit 1
    fi
  fi
fi

local verdict rc
verdict="$(_await_settle)"; rc=$?
case $rc in
  1) exit 1 ;;
  3) print -- "result: TIMED-OUT — checks did not settle within ${timeout}s."; exit 3 ;;
  7) print -- "PR #$pr has no checks to await; treating CI as green, deciding on approval."
     # No checks means no CI gate; fall through to the approval check below
     # (which emits the single authoritative `result:` line).
     verdict="GREEN" ;;
esac
[[ "$verdict" == "GREEN" ]] || { print -- "result: NOT-GREEN — a required check failed on PR #$pr."; exit 6; }

# Green. Now the approval state.
local decision; decision="$(_review_decision)" || exit 1
case "$decision" in
  APPROVED) print -- "result: READY — green + APPROVED; armed auto-merge will fire."; exit 0 ;;
  CHANGES_REQUESTED) print -- "result: CHANGES-REQUESTED — surface the rejecting review; not spinning."; exit 5 ;;
esac

# REVIEW_REQUIRED / NONE: green but no counting approval yet.
if [[ -z "$do_retrigger" ]]; then
  print -- "result: AWAITING-APPROVAL — green, no counting approval (no --retrigger)."
  exit 4
fi

# Re-trigger the Approver ONCE via a /approve comment (the gate honours it,
# #190) — never an empty-commit push (#431-bug-2), never a self-approval (#224).
print -- "re-triggering the Approver once on PR #$pr (/approve comment)…"
if ! "$gh" pr comment "$pr" ${repo_args[@]+"${repo_args[@]}"} --body "/approve" >/dev/null 2>"$err"; then
  print -u2 -- "gh pr comment failed:"; cat "$err" >&2; exit 1
fi

# Wait once more for checks to settle (the re-trigger re-runs the gate), then
# read the decision a final time.
verdict="$(_await_settle)"; rc=$?
case $rc in
  1) exit 1 ;;
  3) print -- "result: TIMED-OUT — checks did not settle after re-trigger."; exit 3 ;;
  7) verdict="GREEN" ;;
esac
[[ "$verdict" == "GREEN" ]] || { print -- "result: NOT-GREEN — a required check failed after re-trigger."; exit 6; }

decision="$(_review_decision)" || exit 1
case "$decision" in
  APPROVED) print -- "result: READY — green + APPROVED after one re-trigger."; exit 0 ;;
  CHANGES_REQUESTED) print -- "result: CHANGES-REQUESTED — surfaced after re-trigger; not spinning."; exit 5 ;;
  *) print -- "result: AWAITING-APPROVAL — still no counting approval after one re-trigger; route to a human."; exit 4 ;;
esac
