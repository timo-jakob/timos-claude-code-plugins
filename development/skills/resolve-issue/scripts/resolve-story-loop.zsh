#!/usr/bin/env zsh
# resolve-story-loop.zsh — the local, pre-push review loop's state machine
# (epic #557, issue #562). Ties the review panel (#560 dispatch) and the
# consolidator (#561) into an autonomous implement→review→fix loop with a hard
# round budget. Runs entirely in the worktree: nothing is pushed and no PR is
# opened until this exits CONVERGED (0) or CONVERGED_WITH_RESIDUE (14, #1435) —
# no ESCALATE_* / BUDGET_EXHAUSTED exit ever opens one.
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
# "no prior tree" the normal case off plugin repos. Four carries ride along:
#   * `<work-dir>/verify-<N>.json` — the previous round's `.blocking` array,
#     i.e. exactly what the fix pass was told to fix, passed as
#     `--fix-verification` and exported as REVIEW_FIX_VERIFICATION;
#   * `<work-dir>/adjudicated.json` — the Low findings prior rounds surfaced and
#     the human let go, passed as `--adjudicated` and exported as
#     REVIEW_ADJUDICATED ("do not re-raise these"). Every entry whose file the
#     last fix pass touched is REMOVED before the round consolidates, so a
#     suggestion legitimately re-raised because the fix was incomplete is never
#     suppressed;
#   * `<work-dir>/.closing-sweep` — the round number of the CLOSING FULL SWEEP;
#   * `<work-dir>/.max-rounds` (plus, transiently, `.max-rounds.tmp.*` — the
#     writer's atomic-rename staging, swept by the same fresh-run clear)
#     — the ceiling a human GRANT bought (#1576),
#     written by `record-grant.zsh` at the interactive extension's step 5 and
#     adopted by `--resume` below, so a grant reaches the loop mechanically
#     instead of living in the conductor's memory across a context that
#     compacts. Like its siblings it is per-RUN and cleared on a fresh start.
# A fifth per-run work-dir file, `<work-dir>/.possible-false-trip-continued`
# (#1498), records the identities this run has already spent its one automatic
# all-ambiguous continuation on. One line per identity, tab-separated:
#   <round><TAB><file><TAB><dimension><TAB><normtitle>
# The IDENTITY is everything after the first tab; the leading round is what makes
# the number of CONTINUATIONS (distinct rounds) derivable from the same file that
# holds the identities, so a counter can never desynchronise from its records.
# `normtitle` collapses all whitespace, so no reviewer-authored title can forge
# the separator.
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
#          ...and an AMBIGUOUS survivor (#1498) buys ONE automatic continuation
#          per identity: when EVERY carried match of the round is
#          `possible_false_trip`, none is Critical, the round is below the
#          ceiling and no identity has continued before, the loop records the
#          identities in `<work-dir>/.possible-false-trip-continued` and takes
#          the round it already had. A second ambiguous match on a recorded
#          identity escalates as before — that is evidence of a stuck blocker,
#          not of a proximity artifact. It is a CONTINUE, not a grant: nothing
#          about the budget moves.
#     -> last round + blockers  => BUDGET_EXHAUSTED
#     -> ...but EITHER of those two endings becomes CONVERGED_WITH_RESIDUE (14,
#          #1435) when ALL THREE residue conditions hold: the last TWO rounds
#          are both zero-CRITICAL, every remaining blocker's file is in the
#          PREVIOUS round's fix-touched set, AND this round ran as a FULL SWEEP
#          (§9 — a delta round meeting the first two promotes the closing sweep
#          instead of ending here, so exit 14 always speaks for the whole diff). The run then opens the PR and files the
#          remainder as follow-up issues instead of spending a human grant on
#          material the reviewers themselves called non-critical and that lives
#          only in the implementer's own last edits. Evaluated at those two rungs
#          and NOWHERE else — never pre-empting CONVERGED, ESCALATE_CONFLICT,
#          ESCALATE_AMBIGUOUS, or an AWAITING_FIX round that still has budget.
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
#   GIT_TREE_ID_BIN           the git binary, read by the ONE git call this
#                             script makes directly (the #1435 fix-touched
#                             diff-tree). Deliberately the SAME name
#                             git-tree-id.zsh reads rather than a second seam:
#                             that script mints the two identities this diffs, so
#                             two names would let stub-minted ids be compared by
#                             real git, which compares nothing.
#   All three are unset in production.
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
#                    Several shapes are refused as STALE_FINDINGS (exit 2, #974,
#                    #1434, #1435), most of them on one of these NAMED grounds —
#                    named rather than numbered, because a count here has already
#                    gone stale more than once. (The ALIAS arm is on none of them:
#                    it is preventive, refusing BECAUSE real panel output exists,
#                    before the sink is truncated.)
#                      NEVER PRODUCED  the round's findings were never made (the
#                                      panel is the driving session's job BETWEEN
#                                      invocations, so these are caller mistakes)
#                      NOTHING TO SEE  no reviewer could have seen anything this
#                                      round
#                      WRONG TREE      the findings describe a tree the loop is
#                                      not looking at (#1435)
#                    The EMPTY-DELTA, FULL-ROUND and CADENCE arms are
#                    WIRING-INDEPENDENT — they fire in hook mode too, where the
#                    panel is --review-cmd's job, because they key on the round's
#                    own state rather than on --findings-file. The rest are
#                    step-mode-only by construction, since hook mode has no
#                    --findings-file at all.
#
#                    (NAMED, NOT NUMBERED, and the rule applies to this block
#                    itself: an ordinal goes stale the next time a shape is
#                    added, and this paragraph's own counts went stale twice
#                    before the numerals were removed. Add a shape by adding a
#                    bullet and a remedy — there is no tally to keep in step.)
#
#                    Every shape, with the wiring-independent arms marked:
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
#                        panel output is never destroyed;
#                      * (WIRING-INDEPENDENT) the CADENCE arm (#1435) — the
#                        findings were produced against a different tree than the
#                        one being consolidated, so they describe a repo state
#                        that no longer exists. Step mode compares the session's
#                        --findings-tree attestation; hook mode compares this
#                        round's own dispatch stamp, catching a --review-cmd
#                        that rewrites the tree mid-round.
#                    Left unguarded, the MISSING/EMPTY and FULL-ROUND arms let
#                    a round nobody reviewed be consumed — on a full round that
#                    is the false CONVERGED that green-lights the PR — and the
#                    BYTE-IDENTICAL arm reads as a blocker surviving two rounds,
#                    the non-convergence fingerprint (#606), tripping a phantom
#                    ESCALATE_NO_CONVERGENCE that blames the fix pass for a
#                    mistake made by the caller.
#
#                    The CADENCE arm is the one that fails in the other
#                    direction: its inputs are perfectly well-formed, and it is
#                    the ORDERING that was wrong — the fix pass ran before the
#                    round it belongs to was consolidated, so the fix-touched
#                    set, every `class` derived from it and the residue decision
#                    would all be computed from a tree the reviewers never read.
#
#                    The remedy is per arm, not one rule: MISSING/EMPTY,
#                    BYTE-IDENTICAL and FULL-ROUND are cleared by producing this
#                    round's real aggregate and re-invoking; the CADENCE arm by
#                    re-running this round's panel against the CURRENT tree and
#                    passing a freshly minted --findings-tree (or by discarding
#                    the fix that moved the tree), never by re-passing the same
#                    attestation and never by dropping the flag — it is
#                    fail-quiet, so dropping it consolidates the very round just
#                    refused; the ALIAS arm by
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
#       [--findings-tree TREE_ID] [--promote FILE]                # step mode
#   resolve-story-loop.zsh --repo PATH [--base REF] \
#       --review-cmd CMD --fix-cmd CMD [--test-cmd CMD] \
#       [--promote FILE] ...                                      # hook mode
#   resolve-story-loop.zsh --no-review   # skip the loop entirely (fast path;
#                                        # refused together with --promote)
#
# Exit codes (also carried as `status` in the JSON on stdout / --status-file):
#   0   CONVERGED (or SKIPPED with --no-review)
#   14  CONVERGED_WITH_RESIDUE    (#1435: the run OPENS ITS PR, and the caller
#                                  files one follow-up issue per remaining
#                                  blocking finding. A distinct code rather than
#                                  a second 0, because the follow-up work
#                                  differs; `outcome: "success"` in telemetry.)
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
#       further causes, and the EMPTY-DELTA, FULL-ROUND and CADENCE arms also
#       fire in hook mode, so exit 2 mid-run is no longer step-mode-only.
#       EMPTY-DELTA (a delta round with an empty scope and nothing carried to
#       verify) and FULL-ROUND (a full round whose panel produced no findings
#       file) have no reviewed round at all, and reading either as CONVERGED is
#       the same false green. CADENCE (#1435) HAS one — but of a repo state that
#       no longer exists.
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
# How far above the PASSED --max-rounds a `.max-rounds` grant sidecar (#1576)
# may raise the ceiling before it is refused as stale/foreign. Derived from the
# interactive extension's own budget: a soft cap of 5 grants x the +3 increment,
# PLUS the one #1434 closing-sweep round record-grant.zsh folds into its base
# (5 * 3 + 1 = 16). The +1 is not slop: a run that was granted its closing sweep
# before its first grant reaches exactly max_rounds + 16 after the fifth, and
# the interactive extension still sanctions that fifth grant ("the cap is a
# nudge by design, not a hard stop"), so a 15 would clamp away exactly the round
# that fifth grant bought, precisely at the sanctioned limit. It is a named
# constant
# because the bare number reads as arbitrary and would drift the moment any of
# those three figures is retuned.
typeset -gr MAX_ROUNDS_SIDECAR_SLACK=16

local self_dir="${0:A:h}"
local DISPATCH="${self_dir}/review-dispatch.zsh"
local CONSOLIDATE="${self_dir}/consolidate-findings.zsh"
local RENDER_PROGRESS="${self_dir}/render-progress-block.zsh"
local TREE_ID="${self_dir}/git-tree-id.zsh"

local repo="" base="origin/main" review_cmd="" fix_cmd="" test_cmd="" findings_file=""
local max_rounds=$MAX_REVIEW_ROUNDS status_file="" work_dir="" no_review=0
local issue="" telemetry_file="" resume=0 gate_attest="" findings_tree="" promote=""

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
  --findings-tree) _need_val "$1" $# "${2:-}"; findings_tree="$2"; shift 2 ;;
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
    print -r -- "  [--findings-tree TREE_ID]  # step mode: the tree the round's panel READ (git-tree-id.zsh),"
    print -r -- "                             # minted BEFORE the panel ran. Omitting it disables the #1435"
    print -r -- "                             # cadence check; it is not --gate-attest and neither implies the other."
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
# How many automatic all-ambiguous continuations this RUN has spent (#1498),
# read by emit_and_exit on EVERY exit for the same reason closing_sweep_granted
# is — so it must exist before the first one (the --no-review fast path). Seeded
# from the marker on --resume, since step mode runs each round as its own
# invocation. A plain assignment, not `local`: see the note above.
pft_continues=0

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
  # RESIDUE (#1435): the reasons are the changelist's, and on the non-convergence
  # rung that changelist necessarily carries `non_converging_blocker` — that is
  # WHY the rung was reached. Copied through unchanged, a run this state exists
  # to call a SUCCESS would report `escalation_reasons: ["non_converging_blocker"]`
  # and render `**Final:** CONVERGED_WITH_RESIDUE — non_converging_blocker` into
  # progress.md: the ending that says "this did not escalate", saying it did. It
  # would also make the two residue rungs report different shapes, since the
  # budget rung usually has none.
  #
  # So `escalation_reasons` keeps its one meaning — THIS RUN ESCALATED — and the
  # reasons move to `residue_replaced_reasons`, which records what residue took
  # the place of. Always present (`[]` everywhere else), for the same reason
  # `promotion_phase` and `closing_sweep_granted` are: a consumer must never have
  # to tell "no reasons" from "a status file predating the key".
  local residue_replaced='[]'
  if [[ "$st" == "CONVERGED_WITH_RESIDUE" ]]; then
    residue_replaced="$esc"
    esc='[]'
  fi
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
  # possible_false_trip_auto_continues (#1498) is ALWAYS present — an integer,
  # 0 on every run that never auto-continued — for the same reason
  # promotion_phase and closing_sweep_granted are: a consumer must never have to
  # tell 0 from "a status file that predates the key". It counts CONTINUATIONS,
  # not identities, so a round that continues on three ambiguous matches adds 1.
  # It is deliberately NOT a budget field: `max_rounds` still reports the
  # caller's value and `closing_sweep_granted` keeps its meaning, because an
  # auto-continue takes the round the run already had rather than granting one.
  # effective_max_rounds / max_rounds_source (#1576) are ALWAYS present, for the
  # same reason promotion_phase and closing_sweep_granted are. They report the
  # ceiling actually in force and where it came from — `flag` or `work-dir` —
  # WITHOUT touching `max_rounds`, which keeps reporting the caller's value.
  # That split is deliberate and mirrors #1434: a mutated `max_rounds` would put
  # the status JSON at odds with the command line that produced it, and every
  # downstream budget reader (build-escalation.zsh's header and its
  # BUDGET_EXHAUSTED line, build-telemetry-record.zsh's payload) would silently
  # change meaning. On a run with no grant the two agree, which is why a
  # consumer can read `max_rounds` exactly as before.
  out=$(jq -nc \
    --arg status "$st" --argjson rounds "$rounds" --argjson max "$max_rounds" \
    --argjson effmax "$effective_max" --arg maxsrc "$max_rounds_source" \
    --arg repo_type "$repo_type" --arg review_skill "$review_skill" \
    --argjson final "$final" --argjson history "$history" --argjson esc "$esc" \
    --argjson clists "$clists" --argjson promotion_phase "$promotion_phase" \
    --argjson granted "$granted_json" --argjson residue_replaced "$residue_replaced" \
    --argjson pftc "$pft_continues" \
    '{status:$status, rounds:$rounds, max_rounds:$max,
      effective_max_rounds:$effmax, max_rounds_source:$maxsrc,
      promotion_phase:$promotion_phase, closing_sweep_granted:$granted,
      possible_false_trip_auto_continues:$pftc,
      repo_type:(if $repo_type=="" then null else $repo_type end),
      review_skill:(if $review_skill=="" then null else $review_skill end),
      escalation_reasons:$esc, residue_replaced_reasons:$residue_replaced,
      history:$history, round_changelists:$clists,
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
    # ...and on a residue exit, say what residue REPLACED rather than leaving the
    # line bare: the human tailing progress.md wants to know the run would
    # otherwise have escalated, without being told that it did (#1435).
    [[ -n "$residue_replaced" && "$residue_replaced" != "[]" ]] && \
      reasons=" — residue replaced: $(print -r -- "$residue_replaced" | jq -r 'join(", ")' 2>/dev/null)"
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
    # CONVERGED_WITH_RESIDUE (#1435) is a SUCCESS, named explicitly rather than
    # left to the catch-all: the run opened its PR. The catch-all is `failed` on
    # purpose, so a status added later is never silently counted as a success —
    # which is exactly why this one has to be added here and in ARCHITECTURE.md's
    # two copies of the mapping, not merely assumed to land right.
    case "$st" in
      CONVERGED|CONVERGED_WITH_RESIDUE|SKIPPED) outcome="success" ;;
      ESCALATE_*|BUDGET_EXHAUSTED)              outcome="escalated" ;;
      *)                                        outcome="failed" ;;
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
            # as "there is an id" to a naive consumer, and the
            # `reference/promotion.md` step 3 guard treats absent and empty
            # identically for exactly that reason.
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
  local cl="$1" r="$2" v="$3" prev_cl="${4:-}" pftc="${5:-0}"
  [[ -n "$work_dir" ]] || return 0
  # judgment-grade per-round counts (#969): the previous round changelist
  # enables fixed-since, the history (which already holds this round — it is
  # appended before this call) enables the cumulative trend line
  local -a extra
  [[ -n "$prev_cl" && -s "$prev_cl" ]] && extra+=(--prev "$prev_cl")
  [[ -s "$history_file" ]] && extra+=(--history "$history_file")
  # #1498: the renderer is a pure function of the changelist, which carries no
  # record of which way the ladder went — so the loop has to tell it that THIS
  # round's ambiguous carried set was auto-continued rather than escalated.
  (( pftc )) && extra+=(--possible-false-trip-continued)
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
  # ONE definition of "a path the loop wrote, not the story" — the same helper
  # `_capture_fix_touched` uses. This function used to inline a work-dir-only
  # copy of it, which was strictly weaker: an in-repo `--status-file` (written by
  # `emit_and_exit` at every AWAITING_FIX, so an untracked changed file from
  # round 2 on) stayed in the scope and was handed to the panel as story code to
  # review, while the fix-touched set correctly dropped it. Two consumers of one
  # fact, disagreeing about the same path, is exactly what this function's own
  # header warns against.
  _drop_loop_internal_paths "$scope_file"
}

# Mint a working-tree identity, with the git seam BRIDGED explicitly (#1435).
#
# `GIT_TREE_ID_BIN` is one name in two scopes, and that is the whole reason this
# helper exists. `_capture_fix_touched` reads it as a parameter of THIS shell,
# while `$TREE_ID` is a child process that sees it only if it was EXPORTED — so a
# caller or test that sets it without exporting would get one binary minting the
# identities and another diffing them, which compares nothing and degrades
# SILENTLY (an unrelated tree pair diffs to some arbitrary set, so residue is
# mis-decided rather than refused). Setting it on the invocation closes that,
# exactly as review-dispatch.zsh's `_delta_files` does. EVERY identity in this
# file goes through here, not just the #1435 ones: the #981 gate attestation and
# the #1434 round identity are comparisons of the same kind.
_tree_id() {  # $1 = repo
  GIT_TREE_ID_BIN="${GIT_TREE_ID_BIN:-git}" "$TREE_ID" "$1"
}

# --- fix-touched capture (#1435) -------------------------------------------
# The set of repo artifacts a round's FIX PASS created or modified, persisted as
# `<work-dir>/fix-touched-<round>.txt` — repo-relative, one path per line. It is
# what the residue decision below tests each remaining blocker's `.file` against,
# and what `consolidate-findings.zsh --fix-touched` derives its `class` from.
#
# FILE-SET membership, not hunk-level: it matches the finding's own `.file`
# granularity and stays robust to the line drift that the #983 proximity matcher
# had to be rebuilt around.
#
# Normalisation and exclusions are review-dispatch.zsh's `_normalise_paths`,
# deliberately identical: the loop's own artifacts under `.review/` and the
# telemetry JSONL are never story code, so a fix pass that only wrote there
# touched NOTHING reviewable — and an empty set means every blocker is a
# `new_defect`, i.e. no residue. One rule for what counts as a repo path, or the
# residue test and the review scope would disagree about the same file.
#
# Both ends are `git write-tree` identities (git-tree-id.zsh), so tracked edits,
# deletions and untracked additions are compared by one uniform rule — the same
# reason `_delta_files` uses `diff-tree` rather than `git diff <tree>`.
_capture_fix_touched() {   # $1 = base tree id, $2 = round
  local base_tree="$1" r="$2" cur="" out=""
  out="$work_dir/fix-touched-$r.txt"
  # Every failure below leaves NO file, which is deliberate: the residue
  # decision requires membership in this set, so an absent set can only make
  # residue unreachable — the fail-closed direction. Announce it, because the
  # visible consequence (an escalation instead of a residue exit) is otherwise
  # indistinguishable from a genuine non-residue run.
  rm -f -- "$out"
  [[ -n "$base_tree" ]] || {
    print -u2 -- "resolve-story-loop: no pre-fix tree identity for round $r — the fix-touched set cannot be computed (#1435); residue is unreachable this round"
    return 1 }
  cur=$(_tree_id "$repo" 2>/dev/null) || cur=""
  [[ -n "$cur" ]] || {
    print -u2 -- "resolve-story-loop: could not compute the post-fix tree identity for round $r — the fix-touched set cannot be computed (#1435); residue is unreachable this round"
    return 1 }
  # `pipefail` is set, so a failing diff-tree fails the pipeline rather than
  # yielding an empty set that would read as "the fix pass touched nothing" —
  # which classifies every blocker `new_defect` and is a claim, not a gap.
  # ONE seam for BOTH halves of the comparison. The two tree ids are minted by
  # git-tree-id.zsh, which honours GIT_TREE_ID_BIN — so pinning a different
  # variable here would let stub-minted ids be diffed by real git (or the
  # reverse), which is not a comparison of anything. review-dispatch.zsh bridges
  # the two the same way in `_delta_files`.
  #
  # `-c core.quotePath=false`: the default TRUE makes diff-tree emit a non-ASCII
  # path as `"src/caf\303\251.zsh"` — quotes and octal escapes included — a
  # spelling that can never equal the plain UTF-8 `.file` a reviewer reports. The
  # blocker would then be stamped `new_defect` and counted outside the set: fail-
  # closed for the VERDICT, but a confidently wrong number in the class histogram
  # the grant decision reads. review-dispatch.zsh's own path listings carry the
  # same flag for the same reason, so the two sets keep one spelling.
  #
  "${GIT_TREE_ID_BIN:-git}" -C "$repo" -c core.quotePath=false \
    diff-tree -r --name-only "$base_tree" "$cur" \
    | sed -E 's#^\./##' | sort -u \
    | sed -e '/^$/d' -e '\#^\.review/#d' -e '\#^\.claude/telemetry/#d' > "$out" || {
    print -u2 -- "resolve-story-loop: could not diff $base_tree..$cur for the round $r fix-touched set (#1435); residue is unreachable this round"
    rm -f -- "$out"
    return 1 }
  # ...then drop the loop's OWN caller-chosen in-repo artifacts (#1435). Done
  # here rather than as another `sed` address: these paths come from the command
  # line, and splicing one into a regex makes the caller's directory name a
  # PATTERN. `.loop-wd` would delete a genuine `xloop-wd/foo.py` (`.` is a
  # wildcard), a `#` in the name would close sed's address early — and with
  # `pipefail` set that kills the whole capture, so a supported work-dir silently
  # makes residue unreachable. `${(b)…}` glob-quotes the prefix, so the match is
  # literal, and it is the same idiom `write_round_scope` uses on the same fact.
  _drop_loop_internal_paths "$out"
  return 0
}

# Filter $1 IN PLACE, removing every line under the repo-internal work-dir and
# every line naming a repo-internal --status-file / --findings-file. Both lists
# are resolved once near the top of the run; when they are empty this is a no-op.
_drop_loop_internal_paths() {  # $1 = file of repo-relative paths
  local f="$1"
  [[ -s "$f" ]] || return 0
  (( ${#loop_internal_files} > 0 )) || [[ -n "$wd_rel" ]] || return 0
  local -a lines
  lines=("${(@f)$(<"$f")}")
  # `${(b)…}` alone is NOT enough: it produces the escaped text, but a parameter
  # expansion result is not re-read as a pattern, so the backslashes match
  # literally and nothing is removed. The pattern has to go through `${~…}` to be
  # interpreted. Invisible for a metachar-free name like `.loop-wd` — which is
  # why it survived unnoticed — and wrong for any work-dir carrying `[`, `?`,
  # `(`, `|` or `^`, where the loop's own state files then leak straight back
  # into the set that decides residue.
  local pat=""
  if [[ -n "$wd_rel" ]]; then
    pat="${(b)wd_rel}*"
    lines=(${lines:#${~pat}})
  fi
  local _f=""
  for _f in "${loop_internal_files[@]}"; do
    pat="${(b)_f}"
    lines=(${lines:#${~pat}})
  done
  if (( ${#lines} )); then
    print -rl -- "${lines[@]}" > "$f"
  else
    : > "$f"
  fi
}

# Promote the NEXT round to the closing full sweep (#1434), granting the one
# round beyond --max-rounds when the budget is already spent. ONE definition,
# because #1435 §9 gave it a SECOND trigger: a delta round whose residue
# conditions hold promotes the sweep exactly as a zero-blocker delta round does.
# Two copies would let the two triggers drift on the grant arithmetic, which is
# the part that decides whether the sweep runs at all.
_promote_closing_sweep() {  # $1 = the round doing the promoting
  # The parameter is named `round` — shadowing the caller's loop variable, which
  # is harmless here (this function reads nothing else from it) and deliberate:
  # the increment is pinned across code and prose by a tripwire that greps for
  # the literal `closing_sweep_round=$(( round + N ))`, so spelling it any other
  # way silently removes the guard that keeps every restatement of the one-round
  # grant in lockstep (#993/#1434).
  local round="$1"
  closing_sweep_round=$(( round + 1 ))
  print -r -- "$closing_sweep_round" > "$closing_sweep_file" || {
    print -u2 -- "resolve-story-loop: could not record the closing sweep at $closing_sweep_file"; return 1 }
  # The grant, once and by exactly one round: a run that spent its whole budget
  # is precisely the run whose safety net matters most, so skipping the sweep
  # there would remove it exactly when it is least affordable to. --max-rounds
  # itself is untouched (see emit_and_exit).
  # Compare and assign against the ceiling IN FORCE, never the passed flag.
  # Since #1576 `effective_max` can already sit above `max_rounds` on a human
  # grant, and a plain assignment keyed on the flag would pull it back DOWN —
  # throwing away granted rounds and reporting BUDGET_EXHAUSTED for rounds the
  # human had already given. `closing_sweep_granted` therefore means what it
  # says: the sweep needed a round beyond the ceiling in force.
  if (( closing_sweep_round > effective_max )); then
    effective_max=$closing_sweep_round
    closing_sweep_granted=1
  fi
  return 0
}

# The cadence guard (#1435 §10). Refuses the round when its findings were
# produced against a different tree than the one about to be consolidated.
#
# Silent when it cannot tell — an absent stamp (an older work-dir, a hand-seeded
# resume) or an unmintable identity. That is the same fail-quiet direction the
# rest of this file takes for missing state: the guard catches a cadence
# MISTAKE, and a toolless or half-migrated environment should lose the detection
# rather than the run.
_cadence_check() {   # $1 = round, $2 = source: "attested" | "stamp"
  local r="$1" want="$2" recorded="" now="" moved="" n_moved=0 src=""
  # TWO sources, one per wiring — see the `case` below for which runs when.
  #
  #   * `--findings-tree` — the identity the SESSION minted before it ran this
  #     round's panel. In step mode the panel runs BETWEEN invocations, so the
  #     loop's own stamp is taken after any fix the session applied first and
  #     would agree with itself no matter what: the session has to attest what
  #     its reviewers actually read. Same identity, same binary
  #     (`git-tree-id.zsh`), so the two are directly comparable.
  #   * the loop's own per-round stamp — covers HOOK mode, where the panel runs
  #     inside the invocation and a `--review-cmd` that rewrites the tree is
  #     caught without any cooperation.
  #
  # Deliberately NOT `--gate-attest`: that answers "may I skip the duplicate
  # test run", which is a claim about the SUITE, not about which tree the
  # reviewers read. Conflating them would let one flag suppress the other.
  # The CALLER picks the source, because the two are checked at different
  # moments and letting either stand in for the other refuses honest runs:
  #
  #   * `attested` runs ONCE, early, before the resume capture and before
  #     `--test-cmd`. It must precede the gate — a suite that writes into the
  #     tree (a regenerated fixture, a formatter invoked from a test) would
  #     otherwise look like a cadence violation, and on the non-plugin stacks
  #     the loop is told to run that gate itself.
  #   * `stamp` runs at consolidation, and is hook mode's arm: there the panel
  #     runs INSIDE the invocation, so a `--review-cmd` that rewrites the tree
  #     is caught with no cooperation from the caller.
  local stamp_file=""
  case "$want" in
    attested)
      [[ -n "$findings_tree" ]] || return 0
      recorded="${findings_tree//[[:space:]]/}"
      src="--findings-tree" ;;
    stamp)
      stamp_file="$work_dir/dispatch-tree-$r.txt"
      [[ -s "$stamp_file" ]] || return 0
      recorded="${$(<"$stamp_file")//[[:space:]]/}"
      src="this round's recorded dispatch tree" ;;
    *) return 0 ;;
  esac
  [[ -n "$recorded" ]] || return 0
  # A caller-supplied identity this repo cannot resolve is NOT the documented
  # silent case: the caller believes the guard ran. Announce it and degrade,
  # rather than letting the `diff-tree` below fail into a bare `return 0`.
  if [[ "$want" == "attested" ]]; then
    "${GIT_TREE_ID_BIN:-git}" -C "$repo" rev-parse --verify --quiet "${recorded}^{tree}" >/dev/null 2>&1 || {
      print -u2 -- "resolve-story-loop: --findings-tree ($recorded) does not resolve to a tree in $repo — the #1435 cadence guard is OFF for round $r"
      return 0 }
  fi
  now=$(_tree_id "$repo" 2>/dev/null) || now=""
  [[ -n "$now" ]] || return 0
  [[ "$recorded" == "$now" ]] && return 0
  # The identities differ — but a bare inequality is NOT the question. The
  # panel writes its findings sink, and the loop its own bookkeeping, inside the
  # repo on perfectly healthy runs, and both move the tree id. Ask the question
  # that matters instead: did any REVIEWABLE file change? Same normalisation and
  # same exclusions as the fix-touched capture, because it is the same notion of
  # "a file the story is about" — a second definition here would fire on runs the
  # capture considers untouched.
  moved="$work_dir/.cadence-$r.txt"
  rm -f -- "$moved"
  "${GIT_TREE_ID_BIN:-git}" -C "$repo" -c core.quotePath=false \
    diff-tree -r --name-only "$recorded" "$now" \
    | sed -E 's#^\./##' | sort -u \
    | sed -e '/^$/d' -e '\#^\.review/#d' -e '\#^\.claude/telemetry/#d' > "$moved" || {
    # cannot tell -> say nothing, like every other gap in this file
    rm -f -- "$moved"; return 0 }
  _drop_loop_internal_paths "$moved"
  n_moved=$(grep -c . -- "$moved" 2>/dev/null) || n_moved=0
  (( n_moved > 0 )) || { rm -f -- "$moved"; return 0 }
  local listing=""
  listing=$(head -n 10 -- "$moved" | sed 's/^/    /')
  rm -f -- "$moved"
  refuse_stale_findings "round $r's findings were produced against tree $recorded ($src), but the working tree is now $now, and $n_moved reviewable file(s) changed in between:
$listing
Those findings describe a tree that no longer exists. The cadence is: a round's findings reach the loop BEFORE that round's fix pass runs, always — otherwise the fix-touched set (and every \`class\` derived from it) attributes this round's blockers to a fix pass that had already happened. Re-run this round's panel against the current tree and pass its aggregate, or discard the fix and re-consolidate. (This is not --gate-attest, which answers a different question and neither causes nor suppresses this refusal.)"
}

# --- the residue condition (#1435) ------------------------------------------
# TRUE when this round's ending may be `CONVERGED_WITH_RESIDUE` instead of an
# escalation. THREE conditions, ALL required — and they are the safety rail, not
# a formality, because this is the first path on which the loop opens a PR
# without a human ever seeing an escalation:
#
#   1. the last TWO rounds' changelists both report `.summary.critical == 0` —
#      nothing consumer-visible is broken, by the reviewers' own reads, and one
#      clean round is not enough to say so;
#   2. EVERY remaining blocking finding's `.file` is in the PREVIOUS round's
#      fix-touched set — the residue lives in the implementer's own last edits,
#      not in shipped behaviour nobody has just rewritten;
#   3. the declaring round ran as a FULL SWEEP (§9). Enforced by the CALLER, at
#      the two ladder rungs, not in here — because the answer on a delta round is
#      not "escalate", it is "promote the closing sweep and come back", and this
#      predicate has no way to say that.
#
# Condition 3 exists because 1 and 2 are satisfiable on any delta round with a
# plateaued trend — the ordinary case. #1434 guarantees `CONVERGED` is only ever
# reached from a full sweep, but it earns that sweep only on a ZERO-blocker delta
# round; residue rounds never return zero, so the sweep would never be earned and
# a PR would open having reviewed only the slices the deltas happened to cover.
# The motivating run did exactly that: it declared residue off a delta round, and
# the sweep that followed (only because an unrelated recovery forced one) found
# ten blockers in files no delta scope had ever contained.
#
# The CRITICAL count has exactly ONE source: `<work-dir>/changelist-<N>.json`,
# which persists across `--resume` because the work-dir accumulators do. Nothing
# residue-derived is written to `history.jsonl` — a second source for one fact is
# how two surfaces come to disagree.
#
# Every "cannot tell" answer returns FALSE (a missing changelist, an unreadable
# count, an absent fix-touched set, a jq failure): the fallback is the escalation
# the loop would have raised anyway, so the honest gap costs a human prompt,
# where the other direction ships a PR nobody agreed to.
_residue_holds() {   # $1 = round, $2 = this round's changelist
  local r="$1" cl="$2" prev_cl="" touched="" set_json="" c_cur="" c_prev="" n_blocking="" n_outside=""
  # NEVER in the promotion sub-loop (#994/#1435). Its blockers are the human's
  # OWN promoted picks, raised from Low precisely because they said "actually, do
  # that one" — and #994's contract is that they "are treated as blocking, not
  # quietly re-waived". Residue would re-waive them, and file the human's
  # explicit request back to them as a follow-up issue.
  #
  # It also keeps the residue story SINGLE-PHASE, which is what lets every
  # downstream surface state one thing rather than two. Residue always comes from
  # the blocking phase, so its blockers are always the ones the residue branch
  # files — the dossier can say "filed" without a per-phase qualifier, the
  # Approver policy can read `open > 0` as tracked disclosed risk without one,
  # and §6's Summary always has issue numbers to name. Allowing a second,
  # never-filed flavour cost four separate conditionals and got the both-residue
  # case wrong in all of them.
  [[ -z "$promote" ]] || return 1
  # Round 1 can never qualify: there is no previous round's fix pass to
  # attribute residue to, and no second changelist to prove the CRITICAL window.
  # Both later tests would fail on their own; stating it here makes the boundary
  # a rule rather than an accident of two other checks.
  (( r >= 2 )) || return 1
  prev_cl="$work_dir/changelist-$(( r - 1 )).json"
  [[ -s "$cl" && -s "$prev_cl" ]] || return 1
  c_cur=$(jq -r '.summary.critical // empty' -- "$cl" 2>/dev/null) || return 1
  c_prev=$(jq -r '.summary.critical // empty' -- "$prev_cl" 2>/dev/null) || return 1
  [[ "$c_cur" == 0 && "$c_prev" == 0 ]] || return 1
  # `-f`, not `-s`: an EMPTY set is a real answer (the fix pass touched nothing
  # reviewable), and it makes the membership test below fail for every blocker —
  # which is the correct verdict, not a reason to refuse the file.
  touched="$work_dir/fix-touched-$(( r - 1 )).txt"
  [[ -f "$touched" ]] || return 1
  # A round with NO blockers is not a residue round — it is the CONVERGED
  # condition, decided before this is ever called. Guarded anyway, because the
  # membership count below is vacuously 0 on an empty list and would otherwise
  # answer TRUE to a question nobody should be asking here.
  n_blocking=$(jq '(.blocking // []) | length' -- "$cl" 2>/dev/null) || return 1
  [[ "$n_blocking" == <-> ]] && (( n_blocking > 0 )) || return 1
  set_json=$(jq -R -s 'split("\n") | map(sub("^\\./"; "")) | map(select(length > 0)) | unique' \
    -- "$touched" 2>/dev/null) || return 1
  [[ -n "$set_json" ]] || return 1
  # the path is bound BEFORE `index`, whose input is $t (the ARRAY): a bare `.`
  # inside it would test the array against itself. Same trap, same fix, as the
  # consolidator's own membership test.
  n_outside=$(jq --argjson t "$set_json" \
    '[ (.blocking // [])[] | ((.file // "") | tostring | sub("^\\./"; "")) as $f
       | select(($t | index($f)) == null) ] | length' -- "$cl" 2>/dev/null) || return 1
  [[ "$n_outside" == <-> ]] || return 1
  (( n_outside == 0 ))
}

# --- the one-shot all-ambiguous auto-continue (#1498) ------------------------
# #983 already auto-continues a VERIFIED false trip — a carried match whose title
# is fully disjoint from its matched prior's, so the finding is demonstrably a
# different one that merely landed inside the proximity window. A POSSIBLE false
# trip (#913/#969) is the case in between: the titles differ but are not
# disjoint, so the loop cannot tell a reworded survivor from a new neighbour. It
# still ends the run today, and twice in one #1435 session it did so on a round
# where EVERY carried match was one and the assessment said as much — 41 minutes
# of a human's wall clock spent confirming what the loop had already reported.
#
# The rung below buys exactly one round in that state, and nothing else. It is
# NOT a bar lowered: the matches stay carried blockers the next round must
# verify, one Critical anywhere in the carried set vetoes, an exact-title match
# beside them vetoes, the ceiling is untouched, and an identity gets one
# continuation for the whole run — a second ambiguous match on it is evidence of
# a stuck blocker, which is what the escalation is for.

# The identities of this round's carried set, one per line, deduplicated.
# BOTH titles of each match are recorded — the item's own and its matched
# prior's — because the ambiguity being continued is precisely a rewording, and
# recording only the current title would let the next round's fresh wording buy
# a second continuation for the same defect.
#
# `normtitle` is the CONSOLIDATOR's own normalisation, transcribed rather than
# invented: one definition, two readers. Because it collapses every whitespace
# run to a single space, a reviewer-authored title can hold no tab and no
# newline, so it can neither forge a field separator nor forge a record.
_pft_identities() {   # $1 = changelist -> identity lines on stdout
  jq -r '
    def normtitle: ((. // "") | tostring | ascii_downcase | gsub("\\s+"; " ")
      | sub("^ +"; "") | sub(" +$"; ""));
    def normfile: ((. // "") | tostring | sub("^\\./"; ""));
    [ (.blocking // [])[] | select(.non_converging == true)
      | (.file | normfile) as $f
      | ((.dimension // "") | tostring) as $d
      | ( [$f, $d, (.title | normtitle)] | join("\t") ),
        ( [$f, $d, (.matched_prior.title | normtitle)] | join("\t") ) ]
    | unique | .[]' -- "$1"
}

# Does this round's carried set meet the FINDINGS half of the rung? The ceiling
# and marker halves are the caller's, so this stays a pure read of one file.
#
# `$stamped` is the same predicate the four sibling surfaces use (progress
# block, escalation table, escalation assessment, telemetry payload): an
# unstamped changelist escalates as it does today, and an ABSENT flag is never
# read as a pass. The empty-carried-set guard runs before the `all` tests
# because `[] | all` is true, and a vacuous yes here would auto-continue a round
# that has no ambiguity at all.
_pft_findings_qualify() {   # $1 = changelist
  local v=""
  v=$(jq -r '
    (.blocking // []) as $blk
    | ((($blk | length) == 0) or ([ $blk[] | has("non_converging") ] | all)) as $stamped
    | ([ $blk[] | select(.non_converging == true) ]) as $carried
    | if ($stamped | not) then "no"
      elif ($carried | length) == 0 then "no"
      elif ([ $carried[] | .possible_false_trip == true ] | all | not) then "no"
      elif ([ $carried[] | select(.priority == "Critical") ] | length) > 0 then "no"
      else "yes" end' -- "$1" 2>/dev/null) || return 1
  [[ "$v" == "yes" ]]
}

# How many continuations the marker records: distinct leading round fields.
# Derived from the same file that holds the identities, so there is no second
# artifact for a partial write to desynchronise.
# An absent or empty marker is a real 0. A marker that EXISTS but yields no
# numeric round field is a degradation, not a fact, and it is announced —
# the same treatment the closing-sweep adoption gives a garbage sidecar, and
# what keeps a reported number either reliable or visibly withheld.
_pft_count() {
  [[ -s "$pft_marker" ]] || { print -r -- 0; return 0 }
  local n=""
  n=$(cut -f1 -- "$pft_marker" 2>/dev/null | sort -u | grep -c '^[0-9][0-9]*$') || n=""
  [[ "$n" == <-> ]] && (( n > 0 )) || {
    print -u2 -- "resolve-story-loop: ignoring an unreadable possible-false-trip marker in $pft_marker — this run's spent continuations will report as 0 (#1498)"
    n=0 }
  print -r -- "$n"
}

# The rung itself: 0 (and the marker appended, the count incremented) when the
# round auto-continues, non-zero when it must escalate.
#
# Every refusal BEFORE the append leaves the marker untouched, which is what
# lets the vetoes be asserted on an absent file. A failed append refuses too,
# and the records it did write only make the bound STRICTER — never looser — so
# the failure direction is the safe one: continuing on a lost record would spend
# the one-shot bound invisibly and let the same identity continue again next
# round, which is the one thing this rung must never do.
_pft_auto_continue() {   # $1 = round, $2 = this round's changelist
  local r="$1" cl="$2" ids="" recorded="" rc=0
  local -a recs
  # The ceiling bound is load-bearing, not decorative: the `while (( round <=
  # effective_max ))` loop exited with an EMPTY loop_status falls through to the
  # `*)` arm of the exit `case` and emits a bare-status exit 1 — an operational
  # failure, not a terminal. At the ceiling the existing paths stand as they are.
  (( r < effective_max )) || return 1
  [[ -n "$work_dir" && -n "$pft_marker" ]] || return 1
  _pft_findings_qualify "$cl" || return 1
  ids=$(_pft_identities "$cl") || return 1
  [[ -n "$ids" ]] || return 1
  # ...and the one-shot bound. A hit on EITHER recorded title counts, which is
  # what stops the rewording that made the match ambiguous from buying a second
  # continuation. The comparison is against everything after the marker's first
  # tab, so a path holding a tab cannot shift the fields apart.
  # ...matched by ONE grep over the whole identity list rather than a grep per
  # identity, so a grep ERROR (exit 2) is distinguishable from "no match"
  # (exit 1). Treating the two alike would make this the one fail-OPEN path in a
  # helper whose every other failure escalates — and the state it would fail
  # open into, spending the one-shot bound while believing nothing was recorded,
  # is the one the rung must never reach.
  if [[ -s "$pft_marker" ]]; then
    recorded=$(cut -f2- -- "$pft_marker" 2>/dev/null) || return 1
    rc=0
    print -r -- "$recorded" | grep -qxF -f <(print -r -- "$ids") || rc=$?
    (( rc == 0 )) && return 1
    (( rc == 1 )) || {
      print -u2 -- "resolve-story-loop: could not test the recorded possible-false-trip identities in $pft_marker — escalating instead (#1498)"
      return 1 }
  fi
  # ONE append, not one per identity. A partial write would leave the marker
  # holding this round while `pft_continues` had never moved — and since the
  # count is DERIVED from the marker on the next --resume, the two would then
  # disagree about the same run, which is exactly what deriving it from one file
  # exists to prevent. Derived here too, for the same reason: after the write
  # the marker is the answer, so nothing is incremented alongside it.
  recs=("${(@f)ids}")
  print -rl -- "${(@)recs/#/$r	}" >> "$pft_marker" || {
    print -u2 -- "resolve-story-loop: could not record the round $r possible-false-trip auto-continue at $pft_marker — escalating instead (#1498)"
    return 1 }
  pft_continues=$(_pft_count)
  return 0
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

# The ceiling the WHILE loop and the BUDGET_EXHAUSTED test actually use, and
# where it came from (#1434 closing sweep, #1576 grant sidecar). Both are
# declared HERE, above the --no-review fast path, for the same reason
# --max-rounds is validated here: that path reaches emit_and_exit without ever
# entering the --resume block below, and `effective_max_rounds` /
# `max_rounds_source` are contracted as ALWAYS-PRESENT — a consumer must never
# have to tell a value from "a status file that predates the key". Declared any
# lower, a SKIPPED record would carry neither.
# `--max-rounds` itself is never mutated (see emit_and_exit): the raised ceiling
# is reported alongside it, never in place of it.
local effective_max=$max_rounds
local max_rounds_source="flag"

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
# `--findings-tree` attests ONE round's panel, and hook mode runs many rounds in
# a single invocation — so the value would be compared against round 2's, 3's, …
# working tree, each of which the previous round's fix pass has legitimately
# moved. That is a guaranteed false refusal, and it would also displace the
# per-round stamp, which is hook mode's own (and sufficient) arm.
if (( ! step_mode )) && [[ -n "$findings_tree" ]]; then
  print -u2 -- "resolve-story-loop: --findings-tree is a step-mode flag (it attests ONE round's panel) — hook mode runs every round in one invocation and uses the per-round dispatch stamp instead"; exit 2
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

# --- the loop's own in-repo artifacts, resolved ONCE (#1435) -----------------
# Every path here is CALLER-CHOSEN and may legitimately sit inside the repo. All
# of them are written by the loop itself, and all are written AFTER the pre-fix
# tree identity is minted — `--status-file` from `emit_and_exit`, the work-dir
# every round, `--findings-file` between step-mode invocations. So each one
# shows up in the `--resume` diff as a file the SESSION's fix pass supposedly
# touched, inflating the very set that decides residue and stamps `class`.
#
# Hook mode dodges this by minting the identity after the round's own writes.
# Step mode cannot: `fix-base-<round>.txt` RECORDS that identity, so it is
# necessarily written after it. Hence an explicit exclusion list rather than an
# ordering rule.
#
# Computed with `:A` on BOTH sides, because the question is about paths and not
# about spellings: `--repo .` with an absolute work-dir, an absolute repo with a
# relative work-dir, a trailing slash, a `./` segment, or the macOS
# `/tmp` -> `/private/tmp` symlink all name the same file and must all match.
# `write_round_scope` already applies exactly this rule to the review scope, so
# this is ONE definition with two consumers rather than two definitions that
# drift.
local wd_rel=""
if [[ "${work_dir:A}" == "${repo:A}"/* ]]; then
  wd_rel="${${work_dir:A}#"${repo:A}"/}/"
fi
# The work-dir is a DIRECTORY (prefix match, trailing slash); the other three are
# single FILES (exact match). Keeping them in separate lists is what stops
# `--status-file "$repo/loop.json"` from also swallowing `loop.json.bak`.
#
# `--telemetry-file` belongs here for a reason the static `.claude/telemetry/`
# exclusion hides: that prefix matches the emitter's DEFAULT sink only, never an
# explicit in-repo path — and the promotion flow tells the caller to re-pass "the
# same file the loop was given", so an explicit value is the documented shape.
# `emit_and_exit` appends to it AFTER the fix-base stamp, so on a granted
# escalate -> resume it lands in the diff as a file the session's fix pass
# supposedly touched: the fail-OPEN direction this whole list exists to close.
local -a loop_internal_files=()
local _lp=""
for _lp in "$status_file" "$findings_file" "$telemetry_file"; do
  [[ -n "$_lp" ]] || continue
  [[ "${_lp:A}" == "${repo:A}"/* ]] || continue
  loop_internal_files+=("${${_lp:A}#"${repo:A}"/}")
done
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
# the identities this run has already spent its one all-ambiguous continuation
# on (#1498) — per-run like the two above, truncated on a fresh start and
# adopted on --resume, because step mode runs each round as its own invocation
local pft_marker="$work_dir/.possible-false-trip-continued"
local adjudicated_file="$work_dir/adjudicated.json"
# the ceiling a human grant bought (#1576), written by record-grant.zsh at the
# interactive extension's step 5 and adopted below — per-run like the markers
# above, so a re-used work-dir cannot fund a run that never earned the rounds
local max_rounds_file="$work_dir/.max-rounds"
# `effective_max` / `max_rounds_source` are declared far above, beside the
# --max-rounds validation, so the --no-review fast path emits them too.
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
  # VALIDATE the human grant's ceiling (#1576) before the closing-sweep block,
  # but do NOT publish it yet — the two adoptions are applied together further
  # down. The split exists because the sweep's clamp needs to know the ceiling
  # this run is really working under: with the grant adopted only afterwards,
  # the clamp would measure a legitimate sweep promoted DURING granted rounds
  # against the un-raised flag and refuse it as stale. That refusal is not
  # cosmetic — a refused marker means the promoted round runs as a delta round,
  # and §9 forbids a delta round from declaring CONVERGED, so the run could
  # only ever end BUDGET_EXHAUSTED however clean it was; at the ceiling it also
  # bricks the resume guard below into a permanent exit 2.
  #
  # Four arms, none of them fatal. A grant sidecar outranks the command line,
  # so it is the file where a WELL-FORMED but wrong number does the damage —
  # the same lesson `.closing-sweep` already learned. The two loud arms end
  # DIFFERENTLY: (b) cannot read a number, so it falls back to the flag; (c)
  # reads one that is merely too large, so it CLAMPS and adopts the cap (see
  # its own note). Either way nothing dies — losing a grant costs one re-grant
  # while dying costs the whole resumable run.
  local sidecar_ceiling=0
  if [[ -s "$max_rounds_file" ]]; then
    # `local mr_val=""`, never a bare `local mr_val`: at TOP LEVEL there is no
    # new scope, so a bare typeset whose name already exists in the environment
    # PRINTS `mr_val=value` — on stdout, ahead of the status JSON. Same hazard
    # the closing-sweep adoption documents just below.
    local mr_val=""
    mr_val=$(<"$max_rounds_file")
    # (a) strip only LEADING and TRAILING whitespace. Collapsing internal
    # whitespace too would repair a multi-token file into a number nobody
    # wrote — `8\n3` reading as `83` — where the point of the shape check is to
    # send anything that is not one integer into the loud arm below.
    # (the `${x#"${x%%[![:space:]]*}"}` idiom rather than `[[:space:]]##`,
    # which needs EXTENDED_GLOB — not set in this file, so the `##` would be
    # taken literally and strip nothing)
    mr_val="${mr_val#"${mr_val%%[![:space:]]*}"}"
    mr_val="${mr_val%"${mr_val##*[![:space:]]}"}"
    if [[ "$mr_val" == <-> ]] && (( ${#mr_val} <= 18 )); then
      local mr_num=$(( 10#$mr_val ))
      # (c) The semantic clamp — it CLAMPS, it does not discard. Beyond
      # MAX_ROUNDS_SIDECAR_SLACK above the flag the file is stale, foreign or
      # corrupt (a `99` must not buy 94 rounds of agent time), but *dropping*
      # it would collapse the ceiling all the way back to `--max-rounds` — and
      # on a run already past that round the resume guard below would then
      # refuse EVERY subsequent `--resume` with exit 2, stranding a granted,
      # in-progress run whose only escape is hand-editing `.max-rounds`, which
      # the docs forbid (raising `--max-rounds` stays sanctioned — the higher of
      # the two wins — and is exactly what the diagnostic points at). The sweep grant is repeatable, so a long legitimate
      # run can reach the cap honestly. Bounding the value keeps the budget
      # honest AND the run resumable; the diagnostic is what makes the
      # difference visible.
      local mr_cap=$(( max_rounds + MAX_ROUNDS_SIDECAR_SLACK ))
      if (( mr_num > mr_cap )); then
        print -u2 -- "resolve-story-loop: clamping a max-rounds sidecar beyond the soft cap (got $mr_num, --max-rounds $max_rounds, cap $mr_cap) in $max_rounds_file — using $mr_cap; raise --max-rounds if the run genuinely earned more"
        mr_num=$mr_cap
      fi
      # (d) At or below the passed flag the flag simply wins, silently — nothing
      # is wrong with the file. This is what makes "a passed value ABOVE the
      # file wins" a special case of one rule rather than a second rule to keep
      # in sync: a human raising --max-rounds further needs no sidecar edit.
      if (( mr_num > max_rounds )); then
        sidecar_ceiling=$mr_num
      fi
    else
      # (b) not a bounded integer — say so and keep the flag
      print -u2 -- "resolve-story-loop: ignoring an unreadable max-rounds sidecar in $max_rounds_file (got: ${mr_val:-<empty>}) — using --max-rounds $max_rounds"
    fi
  fi
  # APPLY the grant here, before the sweep is judged, so there is exactly ONE
  # ceiling in force for the block below to clamp against AND to measure its
  # own grant against. Keeping them as two variables is what let the sweep be
  # clamped against the raised ceiling while still being *stamped* a grant
  # against the un-raised one. `max_rounds` itself is still never mutated.
  if (( sidecar_ceiling > effective_max )); then
    effective_max=$sidecar_ceiling
    # The source is stamped where the value is actually ADOPTED, never merely
    # where a sidecar was found: a sidecar that lost to an already-higher
    # ceiling did not produce `effective_max_rounds`, and claiming it did would
    # make the two keys disagree about the same run.
    max_rounds_source="work-dir"
  fi

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
      # `effective_max`, not `max_rounds`: the sweep is granted ONE round beyond
      # the ceiling this run is really working under, and since #1576 a human
      # grant can raise that. Measuring against the bare flag would refuse a
      # LEGITIMATE sweep promoted during granted rounds — and a refused marker
      # makes the promoted round a delta round, which §9 forbids from declaring
      # CONVERGED, so the run could only ever end BUDGET_EXHAUSTED however clean
      # it was. The stale-marker protection is untouched: a foreign `99` is
      # still far beyond `effective_max + 1`.
      if (( closing_sweep_round > effective_max + 1 )); then
        print -u2 -- "resolve-story-loop: ignoring a closing-sweep marker beyond the one-round grant (got $closing_sweep_round, ceiling in force $effective_max, so the highest grantable sweep is $(( effective_max + 1 ))) in $closing_sweep_file"
        closing_sweep_round=0
      elif (( closing_sweep_round > effective_max )); then
        effective_max=$closing_sweep_round
        closing_sweep_granted=1
      fi
    else
      print -u2 -- "resolve-story-loop: ignoring an unreadable closing-sweep marker in $closing_sweep_file (got: ${cs_round:-<empty>})"
      closing_sweep_round=0
    fi
  fi
  # Adopt this run's spent all-ambiguous continuations (#1498). Step mode runs
  # each round as its own invocation, so without this the escalating round after
  # an auto-continue would report 0 and the escalation summary would claim no
  # continuation was ever spent. Derived from the marker rather than a separate
  # counter, so the two can never disagree; an absent or unreadable marker
  # simply reads 0, the same fail-quiet direction the closing-sweep adoption
  # takes for a garbage sidecar.
  pft_continues=$(_pft_count)
  # a ceiling at or below the resumed round would run zero rounds and fall out
  # of the loop with an empty status — refuse it as a usage error instead
  (( resume_round + 1 <= effective_max )) || {
    print -u2 -- "resolve-story-loop: --resume would start at round $(( resume_round + 1 )) but the ceiling in force is $effective_max (--max-rounds $max_rounds, source $max_rounds_source) — raise --max-rounds above $effective_max"; exit 2 }
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
  # fix-touched / fix-base (#1435) are per-run for the same reason: a previous
  # run's set would attribute THIS run's blockers to a fix pass that never
  # happened here, and residue's whole claim is "these edits are ours".
  # ...and the possible-false-trip marker (#1498) for the same reason: a
  # previous run's identities would silently deny THIS run the continuation it
  # has not spent, and its rounds would inflate this run's reported count.
  # ...and the max-rounds grant sidecar (#1576), which is the largest blast
  # radius of the set: a previous story's granted ceiling would silently FUND
  # rounds this run never earned, and nothing downstream would notice.
  rm_state_err=$(rm -f -- "$work_dir"/tree-*.txt(N) "$work_dir"/dispatch-tree-*.txt(N) "$work_dir"/verify-*.json(N) "$closing_sweep_file" \
    "$pft_marker" "$max_rounds_file" "$work_dir"/.max-rounds.tmp.*(N) "$work_dir"/fix-touched-*.txt(N) "$work_dir"/fix-base-*.txt(N) 2>&1) || \
    print -ru2 -- "resolve-story-loop: could not clear the previous run's iteration state in $work_dir (${rm_state_err}) — a foreign fix-verification carry, closing-sweep marker, possible-false-trip marker, max-rounds sidecar (.max-rounds, .max-rounds.tmp.*) or fix-touched set may be adopted (#1434, #1435, #1498, #1576)"
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
# STEP MODE's other half of the fix-touched capture (#1435) — the DIFF. The
# session applied the previous round's fixes between invocations, so this is the
# first moment the loop can see what they touched: diff the identity stamped at
# that round's AWAITING_FIX against the tree as it stands now.
#
# It runs BEFORE the gate below, deliberately. --test-cmd is the repo's own
# suite, and a suite that writes into the tree (a regenerated fixture, a
# formatter run from a test) would otherwise land in the set as though the
# session's fix pass had made the edit. Before the gate, the set is exactly the
# session's edits and nothing else.
#
# Unconditional on --test-cmd, unlike the gate block: the capture is about the
# fix pass, not about the gate, and a run without --test-cmd must still be able
# to reach a residue ending.
# The three names `refuse_stale_findings` reads, declared BEFORE the cadence
# guard below so an early refusal emits a well-formed status JSON rather than
# dying on an unset parameter. They are filled in from the dispatch plan further
# down; empty here is the honest value — no plan has been parsed yet, and a
# refusal at this point is about the INPUT, not about the stack.
local repo_type="" review_skill="" prev_changelist=""
prev_changelist="$resume_prev"

# --- the cadence guard, BEFORE anything is captured (#1435 §10) --------------
# Placed ahead of the capture, not beside the consolidation, because the capture
# is the first thing that WRITES from the suspect input: it would stamp
# `fix-touched-<resume_round>.txt` from a tree the reviewers never read, and that
# file is what `class` and the residue decision are computed from. Refusing
# afterwards would leave that artifact behind for the next `--resume` to adopt.
#
# `round` is not in scope yet (it is derived below), so the refusal is raised for
# the round being resumed.
#
# NOT gated on `--resume`. Round 1 needs this most, not least: a fresh step-mode
# round is a FULL round, where zero blockers IS the `CONVERGED` condition — so a
# session that runs the panel, then edits, then invokes would exit 0 and open a
# PR on a panel that read a tree which no longer exists. That is the false green
# the guard exists for, and gating on `resume` left exactly it uncovered while
# the flag was accepted without complaint. On a fresh run `resume_round` is 0, so
# the derived round is 1 and the comparison is the right one; the block still
# precedes the capture and the gate.
if (( step_mode )) && [[ -n "$findings_tree" ]]; then
  local round=$(( resume_round + 1 ))
  _cadence_check "$round" attested
  unset round
fi

if (( step_mode && resume )) && [[ -n "$work_dir" && -d "$work_dir" ]]; then
  local fix_base_file="$work_dir/fix-base-$resume_round.txt" fix_base=""
  [[ -s "$fix_base_file" ]] && fix_base="${$(<"$fix_base_file")//[[:space:]]/}"
  if [[ -n "$fix_base" ]]; then
    _capture_fix_touched "$fix_base" "$resume_round" || true
  else
    # An ABSENT stamp is the ordinary older-work-dir case (a run that started
    # before #1435, or a hand-seeded resume), not an anomaly — so it is SILENT.
    # The one shape that is worth saying out loud, a round that could not
    # compute its own identity, already said so at its AWAITING_FIX exit; and
    # the visible consequence either way is the same and fail-closed: no set, so
    # residue is unreachable for the round that follows. Clearing anything left
    # at the path keeps that promise absolute rather than merely likely.
    rm -f -- "$work_dir/fix-touched-$resume_round.txt"
  fi
fi

if (( step_mode && resume )) && [[ -n "$test_cmd" ]]; then
  local gate_skipped=0
  if [[ -n "$gate_attest" ]]; then
    local cur_tree=""
    [[ -x "$TREE_ID" ]] && cur_tree="$(_tree_id "$repo" 2>/dev/null)"
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

local scope_file="$work_dir/scope.txt"
repo_type=$(print -r -- "$plan" | jq -r '.repo_type')
review_skill=$(print -r -- "$plan" | jq -r '.review_skill')
# scope_file is written per round inside the loop (#911) — no pre-loop write,
# so a stale copy can never be mistaken for the round's real scope.
# A --work-dir INSIDE the repo would sweep the loop's own state files
# (scope.txt, changelist-N.json, history.jsonl, …) into the refreshed scope as
# untracked files — the dispatch's #909 exclusion only covers the default
# artifact prefixes. `wd_rel` is computed ONCE near the top of this function
# (beside `loop_internal_files`), because the step-mode fix-touched capture runs
# BEFORE this point and needs the same value; every refresh filters on it.

# --- the loop ---------------------------------------------------------------
# All loop-locals are declared ONCE here: re-running a bare `local NAME` on a
# later iteration makes zsh PRINT the existing parameter to stdout, which would
# corrupt the status JSON. Inside the loop we plain-assign only.
local round=$(( resume_round + 1 )) loop_status="" final_changelist=""
prev_changelist="$resume_prev"
# EVERY declaration here carries an initialiser. At top level zsh opens no new
# scope, so a bare `local NAME` for a name that already exists in the
# environment PRINTS `NAME=value` on stdout — ahead of the status JSON, which is
# this script's stdout contract. The file states that rule three times above,
# and `blocking`, `verdict`, `changelist`, `scoped` and `carried` are ordinary
# enough words to inherit from a caller's environment — so the rule now covers
# the whole block rather than only the lines #1434 added.
local rp="" findings_path="" scoped="" scoped_filtered="" changelist="" blockers=""
local fix_base_tree=""
local digest="" prev_digest_file=""
local prev_findings_empty=0
local blocking=0 conflict=0 nonconv=0 nconf=0 verdict="" ftrips=0
local adj_dropped=0
local cur_tree="" prior_tree="" prior_tree_file="" fix_verification=""
local scope_mode="" replanned_scope_mode="" delta_json="" carried=0
local is_final=0 is_closing_sweep=0 is_empty_delta=0 empty_delta_note=""
local round_scope_empty=0 round_findings_empty=0 rc_empty=0
local skip_fix=0 residue_promoted_sweep=0 pft_continued_round=0 adj_tmp=""
local -a consolidate_args=() plan_args=()
while (( round <= effective_max )); do
  # --- this round's working-tree identity (#1434) ---------------------------
  # Computed BEFORE anything else in the round, so it is exactly the tree the
  # round's reviewers see; the NEXT round diffs against it, which makes its delta
  # precisely what this round's fix pass changed.
  cur_tree=$(_tree_id "$repo" 2>/dev/null) || cur_tree=""
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
  # --- the cadence guard (#1435 §10) ---------------------------------------
  # Record the tree this round's dispatch plan was built against. The round's
  # findings are only about THIS tree, and the fix-touched set — hence `class`,
  # hence residue — is true only if the panel ran before the round's fix pass.
  # A session that fixes first hands the loop findings describing a tree that no
  # longer exists; the arithmetic then stays internally consistent while every
  # input is false, which is the one failure a terminal that opens a PR without
  # human review must not make.
  #
  # Written per round rather than kept in a variable so it survives the
  # invocation boundary: in step mode the panel runs BETWEEN invocations, so the
  # plan and the findings that answer it can be minted in different processes.
  print -r -- "$cur_tree" > "$work_dir/dispatch-tree-$round.txt" || {
    print -u2 -- "resolve-story-loop: could not persist the round $round dispatch tree identity to $work_dir/dispatch-tree-$round.txt"; exit 1 }
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
      # same by `reference/review-loop.md` ("re-plan with `--final` and review the
      # whole story diff"). Recording the delta's empty scope here would contradict what was
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
  # Computed from this story's own attested-tree delta — deliberately NOT from the
  # fix-touched capture (#1435), which exists by this point but is the narrower
  # set. Delta scoping errs toward keeping a suggestion visible, and that is the
  # direction this rule wants.
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
  # findings-round-R.json, per `reference/review-loop.md` *Each round* step 2)
  # would have its real panel output destroyed here, then be told "the panel
  # never ran" — a confidently wrong verdict, and the cp below would fail on
  # identical files anyway. Name the
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
  # A repo-internal work-dir's own files are loop state, never story findings —
  # the #909/#911 exclusion must hold in step mode too (final-review fix, #971).
  #
  # The EXACT list (`--status-file` / `--findings-file` / `--telemetry-file`) is
  # filtered here as well, not just the work-dir prefix (#1435). Leaving it out
  # made this path strictly worse than before that change: the loop rewrites
  # those files every round, so a blocker raised on one is unfixable and
  # re-appears each round — and since the fix-touched capture now correctly drops
  # them, residue condition 2 fails on it forever and the run ends in an
  # escalation about the loop's own bookkeeping. Same fact, same three consumers,
  # one definition.
  if [[ -n "$wd_rel" ]] || (( ${#loop_internal_files} > 0 )); then
    scoped_filtered="$work_dir/.scoped-filtered-$round.json"
    local internal_json="[]"
    internal_json=$(print -rl -- "${loop_internal_files[@]}" \
      | jq -Rsc 'split("\n") | map(select(length > 0))') || internal_json="[]"
    jq -c --arg wd "$wd_rel" --argjson internal "$internal_json" \
      '[ .[] | ((.file // "") | sub("^\\./"; "")) as $p
         | select( (($wd != "") and ($p | startswith($wd))) or (($internal | index($p)) != null) | not ) ]' \
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
  # the PREVIOUS round's fix-touched set (#1435), so each blocker is stamped with
  # where it came from. `-f` not `-s`: an empty set is a real answer (every
  # blocker is then a `new_defect`), and an ABSENT one means the capture could
  # not run — so the flag is omitted and NO item is stamped, which is exactly how
  # every downstream reader tells "no fix-touched information" from "the fix pass
  # touched nothing".
  [[ -f "$work_dir/fix-touched-$(( round - 1 )).txt" ]] && \
    consolidate_args+=( --fix-touched "$work_dir/fix-touched-$(( round - 1 )).txt" )
  # --- the cadence guard fires HERE (#1435 §10) -----------------------------
  # Last moment before the findings become a changelist. Compare the tree this
  # round's plan was built against with the tree as it stands now: if they
  # differ, something rewrote the repo between the panel being scoped and its
  # findings being consumed, and those findings describe a tree that no longer
  # exists.
  #
  # A REFUSAL, never a repair. The loop cannot know which of the two trees the
  # reviewers actually read, so it cannot pick one — and a residue verdict
  # computed from the wrong one is exactly the false audit record §9 and this
  # guard exist to prevent. `--gate-attest` is a different question ("may I skip
  # the duplicate test run"), so it neither causes nor suppresses this.
  _cadence_check "$round" stamp
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
  residue_promoted_sweep=0
  pft_continued_round=0
  if (( blocking == 0 )); then
    if [[ "$scope_mode" == "full" ]]; then
      loop_status="CONVERGED"
    else
      _promote_closing_sweep "$round" || exit 1
      # nothing to fix — the round found no blockers; the next round only
      # re-reviews, at full scope
      skip_fix=1
      (( step_mode )) && loop_status="AWAITING_FIX"
    fi
  elif (( conflict == 1 )); then loop_status="ESCALATE_CONFLICT"
  # RESIDUE (#1435) is evaluated at EXACTLY the two rungs the loop would
  # otherwise end on an escalation, and nowhere else. It never pre-empts
  # CONVERGED (zero blockers still wins, above), never ESCALATE_CONFLICT (a
  # human has to pick between opposed recommendations — no ending can guess it),
  # never ESCALATE_AMBIGUOUS (raised long before this ladder, and about dispatch
  # rather than findings), and never an AWAITING_FIX round that still has budget:
  # the loop keeps FIXING while it can, and residue only replaces an ending.
  #
  # That placement is also what demotes identity-recurrence from sole trigger to
  # one input: a `non_converging` blocker still ENDS the loop, it just no longer
  # decides HOW it ends. Which matters precisely because that signal
  # false-tripped its way through the #687 run — fixes cluster in the same few
  # files, so each round's genuinely-new findings kept landing inside the
  # previous round's proximity window.
  elif (( nonconv == 1 )); then
    if _residue_holds "$round" "$changelist"; then
      if [[ "$scope_mode" == "full" ]]; then
        loop_status="CONVERGED_WITH_RESIDUE"
      else
        _promote_closing_sweep "$round" || exit 1
        residue_promoted_sweep=1
        (( step_mode )) && loop_status="AWAITING_FIX"
      fi
    elif _pft_auto_continue "$round" "$changelist"; then
      # #1498: every carried match of this round is a POSSIBLE false trip, none
      # is Critical, the round is below the ceiling, and no identity has
      # continued before — so take the round this run already had rather than
      # spend a human's attention confirming what the assessment just reported.
      # Strictly BELOW the residue rung above, which keeps #1435's placement
      # rule ("evaluated only where the loop would otherwise choose
      # ESCALATE_NO_CONVERGENCE or BUDGET_EXHAUSTED") intact: residue still wins.
      # An auto-continue is not a grant — nothing here touches effective_max,
      # max_rounds or closing_sweep_granted — so the round falls through exactly
      # as an ordinary continuing round does: empty loop_status in hook mode
      # (the fix hook runs, then the next round), AWAITING_FIX in step mode.
      pft_continued_round=1
      (( step_mode )) && loop_status="AWAITING_FIX"
    else
      loop_status="ESCALATE_NO_CONVERGENCE"
    fi
  elif (( round == effective_max )); then
    if _residue_holds "$round" "$changelist"; then
      if [[ "$scope_mode" == "full" ]]; then
        loop_status="CONVERGED_WITH_RESIDUE"
      else
        _promote_closing_sweep "$round" || exit 1
        residue_promoted_sweep=1
        (( step_mode )) && loop_status="AWAITING_FIX"
      fi
    else
      loop_status="BUDGET_EXHAUSTED"
    fi
  elif (( step_mode )); then loop_status="AWAITING_FIX"
  fi
  case "$loop_status" in
    CONVERGED) verdict="converged" ;;
    CONVERGED_WITH_RESIDUE)
      verdict="converged with residue — every remaining blocker is zero-CRITICAL and lives in the previous round's own fix-touched files; opening the PR and filing the rest as follow-ups (#1435)" ;;
    ESCALATE_CONFLICT) verdict="escalating (unresolved conflict)" ;;
    ESCALATE_NO_CONVERGENCE) verdict="escalating (non-converging blocker)" ;;
    BUDGET_EXHAUSTED) verdict="budget exhausted" ;;
    AWAITING_FIX)
      if (( skip_fix )); then
        verdict="no blockers in the delta — round $closing_sweep_round is the closing full sweep; apply no fix, just --resume"
      elif (( residue_promoted_sweep )); then
        verdict="residue conditions hold, but on a DELTA round — promoting round $closing_sweep_round to the closing full sweep, which is the only round that may declare residue (#1435); apply blockers in-session, then --resume"
      elif (( pft_continued_round )); then
        verdict="every non-convergence match is a possible false trip and none has continued before — auto-continued once, no grant consumed (#1498); apply blockers in-session, then --resume"
      else
        verdict="awaiting fix — apply blockers in-session, then --resume"
      fi ;;
    *) if (( skip_fix )); then
         verdict="no blockers in the delta — promoting round $closing_sweep_round to the closing full sweep"
       elif (( residue_promoted_sweep )); then
         verdict="residue conditions hold, but on a DELTA round — promoting round $closing_sweep_round to the closing full sweep, which is the only round that may declare residue (#1435)"
       elif (( pft_continued_round )); then
         verdict="every non-convergence match is a possible false trip and none has continued before — auto-continued once, no grant consumed (#1498); fix pass (in-loop), continuing"
       else
         verdict="fix pass (in-loop), continuing"
       fi ;;
  esac
  append_progress_round "$changelist" "$round" "$verdict" "$prev_changelist" "$pft_continued_round"
  # STEP MODE's half of the fix-touched capture (#1435) — the SNAPSHOT. The fix
  # pass happens BETWEEN invocations, where this script never observes it, so the
  # pair is split: stamp the pre-fix identity here, diff against it at --resume
  # start (beside the --gate-attest comparison, which reads the same kind of
  # identity for the same reason). Taken after the round's own writes, so a
  # repo-internal --work-dir cannot charge the loop's bookkeeping to the session's
  # fix pass. Written on EVERY AWAITING_FIX, including a zero-blocker delta round
  # that promotes the closing sweep and applies no fix at all: the resulting
  # empty set is the honest answer there ("no fix ran, so nothing is residue"),
  # and residue is correctly unreachable on that sweep.
  # ...and on every GRANTABLE ESCALATING terminal too, not only AWAITING_FIX. An
  # interactive run can be GRANTED more rounds there, and the interactive
  # extension's step 5 (`reference/interactive.md`) requires a
  # fix pass BEFORE the resume — so a fix pass really does follow those exits,
  # and without a stamp its touched set is unrecoverable. The visible cost of
  # omitting it is that the round after a grant carries no `class` at all: no
  # `by_class`, no progress row, and no residue — i.e. the histogram #1435 adds
  # for the grant decision goes dark exactly one round after a grant was spent,
  # which is when it is most wanted. (Observed on this story's own round 3.)
  # A run that stops instead simply leaves an unused stamp behind, which the next
  # fresh run clears — so the cost of listing one terminal too many is nil, and
  # the cost of listing one too few is a silently classless round.
  #
  # ESCALATE_CONFLICT is in the list for the same reason as the other two: the
  # interactive extension covers it, a human picks the winner, and a fix pass
  # follows the grant. ESCALATE_AMBIGUOUS is NOT — `emit_ambiguous` exits before
  # the round produces any findings to classify, so there is nothing for a stamp
  # to serve.
  if [[ "$loop_status" == "AWAITING_FIX" || "$loop_status" == "ESCALATE_NO_CONVERGENCE" \
        || "$loop_status" == "BUDGET_EXHAUSTED" || "$loop_status" == "ESCALATE_CONFLICT" ]]; then
    fix_base_tree=$(_tree_id "$repo" 2>/dev/null) || fix_base_tree=""
    if [[ -n "$fix_base_tree" ]]; then
      print -r -- "$fix_base_tree" > "$work_dir/fix-base-$round.txt" || \
        print -u2 -- "resolve-story-loop: could not persist the round $round pre-fix tree identity to $work_dir/fix-base-$round.txt — residue will be unreachable next round (#1435)"
    else
      print -u2 -- "resolve-story-loop: could not compute the round $round pre-fix tree identity — residue will be unreachable next round (#1435)"
    fi
  fi
  if [[ -n "$loop_status" ]]; then break; fi
  # a zero-blocker delta round has nothing for the fix hook; advancing straight
  # to the closing sweep is the whole point (hook mode)
  if (( skip_fix )); then
    # ...but record the fix-touched fact FIRST (#1435). No fix pass ran, so the
    # honest answer is an EMPTY set, and step mode already produces exactly that
    # (its AWAITING_FIX snapshot diffs against an unmoved tree at the next
    # --resume). Falling through without writing one would make hook mode omit
    # `--fix-touched` on the closing sweep and stamp NO class at all, so the two
    # wirings would disagree about the same state — and hook mode is the seam the
    # bats suite drives, i.e. the one that would stop being able to exercise what
    # production does.
    : > "$work_dir/fix-touched-$round.txt" || \
      print -u2 -- "resolve-story-loop: could not record the empty round $round fix-touched set (#1435); the closing sweep's blockers will carry no class"
    prev_changelist="$changelist"
    (( round++ ))
    continue
  fi

  # 5. fix pass — blockers only (Low suggestions never loop)
  blockers="$work_dir/blockers-$round.json"
  jq -c '{round, blocking, conflicts}' -- "$changelist" > "$blockers" || {
    print -u2 -- "resolve-story-loop: could not build the round $round blockers slice at $blockers"; exit 1 }
  # HOOK MODE's half of the fix-touched capture (#1435): the identity is taken
  # here, immediately before the hook, NOT reused from `tree-$round.txt`. The
  # round has written its changelist, history line and progress block since that
  # snapshot, and a repo-internal --work-dir puts all three inside the tree — so
  # the round's own bookkeeping would otherwise be attributed to the fix pass.
  # A failed identity is not fatal: it only costs this round's residue
  # eligibility, and _capture_fix_touched says so on stderr.
  fix_base_tree=$(_tree_id "$repo" 2>/dev/null) || fix_base_tree=""
  ( export REVIEW_ROUND="$round" REVIEW_REPO="$repo" \
           REVIEW_CHANGELIST="$changelist" REVIEW_BLOCKERS="$blockers"; eval "$fix_cmd" ) || {
    print -u2 -- "resolve-story-loop: --fix-cmd failed at round $round"; exit 1 }
  _capture_fix_touched "$fix_base_tree" "$round" || true

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
  # 14, because 10-13 are taken and 20 is AWAITING_FIX. A distinct code, not a
  # second 0: the caller must be able to tell "converged clean" from "converged
  # with residue to file" WITHOUT parsing the status JSON, since the two ask for
  # different follow-up work.
  CONVERGED_WITH_RESIDUE) code=14 ;;
  AWAITING_FIX) code=20 ;;
  ESCALATE_CONFLICT) code=11 ;;
  ESCALATE_NO_CONVERGENCE) code=12 ;;
  BUDGET_EXHAUSTED) code=13 ;;
  *) code=1 ;;
esac
emit_and_exit "$loop_status" "$round" "$code" "$repo_type" "$review_skill" "$final_changelist" "$history_file" "$changelists_file"
