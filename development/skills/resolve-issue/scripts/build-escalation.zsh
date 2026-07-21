#!/usr/bin/env zsh
# build-escalation.zsh — turn a review-loop status JSON (from
# resolve-story-loop.zsh, #562) into a typed, decision-ready escalation comment
# for a GitHub issue (epic #557, issue #564).
#
# Why: escalation quality decides whether a human interruption costs two minutes
# or an afternoon. Every non-CONVERGED loop exit must produce ONE issue comment
# that states the escalation type, summarises the blocker/ambiguity, lists the
# round history, and offers 2-3 concrete decision-ready options — so the human
# can answer in the thread and re-run `/development:resolve-issue <N>` to resume.
# This script only BUILDS the comment body (deterministic, testable); the skill
# posts it, applies the `needs-human-decision` label, and pushes the branch
# (no PR — a draft would trigger CI and defeat the local loop).
#
# Usage:
#   build-escalation.zsh --status FILE [--issue N] [--branch NAME] [--compare-url URL]
#     --status       the loop's status JSON (required)
#     --issue        issue number (for the header, optional)
#     --branch       pushed branch holding the diff-so-far (optional, linked)
#     --compare-url  a compare/tree URL for the branch (optional, linked)
#
# Exit codes: 0 ok · 2 usage · 1 internal (unreadable / invalid status JSON)

emulate -L zsh
setopt nounset pipefail

local status_file="" issue="" branch="" compare_url="" fmt="comment"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) status_file="$2"; shift 2 ;;
  --issue) issue="$2"; shift 2 ;;
  --branch) branch="$2"; shift 2 ;;
  --compare-url) compare_url="$2"; shift 2 ;;
  --format) fmt="$2"; shift 2 ;;
  -h|--help) print -r -- "usage: build-escalation.zsh --status FILE [--issue N] [--branch NAME] [--compare-url URL] [--format comment|summary]"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$status_file" ]] || { print -u2 -- "usage: build-escalation.zsh --status FILE [--issue N] [--branch NAME] [--compare-url URL] [--format comment|summary]"; exit 2 }
[[ "$fmt" == "comment" || "$fmt" == "summary" ]] || {
  print -u2 -- "build-escalation: --format must be 'comment' or 'summary'"; exit 2 }
[[ -s "$status_file" ]] || { print -u2 -- "build-escalation: status file missing or empty: $status_file"; exit 1 }

local st rounds max_rounds
st=$(jq -r '.status // "UNKNOWN"' "$status_file" 2>/dev/null) || { print -u2 -- "build-escalation: invalid status JSON"; exit 1 }
rounds=$(jq -r '.rounds // 0' "$status_file")
max_rounds=$(jq -r '.max_rounds // 0' "$status_file")

# one-line human summary + the concrete options, per escalation type
local summary
local -a opts
case "$st" in
ESCALATE_CONFLICT)
  summary="Reviewers gave opposing recommendations on the same code that the loop could not reconcile."
  opts=(
    "**Pick a winner** — reply with which recommendation should stand (e.g. keep the performance change and accept the readability cost, or vice-versa); the next run applies your call."
    "**Reconcile** — describe a design that satisfies both (e.g. a documented fast-path helper) and the implementor will follow it."
    "**Split** — move the conflicting concerns into separate issues so each is decided on its own."
  ) ;;
ESCALATE_NO_CONVERGENCE)
  summary="A blocker survived two consecutive review rounds unchanged — the fix passes are not resolving it."
  opts=(
    "**Unblock it** — confirm the blocker is real and add the missing constraint or fix approach the fix passes lacked; re-run to converge."
    "**Waive it** — if it is acceptable for this story, say so with a rationale and it drops to a logged suggestion."
    "**Split** — carve the stubborn blocker into its own follow-up issue and let this story proceed without it."
  ) ;;
BUDGET_EXHAUSTED)
  summary="The round budget (${max_rounds}) was spent with blockers still open."
  opts=(
    "**Extend** — if it is genuinely close, raise the budget (\`--max-rounds\`) and re-run."
    "**Triage** — mark here which remaining blockers must block vs which can be waived, then re-run."
    "**Split** — move the remaining work to a follow-up issue and open the PR for what converged."
  ) ;;
ESCALATE_AMBIGUOUS)
  summary="The repository type could not be resolved to a single review panel."
  opts=(
    "**Name the language** — set \`.maintenance.yml\` \`primary\` to the intended language so dispatch can pick its review panel."
    "**Skip review** — if this repo is out of review scope, re-run with \`--no-review\`."
    "**Add support** — if it is a language we should review, file a follow-up to add its review panel."
  ) ;;
CONVERGED)
  summary="The loop converged — zero blockers remain."
  opts=() ;;
SKIPPED)
  summary="The review loop was skipped (\`--no-review\`)."
  opts=() ;;
*)
  summary="The review loop exited \`${st}\` without converging."
  opts=(
    "Review the status details below and advise how to proceed."
    "Re-run \`/development:resolve-issue\` once the underlying issue is addressed."
  ) ;;
esac

# per-round history, one line each
local history_lines
history_lines=$(jq -r '
  (.history // []) | if length == 0 then "_(no rounds ran)_"
  else (.[] | "- Round \(.round): \(.blocking) blocking, \(.conflicts) conflict(s)"
        + (if .non_converging then ", **non-converging**" else "" end)) end' "$status_file")

# type-specific detail block from the final changelist
local detail
case "$st" in
ESCALATE_CONFLICT)
  detail=$(jq -r '(.final_changelist.conflicts // []) | if length==0 then "" else
    (.[] | "- `\(.file):\(.line)` — \(.between | join(" vs "))") end' "$status_file") ;;
ESCALATE_NO_CONVERGENCE)
  # matched_prior (#913): name the prior-round blocker the fingerprint matched
  # (line proximity, or file-wide when a side has no line), so a false trip — a
  # DIFFERENT finding that merely landed inside the match window after a fix
  # pass shifted lines — is spottable. Deliberately option-agnostic: a false
  # trip means the blocker is FRESH, not stuck — how to act on it (fix, grant
  # rounds, or waive on its own merits) belongs to the surrounding options,
  # which differ between the comment and the interactive summary.
  detail=$(jq -r '((.final_changelist.blocking // []) | map(select(.non_converging))) | if length==0 then "" else
    (.[] | "- `\(.file):\(.line)` [\(.dimension)] \(.title)"
      + (if .matched_prior then
          "\n  - matched prior-round blocker "
          + (if ((.matched_prior.line | type) != "number" or (.line | type) != "number") then "(no line recorded on one side — matched file-wide)" else "at line \(.matched_prior.line)" end)
          + " (\"\(.matched_prior.title)\") — if this is a DIFFERENT finding that only landed inside the match window, the non-convergence flag is a false trip: treat this as a fresh blocker on its own merits, not a stuck one"
        else "" end)) end' "$status_file") ;;
BUDGET_EXHAUSTED)
  detail=$(jq -r '(.final_changelist.blocking // []) | if length==0 then "" else
    (.[] | "- `\(.file):\(.line)` [\(.dimension)/\(.priority)] \(.title)") end' "$status_file") ;;
ESCALATE_AMBIGUOUS)
  detail=$(jq -r '(.final_changelist.dispatch_error // {}) | if . == {} then "" else
    "- \(.error): \(.detail // "")" end' "$status_file") ;;
*) detail="" ;;
esac

# --- summary render (interactive, #562 resume): shares the extraction above,
# omits options / branch note / marker — the skill drives the live options.
if [[ "$fmt" == "summary" ]]; then
  {
    print -r -- "Review loop **\`${st}\`** — ${rounds}/${max_rounds} rounds."
    print -r --
    print -r -- "$summary"
    if [[ -n "$detail" ]]; then
      print -r --
      print -r -- "**Remaining**"
      print -r --
      print -r -- "$detail"
    fi
    print -r --
    print -r -- "**Round history**"
    print -r --
    print -r -- "$history_lines"
  }
  exit 0
fi

# assemble the comment
{
  print -r -- "## 🚦 Review loop escalation — \`${st}\`"
  print -r --
  print -r -- "$summary"
  print -r --
  if [[ -n "$detail" ]]; then
    print -r -- "**Details**"
    print -r --
    print -r -- "$detail"
    print -r --
  fi
  print -r -- "**Round history** (${rounds}/${max_rounds} rounds)"
  print -r --
  print -r -- "$history_lines"
  print -r --
  print -r -- "**How to proceed** — reply in this thread, then re-run \`/development:resolve-issue ${issue:-<N>}\` (the run re-reads this issue, including your comment, so your decision becomes implementation context):"
  print -r --
  local i=1 opt
  for opt in "${opts[@]}"; do
    print -r -- "${i}. ${opt}"
    (( i++ ))
  done
  if [[ -n "$branch" || -n "$compare_url" ]]; then
    print -r --
    if [[ -n "$compare_url" ]]; then
      print -r -- "_Diff so far: [\`${branch:-branch}\`](${compare_url}) — pushed for review, **no PR opened** (a draft would trigger CI and defeat the local loop)._"
    else
      print -r -- "_Diff so far is on branch \`${branch}\` — pushed for review, **no PR opened**._"
    fi
  fi
  print -r --
  print -r -- "<!-- review-loop-escalation: ${st} -->"
}
