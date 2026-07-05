#!/usr/bin/env zsh
# resolve-story-loop.zsh — the local, pre-push review loop's state machine
# (epic #557, issue #562). Ties the review panel (#560 dispatch) and the
# consolidator (#561) into an autonomous implement→review→fix loop with a hard
# round budget. Runs entirely in the worktree: nothing is pushed and no PR is
# opened until this exits CONVERGED.
#
# The agentic steps — running the review panel and applying the implementor's
# fix pass — are model-driven, so they are injected as HOOK COMMANDS. This keeps
# the deterministic state machine (rounds, budget, consolidation, exit-state)
# testable, and lets /development:resolve-issue wire the real panel/fix/test
# commands (or a headless `claude -p`) behind the same seam.
#
# Per-round flow:
#   run review panel (diff-scoped) -> scope to diff -> consolidate
#     -> no blockers            => CONVERGED
#     -> surviving conflict     => ESCALATE_CONFLICT   (early exit)
#     -> non_converging blocker => ESCALATE_NO_CONVERGENCE (early exit)
#     -> last round + blockers  => BUDGET_EXHAUSTED
#     -> else: fix pass (blockers only) -> re-run tests -> next round
#
# Hooks (run via the shell, with these env vars exported):
#   --review-cmd  must write this round's aggregate findings JSON (issue #558
#                 schema) to $REVIEW_FINDINGS. Also sees $REVIEW_ROUND,
#                 $REVIEW_SKILL, $REVIEW_SCOPE_FILE (changed files, one per line),
#                 $REVIEW_REPO. Missing/empty output is treated as "no findings".
#   --fix-cmd     applies the blockers. Sees $REVIEW_ROUND, $REVIEW_REPO,
#                 $REVIEW_CHANGELIST (full changelist) and $REVIEW_BLOCKERS
#                 (blockers-only slice). Expected to leave the tree buildable.
#   --test-cmd    (optional) the repo gate, re-run after a fix; nonzero aborts
#                 the loop as an operational error (exit 1), never a verdict.
#
# Usage:
#   resolve-story-loop.zsh --repo PATH [--base REF] \
#       --review-cmd CMD --fix-cmd CMD [--test-cmd CMD] \
#       [--max-rounds N] [--status-file PATH] [--work-dir DIR]
#   resolve-story-loop.zsh --no-review   # skip the loop entirely (fast path)
#
# Exit codes (also carried as `status` in the JSON on stdout / --status-file):
#   0   CONVERGED (or SKIPPED with --no-review)
#   10  ESCALATE_AMBIGUOUS        (dispatch could not pick a panel — #560)
#   11  ESCALATE_CONFLICT         (a surviving reviewer conflict)
#   12  ESCALATE_NO_CONVERGENCE   (a blocker survived two consecutive rounds)
#   13  BUDGET_EXHAUSTED          (round budget spent with blockers remaining)
#   2   usage error
#   1   internal/operational error (sub-script failed, hook failed, tests red)

emulate -L zsh
setopt nounset pipefail

# --- Constants (issue #557 / #562) ------------------------------------------
typeset -gr MAX_REVIEW_ROUNDS=3
typeset -gra BLOCKING_SEVERITIES=(CRITICAL WARNING)   # == Critical + High

local self_dir="${0:A:h}"
local DISPATCH="${self_dir}/review-dispatch.zsh"
local CONSOLIDATE="${self_dir}/consolidate-findings.zsh"

local repo="" base="origin/main" review_cmd="" fix_cmd="" test_cmd=""
local max_rounds=$MAX_REVIEW_ROUNDS status_file="" work_dir="" no_review=0
local issue="" telemetry_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) repo="$2"; shift 2 ;;
  --base) base="$2"; shift 2 ;;
  --review-cmd) review_cmd="$2"; shift 2 ;;
  --fix-cmd) fix_cmd="$2"; shift 2 ;;
  --test-cmd) test_cmd="$2"; shift 2 ;;
  --max-rounds) max_rounds="$2"; shift 2 ;;
  --status-file) status_file="$2"; shift 2 ;;
  --work-dir) work_dir="$2"; shift 2 ;;
  --issue) issue="$2"; shift 2 ;;
  --telemetry-file) telemetry_file="$2"; shift 2 ;;
  --no-review) no_review=1; shift ;;
  -h|--help) print -r -- "usage: resolve-story-loop.zsh --repo PATH --review-cmd CMD --fix-cmd CMD [--test-cmd CMD] [--base REF] [--max-rounds N] [--issue N] [--telemetry-file PATH] [--no-review]"; exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
local t0=$(date +%s)   # for the telemetry wall-clock (#566)

# emit the status JSON (stdout + optional --status-file) and exit with `code`.
emit_and_exit() {
  local st="$1" rounds="$2" code="$3" repo_type="$4" review_skill="$5" \
        final_changelist_file="$6" history_file="$7" changelists_file="${8:-}"
  local final='null'
  [[ -n "$final_changelist_file" && -s "$final_changelist_file" ]] && final=$(<"$final_changelist_file")
  local history='[]'
  [[ -n "$history_file" && -s "$history_file" ]] && history=$(jq -sc '.' "$history_file")
  # every round's full changelist, in order — the review dossier (#563) needs
  # per-round, per-dimension detail that the final (converged, clean) round lacks
  local clists='[]'
  [[ -n "$changelists_file" && -s "$changelists_file" ]] && clists=$(jq -sc '.' "$changelists_file")
  local esc='[]'
  [[ "$final" != "null" ]] && esc=$(print -r -- "$final" | jq -c '.escalation_reasons // []')
  local out
  out=$(jq -nc \
    --arg status "$st" --argjson rounds "$rounds" --argjson max "$max_rounds" \
    --arg repo_type "$repo_type" --arg review_skill "$review_skill" \
    --argjson final "$final" --argjson history "$history" --argjson esc "$esc" \
    --argjson clists "$clists" \
    '{status:$status, rounds:$rounds, max_rounds:$max,
      repo_type:(if $repo_type=="" then null else $repo_type end),
      review_skill:(if $review_skill=="" then null else $review_skill end),
      escalation_reasons:$esc, history:$history, round_changelists:$clists,
      final_changelist:$final}')
  print -r -- "$out"
  [[ -n "$status_file" ]] && print -r -- "$out" > "$status_file"

  # telemetry (#566): append exactly one JSONL record per run, to the explicit
  # --telemetry-file or the git-ignored default under the repo. Never fatal.
  local tfile="$telemetry_file"
  [[ -z "$tfile" && -n "$repo" ]] && tfile="${repo%/}/.claude/telemetry/review-loop.jsonl"
  if [[ -n "$tfile" ]]; then
    local tmp_status; tmp_status=$(mktemp)
    print -r -- "$out" > "$tmp_status"
    mkdir -p "${tfile:h}"
    local -a issue_arg; [[ -n "$issue" ]] && issue_arg=(--issue "$issue")
    "${self_dir}/build-telemetry-record.zsh" --status "$tmp_status" \
      "${issue_arg[@]}" --ts "$t0" --wall-s "$(( $(date +%s) - t0 ))" >> "$tfile" || true
    rm -f "$tmp_status"
  fi
  exit "$code"
}

# --no-review is the fast path — it short-circuits before any other requirement.
if (( no_review )); then
  emit_and_exit "SKIPPED" 0 0 "" "" "" "" ""
fi

[[ -n "$repo" ]] || { print -u2 -- "resolve-story-loop: --repo is required"; exit 2 }
[[ -d "$repo" ]] || { print -u2 -- "resolve-story-loop: --repo not a directory: $repo"; exit 1 }
[[ -n "$review_cmd" ]] || { print -u2 -- "resolve-story-loop: --review-cmd is required (or use --no-review)"; exit 2 }
[[ -n "$fix_cmd" ]] || { print -u2 -- "resolve-story-loop: --fix-cmd is required (or use --no-review)"; exit 2 }

[[ -n "$work_dir" ]] || work_dir=$(mktemp -d)
mkdir -p "$work_dir"
local history_file="$work_dir/history.jsonl"; : > "$history_file"
local changelists_file="$work_dir/changelists.jsonl"; : > "$changelists_file"

# --- dispatch: which panel, on what scope (typed escalation on failure) -----
local plan rc
plan=$("$DISPATCH" plan --repo "$repo" --base "$base" --round 1); rc=$?
if (( rc == 3 )); then
  # unsupported / ambiguous repo type — surface as an escalation
  local tmpf="$work_dir/dispatch-error.json"; print -r -- "$plan" > "$tmpf"
  # reshape the dispatch error into a changelist-ish carrier so it rides out
  jq -nc --argjson e "$plan" '{escalation_reasons:["ambiguous_dispatch"], dispatch_error:$e,
     summary:{critical:0,high:0,low:0,blocking:0,conflicts:0}, blocking:[], suggestions:[],
     conflicts:[], non_converging:false, round:0}' > "$tmpf"
  emit_and_exit "ESCALATE_AMBIGUOUS" 0 10 "" "" "$tmpf" "$history_file" ""
elif (( rc != 0 )); then
  print -u2 -- "resolve-story-loop: dispatch plan failed (rc=$rc)"; exit 1
fi

local repo_type review_skill scope_file="$work_dir/scope.txt"
repo_type=$(print -r -- "$plan" | jq -r '.repo_type')
review_skill=$(print -r -- "$plan" | jq -r '.review_skill')
print -r -- "$plan" | jq -r '.changed_files[]?' > "$scope_file"

# --- the loop ---------------------------------------------------------------
# All loop-locals are declared ONCE here: re-running a bare `local NAME` on a
# later iteration makes zsh PRINT the existing parameter to stdout, which would
# corrupt the status JSON. Inside the loop we plain-assign only.
local round=1 loop_status="" final_changelist="" prev_changelist=""
local rp findings_path scoped changelist blockers
local blocking conflict nonconv nconf
while (( round <= max_rounds )); do
  # per-round dispatch just to get the round's well-known findings path
  rp=$("$DISPATCH" plan --repo "$repo" --base "$base" --round "$round") || {
    print -u2 -- "resolve-story-loop: dispatch plan failed at round $round"; exit 1 }
  findings_path=$(print -r -- "$rp" | jq -r '.findings_path')
  mkdir -p "${findings_path:h}"
  : > "$findings_path"

  # 1. run the review panel (hook) — it writes findings_path
  ( export REVIEW_ROUND="$round" REVIEW_FINDINGS="$findings_path" \
           REVIEW_SKILL="$review_skill" REVIEW_SCOPE_FILE="$scope_file" \
           REVIEW_REPO="$repo"; eval "$review_cmd" ) || {
    print -u2 -- "resolve-story-loop: --review-cmd failed at round $round"; exit 1 }
  [[ -s "$findings_path" ]] || print -r -- '[]' > "$findings_path"

  # 2. scope findings to the story's diff (#560)
  scoped="$work_dir/scoped-$round.json"
  "$DISPATCH" scope-findings --repo "$repo" --base "$base" --findings "$findings_path" > "$scoped" || {
    print -u2 -- "resolve-story-loop: scope-findings failed at round $round"; exit 1 }

  # 3. consolidate (#561), carrying the previous round for non-convergence
  changelist="$work_dir/changelist-$round.json"
  if [[ -n "$prev_changelist" ]]; then
    "$CONSOLIDATE" --findings "$scoped" --round "$round" --prev "$prev_changelist" > "$changelist" || {
      print -u2 -- "resolve-story-loop: consolidate failed at round $round"; exit 1 }
  else
    "$CONSOLIDATE" --findings "$scoped" --round "$round" > "$changelist" || {
      print -u2 -- "resolve-story-loop: consolidate failed at round $round"; exit 1 }
  fi
  final_changelist="$changelist"
  cat "$changelist" >> "$changelists_file"   # one compact line per round (for the dossier, #563)

  blocking=$(jq '.summary.blocking' "$changelist")
  conflict=$(jq 'if ((.escalation_reasons // []) | index("unresolved_conflict")) then 1 else 0 end' "$changelist")
  nonconv=$(jq 'if .non_converging then 1 else 0 end' "$changelist")
  nconf=$(jq '.summary.conflicts' "$changelist")
  jq -c --argjson r "$round" --argjson b "$blocking" --argjson c "$nconf" --argjson nc "$nonconv" \
     '{round:$r, blocking:$b, conflicts:$c, non_converging:($nc==1)}' <<< '{}' >> "$history_file"

  # 4. decide the round's fate
  if (( blocking == 0 )); then loop_status="CONVERGED"; break; fi
  if (( conflict == 1 )); then loop_status="ESCALATE_CONFLICT"; break; fi
  if (( nonconv == 1 )); then loop_status="ESCALATE_NO_CONVERGENCE"; break; fi
  if (( round == max_rounds )); then loop_status="BUDGET_EXHAUSTED"; break; fi

  # 5. fix pass — blockers only (Low suggestions never loop)
  blockers="$work_dir/blockers-$round.json"
  jq -c '{round, blocking, conflicts}' "$changelist" > "$blockers"
  ( export REVIEW_ROUND="$round" REVIEW_REPO="$repo" \
           REVIEW_CHANGELIST="$changelist" REVIEW_BLOCKERS="$blockers"; eval "$fix_cmd" ) || {
    print -u2 -- "resolve-story-loop: --fix-cmd failed at round $round"; exit 1 }

  # 6. re-run the gate (optional); red after a fix is an operational abort
  if [[ -n "$test_cmd" ]]; then
    ( cd "$repo" && eval "$test_cmd" ) || {
      print -u2 -- "resolve-story-loop: --test-cmd red after fix in round $round"
      emit_and_exit "ERROR" "$round" 1 "$repo_type" "$review_skill" "$final_changelist" "$history_file" "$changelists_file" }
  fi

  prev_changelist="$changelist"
  (( round++ ))
done

local code
case "$loop_status" in
  CONVERGED) code=0 ;;
  ESCALATE_CONFLICT) code=11 ;;
  ESCALATE_NO_CONVERGENCE) code=12 ;;
  BUDGET_EXHAUSTED) code=13 ;;
  *) code=1 ;;
esac
emit_and_exit "$loop_status" "$round" "$code" "$repo_type" "$review_skill" "$final_changelist" "$history_file" "$changelists_file"
