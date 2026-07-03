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
# #521 hardened the settle wait further, after four false NOT-GREEN (exit 6)
# verdicts right after mid-wait head-SHA moves: the head SHA and its check
# rollup are now read ATOMICALLY (one gh call, so the set judged always
# belongs to the SHA judged), progress lines go to stderr (stdout is the
# captured verdict channel — a "waiting:" line there corrupted the verdict
# comparison), and CANCELLED/STALE conclusions are neutral, never failures.
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
#                           optional re-trigger); route to a human. Also the
#                           verdict when the only rejection is STALE — pinned
#                           to a superseded head (#523): that needs a fresh
#                           review, not surfacing (the result line names the
#                           superseded commit).
#   5  CHANGES-REQUESTED  — the Approver (or a reviewer) requested changes
#                           ON THE CURRENT HEAD; do NOT spin — surface the
#                           rejecting review.
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

# Read reviewDecision (APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / empty).
_review_decision() {
  "$gh" pr view "$pr" ${repo_args[@]+"${repo_args[@]}"} \
    --json reviewDecision --jq '.reviewDecision // "NONE"' 2>"$err"
}

# Is a CHANGES_REQUESTED decision STALE — the latest request-changes review
# pinned to a superseded commit, not the current head? A request-changes
# review survives branch updates (only approvals are auto-dismissed on push),
# so reviewDecision alone can carry a rejection of a long-gone SHA (#523);
# terminal exit 5 is reserved for a rejection OF THE CURRENT HEAD. Same
# commit_id == headRefOid test as the orchestrator's Phase 2.5, read
# atomically (head + reviews in one gh call, the #521 rule).
# Returns 0 (stale; echoes the superseded oid), 1 (current — or no rejection
# oid to prove staleness with, where exit 5 stays the conservative verdict),
# 2 (gh failure).
_stale_rejection_oid() {
  local out rej head_oid
  out="$("$gh" pr view "$pr" ${repo_args[@]+"${repo_args[@]}"} \
    --json headRefOid,reviews 2>"$err")" || {
    print -u2 -- "gh pr view (reviews) failed:"; cat "$err" >&2; return 2; }
  rej="$(print -r -- "$out" | jq -r \
    '[.reviews[] | select(.state == "CHANGES_REQUESTED")]
     | sort_by(.submittedAt) | last | .commit.oid // empty')"
  head_oid="$(print -r -- "$out" | jq -r '.headRefOid')"
  [[ -z "$rej" || "$rej" == "$head_oid" ]] && return 1
  print -- "$rej"
  return 0
}

# Wait for the current head SHA's checks to REGISTER and SETTLE.
# Echoes "GREEN" or "NOT-GREEN" on settle; returns:
#   0 settled (verdict on stdout), 3 timed out, 1 gh error, 7 no checks at all.
#
# stdout is the VERDICT channel — the caller captures it with $(…) — so every
# progress line in here goes to stderr. A "waiting:" line on stdout corrupted
# the captured verdict and flipped green PRs to NOT-GREEN whenever a wait
# iteration preceded the settle, i.e. after every mid-wait rebase (#521).
#
# Each poll reads the head SHA and its statusCheckRollup in ONE gh call, so
# the set judged always belongs to the SHA judged — the old two-read shape
# (pr view for the SHA, pr checks for the set) raced after a mid-wait push
# (#521). If a rebase lands mid-wait, the wait restarts against the new SHA
# instead of judging a stale set (#431-bug-1).
_await_settle() {
  local deadline=$(( $(date +%s) + timeout ))
  local register_deadline=$(( $(date +%s) + register_grace ))
  local out rc sha rollup pending total failed
  local sha_at_start=""
  while :; do
    out="$("$gh" pr view "$pr" ${repo_args[@]+"${repo_args[@]}"} \
      --json headRefOid,statusCheckRollup 2>"$err")"
    rc=$?
    if (( rc != 0 )); then
      print -u2 -- "gh pr view failed (rc=$rc):"; cat "$err" >&2
      return 1
    fi
    sha="$(print -r -- "$out" | jq -r '.headRefOid')"
    [[ -z "$sha_at_start" ]] && sha_at_start="$sha"
    if [[ "$sha" != "$sha_at_start" ]]; then
      # A new commit landed (rebase / push): restart the register grace so we
      # don't judge the previous SHA's already-settled checks as this SHA's.
      print -u2 -- "head SHA moved ($sha_at_start -> $sha); restarting wait."
      sha_at_start="$sha"
      register_deadline=$(( $(date +%s) + register_grace ))
    fi

    rollup="$(print -r -- "$out" | jq '.statusCheckRollup // []')"
    total=$(print -r -- "$rollup" | jq 'length')
    if [[ "$total" -eq 0 ]]; then
      # Nothing registered on this SHA yet — or the PR genuinely has no
      # checks. Keep waiting through the register grace before concluding
      # the latter (#431-bug-1).
      if (( $(date +%s) >= register_deadline )); then return 7; fi
      print -u2 -- "waiting: 0 checks registered yet on $sha (grace)…"
      sleep "$interval"; continue
    fi

    # Classify the rollup ourselves — CheckRun nodes plus legacy commit
    # StatusContext nodes — instead of trusting `gh pr checks` buckets.
    pending=$(print -r -- "$rollup" | jq '[.[] | select(
      (.__typename == "StatusContext" and (.state == "PENDING" or .state == "EXPECTED"))
      or (.__typename != "StatusContext" and .status != "COMPLETED"))] | length')
    if [[ "$pending" -eq 0 ]]; then
      # A CANCELLED or STALE run is NOT a failed check. The Approver gate's
      # approve/approver-gate jobs are cancelled by design on every run (the
      # pull_request-triggered run is superseded by the check_suite run,
      # #190), and a rebase marks the superseded suite's runs STALE — so
      # counting either as failure flips a green PR to NOT-GREEN (#520,
      # #521). Only a genuine failure conclusion flips the verdict; a
      # genuinely-cancelled *required* check is caught by branch protection
      # (native auto-merge just won't fire), not by this advisory verdict.
      failed=$(print -r -- "$rollup" | jq '[.[] | select(
        (.__typename == "StatusContext" and (.state == "FAILURE" or .state == "ERROR"))
        or (.__typename != "StatusContext"
            and (.conclusion == "FAILURE" or .conclusion == "TIMED_OUT"
                 or .conclusion == "ACTION_REQUIRED" or .conclusion == "STARTUP_FAILURE")))] | length')
      if [[ "$failed" -eq 0 ]]; then print -- "GREEN"; else print -- "NOT-GREEN"; fi
      return 0
    fi

    if (( $(date +%s) >= deadline )); then return 3; fi
    print -u2 -- "waiting: ${pending}/${total} check(s) still pending on $sha…"
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
local decision stale_oid stale_note=""
decision="$(_review_decision)" || exit 1
case "$decision" in
  APPROVED) print -- "result: READY — green + APPROVED; armed auto-merge will fire."; exit 0 ;;
  CHANGES_REQUESTED)
    stale_oid="$(_stale_rejection_oid)"; rc=$?
    (( rc == 2 )) && exit 1
    if (( rc == 1 )); then
      print -- "result: CHANGES-REQUESTED — surface the rejecting review; not spinning."
      exit 5
    fi
    # Stale: the rejection is pinned to a superseded commit — re-review
    # territory, not a terminal verdict. Fall through to the approval-pending
    # path so --retrigger can supersede it with a fresh review (what the
    # orchestrator otherwise re-derives by hand, #523).
    stale_note=" (only a stale changes-requested at ${stale_oid[1,12]}, superseded head — re-review, not terminal)"
    ;;
esac

# REVIEW_REQUIRED / NONE — or a stale rejection: no counting approval yet.
if [[ -z "$do_retrigger" ]]; then
  print -- "result: AWAITING-APPROVAL — green, no counting approval (no --retrigger)${stale_note}."
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
  CHANGES_REQUESTED)
    # Same staleness test as above: only a rejection of the CURRENT head is
    # terminal. If the re-triggered review hasn't landed yet, the decision
    # still carries the old stale rejection — that's awaiting, not rejected.
    stale_oid="$(_stale_rejection_oid)"; rc=$?
    (( rc == 2 )) && exit 1
    if (( rc == 1 )); then
      print -- "result: CHANGES-REQUESTED — surfaced after re-trigger; not spinning."
      exit 5
    fi
    print -- "result: AWAITING-APPROVAL — only a stale changes-requested at ${stale_oid[1,12]} (superseded head) after one re-trigger; route to a human."
    exit 4 ;;
  *) print -- "result: AWAITING-APPROVAL — still no counting approval after one re-trigger; route to a human."; exit 4 ;;
esac
