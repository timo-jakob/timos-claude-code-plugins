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
# Rounds after the first ITERATE (#1434). At the START of every round the loop
# computes and persists the working-tree identity the round's reviewers will see
# (`git-tree-id.zsh` -> `<work-dir>/tree-<N>.txt`), and from round 2 on hands the
# PREVIOUS round's identity to `plan --prior-tree`, so an intermediate round is
# scoped to exactly what the last fix pass changed. This is deliberately
# INDEPENDENT of `--gate-attest` — that flag is optional, session-supplied and
# produced only by run-gate.zsh on plugin repos, so leaning on it would make
# "no prior tree" the normal case off plugin repos. Three carries ride along:
#   * `<work-dir>/verify-<N>.json` — the previous round's `.blocking` array,
#     i.e. exactly what the fix pass was told to fix, passed as
#     `--fix-verification` and exported as REVIEW_FIX_VERIFICATION;
#   * `<work-dir>/adjudicated.json` — the Low findings prior rounds surfaced and
#     the human let go, passed as `--adjudicated` and exported as
#     REVIEW_ADJUDICATED ("do not re-raise these"). Every entry whose file the
#     last fix pass touched is REMOVED before the round consolidates, so a
#     suggestion legitimately re-raised because the fix was incomplete is never
#     suppressed;
#   * `<work-dir>/.closing-sweep` — the round number of the CLOSING FULL SWEEP.
# Delta scoping buys convergence but could hide a defect that only exists in the
# interaction between rounds, so no run may END on a delta round: `CONVERGED` is
# declarable only on a `scope_mode: "full"` round. A delta round that reaches
# zero blockers therefore PROMOTES the next round to a closing full sweep rather
# than converging itself — and if it was already at the ceiling, that sweep is
# granted ONE round beyond `--max-rounds` (once), because the safety net must
# not be skipped exactly when the run has been longest. `--max-rounds` in the
# status JSON keeps reporting what the caller passed; `closing_sweep_granted`
# records the grant.
#
# Per-round flow:
#   persist this round tree identity (#1434; missing prior identity => exit 1)
#     -> re-dispatch (fresh scope; ambiguous => ESCALATE_AMBIGUOUS, #912)
#     -> run review panel (scoped: full diff on round 1 and the closing sweep,
#        else the delta since the previous round) -> scope to diff (ALWAYS the
#        full story diff — scope-findings is never handed --prior-tree, or a
#        fix-verification finding in a file untouched since the last round would
#        be silently dropped) -> consolidate
#     -> no blockers on a FULL round   => CONVERGED
#     -> no blockers on a DELTA round  => promote the next round to the closing
#        full sweep (no fix pass runs; step mode exits AWAITING_FIX with
#        final_changelist.summary.blocking == 0). A round whose panel saw an
#        EMPTY scope stays a delta round in step mode for exactly this reason:
#        it can then never be a run's last word.
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
# Seams (for tests):
#   RESOLVE_LOOP_DIGEST_TOOL  selects WHICH of the two supported tool NAMES
#                             (`shasum` | `sha256sum`) backs the byte-identical
#                             stale-findings guard (#974), so a test can drive
#                             each arm. It is a name, NOT a path: any other
#                             value — including an absolute path to a real
#                             shasum — is rejected and the guard degrades off.
#   RESOLVE_LOOP_PAYLOAD_BIN  pins the telemetry payload builder (a PATH), so a
#                             test can drive the "failed payload build emits
#                             nothing" branch (#1004). This one follows
#                             review-dispatch.zsh's DETECT_STACK_BIN convention.
#   Both are unset in production.
#
# Step mode:
#   --findings-file  this round's aggregate findings JSON (issue #558 schema,
#                    a flat array). A missing/empty file is refused on every
#                    FULL round, including a fresh run's round 1 (#1434): zero
#                    blockers on a full round is the CONVERGED condition, so an
#                    absent aggregate must never be read as a clean review. It
#                    is still read as "no findings" on a DELTA round, where the
#                    round cannot converge anyway — reachable through hook mode,
#                    since in step mode every delta round arrives via --resume,
#                    where the missing/empty arm below refuses first.
#                    On --resume, --test-cmd (when given)
#                    runs FIRST — it gates the previous round's in-session fix;
#                    red exits ERROR (1).
#
#                    FIVE shapes are refused as STALE_FINDINGS (exit 2, #974,
#                    #1434), on either of two grounds: the round's findings were
#                    never produced (the panel is the driving session's job
#                    BETWEEN invocations, so these are caller mistakes), or no
#                    reviewer could have seen anything this round. TWO of the
#                    five are wiring-independent — they fire in hook mode too,
#                    where the panel is --review-cmd's job: the EMPTY-DELTA arm
#                    and the FULL-ROUND arm below. They key on the round's own
#                    state rather than on --findings-file, which is why. The
#                    other three are step-mode-only by construction, since hook
#                    mode has no --findings-file at all. (Named, not numbered:
#                    an ordinal cross-reference goes stale the next time a shape
#                    is added, and this one already did once.)
#
#                    All five, with the two wiring-independent arms marked:
#                      * missing/empty on --resume — a panel that found nothing
#                        must still write `[]`, so silence is not evidence;
#                      * content byte-identical to the round just consumed — a
#                        stale path re-passed, or the new round's file never
#                        written. WAIVED (#1434) for the promoted closing full
#                        sweep when the round before it LOOKED AT SOMETHING AND
#                        FOUND NOTHING — there `[]` twice running is the
#                        expected shape of a healthy convergence rather than
#                        evidence of a stale path. All three facts are required
#                        (a recorded sweep, empty consumed findings, a non-empty
#                        scope): the empty-delta promotion records a sweep too
#                        and follows a round WITH blockers, and a blind round
#                        found nothing only because it saw nothing;
#                      * (WIRING-INDEPENDENT) the round's delta is EMPTY and
#                        NOTHING is carried to verify (#1434) — nothing has changed since a round that
#                        already found nothing, so no reviewer would see
#                        anything, and re-running the panel cannot help. (An
#                        empty delta WITH a carry is not refused: see the
#                        verification-only round above.)
#                      * (WIRING-INDEPENDENT) the round is FULL and its panel
#                        produced NO findings file at all (#1434) — zero blockers on a full round is
#                        the CONVERGED condition, so an absent aggregate must
#                        never be read as a clean review. WIRING-INDEPENDENT:
#                        this arm keys on findings_path, so it fires on a fresh
#                        run's round 1 and on every full round in hook mode. It
#                        is what makes the panels' own "on a full round, report
#                        and write no findings file" terminal enforceable. The
#                        `[]` default survives only on a DELTA round, which
#                        cannot converge anyway;
#                      * --findings-file IS the round's own dispatch
#                        findings_path — the caller aimed at the internal sink,
#                        which this script truncates; refused up front so the
#                        panel output is never destroyed.
#                    Left unguarded, the MISSING/EMPTY and FULL-ROUND arms let
#                    a round nobody reviewed be consumed — on a full round that
#                    is the false CONVERGED that green-lights the PR — and the
#                    BYTE-IDENTICAL arm reads as a blocker surviving two rounds,
#                    the non-convergence fingerprint (#606), tripping a phantom
#                    ESCALATE_NO_CONVERGENCE that blames the fix pass for a
#                    mistake made by the caller.
#
#                    The remedy is per arm, not one rule: MISSING/EMPTY,
#                    BYTE-IDENTICAL and FULL-ROUND are cleared by producing this
#                    round's real aggregate and re-invoking; the ALIAS arm by
#                    pointing --findings-file at the panel's own file (its
#                    output is intact); and the EMPTY-DELTA arm by restoring
#                    the closing-sweep marker the previous round earned, or
#                    re-invoking under the --max-rounds it was written under.
#                    That arm fires only when the carry is EMPTY too, so there
#                    is nothing to fix there either — and no re-run of the panel
#                    can clear it.
#
# Telemetry note: an extended run (escalate -> grant -> --resume) appends one
# record per terminal exit, each spanning from .t0 — so consecutive records of
# one extended loop overlap and wall_s must not be summed across them.
# Each terminal exit that emits a record also writes that record's `run_id` to
# `<work-dir>/.telemetry-run-id` (#995), so a later enrichment can JOIN the run
# it enriches instead of minting an orphan id. It is best-effort like the
# emission itself, and cleared both on a fresh (non---resume) start and again
# immediately before each emission attempt — so it holds the id of THIS
# terminal exit's record, or NOTHING. A failed emission therefore leaves no id
# rather than the previous exit's, which a reader would otherwise join to a
# superseded record. Each loop's sidecar lives in its OWN --work-dir, so a
# second loop against the same story (the promotion sub-loop, which takes a
# fresh work-dir) never touches this one. The status JSON also carries `promotion_phase` (true exactly when this
# invocation carried OR ADOPTED a promoted set — an adopting --resume counts),
# which the payload builder copies through so the documented convergence-rate
# metrics can exclude a promotion pass.
#
# Hooks (run via the shell, with these env vars exported):
#   --review-cmd  must write this round's aggregate findings JSON (issue #558
#                 schema) to $REVIEW_FINDINGS. Also sees $REVIEW_ROUND,
#                 $REVIEW_SKILL, $REVIEW_SCOPE_FILE (changed files, one per line),
#                 $REVIEW_REPO, and — since #1434 — $REVIEW_SCOPE_MODE ("full" |
#                 "delta"), $REVIEW_FIX_VERIFICATION (round >= 2: the previous
#                 round's blockers, to verify the fix actually landed) and
#                 $REVIEW_ADJUDICATED (already-waived suggestions the panel must
#                 not re-raise). $REVIEW_FIX_VERIFICATION is EMPTY on round 1,
#                 which has nothing to verify; $REVIEW_ADJUDICATED is ALWAYS a
#                 path — the file simply holds `[]` until something is waived —
#                 so test its CONTENTS, never its presence. Missing/empty
#                 output is treated as "no findings" on a DELTA round only; on
#                 a FULL round it is refused as STALE_FINDINGS (#1434), since
#                 zero blockers there is the CONVERGED condition.
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
#       [--max-rounds N] [--status-file PATH] [--work-dir DIR] \
#       [--issue N] [--telemetry-file PATH] [--gate-attest TREE_ID] \
#       [--promote FILE]                                          # step mode
#   resolve-story-loop.zsh --repo PATH [--base REF] \
#       --review-cmd CMD --fix-cmd CMD [--test-cmd CMD] \
#       [--promote FILE] ...                                      # hook mode
#   resolve-story-loop.zsh --no-review   # skip the loop entirely (fast path;
#                                        # refused together with --promote)
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
#       supplies the round's real findings. Since #1434 the same refusal covers
#       two further causes, BOTH of which also fire in hook mode, so exit 2
#       mid-run is no longer step-mode-only: a delta round with an EMPTY scope
#       and nothing carried to verify, and a FULL round whose panel produced no
#       findings file at all. There is no reviewed round in either, and reading
#       one as CONVERGED is the same false green.
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
local issue="" telemetry_file="" resume=0 gate_attest="" promote=""

# A value flag with no value, or one whose value is the NEXT FLAG, is a caller
# mistake — and both are silent disasters here. Under `nounset` a dangling
# `--issue` aborts on the bare `$2` with zsh's raw "2: parameter not set" and
# exit 1, which this script's taxonomy reserves for *internal* errors. And the
# unquoted `--telemetry-file $VAR` idiom with VAR unset collapses so the next
# flag becomes the value: `--telemetry-file --resume` would swallow `--resume`,
# silently running FRESH (truncating the prior rounds' accumulators) and then
# losing the telemetry record when the emitter rejects the flag-shaped path.
# Both sibling scripts guard exactly this way; a half-applied rule is the
# inconsistency the next caller trips on, so it covers EVERY value flag.
_need_val() {  # $1 = flag, $2 = remaining arg count, $3 = candidate value
  [[ $2 -ge 2 ]] || {
    print -u2 -- "resolve-story-loop: $1 requires a value"; exit 2 }
  [[ "$3" != --* ]] || {
    print -u2 -- "resolve-story-loop: $1 requires a value (got the flag $3)"; exit 2 }
  # An EXPLICIT empty value is the same mistake wearing a third hat — the
  # realistic `--flag "$VAR"` with VAR unset — and left alone it reads
  # downstream as "flag omitted", exit 0. The damage varies by flag and the
  # worst is silent: `--test-cmd ""` makes BOTH gate call sites fall to their
  # `[[ -n "$test_cmd" ]]` branches, so the loop can converge having never run
  # the suite. `--issue ""` drops the envelope's issue linkage; `--status-file
  # ""` writes no verdict file. Both sibling scripts refuse it, so refuse it
  # here too — for every value flag EXCEPT the one whose contract already
  # assigns empty a meaning (see _need_val_optional below).
  [[ -n "$3" ]] || {
    print -u2 -- "resolve-story-loop: $1 requires a non-empty value"; exit 2 }
}

# --gate-attest is the deliberate exception: #981 defines an empty value as
# FAIL-CLOSED ("a mismatch, an empty/absent value, or an uncomputable current
# identity runs --test-cmd as before"), so `--gate-attest ""` must degrade to
# "no attestation" and run the gate, NOT abort as a usage error. Refusing it
# would turn a documented safe default into a hard failure. The arg-count and
# flag-shape checks still apply — those are caller mistakes under any contract.
_need_val_optional() {  # $1 = flag, $2 = remaining arg count, $3 = candidate
  [[ $2 -ge 2 ]] || {
    print -u2 -- "resolve-story-loop: $1 requires a value"; exit 2 }
  [[ "$3" != --* ]] || {
    print -u2 -- "resolve-story-loop: $1 requires a value (got the flag $3)"; exit 2 }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo) _need_val "$1" $# "${2:-}"; repo="$2"; shift 2 ;;
  --base) _need_val "$1" $# "${2:-}"; base="$2"; shift 2 ;;
  --review-cmd) _need_val "$1" $# "${2:-}"; review_cmd="$2"; shift 2 ;;
  --fix-cmd) _need_val "$1" $# "${2:-}"; fix_cmd="$2"; shift 2 ;;
  --test-cmd) _need_val "$1" $# "${2:-}"; test_cmd="$2"; shift 2 ;;
  --gate-attest) _need_val_optional "$1" $# "${2:-}"; gate_attest="$2"; shift 2 ;;
  --findings-file) _need_val "$1" $# "${2:-}"; findings_file="$2"; shift 2 ;;
  # --promote (#994): pass-through in SUBSTANCE. The loop never *interprets* the
  # promoted set — but it does validate the file's shape up front
  # (_validate_promote) and canonicalise the path, then forwards that path to the
  # consolidator on EVERY round of a promotion sub-loop, so a promoted item stays
  # promoted across rounds instead of silently reverting to Low after round 1.
  # Both of those are load-bearing: without the shape check a bad file fails
  # mid-round as a bare exit 1 that writes no status JSON (#912), and without the
  # canonicalisation the persisted state is cwd-relative.
  --promote) _need_val "$1" $# "${2:-}"; promote="$2"; shift 2 ;;
  --max-rounds) _need_val "$1" $# "${2:-}"; max_rounds="$2"; shift 2 ;;
  --status-file) _need_val "$1" $# "${2:-}"; status_file="$2"; shift 2 ;;
  --work-dir) _need_val "$1" $# "${2:-}"; work_dir="$2"; shift 2 ;;
  --issue) _need_val "$1" $# "${2:-}"; issue="$2"; shift 2 ;;
  --telemetry-file) _need_val "$1" $# "${2:-}"; telemetry_file="$2"; shift 2 ;;
  --no-review) no_review=1; shift ;;
  --resume) resume=1; shift ;;
  -h|--help)
    print -r -- "usage: resolve-story-loop.zsh --repo PATH (--findings-file FILE | --review-cmd CMD --fix-cmd CMD)"
    print -r -- "  [--test-cmd CMD] [--gate-attest TREE_ID] [--base REF] [--max-rounds N] [--resume] [--issue N]"
    print -r -- "  [--promote FILE]"
    print -r -- "  [--work-dir DIR] [--status-file PATH] [--telemetry-file PATH]"
    print -r -- "  [--no-review]   # fast path; mutually exclusive with --promote"
    exit 0 ;;
  -*) print -u2 -- "unknown flag: $1"; exit 2 ;;
  *) print -u2 -- "unexpected argument: $1"; exit 2 ;;
  esac
done
local t0=$(date +%s)   # for the telemetry wall-clock (#566)

# The closing-sweep grant (#1434), read by emit_and_exit on EVERY exit — so it
# must exist before the first one (the --no-review fast path). A plain
# assignment, not `local`: at top level there is no new scope, and a bare
# `local NAME` whose name already exists in the environment PRINTS `NAME=value`
# on stdout, ahead of the status JSON.
closing_sweep_granted=0
# the round number of the closing full sweep, 0 until a zero-blocker delta round
# promotes one (or a --resume adopts one from <work-dir>/.closing-sweep)
closing_sweep_round=0

# Clear a stale telemetry run-id sidecar (#995) as EARLY as the run is known to
# be fresh — here, right after argument parsing, where `work_dir` and `resume`
# are final. The invariant is "a fresh run never hands back the PREVIOUS run's
# id", and everything that can exit before the fresh-run setup would otherwise
# break it: the --issue guards just below, the --no-review fast path (which
# returns SKIPPED before any work-dir setup, and skips telemetry entirely when
# --repo is not a directory), and every usage exit
# down to _validate_promote's — which the promotion sub-loop's own invocation
# hits. A caller then reads a foreign story's id and joins its enrichment onto
# that run's record. The in-parse exits above (_need_val, unknown flag)
# necessarily precede this and are not covered; they need a two-pass parse,
# which is not worth it for a caller-visible failure the caller re-invokes past.
# `rm -f` on a path whose directory does not exist yet is a no-op, and a
# --resume deliberately KEEPS the sidecar: it continues the same loop, whose
# next terminal exit overwrites it.
if (( ! resume )) && [[ -n "$work_dir" ]]; then
  # create it here rather than letting the telemetry block below do it as a side
  # effect: the --no-review fast path exits above the loop's own `mkdir -p`, so
  # without this the sidecar write would be the sole creator of the tree. `--`
  # because a --work-dir value may legitimately begin with a single dash.
  mkdir -p -- "$work_dir" 2>/dev/null || true
  # non-fatal, but never silent: rm -f still fails on an unwritable work-dir or
  # a directory at that path, and a silent failure leaves the stale id in place
  # — the exact state this clear exists to prevent, with nothing to notice it.
  # keep rm's OWN message: it is the only thing that separates the three
  # reachable failures (unwritable/unsearchable work-dir, a directory planted at
  # the sidecar path, --work-dir naming a regular file), and the diagnostic
  # below names none of them
  # `local rm_err=""`, never a bare `local rm_err`: at TOP LEVEL there is no new
  # scope, so a bare typeset whose name already exists in the environment PRINTS
  # `rm_err=value` — on stdout, ahead of the status JSON. Same hazard this file
  # documents for the loop-local declarations further down.
  local rm_err=""
  # -r: rm_err holds an EXTERNAL command's output, and print without -r
  # escape-processes it — mangling the very path that distinguishes the three
  # reachable failures
  rm_err=$(rm -f -- "$work_dir/.telemetry-run-id" 2>&1) || \
    print -ru2 -- "resolve-story-loop: could not clear the stale telemetry run-id sidecar at $work_dir/.telemetry-run-id (${rm_err}) — a later read may return a PREVIOUS run's id (#995)"
fi


# --issue rides straight into the telemetry envelope, whose contract is a
# non-negative integer. Before #1004 a junk value (`--issue '#123'` from a
# caller's glue) was coerced to null and the record still landed; now the
# emitter rejects it and `|| true` swallows the rejection, costing the ENTIRE
# terminal record at the very end of a run. Fail at parse time instead, where
# the caller can still see it.
[[ -z "$issue" || "$issue" == <-> ]] || {
  print -u2 -- "resolve-story-loop: --issue must be a non-negative integer (got: $issue)"; exit 2 }
# ...and the emitter's WIDTH cap too. Porting only the digits-only half would
# leave the same hole this guard exists to close: a 19+ digit value is
# digit-only, so it would sail past here, be rejected by the emitter at
# terminal-exit time, and lose the whole record behind `|| true`.
[[ -z "$issue" || ${#issue} -le 18 ]] || {
  print -u2 -- "resolve-story-loop: --issue is out of range (max 18 digits, got: $issue)"; exit 2 }

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
  # promotion_phase (#995) is ALWAYS present — a plain boolean, true exactly
  # when this invocation carried OR ADOPTED a promoted set, i.e. when it is the
  # promotion sub-loop. It is derived AFTER the --resume adoption branch on
  # purpose: a resume that drops --promote and re-adopts the work-dir's .promote
  # is still the promotion sub-loop, and its (often CONVERGED) record must not
  # be counted as a phase-1 story. build-telemetry-record.zsh copies it into the payload so the
  # documented convergence metrics can exclude the second pass; always-present
  # means a consumer never has to distinguish "false" from "an older status
  # file that predates the key".
  local promotion_phase='false'
  [[ -n "$promote" ]] && promotion_phase='true'
  # closing_sweep_granted (#1434) is ALWAYS present, for the same reason
  # promotion_phase is: a consumer must never have to tell `false` from "a status
  # file that predates the key". `max_rounds` deliberately keeps reporting the
  # value the caller PASSED — the one-round grant is a fact about this run, not a
  # retune of the budget, and a mutated ceiling here would make every downstream
  # budget reader (the SKILL soft cap, the escalation summary) disagree with the
  # command line that produced it.
  local granted_json='false'
  (( closing_sweep_granted )) && granted_json='true'
  out=$(jq -nc \
    --arg status "$st" --argjson rounds "$rounds" --argjson max "$max_rounds" \
    --arg repo_type "$repo_type" --arg review_skill "$review_skill" \
    --argjson final "$final" --argjson history "$history" --argjson esc "$esc" \
    --argjson clists "$clists" --argjson promotion_phase "$promotion_phase" \
    --argjson granted "$granted_json" \
    '{status:$status, rounds:$rounds, max_rounds:$max,
      promotion_phase:$promotion_phase, closing_sweep_granted:$granted,
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

  # telemetry (#566, on the shared `telemetry/v1` contract since #1004): append
  # exactly one JSONL record per TERMINAL EXIT — terminal statuses only, never the
  # non-terminal AWAITING_FIX (#971) or the STALE_FINDINGS refusal (#974), which
  # would double-count the loop that resumes right after it. The envelope AND
  # the sink belong to the shared emitter (#740 child (a)); this loop supplies
  # only its own `payload` and the envelope's linkage fields. Never fatal — a
  # telemetry failure can't change the loop's exit.
  #
  # `repo` must be an existing directory: the emitter derives the repo identity
  # and the default sink from it. It always is by the time a loop runs, but the
  # --no-review fast path short-circuits BEFORE the --repo checks, so guard here
  # rather than hand the emitter a path it would reject.
  if [[ "$st" != "AWAITING_FIX" && "$st" != "STALE_FINDINGS" && -d "$repo" ]]; then
    local t_begin="$t0"
    if [[ -n "$work_dir" && -s "$work_dir/.t0" ]]; then
      t_begin=$(<"$work_dir/.t0")
      # digits AND width: `--ts` carries the emitter's 18-digit cap, so an
      # over-wide .t0 would be rejected there and cost the whole record
      [[ "$t_begin" == <-> && ${#t_begin} -le 18 ]] || t_begin="$t0"
    fi
    # The loop's own status narrows onto the 4-value cross-pipeline `outcome`
    # enum dashboards group on; nothing is lost, because the full status stays
    # in the payload. The catch-all is `failed` (ERROR today) rather than a
    # guess, so a status added later is never silently counted as a success.
    local outcome
    case "$st" in
      CONVERGED|SKIPPED)           outcome="success" ;;
      ESCALATE_*|BUDGET_EXHAUSTED) outcome="escalated" ;;
      *)                           outcome="failed" ;;
    esac
    # wall_s is REQUIRED and must be non-negative; the emitter rejects a
    # negative outright (exit 2), which `|| true` would swallow — costing the
    # whole record. A backwards clock step (NTP) or a work-dir whose `.t0` is
    # stamped ahead of now both produce one, so clamp rather than lose the run.
    local wall_s=$(( $(date +%s) - t_begin ))
    (( wall_s >= 0 )) || wall_s=0
    local tmp_status="" tmp_payload=""
    tmp_status=$(mktemp) && tmp_payload=$(mktemp) && {
      print -r -- "$out" > "$tmp_status"
      # a failed payload build emits NOTHING: an envelope wrapped around an
      # empty/partial payload would validate (payload is OPEN) and still be
      # useless — it would silently poison the convergence metrics.
      # RESOLVE_LOOP_PAYLOAD_BIN pins the builder so a test can exercise that
      # branch — the DETECT_STACK_BIN / RESOLVE_LOOP_DIGEST_TOOL convention;
      # unset in production.
      local payload_bin="${RESOLVE_LOOP_PAYLOAD_BIN:-${self_dir}/build-telemetry-record.zsh}"
      if "$payload_bin" --status "$tmp_status" > "$tmp_payload"; then
        local -a emit_args
        emit_args=(--pipeline review-loop --kind run --outcome "$outcome"
                   --repo-dir "$repo" --ts "$t_begin"
                   --wall-s "$wall_s"
                   --payload "$tmp_payload")
        [[ -n "$issue" ]] && emit_args+=(--issue "$issue")
        [[ -n "$repo_type" && "$repo_type" != "null" ]] && emit_args+=(--repo-type "$repo_type")
        [[ -n "$telemetry_file" ]] && emit_args+=(--telemetry-file "$telemetry_file")
        # The emitter echoes the record to stdout. The loop's stdout is the
        # status JSON contract, so it is CAPTURED, never printed (stderr stays
        # visible for diagnosis) — and the capture is what makes the minted
        # `run_id` recoverable (#995): a promotion enrichment must carry the
        # enriched run's id, and a fresh one would validate cleanly while being
        # permanently orphaned. It goes to a `<work-dir>/.telemetry-run-id`
        # sidecar rather than into the status JSON, because the status JSON is
        # written BEFORE telemetry runs — deliberately, so a slow or broken
        # emitter can neither delay nor damage the loop's primary output. The
        # sidecar mirrors the existing `.t0` idiom, is rewritten on every
        # terminal exit, and every failure here stays swallowed.
        # Clear before attempting: the sidecar is otherwise cleared only at
        # fresh-run start, so on an extended run (escalate -> grant -> resume)
        # a FAILED emission on the later terminal exit would leave the EARLIER
        # exit's id in place. A reader then finds a non-empty sidecar — the
        # "no id, no enrichment" valve never fires — and joins the enrichment to
        # a superseded record. Clearing here makes the invariant exact: the
        # sidecar holds the id of THIS terminal exit's record, or nothing.
        [[ -d "$work_dir" ]] && { rm -f -- "$work_dir/.telemetry-run-id" 2>/dev/null || true }
        local rec=""
        if rec=$("${self_dir}/../../../scripts/telemetry/emit-telemetry.zsh" "${emit_args[@]}"); then
          # `-d`, not `-n`: the work-dir is created up front (next to the
          # stale-sidecar clear, and again in the fresh-run setup), so this
          # branch never has to create it — directory creation must not be an
          # emergent side effect of a best-effort telemetry path. A work-dir
          # that still does not exist here is one the write would fail on
          # anyway. The one gap this leaves is `--no-review --resume` with a
          # nonexistent work-dir: the up-front mkdir is resume-gated and the
          # fast path exits above the fresh-run setup, so that exit emits its
          # record and writes no sidecar.
          if [[ -n "$work_dir" && -d "$work_dir" && -n "$rec" ]]; then
            local rid=""
            rid=$(print -r -- "$rec" | jq -r '.run_id // empty' 2>/dev/null) || rid=""
            # only a non-empty id is worth persisting: an empty file would read
            # as "there is an id" to a naive consumer, and the SKILL.md guard
            # treats absent and empty identically for exactly that reason.
            # brace-group the redirection so a failure to OPEN the sidecar path
            # (a read-only work-dir, a directory at that path) is swallowed too
            # — zsh installs redirections left to right, so `print … > f
            # 2>/dev/null` would report the open failure on the real stderr
            # before the discard is in place. Same idiom as the progress.md and
            # history writes above.
            # a MULTI-LINE rid is unusable as a join key but would pass a bare
            # -n guard, and the emitter only requires --run-id to be non-empty —
            # so it would land as a cleanly-validating orphan
            [[ -n "$rid" && "$rid" != *$'\n'* ]] && { { print -r -- "$rid" > "$work_dir/.telemetry-run-id" ; } 2>/dev/null || true }
          fi
        fi
      fi
    }
    rm -f -- "$tmp_status" "$tmp_payload" 2>/dev/null || true
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
      summary:{critical:0,high:0,low:0,blocking:0,conflicts:0,false_trips:0,adjudicated_dropped:0}, blocking:[], suggestions:[],
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

# Write this round's review scope: the dispatch descriptor's changed_files
# (#911 — refreshed per round, so a file the previous fix pass created is
# reviewed rather than invisible behind a scope frozen at invocation start),
# minus a repo-internal work-dir's own state files (#909/#911 — those are loop
# state, never story code, and the dispatch's own exclusions cover only the
# default artifact prefixes). ONE definition, because #1434 may re-plan a round
# and must re-derive the scope the same way; two copies is how they drift.
# Returns non-zero on a failed extraction — the caller aborts the round rather
# than leaving a truncated scope behind.
write_round_scope() {  # $1 = descriptor JSON, $2 = round
  local desc="$1" r="$2"
  print -r -- "$desc" | jq -r '.changed_files[]?' > "$scope_file" || {
    print -u2 -- "resolve-story-loop: could not extract scope at round $r"; return 1 }
  if [[ -n "$wd_rel" && -s "$scope_file" ]]; then
    local -a lines
    lines=("${(@f)$(<"$scope_file")}")
    lines=(${lines:#${(b)wd_rel}*})
    if (( ${#lines} )); then
      print -rl -- "${lines[@]}" > "$scope_file"
    else
      : > "$scope_file"
    fi
  fi
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
# --max-rounds reaches `--argjson max` in emit_and_exit on EVERY exit — the
# --no-review fast path below included — so it must be validated BEFORE that
# path, not after it. A non-positive/non-numeric ceiling would otherwise make
# jq fail, blanking the status JSON while still exiting 0.
[[ "$max_rounds" == <-> ]] && [[ ${#max_rounds} -le 18 ]] && (( 10#$max_rounds >= 1 )) || {
  print -u2 -- "resolve-story-loop: --max-rounds must be a positive integer of at most 18 digits (got: $max_rounds)"; exit 2 }
# `<->` accepts leading zeros but JSON forbids them, so a `03` would reach
# --argjson and fail there — emptying `out`, printing a BLANK line as the
# status JSON, and losing the telemetry record while the exit code still
# claimed a verdict. Normalize, exactly as the shared emitter does.
max_rounds=$(( 10#$max_rounds ))

# --promote with --no-review is a contradiction, not a fallback: nothing is
# consolidated, so there is no overlay to apply — and the fast path reaches
# emit_and_exit ABOVE _validate_promote, so the combination would stamp
# promotion_phase:true on a SKIPPED record from a promote file that was never
# even checked to exist. Refuse it where the sibling contradiction
# (--findings-file with --review-cmd) is refused.
if (( no_review )) && [[ -n "$promote" ]]; then
  print -u2 -- "resolve-story-loop: --promote is meaningless with --no-review (nothing is consolidated)"; exit 2
fi

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

[[ -n "$work_dir" ]] || work_dir=$(mktemp -d)
mkdir -p -- "$work_dir"
local history_file="$work_dir/history.jsonl"
# --promote is an INPUT PATH, and the only one the loop used to forward blind.
# Left unchecked, a typo survives parse and the run does a full round's setup —
# per-round dispatch, scope refresh, truncating the round sink, consuming
# --findings-file — before the consolidator rejects it; the loop maps that to a
# BARE exit 1 that writes no status JSON, so --status-file keeps the previous
# invocation's verdict (the #912 hazard every other refusal here is typed to
# avoid). --repo and --findings-file are validated up front; so is this now.
# ONE validator for the promote file, used by BOTH the explicit-flag path and the
# resume-adoption path — two hand-written copies is how the two drift, and they
# already did: the first spelling used `jq -e`, whose exit status reflects only
# the LAST output value, so a file holding two concatenated arrays (written with
# >> instead of >) emitted true,true and passed. `--slurp` makes jq see the whole
# file as ONE value, so the count is checkable.
#
# Validating the SHAPE up front — not merely that a file exists — is the point:
# every refusal the consolidator makes on this file would otherwise surface
# mid-round as a BARE exit 1 that writes no status JSON, leaving --status-file
# holding the previous invocation's verdict (#912). jq's own parse diagnostic is
# kept (only the filter result is discarded): for a file a model wrote from a
# multiSelect, "line N, column M" is what locates the slip.
_validate_promote() {  # $1 = path, $2 = label for the diagnostic
  [[ -f "$1" && -s "$1" ]] || {
    print -u2 -- "resolve-story-loop: $2 must be a non-empty regular file: $1"; exit 2 }
  # `type == "object"` alone accepts `[{}]` and mis-keyed objects (`path` for
  # `file`, a missing `dimension`) — plausible slips for a file a model writes
  # from a multiSelect. The consolidator would then compare against empty
  # strings, match nothing, and the sub-loop would exit CONVERGED having done
  # none of the work: the same terminal-SUCCESS failure the persistence
  # machinery exists to prevent, reached by another road. Require the keys.
  # Mirrors the consolidator's predicate exactly, so the two cannot drift:
  # `file`/`dimension` must be non-empty (they are matched for equality, so an
  # empty one is meaningless), `title` must be a string but MAY be empty (a
  # genuinely untitled finding stays promotable, and the overlay caps a
  # tokenless key at one item). A NON-EMPTY array is required on top: `[]` would
  # run a provably no-op overlay every round and converge reporting success,
  # when the contract is that selecting nothing skips the sub-loop entirely.
  jq -e -s 'length == 1 and (.[0] | type == "array" and length > 0
              and all(.[]; type == "object"
                    and (.file | type == "string" and length > 0)
                    and (.dimension | type == "string" and length > 0)
                    and (.title | type == "string")))' \
    -- "$1" >/dev/null || {
    print -u2 -- "resolve-story-loop: $2 must be exactly ONE non-empty JSON array of objects with non-empty file and dimension and a string title: $1"; exit 2 }
}

if [[ -n "$promote" ]]; then
  _validate_promote "$promote" "--promote"
  # Persisted state must not be cwd-relative: step mode spans invocations whose
  # cwd need not be stable, and a bare `promoted.json` would resolve differently
  # (or, worse, resolve to a DIFFERENT same-named file) on the next one.
  promote="${promote:A}"
fi

local changelists_file="$work_dir/changelists.jsonl"
# The promoted set is CROSS-INVOCATION state, so it lives in the work-dir like
# every other piece (history, changelists, .t0, findings digests). Forwarding it
# per round only covers rounds inside ONE invocation — but step mode, the
# canonical wiring, runs each round as its own invocation. A --resume that
# omitted --promote would consolidate with no overlay, drop the promoted item
# back to Low, reach `.summary.blocking == 0` and exit CONVERGED (0): the
# feature failing as a terminal SUCCESS, and one non-convergence detection
# cannot catch, because the demoted item is no longer in `.blocking` to match
# against $prevblk. So persist it on a fresh run and adopt it on resume.
local promote_state="$work_dir/.promote"
# On --resume we CONTINUE a prior run: the work-dir IS the state. Read the last
# completed round from history, and re-use its persisted changelist file as the
# prior round so non-convergence detection spans the extension. A fresh run
# (no --resume) truncates both accumulators as before.
local resume_round=0 resume_prev=""
# Per-round iteration state (#1434), all of it per-RUN: truncated on a fresh
# start beside .findings-digest-* / .promote, adopted on --resume.
local closing_sweep_file="$work_dir/.closing-sweep"
local adjudicated_file="$work_dir/adjudicated.json"
# The ceiling the WHILE loop and the BUDGET_EXHAUSTED test actually use. It
# equals --max-rounds except on a run whose closing sweep was granted the one
# extra round; --max-rounds itself is never mutated (see emit_and_exit).
local effective_max=$max_rounds
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
  local hist_n=0 clist_n=0
  hist_n=$(jq -sc 'length' "$history_file")
  clist_n=0
  [[ -s "$changelists_file" ]] && clist_n=$(jq -sc 'length' "$changelists_file")
  if (( clist_n == hist_n + 1 )); then
    print -u2 -- "resolve-story-loop: --resume dropping 1 orphaned changelist line — prior run killed mid-append"
    local clist_trunc="$work_dir/.changelists-trunc"
    head -n "$hist_n" -- "$changelists_file" > "$clist_trunc" && mv -- "$clist_trunc" "$changelists_file" || {
      print -u2 -- "resolve-story-loop: --resume could not truncate $changelists_file"; exit 1 }
  elif (( clist_n != hist_n )); then
    print -u2 -- "resolve-story-loop: --resume accumulator skew beyond the kill window (history $hist_n vs changelists $clist_n) in $work_dir — corrupt work-dir"; exit 1
  fi
  resume_round=$(tail -n 1 -- "$history_file" | jq -r '.round')
  [[ "$resume_round" == <-> ]] || {
    print -u2 -- "resolve-story-loop: --resume could not read a round number from $history_file"; exit 1 }
  resume_prev="$work_dir/changelist-$resume_round.json"
  [[ -s "$resume_prev" ]] || {
    print -u2 -- "resolve-story-loop: --resume cannot find prior changelist $resume_prev"; exit 1 }
  # Adopt a granted closing sweep BEFORE the ceiling guard (#1434). Without
  # this, the one case the grant exists for — a zero-blocker delta round at the
  # ceiling — would be refused by the very next --resume, so the safety net
  # would be unreachable in step mode, which is the canonical wiring.
  if [[ -s "$closing_sweep_file" ]]; then
    # `local cs_round=""`, never a bare `local cs_round`: at TOP LEVEL there is
    # no new scope, so a bare typeset whose name already exists in the
    # environment PRINTS `cs_round=value` — on stdout, ahead of the status JSON.
    local cs_round=""
    cs_round=$(<"$closing_sweep_file")
    cs_round="${cs_round//[[:space:]]/}"
    # a garbage sidecar must not become a ceiling: fall back to --max-rounds and
    # say so, rather than silently granting or silently refusing
    if [[ "$cs_round" == <-> ]] && (( ${#cs_round} <= 18 )); then
      closing_sweep_round=$(( 10#$cs_round ))
      # The format check above is not enough: a WELL-FORMED but wrong number is
      # the road that actually defeats the budget. The grant is contracted as
      # ONE round beyond --max-rounds, so anything past that is refused rather
      # than adopted — a foreign or corrupted marker holding `99` would
      # otherwise raise the ceiling by 94 rounds with no diagnostic, and a
      # resume passing a SMALLER --max-rounds than the run that wrote the
      # marker would adopt a sweep two or more rounds out while also stamping
      # closing_sweep_granted on a sweep that was never a grant. The promotion
      # path cannot produce this (it always writes round + 1); only adoption
      # can, so only adoption needs the clamp.
      if (( closing_sweep_round > max_rounds + 1 )); then
        print -u2 -- "resolve-story-loop: ignoring a closing-sweep marker beyond the one-round grant (got $closing_sweep_round, --max-rounds $max_rounds, so the highest grantable sweep is $(( max_rounds + 1 ))) in $closing_sweep_file"
        closing_sweep_round=0
      elif (( closing_sweep_round > max_rounds )); then
        effective_max=$closing_sweep_round
        closing_sweep_granted=1
      fi
    else
      print -u2 -- "resolve-story-loop: ignoring an unreadable closing-sweep marker in $closing_sweep_file (got: ${cs_round:-<empty>})"
      closing_sweep_round=0
    fi
  fi
  # a ceiling at or below the resumed round would run zero rounds and fall out
  # of the loop with an empty status — refuse it as a usage error instead
  (( resume_round + 1 <= effective_max )) || {
    print -u2 -- "resolve-story-loop: --resume would start at round $(( resume_round + 1 )) but --max-rounds is $max_rounds — raise --max-rounds"; exit 2 }
  # an older work-dir (or one whose file was cleaned up) simply starts empty
  [[ -f "$adjudicated_file" && -s "$adjudicated_file" ]] || print -r -- '[]' > "$adjudicated_file" || {
    print -u2 -- "resolve-story-loop: could not initialise $adjudicated_file"; exit 1 }
  # ...and a non-empty one is adopted only if it still holds ONE JSON array.
  # This is PERSISTENT state: a truncated or hand-edited file would abort the
  # invalidation jq (or the consolidator's own --adjudicated refusal) as a BARE
  # exit 1 that writes no status JSON, and every later --resume would die at the
  # same point with the work-dir bricked. Re-initialise rather than refuse — the
  # cost is at most one already-waived suggestion logged again, which is the
  # harmless direction the whole drop rule is built on.
  # The predicate must match what the DOWNSTREAM refusals check, not merely the
  # container: `["foo"]` passes an array test and then aborts the invalidation
  # jq on `$e.file`, and `[{"file":"a.zsh"}]` passes both and is refused by the
  # consolidator's own --adjudicated validator. Either way the loop dies as a
  # BARE exit 1 that writes no status JSON, and because this file is PERSISTENT
  # state every later --resume dies at the same point. So mirror the
  # consolidator's element predicate exactly.
  jq -e -s 'length == 1 and (.[0] | type == "array" and all(.[]; type == "object"
              and (.file | type == "string" and length > 0)
              and (.dimension | type == "string" and length > 0)
              and (.title | type == "string")))' -- "$adjudicated_file" >/dev/null 2>&1 || {
    print -u2 -- "resolve-story-loop: --resume found a damaged $adjudicated_file — re-initialising to [] (no suggestion will be suppressed this run)"
    print -r -- '[]' > "$adjudicated_file" || {
      print -u2 -- "resolve-story-loop: could not re-initialise $adjudicated_file"; exit 1 } }
  # adopt the run's promoted set when this invocation did not carry it: dropping
  # --promote on a resume is a one-flag slip in a long command line, and its
  # failure mode is a silent CONVERGED rather than an error. An explicit
  # --promote still wins (a caller may legitimately re-point it), but it must
  # then be usable — a stale path would otherwise fail per-round as a bare exit 1.
  # `-e`, not `-s`: a ZERO-BYTE .promote is BROKEN state, not absent state. With
  # `-s` it would be skipped silently, no overlay forwarded, and the sub-loop
  # could reach CONVERGED — the very silent success the file exists to prevent,
  # reached through the file itself.
  if [[ -z "$promote" && -e "$promote_state" ]]; then
    promote=$(<"$promote_state")
    [[ -n "$promote" ]] || {
      print -u2 -- "resolve-story-loop: $promote_state is empty — the promoted set was lost; re-pass --promote"; exit 2 }
    # the recovered path names a file OUTSIDE the work-dir (the scratch dir the
    # promote file lives in), so between rounds it can have been cleaned up OR
    # rewritten badly — validate it through the SAME helper as an explicit
    # --promote, and refuse loudly rather than forwarding a bad path that would
    # fail mid-round as an untyped exit 1
    _validate_promote "$promote" "--resume adopted promoted set from $promote_state"
    print -u2 -- "resolve-story-loop: --resume adopting the run's promoted set from $promote_state ($promote)"
  fi
else
  : > "$history_file" || {
    print -u2 -- "resolve-story-loop: could not truncate $history_file for a fresh run"; exit 1 }
  : > "$changelists_file" || {
    print -u2 -- "resolve-story-loop: could not truncate $changelists_file for a fresh run"; exit 1 }
  # the consumed-findings digests are per-run state too (#974): a re-used
  # work-dir must not let a previous run's round-N digest veto this run's
  # round N+1
  rm -f -- "$work_dir"/.findings-digest-*(N) "$work_dir"/.findings-empty-*(N)
  # the promoted set is per-run state too: record it for later --resume
  # invocations, and clear a previous run's so a re-used work-dir cannot
  # resurrect an overlay this run did not ask for
  rm -f -- "$promote_state"
  # the iteration state (#1434) is per-run for exactly the same reason: a
  # re-used work-dir must not let a previous run's tree identity scope THIS
  # run's round 2 (a delta against a foreign tree is arbitrary), nor its waived
  # suggestions suppress this run's findings, nor its closing-sweep marker grant
  # a round this run never earned. `(N)` so an empty glob is not an error.
  # DIAGNOSED, not silent — the same argument the telemetry-sidecar clear above
  # makes: a silent failure leaves the previous run's state in place, which is
  # the exact condition this clear exists to prevent, with nothing to notice it.
  # A foreign `verify-2.json` in particular is read as present by the round-2
  # fallback (`! -s`), so a PREVIOUS run's blockers would be forwarded to this
  # run's panel as its fix-verification carry.
  local rm_state_err=""
  rm_state_err=$(rm -f -- "$work_dir"/tree-*.txt(N) "$work_dir"/verify-*.json(N) "$closing_sweep_file" 2>&1) || \
    print -ru2 -- "resolve-story-loop: could not clear the previous run's iteration state in $work_dir (${rm_state_err}) — a foreign fix-verification carry or closing-sweep marker may be adopted (#1434)"
  print -r -- '[]' > "$adjudicated_file" || {
    print -u2 -- "resolve-story-loop: could not initialise $adjudicated_file"; exit 1 }
  # (the telemetry run-id sidecar is cleared far earlier — see the #995 note
  # above the --no-review fast path, which must run before every exit that can
  # precede this setup)
  # the loop's logical start — a step-mode run spans several invocations, and
  # the terminal telemetry must report whole-loop wall clock, not the last
  # round's (#971)
  print -r -- "$t0" > "$work_dir/.t0"
fi

# Persist AFTER the resume/fresh branch, so an explicit --promote is recorded on
# EVERY invocation that carries one — not just a fresh run. Writing it only on the
# fresh branch left `.promote` stale the moment a --resume re-pointed the flag:
# the NEXT resume that omitted it would adopt the SUPERSEDED set, and a promotion
# first added on a resume was never persisted at all (so a later omitted-flag
# resume ran with no overlay and could reach CONVERGED). The fresh branch above
# clears the file, so a re-used work-dir still cannot resurrect a previous run's
# set. Losing this state silently would degrade to a false CONVERGED, so a failed
# write is fatal rather than swallowed.
if [[ -n "$promote" ]]; then
  print -r -- "$promote" > "$promote_state" || {
    print -u2 -- "resolve-story-loop: could not persist the promoted set to $promote_state"; exit 1 }
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
local plan="" rc=0
plan=$("$DISPATCH" plan --repo "$repo" --base "$base" --round 1); rc=$?
if (( rc == 3 )); then
  # unsupported / ambiguous repo type — surface as an escalation. On --resume
  # the prior run's rounds and changelists are real state and must ride out
  # with the status, never a hardcoded fresh-run zero (#912).
  emit_ambiguous "$plan" "$resume_round" "" ""
elif (( rc != 0 )); then
  print -u2 -- "resolve-story-loop: dispatch plan failed (rc=$rc)"; exit 1
fi

local repo_type="" review_skill="" scope_file="$work_dir/scope.txt"
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
# EVERY declaration here carries an initialiser. At top level zsh opens no new
# scope, so a bare `local NAME` for a name that already exists in the
# environment PRINTS `NAME=value` on stdout — ahead of the status JSON, which is
# this script's stdout contract. The file states that rule three times above,
# and `blocking`, `verdict`, `changelist`, `scoped` and `carried` are ordinary
# enough words to inherit from a caller's environment — so the rule now covers
# the whole block rather than only the lines #1434 added.
local rp="" findings_path="" scoped="" scoped_filtered="" changelist="" blockers=""
local digest="" prev_digest_file=""
local prev_findings_empty=0
local blocking=0 conflict=0 nonconv=0 nconf=0 verdict="" ftrips=0
local adj_dropped=0
local cur_tree="" prior_tree="" prior_tree_file="" fix_verification=""
local scope_mode="" replanned_scope_mode="" delta_json="" carried=0
local is_final=0 is_closing_sweep=0 is_empty_delta=0 empty_delta_note=""
local round_scope_empty=0 round_findings_empty=0 rc_empty=0
local skip_fix=0 adj_tmp=""
local -a consolidate_args=() plan_args=()
while (( round <= effective_max )); do
  # --- this round's working-tree identity (#1434) ---------------------------
  # Computed BEFORE anything else in the round, so it is exactly the tree the
  # round's reviewers see; the NEXT round diffs against it, which makes its delta
  # precisely what this round's fix pass changed.
  cur_tree=$("$TREE_ID" "$repo" 2>/dev/null) || cur_tree=""
  [[ -n "$cur_tree" ]] || {
    print -u2 -- "resolve-story-loop: could not compute the working-tree identity for round $round in $repo — the next round would have nothing to iterate on"; exit 1 }
  print -r -- "$cur_tree" > "$work_dir/tree-$round.txt" || {
    print -u2 -- "resolve-story-loop: could not persist the round $round tree identity to $work_dir/tree-$round.txt"; exit 1 }

  # the PREVIOUS round's identity is what scopes this one. A missing or blank
  # one is a hard error, never a silent fall back to the full diff: that
  # fallback is the defect this story fixes, and it would be invisible.
  prior_tree=""
  if (( round >= 2 )); then
    prior_tree_file="$work_dir/tree-$(( round - 1 )).txt"
    prior_tree=""
    [[ -s "$prior_tree_file" ]] && prior_tree="${$(<"$prior_tree_file")//[[:space:]]/}"
    [[ -n "$prior_tree" ]] || {
      print -u2 -- "resolve-story-loop: round $round has no usable prior tree identity at $prior_tree_file — cannot scope a delta round; start a fresh --work-dir"; exit 1 }
  fi

  # --- fix-verification carry (#1434) --------------------------------------
  # Exactly what the previous round's fix pass was told to fix, so this round's
  # panel can verify each item actually landed instead of re-deriving it.
  #
  # It is normally written at the END of the PREVIOUS round (see below), because
  # in step mode — the canonical wiring — this round's panel runs BEFORE this
  # invocation exists, so a file first created here would never be readable by
  # the reviewers who are supposed to consume it. This block is the FALLBACK for
  # the cases where no such file is on disk: an older work-dir, or the first
  # round of a `--resume` into a run that predates the end-of-round write.
  fix_verification=""
  if (( round >= 2 )); then
    fix_verification="$work_dir/verify-$round.json"
    # `! -s`, not `! -e`: the end-of-round write opens and truncates its target
    # before jq fills it, so a run killed in that window (or an ENOSPC) leaves a
    # ZERO-BYTE carry behind. Read as "present", it would be forwarded as an
    # empty carry — the panel gets nothing to verify and a blocker rides out to
    # CONVERGED, the exact guarantee this carry exists to add — or, on an
    # empty-delta round, refuse with "the previous round left no blockers",
    # a claim about the previous round the loop never established. A legitimate
    # `[]` is three bytes and still counts as present.
    if [[ ! -s "$fix_verification" ]]; then
      if [[ -n "$prev_changelist" && -s "$prev_changelist" ]]; then
        jq -c '.blocking // []' -- "$prev_changelist" > "$fix_verification" || {
          print -u2 -- "resolve-story-loop: could not build the fix-verification carry at $fix_verification"; exit 1 }
      else
        print -r -- '[]' > "$fix_verification" || {
          print -u2 -- "resolve-story-loop: could not build the fix-verification carry at $fix_verification"; exit 1 }
      fi
    fi
    # ...and it must be a JSON ARRAY before anything consumes it. A corrupt
    # carry is otherwise invisible on an ordinary delta round: only the
    # empty-delta path ever runs `jq length` on it, so a truncated or
    # half-written file would be handed to the panel as though it were a carry.
    jq -e -s 'length == 1 and (.[0] | type == "array")' -- "$fix_verification" >/dev/null 2>&1 || {
      print -u2 -- "resolve-story-loop: the fix-verification carry $fix_verification is not a JSON array — the round $(( round - 1 )) blockers cannot be verified"; exit 1 }
  fi

  # a round is the closing full sweep only if a prior zero-blocker delta round
  # promoted it — never by default, and never twice. `is_closing_sweep` keeps
  # that fact separate from `is_final`, which the empty-delta branch below may
  # also set: only the PROMOTED sweep follows a round that found nothing, and
  # the stale-findings digest guard needs to tell the two apart.
  is_closing_sweep=0
  (( closing_sweep_round > 0 && round == closing_sweep_round )) && is_closing_sweep=1
  is_final=$is_closing_sweep
  # ...and a third, set by the empty-delta branch below: a round whose delta was
  # empty knows NOTHING in the tree changed since the round before, so identical
  # findings are a shape its own scope explains. The digest guard reads it only
  # to word its refusal, never to waive it.
  is_empty_delta=0

  # per-round dispatch: the round's well-known findings path AND a fresh scope
  plan_args=( plan --repo "$repo" --base "$base" --round "$round" )
  [[ -n "$prior_tree" ]] && plan_args+=( --prior-tree "$prior_tree" )
  (( is_final )) && plan_args+=( --final )
  [[ -n "$fix_verification" ]] && plan_args+=( --fix-verification "$fix_verification" )
  plan_args+=( --adjudicated "$adjudicated_file" )
  rp=$("$DISPATCH" "${plan_args[@]}"); rc=$?
  if (( rc == 3 )); then
    # a fix pass changed what detection sees (e.g. added a second supported
    # language) — the same typed escalation as the pre-loop path, not a bare
    # exit 1 that leaves --status-file holding the previous verdict (#912)
    emit_ambiguous "$rp" "$(( round - 1 ))" "$repo_type" "$review_skill"
  elif (( rc != 0 )); then
    print -u2 -- "resolve-story-loop: dispatch plan failed at round $round (rc=$rc)"; exit 1
  fi
  # --- an EMPTY delta is never a reviewed round (#1434) ---------------------
  # A delta round whose scope is empty saw nothing. Consuming it as an ordinary
  # round would let it reach zero blockers and — via the closing-sweep
  # promotion — green-light a PR on the strength of a round in which no reviewer
  # looked at anything. Two shapes, and they end differently:
  #   * something IS carried to verify (the previous round's blockers) — a
  #     legitimate verification-only round, and the two wirings handle it
  #     differently (see the branch below). HOOK MODE promotes it to a full
  #     sweep in place, because its panel runs after the re-plan, and it may then
  #     declare CONVERGED. STEP MODE leaves it a DELTA round — its panel already
  #     ran against the empty delta — so it is consumed normally but cannot
  #     converge; a clean result promotes the closing full sweep instead;
  #   * nothing carried either — refuse it, typed, exactly as a never-produced
  #     findings file is refused. This is the ONLY empty-delta refusal.
  #
  # Emptiness is judged on the WRITTEN scope, not on the descriptor's
  # `scope_empty`. The two differ in exactly one case, and it is a real one: a
  # repo-internal `--work-dir` puts the loop's own state files (history.jsonl,
  # the changelists, progress.md, the tree ids) squarely inside every delta, so
  # the descriptor reports a non-empty scope while the #909/#911 filter leaves
  # the panel with nothing at all. Trusting `scope_empty` there would wave
  # through precisely the unreviewed round this branch exists to catch. A
  # descriptor-empty scope is filtered-empty too, so this is a superset.
  # The descriptor's own `scope_empty` is deliberately NOT read: it would be a
  # second, weaker answer to the question the line below already answers, and a
  # dead read carrying `|| exit 1` gives an unused value the power to end a run.
  scope_mode=$(print -r -- "$rp" | jq -r '.scope_mode // "full"') || {
    print -u2 -- "resolve-story-loop: could not read scope_mode at round $round"; exit 1 }
  write_round_scope "$rp" "$round" || exit 1
  if [[ "$scope_mode" == "delta" && ! -s "$scope_file" ]]; then
    # A DAMAGED carry is not "nothing to verify". Collapsing the two would make
    # the refusal below claim "the previous round left no blockers to verify" —
    # a statement about the previous round the loop never established — and
    # advise stopping on a run whose blockers are merely unreadable.
    carried=0
    if [[ -n "$fix_verification" && -s "$fix_verification" ]]; then
      carried=$(jq 'length' -- "$fix_verification") || {
        print -u2 -- "resolve-story-loop: could not read the fix-verification carry $fix_verification at round $round"; exit 1 }
      [[ "$carried" == <-> ]] || {
        print -u2 -- "resolve-story-loop: non-numeric fix-verification length at round $round ($fix_verification): ${carried:-<empty>}"; exit 1 }
    fi
    if (( carried > 0 )); then
      is_empty_delta=1
      # A legitimate verification-only round: nothing changed, but the previous
      # round's blockers still need checking. WHERE the panel runs relative to
      # this invocation decides what the loop may do about it, and the two
      # wirings differ:
      #
      # HOOK MODE — `--review-cmd` runs BELOW, after the re-plan, so widening
      # the round to a full sweep here genuinely widens what the panel sees. The
      # round is then a real full sweep and may declare CONVERGED.
      #
      # STEP MODE — the panel already ran, BEFORE this invocation, against the
      # scope the session's own plan returned: the empty delta. Re-planning
      # would change only the descriptor, not what anybody reviewed, and
      # `scope_mode: "full"` with zero blockers is exactly the CONVERGED
      # condition — a false green that ships the previous round's unfixed
      # blockers AND skips the closing sweep, since CONVERGED ends the run. So
      # the round is left a DELTA round: it is consumed normally (its blockers,
      # if any, still count) but it CANNOT converge, and a zero-blocker result
      # promotes the next round to the closing full sweep, which the session
      # scopes with --final and really does review. The guarantee is structural
      # — a round whose panel saw an empty scope can never be a run's last word
      # — rather than a refusal that would pre-empt the more specific #974
      # findings guards below.
      #
      # progress.md, not stderr: a normal-path event on a healthy run, and the
      # loop keeps its two streams clean (stdout is the status JSON contract).
      # Same non-fatal brace-group idiom as the `**Gate (round N):**` line.
      if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        if (( step_mode )); then
          { print -r -- "**Scope (round ${round}):** empty delta with ${carried} carried blocker(s) to verify — this round cannot converge; a clean result promotes the closing full sweep (#1434)" \
            >> "$work_dir/progress.md" ; } 2>/dev/null || true
        else
          { print -r -- "**Scope (round ${round}):** empty delta with ${carried} carried blocker(s) to verify — running this round as a full sweep (#1434)" \
            >> "$work_dir/progress.md" ; } 2>/dev/null || true
        fi
      fi
      # BOTH wirings re-plan and re-derive the SCOPE, because in both the round
      # is reviewed against the whole story diff: hook mode's `--review-cmd`
      # runs below, after this, and step mode's session-side panel was told the
      # same by SKILL.md ("re-plan with --final and review the whole story
      # diff"). Recording the delta's empty scope here would contradict what was
      # actually reviewed: the loop's own record of the round would say the
      # panel saw nothing when it saw everything, and every downstream reader of
      # that record — the empty-findings marker, the progress tail, a
      # maintainer — would be reasoning about a round that did not happen.
      is_final=1
      plan_args+=( --final )
      rp=$("$DISPATCH" "${plan_args[@]}"); rc=$?
      if (( rc == 3 )); then
        emit_ambiguous "$rp" "$(( round - 1 ))" "$repo_type" "$review_skill"
      elif (( rc != 0 )); then
        print -u2 -- "resolve-story-loop: dispatch plan failed at round $round (rc=$rc)"; exit 1
      fi
      # the SAME status guard as the first read (#1434 review): an unchecked
      # jq here leaves scope_mode EMPTY, which fails the `== "full"` test
      # below, so a round that should be classified as full would be read as a
      # delta round — promoting yet another sweep, and at the ceiling burning
      # the one-round grant, instead of being able to converge
      replanned_scope_mode=$(print -r -- "$rp" | jq -r '.scope_mode // "full"') || {
        print -u2 -- "resolve-story-loop: could not read scope_mode after the re-plan at round $round"; exit 1 }
      write_round_scope "$rp" "$round" || exit 1
      # ...but only HOOK mode adopts the full mode for the CONVERGENCE decision.
      # In step mode the panel ran before this invocation, so however wide its
      # scope was, this round must not be able to end the run: it stays a delta
      # round, and a clean result promotes the closing full sweep.
      if (( ! step_mode )); then
        scope_mode="$replanned_scope_mode"
      fi
    else
      # "or stop" is deliberately NOT offered here. The previous round found
      # nothing, but a zero-blocker round is either a full sweep (which would
      # have ended the run as CONVERGED, so it cannot be the round before this
      # one) or a DELTA round — and no run may end on a delta round, which is
      # the whole point of the closing sweep. So reaching this branch means the
      # sweep the previous round earned is not queued: either the tree really
      # has not moved and the fix pass has not happened yet, or the run's
      # `.closing-sweep` marker was lost after that round was recorded.
      refuse_stale_findings "the round $round delta against the previous round is EMPTY and the previous round left no blockers to verify — nothing has changed since it, so no reviewer would see anything — and with an empty carry there is nothing to fix either. The previous round found nothing, so its closing full sweep should have been queued in $closing_sweep_file: restore that marker (its content is round $round), or re-invoke under the --max-rounds it was written under, rather than ending the run on a delta round. Do NOT invent a code change just to move the tree."
    fi
  fi
  # delta_files is read AFTER any re-plan, so the invalidation below always uses
  # the descriptor the round actually ran with. It is present on a full round too
  # whenever a prior tree was given — which is exactly the closing sweep.
  delta_json=$(print -r -- "$rp" | jq -c '.delta_files // []') || {
    print -u2 -- "resolve-story-loop: could not read delta_files at round $round"; exit 1 }

  # --- INVALIDATE the adjudications the last fix pass disturbed (#1434) -----
  # Every entry whose file appears in this round's delta_files goes, because a
  # suggestion re-raised in a file that was just edited is plausibly a NEW
  # observation about the new code, not a re-litigation of the old one.
  # Computed from this story's own attested-tree delta — deliberately not from a
  # fix-touched capture, which does not exist yet (#1435 lands after this).
  # File-granular on purpose: it errs toward keeping a suggestion visible, and
  # the cost of that is one logged Low where the cost of erring the other way is
  # a real finding silently deleted.
  #
  # It runs HERE — before the panel, not just before the consolidator — because
  # the panel is told "do not re-raise these" via REVIEW_ADJUDICATED. A
  # suggestion the panel withholds never reaches the consolidator at all, so an
  # invalidation that ran only downstream would protect nothing on the path that
  # actually suppresses. (In step mode the panel runs between invocations and
  # reads the file as the PREVIOUS round left it; making that exact too needs
  # the session to invalidate before it spawns its panel — a follow-up.)
  if [[ "$delta_json" != "[]" && "$delta_json" != "null" ]]; then
    adj_tmp="$work_dir/.adjudicated-invalidated.json"
    # bind the entry FIRST: inside `$d | index(...)` the input is $d, so a bare
    # `.file` would index the delta ARRAY with a string and abort the program
    jq -c --argjson d "$delta_json" \
      '[ .[] | . as $e | select(($d | index($e.file // "")) == null) ]' -- "$adjudicated_file" > "$adj_tmp" || {
      print -u2 -- "resolve-story-loop: could not invalidate adjudications at round $round"; exit 1 }
    mv -- "$adj_tmp" "$adjudicated_file" || {
      print -u2 -- "resolve-story-loop: could not write back $adjudicated_file at round $round"; exit 1 }
  fi
  findings_path=$(print -r -- "$rp" | jq -r '.findings_path')
  # (the scope was written by write_round_scope above, before the empty-delta
  # decision that has to read it)
  mkdir -p -- "${findings_path:h}" || {
    print -u2 -- "resolve-story-loop: could not create the findings sink directory ${findings_path:h} at round $round"; exit 1 }
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
  : > "$findings_path" || {
    print -u2 -- "resolve-story-loop: could not truncate the round $round findings sink $findings_path"; exit 1 }

  # 1. obtain this round's findings: step mode consumes --findings-file (the
  # session already ran the panel in-session, #971); hook mode runs the
  # injected panel command
  if (( step_mode )); then
    # (#974) silence is not evidence on a resumed round: the panel runs between
    # invocations, and one that found nothing still writes `[]`. Consuming a
    # missing/empty file as "no findings" here would converge the loop on a
    # round nobody reviewed — the false CONVERGED that per-round file names
    # make the LIKELIER shape of this mistake. A fresh run's round 1 is a FULL
    # round, so a missing/empty --findings-file is refused there too — by the
    # full-round guard further down, not by this --resume arm.
    if (( resume )) && [[ ! -s "$findings_file" ]]; then
      refuse_stale_findings "--findings-file is missing or empty on --resume ($findings_file) — did this round's review panel run? A panel that found nothing must still write []."
    fi
    if [[ -s "$findings_file" ]]; then
      # `--slurp`, never a bare `jq -e`: `jq -e`'s status reflects only the LAST
      # output value, so a file holding two concatenated arrays (a panel that
      # wrote with `>>` instead of `>` — the likeliest slip in a file a model
      # writes between invocations) emits true,true and PASSES. Every consumer
      # downstream then multiplies: two scoped arrays, two changelist objects,
      # a two-line `blocking` capture that aborts the arithmetic, and a BLANK
      # status JSON emitted beside an exit code that claims a verdict. Same
      # rule, same reason, as `_validate_promote`.
      jq -e -s 'length == 1 and (.[0] | type == "array")' -- "$findings_file" >/dev/null 2>&1 || {
        print -u2 -- "resolve-story-loop: --findings-file must hold exactly ONE JSON array: $findings_file"; exit 1 }
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
      #
      # ONE exception (#1434): a round that follows a round which itself found
      # NOTHING. That is the promoted closing full sweep — it exists precisely
      # because the delta round before it was clean, so the previous round's
      # findings were `[]`, and a full sweep that also finds nothing writes `[]`
      # again, byte for byte. The guard cannot tell that from a stale path, and
      # refusing it would make convergence unreachable on exactly the healthiest
      # runs.
      #
      # The waiver is keyed on ALL THREE facts — a recorded sweep, the previous
      # round's consumed findings being `[]`, and that round's scope having been
      # non-empty — never on `is_closing_sweep` alone: a sweep is also recorded
      # by the empty-delta promotion, which follows a round WITH blockers, where
      # a byte-identical repeat is still the real mistake the guard exists to
      # catch.
      #
      # And the second fact is read from the previous round's CONSUMED findings
      # (`.findings-empty-<N>`), not from its scoped ones. `scoped-<N>.json` is
      # what survives `scope-findings` and the work-dir filter, so it is empty
      # whenever a panel reported ONLY out-of-diff findings — a round whose raw
      # findings were substantial. Keying on that would waive the guard for a
      # round the justification does not cover, and a caller re-passing the
      # stale path would have it consumed by the sweep, filtered to nothing
      # again, and exit CONVERGED on a panel that never ran. The consumed file
      # is the fact the sentence above is actually about.
      # The missing/empty half of the guard always applies: a panel that found
      # nothing must still write `[]`.
      digest=$(findings_digest "$findings_file")
      prev_digest_file="$work_dir/.findings-digest-$(( round - 1 ))"
      prev_findings_empty=0
      # `-f && -s`, both conjuncts load-bearing, and the same parity the other
      # work-dir reads carry. `-s` because the marker's own write truncates
      # before it fills, so a zero-byte file is a FAILED write; `-f` because
      # `-s` alone is TRUE for a directory, so anything that left one at this
      # path — a failed write into it, a restored backup — would read as a
      # valid marker. Either misread waives the guard on the run's last word:
      # fail-OPEN, and the opposite of what the write's own diagnostic promises.
      (( is_closing_sweep )) && [[ -f "$work_dir/.findings-empty-$(( round - 1 ))" && -s "$work_dir/.findings-empty-$(( round - 1 ))" ]] && prev_findings_empty=1
      # ...and the DIGEST half takes the same `-f && -s` shape, as PARITY rather
      # than as a behaviour change — state it honestly, because the two halves
      # are not alike. On the marker read above `-f` is load-bearing: a
      # directory there passes `-s`, sets prev_findings_empty and WAIVES the
      # guard. Here the condition ends in a content comparison, so a directory
      # or a partial file makes it false either way (`$(<dir)` yields the empty
      # string, which never equals a real hex digest) — the guard does not
      # refuse with or without the conjuncts. They are kept so both halves read
      # the same way and neither invites the other's mistake; if a damaged
      # digest sidecar should ever REFUSE rather than silently not-refuse, that
      # needs its own diagnostic arm, not these conjuncts.
      if (( ! prev_findings_empty )) && [[ -n "$digest" && -f "$prev_digest_file" && -s "$prev_digest_file" && "$digest" == "$(<"$prev_digest_file")" ]]; then
        # The refusal is EXTENDED by the round's own scope, never waived by it.
        # The stale-path diagnosis stays first — it is the likelier cause and
        # the only one the caller can fix by re-invoking. But on an empty-delta
        # round the loop additionally KNOWS the tree did not move, so a panel
        # that really did run would legitimately re-find the same things; left
        # unsaid, the caller reads "run the panel again" as the whole remedy and
        # loops on it, since no per-round path can change the bytes.
        empty_delta_note=""
        (( is_empty_delta )) && empty_delta_note=" Round $round's delta was also EMPTY: if the panel DID run, nothing in the tree changed since round $(( round - 1 )), so the same blockers are simply still unfixed — apply the fixes, or stop and escalate."
        refuse_stale_findings "--findings-file is byte-identical to round $(( round - 1 ))'s consumed findings ($findings_file) — did this round's review panel run? Write each round's aggregate findings to its own path (findings-round-N.json) before --resume.${empty_delta_note}"
      fi
      cp -- "$findings_file" "$findings_path" || {
        print -u2 -- "resolve-story-loop: could not copy --findings-file"; exit 1 }
      # Classify the round once, for both records below.
      # `jq -e`'s status is read, never used as a verdict: it exits 1 for a
      # false result but 5 for a program error, and treating a dead jq as "the
      # findings are not empty" would flip BOTH records the wrong way at once —
      # a blind round would record a digest again, and the marker would be
      # cleared, leaving the sweep's waiver disarmed. Same rule the sibling
      # dispatch applies to its language probe (#1177).
      round_scope_empty=0; round_findings_empty=0
      [[ -s "$scope_file" ]] || round_scope_empty=1
      jq -e -s 'length == 1 and (.[0] | length == 0)' -- "$findings_path" >/dev/null 2>&1
      rc_empty=$?
      (( rc_empty <= 1 )) || {
        print -u2 -- "resolve-story-loop: could not classify the round $round findings as empty ($findings_path)"; exit 1 }
      (( rc_empty == 0 )) && round_findings_empty=1

      # record only AFTER a successful consume, so a failed round leaves no
      # digest to veto its retry
      #
      # ...and record NOTHING for a BLIND round that consumed `[]` (#1434): its
      # panel saw an empty scope, so `[]` is not a fingerprint of anything and a
      # byte comparison against it carries no information. Keeping one would
      # wedge the run: the closing sweep such a round promotes reviews the whole
      # diff, legitimately finds nothing, writes `[]` — and would be refused as
      # a stale re-pass, with no action able to change the bytes of an empty
      # array. The guard loses nothing, because an empty findings file asserts
      # nothing that a re-pass could falsify. The stale `rm -f` matters for a
      # retried round: a previous attempt's digest must not veto this one.
      if (( round_scope_empty && round_findings_empty )); then
        rm -f -- "$work_dir/.findings-digest-$round"
      elif [[ -n "$digest" ]]; then
        print -r -- "$digest" > "$work_dir/.findings-digest-$round" || \
          print -u2 -- "resolve-story-loop: could not record the round $round findings digest — the byte-identical stale-findings guard will be off for round $(( round + 1 ))"
      fi
      # ...and, beside it, whether this round's panel LOOKED AT SOMETHING AND
      # FOUND NOTHING (#1434). That is the fact the closing sweep's digest
      # waiver rests on, and both halves matter:
      #   * the consumed findings must be `[]` — knowable only here, because
      #     downstream they have been scope-filtered, which also empties a round
      #     whose panel reported plenty but all of it out of diff;
      #   * the round's SCOPE must have been non-empty — otherwise "found
      #     nothing" is really "saw nothing", and waiving after such a round
      #     would disarm the guard on the sweep that is the last chance to catch
      #     what it never saw. (A verification-only round is re-planned to the
      #     full diff above, so the remaining scope-empty case is a FULL round
      #     over a story diff that is itself empty.)
      # A marker file rather than a value, so its ABSENCE (an older work-dir, a
      # round that never got this far, a failed write) reads as "not empty" and
      # the guard stays armed — fail-closed, like every other arm; the reader
      # uses `-f && -s`, so a zero-byte partial write AND a directory left at
      # the path both read as absent too (the `-f` half is load-bearing on this
      # guard — see the read site's own note). The clear on
      # the else branch is diagnosed rather than silent: it is the one direction
      # that fails OPEN (a stale marker from a retried round would disarm the
      # waiver), and nothing else would notice.
      if (( ! round_scope_empty && round_findings_empty )); then
        print -r -- 1 > "$work_dir/.findings-empty-$round" || \
          print -u2 -- "resolve-story-loop: could not record the round $round empty-findings marker — the closing-sweep digest waiver will stay armed (fail-closed)"
      else
        rm -f -- "$work_dir/.findings-empty-$round" || \
          print -u2 -- "resolve-story-loop: could not clear the round $round empty-findings marker — the closing-sweep digest waiver may be wrongly disarmed"
      fi
    fi
  else
    # #1434 adds three: the round's scope mode, the previous round's blockers to
    # verify, and the already-waived suggestions the panel must not re-raise.
    # REVIEW_FIX_VERIFICATION is an empty string on round 1 (nothing to verify);
    # REVIEW_ADJUDICATED is always a path, holding `[]` until something is
    # waived — so a hook must read its CONTENTS, not test for emptiness.
    ( export REVIEW_ROUND="$round" REVIEW_FINDINGS="$findings_path" \
             REVIEW_SKILL="$review_skill" REVIEW_SCOPE_FILE="$scope_file" \
             REVIEW_REPO="$repo" REVIEW_SCOPE_MODE="$scope_mode" \
             REVIEW_FIX_VERIFICATION="$fix_verification" \
             REVIEW_ADJUDICATED="$adjudicated_file"; eval "$review_cmd" ) || {
      print -u2 -- "resolve-story-loop: --review-cmd failed at round $round"; exit 1 }
  fi
  # The `[]` default is a DELTA-round convenience, never a full-round one
  # (#1434). On a full round zero blockers IS the CONVERGED condition, so
  # synthesizing `[]` for a panel that produced no file would converge the run
  # on a review nobody performed — and it would silently overrule the terminal
  # every panel now carries, which says that on a full round with an empty
  # scope (or, for the render-first `kubernetes` panel, any not-applicable
  # shape) the panel reports to its caller and writes NO findings file
  # precisely so the loop refuses. Without this the promise is unenforced on
  # exactly the rounds that matter: a fresh run's round 1, which is always
  # full and never `--resume`, and every full round in hook mode, where the
  # `--findings-file` guards do not apply at all.
  if [[ ! -s "$findings_path" ]]; then
    if [[ "$scope_mode" == "full" ]]; then
      # Branched on the wiring, because the two name DIFFERENT files. In step
      # mode the caller's own --findings-file is what was empty, and pointing
      # them at $findings_path would send them to write into the internal sink
      # — which the alias guard above then refuses, so one mistake would cost
      # two contradictory refusals.
      if (( step_mode )); then
        refuse_stale_findings "round $round is a FULL round and --findings-file is missing or empty ($findings_file) — a full round with zero blockers is the CONVERGED condition, so an absent aggregate is refused rather than read as a clean review. If the panel reported the round failed or not applicable, act on that (see §3.5 step 2); otherwise run the panel and write its aggregate to its OWN path (findings-round-${round}.json), never the dispatch sink $findings_path."
      fi
      refuse_stale_findings "round $round is a FULL round and --review-cmd produced no findings at \$REVIEW_FINDINGS ($findings_path) — a full round with zero blockers is the CONVERGED condition, so an absent aggregate is refused rather than read as a clean review. A panel that found nothing must still write []."
    fi
    print -r -- '[]' > "$findings_path" || {
      print -u2 -- "resolve-story-loop: could not initialise the round $round findings sink $findings_path"; exit 1 }
  fi

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
    mv -- "$scoped_filtered" "$scoped" || {
    print -u2 -- "resolve-story-loop: could not write back the work-dir-filtered scope at round $round"; exit 1 }
  fi

  # 3. consolidate (#561), carrying the previous round for non-convergence
  # (the adjudicated list was already invalidated above, before the panel read
  # it — see the block next to `delta_json`)
  changelist="$work_dir/changelist-$round.json"
  # built as an array so --prev and --promote compose: the old if/else pair had
  # no room for a second optional flag without a four-way branch, and a promoted
  # set must reach the consolidator on the --prev rounds too (round 2+ is exactly
  # where an un-forwarded overlay would drop the item back to Low).
  consolidate_args=( --findings "$scoped" --round "$round" )
  [[ -n "$prev_changelist" ]] && consolidate_args+=( --prev "$prev_changelist" )
  [[ -n "$promote" ]] && consolidate_args+=( --promote "$promote" )
  consolidate_args+=( --adjudicated "$adjudicated_file" )
  "$CONSOLIDATE" "${consolidate_args[@]}" > "$changelist" || {
    print -u2 -- "resolve-story-loop: consolidate failed at round $round"; exit 1 }
  final_changelist="$changelist"
  # CHECKED, because the accumulators ARE the resume state. A failed or partial
  # write leaves changelists BEHIND history, and the --resume repair only knows
  # how to fix the other direction (exactly one line AHEAD, the kill-window
  # orphan) — this skew falls to "corrupt work-dir" with no recovery but
  # discarding every prior round. Aborting here instead leaves the two equal, so
  # the round simply re-runs.
  cat -- "$changelist" >> "$changelists_file" || {   # one compact line per round (for the dossier, #563)
    print -u2 -- "resolve-story-loop: could not append the round $round changelist to $changelists_file"; exit 1 }

  # Write the NEXT round's fix-verification carry HERE, not at that round's
  # start (#1434 review). In step mode the next round's panel runs between
  # invocations, so a file created at the start of the next invocation would be
  # written after the reviewers who are meant to read it have already finished —
  # the carry would be contracted, passed to `plan`, and inert. Writing it now
  # means it is on disk before the session spawns that panel.
  jq -c '.blocking // []' -- "$changelist" > "$work_dir/verify-$(( round + 1 )).json" || {
    print -u2 -- "resolve-story-loop: could not write the round $(( round + 1 )) fix-verification carry"; exit 1 }

  # Only NOW record this round's own suggestions as adjudicated (#1434) — doing
  # it before consolidation would let a round drop its own findings, which is
  # both wrong and impossible to notice from the outside.
  #
  # NORMALISE and FILTER on the way in, to the consolidator's own --adjudicated
  # predicate. The consolidator deliberately TOLERATES malformed reviewer input
  # in these fields — a missing `dimension` becomes "", and `// ` leaves a
  # non-string `title` (a reviewer emitting `"title": 42`) untouched — so copying
  # `suggestions[]` verbatim can persist an entry its own validator will reject.
  # The next round then fails validation, the loop aborts as a BARE exit 1 that
  # writes no status JSON (the #912 hazard), and because the bad entry is
  # PERSISTENT state every later --resume dies at the same point: one reviewer
  # forgetting `dimension` on one finding bricks the work-dir. An entry that
  # cannot carry a non-empty file+dimension matches nothing anyway, so dropping
  # it costs no suppression.
  blocking=$(jq '.summary.blocking' "$changelist")
  conflict=$(jq 'if ((.escalation_reasons // []) | index("unresolved_conflict")) then 1 else 0 end' "$changelist")
  nonconv=$(jq 'if .non_converging then 1 else 0 end' "$changelist")
  nconf=$(jq '.summary.conflicts' "$changelist")
  # false_trips (#983): proximity matches identity cleared as genuinely different —
  # recorded per round so telemetry/history show the auto-continue, but they NEVER
  # drive an escalation (that is $nonconv, which the consolidator already excludes
  # them from).
  ftrips=$(jq '.summary.false_trips // 0' "$changelist")
  # adjudicated_dropped (#1434) rides the per-round line so history.jsonl stays a
  # single-file run summary: "why did round 4 log fewer suggestions than round 3"
  # is answerable without opening four changelists.
  # status-checked, unlike its pre-existing siblings above: an empty capture
  # would reach `--argjson ad` below, jq would refuse it, and the whole history
  # append would write nothing — leaving history one line short of changelists,
  # which the next --resume reads as the kill-window orphan and repairs by
  # TRUNCATING a completed round's changelist. (The siblings want the same
  # treatment; that is a follow-up, not this story's scope.)
  adj_dropped=$(jq '.summary.adjudicated_dropped // 0' -- "$changelist") || {
    print -u2 -- "resolve-story-loop: could not read summary.adjudicated_dropped at round $round"; exit 1 }
  jq -c --argjson r "$round" --argjson b "$blocking" --argjson c "$nconf" --argjson nc "$nonconv" \
     --argjson ft "$ftrips" --argjson ad "$adj_dropped" \
     '{round:$r, blocking:$b, conflicts:$c, non_converging:($nc==1), false_trips:$ft,
       adjudicated_dropped:$ad}' <<< '{}' >> "$history_file" || {
    print -u2 -- "resolve-story-loop: could not append the round $round history line to $history_file"; exit 1 }

  # ...and ONLY NOW record this round's suggestions as adjudicated. The append
  # is deliberately the LAST write of the round, after the history line.
  #
  # The --resume kill-window repair reads "changelists exactly one line ahead of
  # history" as "the orphaned round re-runs", so anything committed between the
  # changelist append and the history line is state a re-run inherits as if the
  # round had completed. With the append ordered before it, a round that re-runs
  # would find its OWN suggestions already adjudicated and drop them — and the
  # invalidation above cannot save the case that matters, because the closing
  # sweep applies no fix pass, so its `delta_files` is `[]` and nothing is
  # invalidated. A suggestion only the sweep found would then be deleted from
  # the changelist that the promotion phase and the telemetry `waived` count
  # both read, with no surface left to restore it from.
  #
  # Ordered last, a kill in the window instead loses one round's adjudications,
  # so a waived suggestion is logged once more. That is the direction the drop
  # rule is built on: over-dropping deletes a real defect, under-dropping costs
  # one line. Nothing between the two reads $adjudicated_file, and its next
  # consumer is the NEXT invocation's consolidate, so the happy path is
  # unchanged.
  #
  # ...and for the SAME reason this pair WARNS instead of exiting. An `exit 1`
  # here would sit between the round's history line and the promotion record
  # below, on an ordinary I/O failure rather than a kill: the round would be
  # complete and consistent on disk (history and changelists equal, so the
  # --resume repair correctly does nothing) with the closing sweep it just
  # earned never written. The next --resume would then plan an ordinary delta
  # round against an unmoved tree and refuse it, every time, until someone
  # hand-wrote the marker. Warning costs one re-logged suggestion; exiting
  # costs the run.
  adj_tmp="$work_dir/.adjudicated-appended.json"
  jq -sc '(.[0] + [ .[1].suggestions[]?
                    | { file: ((.file // "") | tostring),
                        line,
                        dimension: ((.dimension // "") | tostring),
                        title: ((.title // "") | tostring) }
                    | select(((.file | length) > 0) and ((.dimension | length) > 0)) ])
          | unique_by([.file, (.line|tostring), .dimension, .title])' \
    -- "$adjudicated_file" "$changelist" > "$adj_tmp" && \
  mv -- "$adj_tmp" "$adjudicated_file" || \
    print -u2 -- "resolve-story-loop: could not record round $round's suggestions as adjudicated ($adjudicated_file) — the round STANDS; at most one already-waived suggestion is logged again next round"
  rm -f -- "$adj_tmp"


  # 4. decide the round's fate. In step mode a survivable round (blockers,
  # budget left) exits AWAITING_FIX (20): the fix pass is the driving session's
  # job, in-session, before it re-invokes with --resume (#971).
  # #1434: CONVERGED is declarable only on a FULL round. A delta round that
  # reaches zero blockers has proved nothing about the story as a whole — only
  # about the slice it looked at — so it promotes the NEXT round to a closing
  # full sweep instead of ending the run. That sweep is the safety net against
  # the one thing delta scoping could hide: a defect that exists only in the
  # interaction between rounds.
  skip_fix=0
  if (( blocking == 0 )); then
    if [[ "$scope_mode" == "full" ]]; then
      loop_status="CONVERGED"
    else
      closing_sweep_round=$(( round + 1 ))
      print -r -- "$closing_sweep_round" > "$closing_sweep_file" || {
        print -u2 -- "resolve-story-loop: could not record the closing sweep at $closing_sweep_file"; exit 1 }
      # The grant, once and by exactly one round: a run that spent its whole
      # budget is precisely the run whose safety net matters most, so skipping
      # the sweep there would remove it exactly when it is least affordable to.
      # --max-rounds itself is untouched (see emit_and_exit).
      if (( closing_sweep_round > max_rounds )); then
        effective_max=$closing_sweep_round
        closing_sweep_granted=1
      fi
      # nothing to fix — the round found no blockers; the next round only
      # re-reviews, at full scope
      skip_fix=1
      (( step_mode )) && loop_status="AWAITING_FIX"
    fi
  elif (( conflict == 1 )); then loop_status="ESCALATE_CONFLICT"
  elif (( nonconv == 1 )); then loop_status="ESCALATE_NO_CONVERGENCE"
  elif (( round == effective_max )); then loop_status="BUDGET_EXHAUSTED"
  elif (( step_mode )); then loop_status="AWAITING_FIX"
  fi
  case "$loop_status" in
    CONVERGED) verdict="converged" ;;
    ESCALATE_CONFLICT) verdict="escalating (unresolved conflict)" ;;
    ESCALATE_NO_CONVERGENCE) verdict="escalating (non-converging blocker)" ;;
    BUDGET_EXHAUSTED) verdict="budget exhausted" ;;
    AWAITING_FIX)
      if (( skip_fix )); then
        verdict="no blockers in the delta — round $closing_sweep_round is the closing full sweep; apply no fix, just --resume"
      else
        verdict="awaiting fix — apply blockers in-session, then --resume"
      fi ;;
    *) if (( skip_fix )); then
         verdict="no blockers in the delta — promoting round $closing_sweep_round to the closing full sweep"
       else
         verdict="fix pass (in-loop), continuing"
       fi ;;
  esac
  append_progress_round "$changelist" "$round" "$verdict" "$prev_changelist"
  if [[ -n "$loop_status" ]]; then break; fi
  # a zero-blocker delta round has nothing for the fix hook; advancing straight
  # to the closing sweep is the whole point (hook mode)
  if (( skip_fix )); then
    prev_changelist="$changelist"
    (( round++ ))
    continue
  fi

  # 5. fix pass — blockers only (Low suggestions never loop)
  blockers="$work_dir/blockers-$round.json"
  jq -c '{round, blocking, conflicts}' -- "$changelist" > "$blockers" || {
    print -u2 -- "resolve-story-loop: could not build the round $round blockers slice at $blockers"; exit 1 }
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

local code=1
case "$loop_status" in
  CONVERGED) code=0 ;;
  AWAITING_FIX) code=20 ;;
  ESCALATE_CONFLICT) code=11 ;;
  ESCALATE_NO_CONVERGENCE) code=12 ;;
  BUDGET_EXHAUSTED) code=13 ;;
  *) code=1 ;;
esac
emit_and_exit "$loop_status" "$round" "$code" "$repo_type" "$review_skill" "$final_changelist" "$history_file" "$changelists_file"
