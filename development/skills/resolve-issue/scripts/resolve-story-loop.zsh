#!/usr/bin/env zsh
# resolve-story-loop.zsh — the local, pre-push review loop's state machine
# (epic #557, issue #562). Ties the review panel (#560 dispatch) and the
# consolidator (#561) into an autonomous implement→review→fix loop with a hard
# round budget. Runs entirely in the worktree: nothing is pushed and no PR is
# opened until this exits CONVERGED.
#
# The agentic steps — running the review panel and applying the implementor's
# fix pass — are model-driven. The canonical wiring is STEP MODE (#971): the
# driving session runs the panel in-session (visible review agents), passes the
# aggregate findings via --findings-file, and this script processes exactly ONE
# round per invocation — exiting AWAITING_FIX (20) when blockers remain with
# budget left, so the session applies the fixes in-session (visible edits) and
# re-invokes with --resume. HOOK MODE (--review-cmd/--fix-cmd) remains as the
# deterministic seam the bats suite drives the state machine through; wiring a
# headless `claude -p` behind it is NOT a supported pattern — it hides the
# whole loop from the user behind one opaque background task.
#
# Per-round flow:
#   re-dispatch (fresh scope; ambiguous => ESCALATE_AMBIGUOUS, #912)
#     -> run review panel (diff-scoped) -> scope to diff -> consolidate
#     -> no blockers            => CONVERGED
#     -> surviving conflict     => ESCALATE_CONFLICT   (early exit)
#     -> non_converging blocker => ESCALATE_NO_CONVERGENCE (early exit). Identity-
#          based (#983): a cross-round proximity match whose title identity
#          CLEARS it as a genuinely different finding is a false_trip, NOT
#          non_converging — the loop auto-continues (records it, no escalation,
#          no human grant), so only verified/ambiguous survivors escalate here.
#     -> last round + blockers  => BUDGET_EXHAUSTED
#     -> else: step mode        => AWAITING_FIX (fix in-session, --resume)
#              hook mode        => fix pass -> re-run tests -> next round
#
# Every round also appends a human-readable block to $work_dir/progress.md
# (#971) — the user tails it to watch a long run; writes are never fatal.
#
# Step mode:
#   --findings-file  this round's aggregate findings JSON (issue #558 schema,
#                    a flat array). On a FRESH run's round 1 a missing/empty
#                    file = "no findings". On --resume, --test-cmd (when given)
#                    runs FIRST — it gates the previous round's in-session fix;
#                    red exits ERROR (1).
#
#                    Shapes of one caller mistake are refused as STALE_FINDINGS
#                    (exit 2, #974) — the panel is the driving session's job
#                    BETWEEN invocations, so each means it never ran for this
#                    round:
#                      * missing/empty on --resume — a panel that found nothing
#                        must still write `[]`, so silence is not evidence;
#                      * content byte-identical to the round just consumed — a
#                        stale path re-passed, or the new round's file never
#                        written;
#                      * --findings-file IS the round's own dispatch
#                        findings_path — the caller aimed at the internal sink,
#                        which this script truncates; refused up front so the
#                        panel output is never destroyed.
#                    Left unguarded, the first converges the loop on an
#                    unreviewed round (a false CONVERGED that green-lights the
#                    PR) and the second reads as a blocker surviving two rounds
#                    — the non-convergence fingerprint (#606) — tripping a
#                    phantom ESCALATE_NO_CONVERGENCE that blames the fix pass
#                    for a mistake made by the caller. Both are recoverable:
#                    produce this round's findings and re-invoke.
#
# Telemetry note: an extended run (escalate -> grant -> --resume) appends one
# record per terminal exit, each spanning from .t0 — so consecutive records of
# one extended loop overlap and wall_s must not be summed across them.
#
# Hooks (run via the shell, with these env vars exported):
#   --review-cmd  must write this round's aggregate findings JSON (issue #558
#                 schema) to $REVIEW_FINDINGS. Also sees $REVIEW_ROUND,
#                 $REVIEW_SKILL, $REVIEW_SCOPE_FILE (changed files, one per line),
#                 $REVIEW_REPO. Missing/empty output is treated as "no findings".
#   --fix-cmd     applies the blockers. Sees $REVIEW_ROUND, $REVIEW_REPO,
#                 $REVIEW_CHANGELIST (full changelist) and $REVIEW_BLOCKERS
#                 (blockers-only slice). Expected to leave the tree buildable.
#   --test-cmd    the repo gate. Hook mode: re-run after each fix. Step mode:
#                 run at --resume start (see above). Nonzero aborts the loop as
#                 an operational error (exit 1), never a verdict.
#   --gate-attest gate attestation (#981), step mode + --resume only. The tree
#                 identity (git-tree-id.zsh, e.g. run-gate.zsh's `tree` field)
#                 the driving session ALREADY gated green for the round it is
#                 resuming. At --resume start the loop compares it to the current
#                 working tree and SKIPS its own --test-cmd run ONLY on an exact
#                 match — the session and the loop would otherwise run the SAME
#                 full suite on the SAME tree twice (~24 min in the #976 session).
#                 Fail-closed: a mismatch, an empty/absent value, or an
#                 uncomputable current identity runs --test-cmd as before. The
#                 gate itself never weakens — this removes only a byte-identical
#                 duplicate. Ignored without --test-cmd or without --resume.
#
# Usage:
#   resolve-story-loop.zsh --repo PATH [--base REF] \
#       --findings-file FILE [--test-cmd CMD] [--resume] \
#       [--max-rounds N] [--status-file PATH] [--work-dir DIR]    # step mode
#   resolve-story-loop.zsh --repo PATH [--base REF] \
#       --review-cmd CMD --fix-cmd CMD [--test-cmd CMD] ...       # hook mode
#   resolve-story-loop.zsh --no-review   # skip the loop entirely (fast path)
#
# Exit codes (also carried as `status` in the JSON on stdout / --status-file):
#   0   CONVERGED (or SKIPPED with --no-review)
#   20  AWAITING_FIX              (step mode only: blockers remain, budget
#                                  left — fix in-session, then --resume)
#   10  ESCALATE_AMBIGUOUS        (dispatch could not pick a panel — #560 —
#                                  pre-loop or at any round's re-dispatch, #912)
#   11  ESCALATE_CONFLICT         (a surviving reviewer conflict)
#   12  ESCALATE_NO_CONVERGENCE   (a blocker survived two consecutive rounds)
#   13  BUDGET_EXHAUSTED          (round budget spent with blockers remaining)
#   2   usage error. Mid-run, step mode's STALE_FINDINGS refusal (#974) uses
#       this code and DOES write the status JSON (stdout + --status-file), so a
#       consumer never reads the previous round's verdict as if it were this
#       invocation's. It is a non-terminal refusal: no telemetry record and no
#       progress.md `**Final:**` line, because the loop resumes once the caller
#       supplies the round's real findings.
#   1   internal/operational error (sub-script failed, hook failed, tests red)

emulate -L zsh
setopt nounset pipefail

# --- Constants (issue #557 / #562 / #993) -----------------------------------
# 5, not 3 (#993): the cap is an UPPER bound — the loop stops the moment blocking
# findings reach 0 — so a larger default costs the easy majority nothing and only
# affects the hard tail, where it buys fewer human approval round-trips. Telemetry
# also showed convergence is non-monotonic (blocking counts rise again as fixes
# surface new problems), so a longer leash avoids escalating runs that self-resolve.
typeset -gr MAX_REVIEW_ROUNDS=5
typeset -gra BLOCKING_SEVERITIES=(CRITICAL WARNING)   # == Critical + High

local self_dir="${0:A:h}"
local DISPATCH="${self_dir}/review-dispatch.zsh"
local CONSOLIDATE="${self_dir}/consolidate-findings.zsh"
local RENDER_PROGRESS="${self_dir}/render-progress-block.zsh"
local TREE_ID="${self_dir}/git-tree-id.zsh"

local repo="" base="origin/main" review_cmd="" fix_cmd="" test_cmd="" findings_file=""
local max_rounds=$MAX_REVIEW_ROUNDS status_file="" work_dir="" no_review=0
local issue="" telemetry_file="" resume=0 gate_attest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) repo="$2"; shift 2 ;;
  --base) base="$2"; shift 2 ;;
  --review-cmd) review_cmd="$2"; shift 2 ;;
  --fix-cmd) fix_cmd="$2"; shift 2 ;;
  --test-cmd) test_cmd="$2"; shift 2 ;;
  --gate-attest) gate_attest="$2"; shift 2 ;;
  --findings-file) findings_file="$2"; shift 2 ;;
  --max-rounds) max_rounds="$2"; shift 2 ;;
  --status-file) status_file="$2"; shift 2 ;;
  --work-dir) work_dir="$2"; shift 2 ;;
  --issue) issue="$2"; shift 2 ;;
  --telemetry-file) telemetry_file="$2"; shift 2 ;;
  --no-review) no_review=1; shift ;;
  --resume) resume=1; shift ;;
  -h|--help)
    print -r -- "usage: resolve-story-loop.zsh --repo PATH (--findings-file FILE | --review-cmd CMD --fix-cmd CMD)"
    print -r -- "  [--test-cmd CMD] [--gate-attest TREE_ID] [--base REF] [--max-rounds N] [--resume] [--issue N]"
    print -r -- "  [--work-dir DIR] [--status-file PATH] [--telemetry-file PATH] [--no-review]"
    exit 0 ;;
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

  # progress.md terminal line (#971) — non-fatal; neither AWAITING_FIX nor the
  # STALE_FINDINGS refusal (#974) is terminal, so neither closes the file.
  # Same brace-group rationale as append_progress_round above: a redirection
  # setup failure must not leak to the real stderr.
  if [[ -n "$work_dir" && -d "$work_dir" && "$st" != "AWAITING_FIX" && "$st" != "STALE_FINDINGS" ]]; then
    local reasons=""
    [[ -n "$esc" && "$esc" != "[]" ]] && reasons=" — $(print -r -- "$esc" | jq -r 'join(", ")' 2>/dev/null)"
    { print -r -- "**Final:** ${st}${reasons} ($(date +%H:%M:%S))" >> "$work_dir/progress.md" ; } 2>/dev/null || true
  fi

  # telemetry (#566): append exactly one JSONL record per LOOP — terminal
  # statuses only, never the non-terminal AWAITING_FIX (#971) or the
  # STALE_FINDINGS refusal (#974), which would double-count the loop that
  # resumes right after it — to the explicit --telemetry-file or the
  # git-ignored default under the repo. Never fatal.
  local tfile="$telemetry_file"
  [[ -z "$tfile" && -n "$repo" ]] && tfile="${repo%/}/.claude/telemetry/review-loop.jsonl"
  if [[ -n "$tfile" && "$st" != "AWAITING_FIX" && "$st" != "STALE_FINDINGS" ]]; then
    local t_begin="$t0"
    if [[ -n "$work_dir" && -s "$work_dir/.t0" ]]; then
      t_begin=$(<"$work_dir/.t0")
      [[ "$t_begin" == <-> ]] || t_begin="$t0"
    fi
    local tmp_status; tmp_status=$(mktemp)
    print -r -- "$out" > "$tmp_status"
    mkdir -p "${tfile:h}"
    local -a issue_arg; [[ -n "$issue" ]] && issue_arg=(--issue "$issue")
    "${self_dir}/build-telemetry-record.zsh" --status "$tmp_status" \
      "${issue_arg[@]}" --ts "$t_begin" --wall-s "$(( $(date +%s) - t_begin ))" >> "$tfile" || true
    rm -f "$tmp_status"
  fi
  exit "$code"
}

# build the ambiguous-dispatch carrier and emit the typed escalation (#912).
# Shared by the pre-loop and per-round dispatch paths so exit 10's contract
# (typed status JSON + code 10) holds wherever detection turns ambiguous.
# `rounds` is the completed-round count — the prior run's on --resume, the
# current round minus one mid-loop — so it always agrees with history.
emit_ambiguous() {
  local err_json="$1" rounds="$2" rtype="$3" rskill="$4"
  local carrier="$work_dir/dispatch-error.json"
  jq -nc --argjson e "$err_json" --argjson r "$rounds" \
    '{escalation_reasons:["ambiguous_dispatch"], dispatch_error:$e,
      summary:{critical:0,high:0,low:0,blocking:0,conflicts:0,false_trips:0}, blocking:[], suggestions:[],
      conflicts:[], non_converging:false, false_trips:[], round:$r}' > "$carrier"
  emit_and_exit "ESCALATE_AMBIGUOUS" "$rounds" 10 "$rtype" "$rskill" "$carrier" "$history_file" "$changelists_file"
}

# append one per-round block to the tail-able progress file (#971). Rendering
# is render-progress-block.zsh (a testable pure function); transparency must
# never abort a run, so every failure here is swallowed.
append_progress_round() {
  local cl="$1" r="$2" v="$3" prev_cl="${4:-}"
  [[ -n "$work_dir" ]] || return 0
  # judgment-grade per-round counts (#969): the previous round changelist
  # enables fixed-since, the history (which already holds this round — it is
  # appended before this call) enables the cumulative trend line
  local -a extra
  [[ -n "$prev_cl" && -s "$prev_cl" ]] && extra+=(--prev "$prev_cl")
  [[ -s "$history_file" ]] && extra+=(--history "$history_file")
  # the append target's OWN open failure (e.g. a directory sits at the path)
  # is a shell-level redirection error, reported on the CURRENT stderr before
  # the trailing `2>/dev/null` would apply to it — brace-group it so the
  # 2>/dev/null covers the redirection setup too, not just the command (#971).
  { "$RENDER_PROGRESS" --changelist "$cl" --round "$r" --verdict "$v" "${extra[@]}" \
    >> "$work_dir/progress.md" ; } 2>/dev/null || true
}

# refuse this round's findings as never-produced (#974) and exit 2. Typed, so
# --status-file can never keep the PREVIOUS invocation's AWAITING_FIX and read
# as this one's verdict (the #912 lesson) — but NOT terminal: emit_and_exit
# skips telemetry and the progress `**Final:**` line for this status, because
# the caller fixes the invocation and resumes the same work-dir. `rounds` is
# the completed-round count, so it agrees with history as everywhere else.
refuse_stale_findings() {
  local detail="$1"
  print -u2 -- "resolve-story-loop: $detail"
  # a refusal is still worth a progress line — the user tailing progress.md
  # must see WHY a round they expected did not happen (same non-fatal rules)
  if [[ -n "$work_dir" && -d "$work_dir" ]]; then
    { print -r -- "**Refused (round ${round}):** stale findings — $detail" \
      >> "$work_dir/progress.md" ; } 2>/dev/null || true
  fi
  emit_and_exit "STALE_FINDINGS" "$(( round - 1 ))" 2 "$repo_type" "$review_skill" \
    "$prev_changelist" "$history_file" "$changelists_file"
}

# content digest of a findings file, for the stale-findings guard (#974).
# Prints the hex digest, or NOTHING when no digest tool is available — the
# guard is a caller-mistake detector, so a toolless environment loses the
# detection rather than the run.
#
# The tool is chosen by existence, so on any host that ships `shasum` (both CI
# lanes do) the `sha256sum` arm is otherwise unreachable and untestable.
# RESOLVE_LOOP_DIGEST_TOOL pins the implementation to exercise each arm — the
# DETECT_STACK_BIN convention; unset in production.
findings_digest() {
  local tool="${RESOLVE_LOOP_DIGEST_TOOL:-}"
  if [[ -n "$tool" ]]; then
    # an explicit pin that names an unknown tool, or one absent on this host,
    # would otherwise fall through to the silent no-digest arm and read as
    # "toolless" — say why the guard went dark, so a mis-pinned test run is
    # diagnosable rather than a mysterious non-refusal
    if [[ "$tool" != shasum && "$tool" != sha256sum ]] || (( ! $+commands[$tool] )); then
      print -u2 -- "resolve-story-loop: RESOLVE_LOOP_DIGEST_TOOL=$tool not usable — byte-identical guard disabled"
      return 0
    fi
  else
    (( $+commands[shasum] )) && tool=shasum || { (( $+commands[sha256sum] )) && tool=sha256sum }
  fi
  case "$tool" in
    shasum)    shasum -a 256 -- "$1" 2>/dev/null | awk '{print $1}' ;;
    sha256sum) sha256sum -- "$1" 2>/dev/null | awk '{print $1}' ;;
    *)         return 0 ;;
  esac
}

# --no-review is the fast path — it short-circuits before any other requirement.
if (( no_review )); then
  emit_and_exit "SKIPPED" 0 0 "" "" "" "" ""
fi

[[ -n "$repo" ]] || { print -u2 -- "resolve-story-loop: --repo is required"; exit 2 }
[[ -d "$repo" ]] || { print -u2 -- "resolve-story-loop: --repo not a directory: $repo"; exit 1 }
# Step mode (#971): --findings-file replaces BOTH model-driven hooks — the
# driving session runs the panel and the fix pass in-session, one round per
# invocation. Mixing the two wirings is a contradiction, not a fallback.
local step_mode=0
[[ -n "$findings_file" ]] && step_mode=1
if (( step_mode )) && [[ -n "$review_cmd" || -n "$fix_cmd" ]]; then
  print -u2 -- "resolve-story-loop: --findings-file is mutually exclusive with --review-cmd/--fix-cmd"; exit 2
fi
if (( ! step_mode )); then
  [[ -n "$review_cmd" ]] || {
    print -u2 -- "resolve-story-loop: --review-cmd is required (or use --findings-file / --no-review)"; exit 2 }
  [[ -n "$fix_cmd" ]] || {
    print -u2 -- "resolve-story-loop: --fix-cmd is required (or use --findings-file / --no-review)"; exit 2 }
fi
# a non-positive/non-numeric ceiling would skip the loop entirely and fall out
# with an empty status — refuse it up front as the usage error it is
[[ "$max_rounds" == <-> ]] && (( max_rounds >= 1 )) || {
  print -u2 -- "resolve-story-loop: --max-rounds must be a positive integer (got: $max_rounds)"; exit 2 }

[[ -n "$work_dir" ]] || work_dir=$(mktemp -d)
mkdir -p "$work_dir"
local history_file="$work_dir/history.jsonl"
local changelists_file="$work_dir/changelists.jsonl"
# On --resume we CONTINUE a prior run: the work-dir IS the state. Read the last
# completed round from history, and re-use its persisted changelist file as the
# prior round so non-convergence detection spans the extension. A fresh run
# (no --resume) truncates both accumulators as before.
local resume_round=0 resume_prev=""
if (( resume )); then
  [[ -s "$history_file" ]] || {
    print -u2 -- "resolve-story-loop: --resume needs an existing non-empty history in --work-dir"; exit 2 }
  # the accumulators ARE the resume state — a partial line left by a killed run
  # would otherwise surface only at the final emit, as an empty status JSON
  jq -e -sc '.' "$history_file" >/dev/null 2>&1 || {
    print -u2 -- "resolve-story-loop: --resume found corrupt history in $history_file"; exit 1 }
  if [[ -s "$changelists_file" ]]; then
    jq -e -sc '.' "$changelists_file" >/dev/null 2>&1 || {
      print -u2 -- "resolve-story-loop: --resume found corrupt changelists in $changelists_file"; exit 1 }
  fi
  # kill-window skew (#913): each round appends its changelist BEFORE its
  # history line, so a run killed between the two appends leaves changelists
  # EXACTLY ONE valid line ahead of history — both accumulators individually
  # valid JSONL, so the checks above pass. The orphaned round re-runs on resume;
  # keeping its stale line would duplicate the round in .round_changelists,
  # skewing the dossier (#563) and the SKILL soft-cap read. Truncate that one
  # orphan. Any OTHER skew (surplus >1, or history ahead) cannot come from the
  # single kill window — it is foreign corruption, and silently repairing it
  # could drop a completed round's record, so it errors like the corrupt-JSONL
  # cases above.
  local hist_n clist_n
  hist_n=$(jq -sc 'length' "$history_file")
  clist_n=0
  [[ -s "$changelists_file" ]] && clist_n=$(jq -sc 'length' "$changelists_file")
  if (( clist_n == hist_n + 1 )); then
    print -u2 -- "resolve-story-loop: --resume dropping 1 orphaned changelist line — prior run killed mid-append"
    local clist_trunc="$work_dir/.changelists-trunc"
    head -n "$hist_n" "$changelists_file" > "$clist_trunc" && mv "$clist_trunc" "$changelists_file" || {
      print -u2 -- "resolve-story-loop: --resume could not truncate $changelists_file"; exit 1 }
  elif (( clist_n != hist_n )); then
    print -u2 -- "resolve-story-loop: --resume accumulator skew beyond the kill window (history $hist_n vs changelists $clist_n) in $work_dir — corrupt work-dir"; exit 1
  fi
  resume_round=$(tail -n 1 "$history_file" | jq -r '.round')
  [[ "$resume_round" == <-> ]] || {
    print -u2 -- "resolve-story-loop: --resume could not read a round number from $history_file"; exit 1 }
  resume_prev="$work_dir/changelist-$resume_round.json"
  [[ -s "$resume_prev" ]] || {
    print -u2 -- "resolve-story-loop: --resume cannot find prior changelist $resume_prev"; exit 1 }
  # a ceiling at or below the resumed round would run zero rounds and fall out
  # of the loop with an empty status — refuse it as a usage error instead
  (( resume_round + 1 <= max_rounds )) || {
    print -u2 -- "resolve-story-loop: --resume would start at round $(( resume_round + 1 )) but --max-rounds is $max_rounds — raise --max-rounds"; exit 2 }
else
  : > "$history_file"
  : > "$changelists_file"
  # the consumed-findings digests are per-run state too (#974): a re-used
  # work-dir must not let a previous run's round-N digest veto this run's
  # round N+1
  rm -f -- "$work_dir"/.findings-digest-*(N)
  # the loop's logical start — a step-mode run spans several invocations, and
  # the terminal telemetry must report whole-loop wall clock, not the last
  # round's (#971)
  print -r -- "$t0" > "$work_dir/.t0"
fi

# Step mode gates the PREVIOUS round's in-session fix here (#971): the fix ran
# between invocations, so the "red after a fix aborts" check runs at resume
# start — deterministically, before any new round work.
#
# Gate attestation (#981): the driving session already ran this identical full
# suite green in SKILL.md Step 3 right after applying the fix. When it passes the
# tree identity it gated (--gate-attest) and that identity EXACTLY matches the
# current working tree, the --test-cmd run here is a byte-identical duplicate — so
# skip it. Fail-closed: skip ONLY on a successfully-computed exact match; a
# mismatch (tree changed since the attestation), an empty/absent value, or an
# uncomputable current identity all fall through to running --test-cmd as before.
# The gate never weakens — this removes only the duplicate, never the check.
if (( step_mode && resume )) && [[ -n "$test_cmd" ]]; then
  local gate_skipped=0
  if [[ -n "$gate_attest" ]]; then
    local cur_tree=""
    [[ -x "$TREE_ID" ]] && cur_tree="$("$TREE_ID" "$repo" 2>/dev/null)"
    if [[ -n "$cur_tree" && "$cur_tree" == "$gate_attest" ]]; then
      gate_skipped=1
      print -u2 -- "resolve-story-loop: --gate-attest matches the working tree ($cur_tree) — skipping the duplicate --test-cmd run (#981)"
      if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        { print -r -- "**Gate (round $(( resume_round + 1 ))):** attested green — skipped the duplicate full-suite run (#981)" \
          >> "$work_dir/progress.md" ; } 2>/dev/null || true
      fi
    else
      print -u2 -- "resolve-story-loop: --gate-attest does not match the working tree (attested '${gate_attest}', current '${cur_tree:-<uncomputable>}') — running --test-cmd (fail-closed, #981)"
    fi
  fi
  if (( ! gate_skipped )); then
    ( cd "$repo" && eval "$test_cmd" ) || {
      print -u2 -- "resolve-story-loop: --test-cmd red on --resume (prior round's fix broke the gate)"
      emit_and_exit "ERROR" "$resume_round" 1 "" "" "$resume_prev" "$history_file" "$changelists_file" }
  fi
fi

# --- dispatch: which panel, on what scope (typed escalation on failure) -----
local plan rc
plan=$("$DISPATCH" plan --repo "$repo" --base "$base" --round 1); rc=$?
if (( rc == 3 )); then
  # unsupported / ambiguous repo type — surface as an escalation. On --resume
  # the prior run's rounds and changelists are real state and must ride out
  # with the status, never a hardcoded fresh-run zero (#912).
  emit_ambiguous "$plan" "$resume_round" "" ""
elif (( rc != 0 )); then
  print -u2 -- "resolve-story-loop: dispatch plan failed (rc=$rc)"; exit 1
fi

local repo_type review_skill scope_file="$work_dir/scope.txt"
repo_type=$(print -r -- "$plan" | jq -r '.repo_type')
review_skill=$(print -r -- "$plan" | jq -r '.review_skill')
# scope_file is written per round inside the loop (#911) — no pre-loop write,
# so a stale copy can never be mistaken for the round's real scope.
# A --work-dir INSIDE the repo would sweep the loop's own state files
# (scope.txt, changelist-N.json, history.jsonl, …) into the refreshed scope as
# untracked files — the dispatch's #909 exclusion only covers the default
# artifact prefixes. Compute the work-dir's repo-relative prefix once so every
# refresh filters it.
local wd_rel=""
if [[ "${work_dir:A}" == "${repo:A}"/* ]]; then
  wd_rel="${${work_dir:A}#"${repo:A}"/}/"
fi

# --- the loop ---------------------------------------------------------------
# All loop-locals are declared ONCE here: re-running a bare `local NAME` on a
# later iteration makes zsh PRINT the existing parameter to stdout, which would
# corrupt the status JSON. Inside the loop we plain-assign only.
local round=$(( resume_round + 1 )) loop_status="" final_changelist="" prev_changelist="$resume_prev"
local rp findings_path scoped scoped_filtered changelist blockers
local digest prev_digest_file
local blocking conflict nonconv nconf verdict ftrips
local -a scope_lines
while (( round <= max_rounds )); do
  # per-round dispatch: the round's well-known findings path AND a fresh scope
  rp=$("$DISPATCH" plan --repo "$repo" --base "$base" --round "$round"); rc=$?
  if (( rc == 3 )); then
    # a fix pass changed what detection sees (e.g. added a second supported
    # language) — the same typed escalation as the pre-loop path, not a bare
    # exit 1 that leaves --status-file holding the previous verdict (#912)
    emit_ambiguous "$rp" "$(( round - 1 ))" "$repo_type" "$review_skill"
  elif (( rc != 0 )); then
    print -u2 -- "resolve-story-loop: dispatch plan failed at round $round (rc=$rc)"; exit 1
  fi
  findings_path=$(print -r -- "$rp" | jq -r '.findings_path')
  # refresh the scope from THIS round's plan (#911): a file the previous round's
  # fix pass created must be reviewed, not silently invisible behind a scope
  # frozen at invocation start (artifact paths stay excluded — #909 lives in
  # the dispatch's _changed_files, which this recomputation goes through).
  # This write is the review hook's ONLY scope source, so a failed extraction
  # must abort the round, never leave a truncated scope behind.
  print -r -- "$rp" | jq -r '.changed_files[]?' > "$scope_file" || {
    print -u2 -- "resolve-story-loop: could not extract scope at round $round"; exit 1 }
  # a repo-internal work-dir's own files are loop state, never story code
  if [[ -n "$wd_rel" && -s "$scope_file" ]]; then
    scope_lines=("${(@f)$(<"$scope_file")}")
    scope_lines=(${scope_lines:#${(b)wd_rel}*})
    if (( ${#scope_lines} )); then
      print -rl -- "${scope_lines[@]}" > "$scope_file"
    else
      : > "$scope_file"
    fi
  fi
  mkdir -p "${findings_path:h}"
  # (#974) refuse the alias BEFORE truncating: findings_path is the round's
  # internal sink, and the very next line zero-bytes it. A session that passed
  # the dispatch plan's findings_path as --findings-file (instead of its own
  # findings-round-R.json, per SKILL.md) would have its real panel output
  # destroyed here, then be told "the panel never ran" — a confidently wrong
  # verdict, and the cp below would fail on identical files anyway. Name the
  # mistake instead, while the bytes are still intact. Compare canonical paths
  # (catches symlinks and ./-prefixed spellings) AND device+inode via -ef
  # (catches a hardlink to the same file, which canonicalizes differently).
  if (( step_mode )) && [[ -n "$findings_file" ]] && \
     { [[ "${findings_file:A}" == "${findings_path:A}" ]] || [[ "$findings_file" -ef "$findings_path" ]] }; then
    refuse_stale_findings "--findings-file must not be the round's own findings_path ($findings_path) — pass this round's aggregated findings (e.g. findings-round-${round}.json), not the dispatch sink."
  fi
  : > "$findings_path"

  # 1. obtain this round's findings: step mode consumes --findings-file (the
  # session already ran the panel in-session, #971); hook mode runs the
  # injected panel command
  if (( step_mode )); then
    # (#974) silence is not evidence on a resumed round: the panel runs between
    # invocations, and one that found nothing still writes `[]`. Consuming a
    # missing/empty file as "no findings" here would converge the loop on a
    # round nobody reviewed — the false CONVERGED that per-round file names
    # make the LIKELIER shape of this mistake. A fresh run's round 1 keeps the
    # documented missing == no-findings behaviour.
    if (( resume )) && [[ ! -s "$findings_file" ]]; then
      refuse_stale_findings "--findings-file is missing or empty on --resume ($findings_file) — did this round's review panel run? A panel that found nothing must still write []."
    fi
    if [[ -s "$findings_file" ]]; then
      jq -e 'type=="array"' "$findings_file" >/dev/null 2>&1 || {
        print -u2 -- "resolve-story-loop: --findings-file is not a JSON array: $findings_file"; exit 1 }
      # stale-findings guard (#974): the panel is the session's job, run between
      # invocations — so findings byte-identical to the round just consumed mean
      # it did NOT run (a stale path re-passed, or the new round's file never
      # written). Refuse as the usage error it is, naming the actual mistake,
      # rather than consuming it and reporting the phantom non-convergence
      # (#606) that identical blockers across two rounds would otherwise look
      # like. Content-based, not path-based: a fresh per-round path holding the
      # previous round's bytes is the same mistake. Only the IMMEDIATELY
      # preceding round is compared — a blocker legitimately re-found by a real
      # panel run varies in its evidence text, and non-convergence is gathered on
      # [file, dimension, line-proximity] with a title-identity verdict (#983), so
      # an exact or token-sharing re-find still escalates (only a fully disjoint
      # retitle auto-continues as a false trip, which this guard is unrelated to).
      digest=$(findings_digest "$findings_file")
      prev_digest_file="$work_dir/.findings-digest-$(( round - 1 ))"
      if [[ -n "$digest" && -s "$prev_digest_file" && "$digest" == "$(<"$prev_digest_file")" ]]; then
        refuse_stale_findings "--findings-file is byte-identical to round $(( round - 1 ))'s consumed findings ($findings_file) — did this round's review panel run? Write each round's aggregate findings to its own path (findings-round-N.json) before --resume."
      fi
      cp "$findings_file" "$findings_path" || {
        print -u2 -- "resolve-story-loop: could not copy --findings-file"; exit 1 }
      # record only AFTER a successful consume, so a failed round leaves no
      # digest to veto its retry
      if [[ -n "$digest" ]]; then
        print -r -- "$digest" > "$work_dir/.findings-digest-$round"
      fi
    fi
  else
    ( export REVIEW_ROUND="$round" REVIEW_FINDINGS="$findings_path" \
             REVIEW_SKILL="$review_skill" REVIEW_SCOPE_FILE="$scope_file" \
             REVIEW_REPO="$repo"; eval "$review_cmd" ) || {
      print -u2 -- "resolve-story-loop: --review-cmd failed at round $round"; exit 1 }
  fi
  [[ -s "$findings_path" ]] || print -r -- '[]' > "$findings_path"

  # 2. scope findings to the story's diff (#560)
  scoped="$work_dir/scoped-$round.json"
  "$DISPATCH" scope-findings --repo "$repo" --base "$base" --findings "$findings_path" > "$scoped" || {
    print -u2 -- "resolve-story-loop: scope-findings failed at round $round"; exit 1 }
  # a repo-internal work-dir's own files are loop state, never story findings —
  # the #909/#911 exclusion must hold in step mode too (final-review fix, #971)
  if [[ -n "$wd_rel" ]]; then
    scoped_filtered="$work_dir/.scoped-filtered-$round.json"
    jq -c --arg wd "$wd_rel" '[ .[] | select(((.file // "") | sub("^\\./"; "")) | startswith($wd) | not) ]' \
      "$scoped" > "$scoped_filtered" || {
      print -u2 -- "resolve-story-loop: work-dir scope filter failed at round $round"; exit 1 }
    mv "$scoped_filtered" "$scoped"
  fi

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
  # false_trips (#983): proximity matches identity cleared as genuinely different —
  # recorded per round so telemetry/history show the auto-continue, but they NEVER
  # drive an escalation (that is $nonconv, which the consolidator already excludes
  # them from).
  ftrips=$(jq '.summary.false_trips // 0' "$changelist")
  jq -c --argjson r "$round" --argjson b "$blocking" --argjson c "$nconf" --argjson nc "$nonconv" \
     --argjson ft "$ftrips" \
     '{round:$r, blocking:$b, conflicts:$c, non_converging:($nc==1), false_trips:$ft}' <<< '{}' >> "$history_file"

  # 4. decide the round's fate. In step mode a survivable round (blockers,
  # budget left) exits AWAITING_FIX (20): the fix pass is the driving session's
  # job, in-session, before it re-invokes with --resume (#971).
  if (( blocking == 0 )); then loop_status="CONVERGED"
  elif (( conflict == 1 )); then loop_status="ESCALATE_CONFLICT"
  elif (( nonconv == 1 )); then loop_status="ESCALATE_NO_CONVERGENCE"
  elif (( round == max_rounds )); then loop_status="BUDGET_EXHAUSTED"
  elif (( step_mode )); then loop_status="AWAITING_FIX"
  fi
  case "$loop_status" in
    CONVERGED) verdict="converged" ;;
    ESCALATE_CONFLICT) verdict="escalating (unresolved conflict)" ;;
    ESCALATE_NO_CONVERGENCE) verdict="escalating (non-converging blocker)" ;;
    BUDGET_EXHAUSTED) verdict="budget exhausted" ;;
    AWAITING_FIX) verdict="awaiting fix — apply blockers in-session, then --resume" ;;
    *) verdict="fix pass (in-loop), continuing" ;;
  esac
  append_progress_round "$changelist" "$round" "$verdict" "$prev_changelist"
  if [[ -n "$loop_status" ]]; then break; fi

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
  AWAITING_FIX) code=20 ;;
  ESCALATE_CONFLICT) code=11 ;;
  ESCALATE_NO_CONVERGENCE) code=12 ;;
  BUDGET_EXHAUSTED) code=13 ;;
  *) code=1 ;;
esac
emit_and_exit "$loop_status" "$round" "$code" "$repo_type" "$review_skill" "$final_changelist" "$history_file" "$changelists_file"
