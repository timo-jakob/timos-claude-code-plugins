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
#     --grants       interactive-extension grants already consumed (optional;
#                    rendered against the soft cap so the human sees the
#                    context at the grant prompt, #969)
#
# Exit codes: 0 ok · 2 usage · 1 internal (unreadable / invalid status JSON)

emulate -L zsh
setopt nounset pipefail

local status_file="" issue="" branch="" compare_url="" fmt="comment" grants=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --status) status_file="$2"; shift 2 ;;
  --issue) issue="$2"; shift 2 ;;
  --branch) branch="$2"; shift 2 ;;
  --compare-url) compare_url="$2"; shift 2 ;;
  --format) fmt="$2"; shift 2 ;;
  --grants) grants="$2"; shift 2 ;;
  -h|--help) print -r -- "usage: build-escalation.zsh --status FILE [--issue N] [--branch NAME] [--compare-url URL] [--format comment|summary] [--grants N]"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
[[ -n "$status_file" ]] || { print -u2 -- "usage: build-escalation.zsh --status FILE [--issue N] [--branch NAME] [--compare-url URL] [--format comment|summary] [--grants N]"; exit 2 }
[[ "$fmt" == "comment" || "$fmt" == "summary" ]] || {
  print -u2 -- "build-escalation: --format must be 'comment' or 'summary'"; exit 2 }
[[ -z "$grants" || "$grants" == <-> ]] || {
  print -u2 -- "build-escalation: --grants must be a non-negative integer (got: $grants)"; exit 2 }
[[ -z "$issue" || "$issue" == <-> ]] || {
  print -u2 -- "build-escalation: --issue must be an issue number (got: $issue)"; exit 2 }
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
  detail=$(jq -r '
    def safe: tostring | gsub("[\r\n`]"; " ") | .[0:200];
    (.final_changelist.conflicts // []) | if length==0 then "" else
    (.[] | "- `\(.file | safe)\(if (.line | type) == "number" then ":\(.line)" else "" end)` — \(.between | join(" vs "))") end' "$status_file") ;;
ESCALATE_NO_CONVERGENCE)
  # matched_prior (#913): name the prior-round blocker the fingerprint matched
  # (line proximity, or file-wide when a side has no line), so a false trip — a
  # DIFFERENT finding that merely landed inside the match window after a fix
  # pass shifted lines — is spottable. The consolidator now stamps
  # possible_false_trip (#969) when the titles differ; render the flag so the
  # human never has to open the JSON. Deliberately option-agnostic: a false
  # trip means the blocker is FRESH, not stuck — how to act on it (fix, grant
  # rounds, or waive on its own merits) belongs to the surrounding options,
  # which differ between the comment and the interactive summary.
  detail=$(jq -r '
    def sevword: if .=="Critical" then "Critical" elif .=="High" then "Warning" else "Suggestion" end;
    def safe: tostring | gsub("[\r\n`]"; " ") | .[0:200];
    ((.final_changelist.blocking // []) | map(select(.non_converging))) | if length==0 then "" else
    (.[] | "- `\(.file | safe)\(if (.line | type) == "number" then ":\(.line)" else "" end)` [\(.dimension | safe)/\((.priority // "High") | sevword)\(if .promoted == true then " (promoted)" else "" end)] \(.title | safe)"
      + (if .matched_prior then
          "\n  - matched prior-round blocker "
          + (if ((.matched_prior.line | type) != "number" or (.line | type) != "number") then "(no line recorded on one side — matched file-wide)" else "at line \(.matched_prior.line)" end)
          + " (\"\(.matched_prior.title // "" | safe)\")"
          + (if .possible_false_trip == true then " — **flagged possible false trip**: the titles differ, so this may be a NEW finding that only landed inside the match window; treat it as a fresh blocker on its own merits, not a stuck one"
             else " — if this is a DIFFERENT finding that only landed inside the match window, the non-convergence flag is a false trip: treat this as a fresh blocker on its own merits, not a stuck one" end)
        else "" end)) end' "$status_file") ;;
BUDGET_EXHAUSTED)
  detail=$(jq -r '
    def sevword: if .=="Critical" then "Critical" elif .=="High" then "Warning" else "Suggestion" end;
    def safe: tostring | gsub("[\r\n`]"; " ") | .[0:200];
    (.final_changelist.blocking // []) | if length==0 then "" else
    (.[] | "- `\(.file | safe)\(if (.line | type) == "number" then ":\(.line)" else "" end)` [\(.dimension | safe)/\((.priority // "High") | sevword)\(if .promoted == true then " (promoted)" else "" end)] \(.title | safe)"
      + (if .false_trip == true then " — identity-cleared false trip (#983): landed in a prior-round blocker match window but shares no title terms, so it is a FRESH blocker, not a stuck one" else "" end)) end' "$status_file") ;;
ESCALATE_AMBIGUOUS)
  detail=$(jq -r '(.final_changelist.dispatch_error // {}) | if . == {} then "" else
    "- \(.error): \(.detail // "")" end' "$status_file") ;;
*) detail="" ;;
esac

# --- per-round progress table + convergence assessment (#969) ----------------
# Both are derived from .round_changelists (the full per-round changelists the
# loop already retains for the dossier, #563), so the in-session summary, the
# grant prompt, the escalation comment, AND progress.md all read the SAME
# computed numbers — the stamped/carried/new/fixed derivation below is one of
# THREE copies kept in lockstep with render-progress-block.zsh and
# build-telemetry-record.zsh; change all three together. (build-dossier.zsh is
# NOT one of them — it has no such derivation; it shares only the per-item
# `promoted` expression, whose own copy count is noted at that expression.)
# The new/carried/fixed columns need the #913 per-item non_converging stamp;
# a stamp-less round degrades those cells to "–" rather than a confident wrong
# number. Fixed counts DISTINCT matched priors (two current blockers matching
# the same prior must not hide a genuinely fixed second one). An empty
# .round_changelists (older status JSONs, ambiguous-dispatch carriers) renders
# neither block — the round history above still carries the bare trend. The
# Promoted column (#995) is a SUBSET of Warning, never added to it. NB: the
# `(N promoted)` round suffix in build-dossier.zsh decides PER ROUND, unlike
# this table-wide column — see ARCHITECTURE.md.
local round_table assessment
round_table=$(jq -r '
  (.round_changelists // []) as $rs
  | if ($rs | length) == 0 then "" else
    # The Promoted column renders only when SOME round actually has a promoted
    # blocker — the same "only when non-zero" rule progress.md applies to its
    # `promoted:` term, and what keeps a run without --promote byte-identical to
    # before the column existed. Table-wide, never per-row: a column present in
    # one row and absent in another is not a markdown table.
    ( [ $rs[] | (.blocking // [])[] | select(.promoted == true) ] | length > 0) as $anyprom
    | ( [ (if $anyprom
           then "| Round | Critical | Warning | Suggestion | Promoted | New | Carried | Fixed since prior |"
           else "| Round | Critical | Warning | Suggestion | New | Carried | Fixed since prior |" end),
          (if $anyprom then "|---|---|---|---|---|---|---|---|" else "|---|---|---|---|---|---|---|" end) ]
      + [ range(0; $rs | length) as $i | $rs[$i] as $r
          | ($r.blocking // []) as $blk
          | ((($blk | length) == 0) or ([ $blk[] | has("non_converging") ] | all)) as $stamped
          | (if $stamped then ([ $blk[] | select(.non_converging == true) ] | length) else null end) as $carried
          | (if $stamped then ($blk | map(select(.non_converging == true)
                | {file, dimension, mp: (.matched_prior // {line, title})})
              | unique_by([.file, .dimension, .mp.line, .mp.title]) | length)
             else null end) as $carried_priors
          | (if $carried != null then (($blk | length) - $carried) else null end) as $new
          | (if ($i > 0) and ($carried_priors != null)
             then (((($rs[$i-1].blocking // []) | length) - $carried_priors) | if . < 0 then 0 else . end)
             else null end) as $fixed
          # human-promoted blockers (#995) — a SUBSET of the Warning column, not
          # an addition to it. Same per-item expression as the four sibling
          # copies (progress block, telemetry payload, and the two
          # build-dossier reads: raised-set + round suffix, #1064), and no
          # stamp gate: an unstamped round counts 0, never "–".
          | ([ $blk[] | select(.promoted == true) ] | length) as $promoted
          | "| \($r.round // ($i + 1)) | \($r.summary.critical // 0) | \($r.summary.high // 0) | \($r.summary.low // 0) |"
            + (if $anyprom then " \($promoted) |" else "" end)
            + " \($new // "–") | \($carried // "–") | \($fixed // "–") |"
        ]
      | join("\n") ) end' "$status_file")
assessment=$(jq -r '
  (.round_changelists // []) as $rs
  | if ($rs | length) == 0 then "" else
    ( [ $rs[] | ((.blocking // []) | length) ] ) as $series
    | ($rs[-1].blocking // []) as $lastblk
    | ((($lastblk | length) == 0) or ([ $lastblk[] | has("non_converging") ] | all)) as $stamped
    | (if $stamped then ([ $lastblk[] | select(.non_converging == true) ] | length) else null end) as $carried
    | (if $stamped then ([ $lastblk[] | select((.non_converging == true) and (.possible_false_trip == true)) ] | length) else 0 end) as $ftrips
    | (if ($series | length) < 2 then null
       elif $series[-1] < $series[-2] then "improving"
       elif $series[-1] == $series[-2] then "flat"
       else "regressing" end) as $trend
    | "Blocking findings by round: " + ($series | map(tostring) | join(" → ")) + "."
      + (if $ftrips > 0 then
           " \($ftrips) of the \($carried) non-convergence match(es) look like line-proximity false trips (the matched prior blocker has a different title) — those blockers may be new, not stuck."
         else "" end)
      + (if ($series[-1] == 0) then " The final round has zero blockers — converged; no further rounds needed."
         elif ($trend == null) or ($carried == null) then ""
         elif ($trend == "improving") and (($carried - $ftrips) == 0)
         then " Blockers are falling and the remaining \($series[-1]) are new rather than carried — another round is likely to help."
         elif ($trend != "improving") and (($carried - $ftrips) > 0)
         then " \($carried - $ftrips) blocker(s) carried across rounds unmoved by the fix pass — extending alone is unlikely to help; give direction, waive, or split."
         elif ($trend == "improving")
         then " Blockers are falling, but \($carried - $ftrips) genuinely carried one(s) remain — extending can help if paired with direction on the carried blocker(s)."
         else " Blockers are not falling, but the remaining ones are new rather than carried — one more round may still help; judge from the table."
         end)
    end' "$status_file")

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
    if [[ -n "$round_table" ]]; then
      print -r --
      print -r -- "**Per-round progress**"
      print -r --
      print -r -- "$round_table"
    fi
    if [[ -n "$assessment" ]]; then
      print -r --
      print -r -- "**Convergence assessment**"
      print -r --
      print -r -- "$assessment"
    fi
    if [[ -n "$grants" ]]; then
      print -r --
      print -r -- "Grants consumed: ${grants} (soft cap 5)."
    fi
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
  if [[ -n "$round_table" ]]; then
    print -r -- "**Per-round progress**"
    print -r --
    print -r -- "$round_table"
    print -r --
  fi
  if [[ -n "$assessment" ]]; then
    print -r -- "**Convergence assessment**"
    print -r --
    print -r -- "$assessment"
    print -r --
  fi
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
