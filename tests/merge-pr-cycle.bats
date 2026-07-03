#!/usr/bin/env bats
#
# Behavioral tests for merge-pr-cycle.zsh (#431, #521): the blessed merge-cycle
# helper that replaces the improvised background loops which carried two real
# bugs on the tick-client-snapper run —
#   (1) judging "settled" before the head SHA's checks had registered, and
#   (2) a zsh `$new:refs` refspec mangling from forcing fresh SHAs.
# #521 added two more bug classes, both regression-tested here:
#   (3) progress lines printed to stdout corrupted the captured verdict, so any
#       wait iteration before settle (always the case right after a head-SHA
#       move) flipped a green PR to NOT-GREEN, and
#   (4) the head SHA and its check set were read in two separate gh calls, so
#       the set judged could belong to a superseded SHA (whose cancelled/stale
#       runs must never count as failures).
# Drives the script against a FAKE gh (the GH_BIN seam) so every exit path is
# deterministic.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/maintenance/scripts/merge-pr-cycle.zsh"
  DECISION_FILE="$BATS_TEST_TMPDIR/decision"   # updated by `gh pr comment`
  COMMENT_LOG="$BATS_TEST_TMPDIR/comments"      # records /approve re-triggers
  FAKE_GH="$BATS_TEST_TMPDIR/gh"
  : > "$COMMENT_LOG"
  export GH_BIN="$FAKE_GH"

  # Fake gh dispatches on the subcommand. The script reads the head SHA and its
  # statusCheckRollup ATOMICALLY via `pr view --json headRefOid,statusCheckRollup`
  # (#521); the fake serves those reads from a SEQUENCE of state files so a test
  # can script what each successive poll observes:
  #   state.N     the Nth rollup poll's response (N = 1, 2, …)
  #   state.last  every poll past the scripted sequence (the steady state)
  # The stale-rejection probe (#523) reads `pr view --json headRefOid,reviews`;
  # the fake serves reviews.json for it. Env toggles drive the remaining
  # conditions:
  #   GH_DECISION       initial reviewDecision (default REVIEW_REQUIRED)
  #   GH_DECISION_AFTER reviewDecision written by `pr comment` (re-trigger flips it)
  #   GH_ERROR=1        the rollup read fails with an auth error
  #   GH_UPDATE_CONFLICT=1  `pr update-branch` reports a merge conflict
  # `pr comment` also promotes reviews-after.json to reviews.json when a test
  # staged one (the re-triggered Approver superseding the stale rejection).
  cat > "$FAKE_GH" <<EOF
#!/usr/bin/env bash
sub="\$2"   # 'view' | 'comment' | 'update-branch'
case "\$sub" in
  view)
    if printf '%s ' "\$@" | grep -q statusCheckRollup; then
      if [ "\${GH_ERROR:-}" = "1" ]; then echo "HTTP 401: Bad credentials" >&2; exit 1; fi
      n=\$(cat "$BATS_TEST_TMPDIR/poll-count" 2>/dev/null || echo 0); n=\$((n+1))
      printf %s "\$n" > "$BATS_TEST_TMPDIR/poll-count"
      f="$BATS_TEST_TMPDIR/state.\$n"
      [ -f "\$f" ] || f="$BATS_TEST_TMPDIR/state.last"
      cat "\$f"; exit 0
    fi
    if printf '%s ' "\$@" | grep -q "headRefOid,reviews"; then
      cat "$BATS_TEST_TMPDIR/reviews.json"; exit 0
    fi
    if printf '%s ' "\$@" | grep -q reviewDecision; then
      if [ -s "$DECISION_FILE" ]; then cat "$DECISION_FILE"; else echo "\${GH_DECISION:-REVIEW_REQUIRED}"; fi
      exit 0
    fi
    exit 0 ;;
  comment)
    echo "approve" >> "$COMMENT_LOG"
    [ -n "\${GH_DECISION_AFTER:-}" ] && echo "\${GH_DECISION_AFTER}" > "$DECISION_FILE"
    if [ -f "$BATS_TEST_TMPDIR/reviews-after.json" ]; then
      cp "$BATS_TEST_TMPDIR/reviews-after.json" "$BATS_TEST_TMPDIR/reviews.json"
    fi
    exit 0 ;;
  update-branch)
    if [ "\${GH_UPDATE_CONFLICT:-}" = "1" ]; then echo "merge conflict" >&2; exit 1; fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$FAKE_GH"
}

# fast: no real sleeps, short windows. Script flags pass through "$@"; gh
# conditions are set by each test via `export GH_*` before calling.
cycle() { run zsh "$S" --timeout 5 --interval 0 --register-grace 0 "$@" 99; }

# state <N|last> <sha> <rollup-json> — script the Nth poll's atomic response.
state() { printf '{"headRefOid":"%s","statusCheckRollup":%s}' "$2" "$3" > "$BATS_TEST_TMPDIR/state.$1"; }

# Rollup fixtures: CheckRun conclusions + a legacy commit StatusContext, the
# two context shapes statusCheckRollup interleaves.
ROLLUP_GREEN='[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"b","state":"SUCCESS"}]'
ROLLUP_RED='[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"b","status":"COMPLETED","conclusion":"SUCCESS"}]'
ROLLUP_PENDING='[{"__typename":"CheckRun","name":"a","status":"IN_PROGRESS","conclusion":""}]'
# Required contexts pass, but the Approver gate's jobs are CANCELLED — the
# normal state of every Approver PR (the pull_request run is superseded by the
# check_suite run, #190). This must read as GREEN, not NOT-GREEN.
ROLLUP_GREEN_CANCELLED_APPROVER='[{"__typename":"CheckRun","name":"test-and-coverage","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"sonarcloud","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"approve","status":"COMPLETED","conclusion":"CANCELLED"},{"__typename":"CheckRun","name":"approver-gate","status":"COMPLETED","conclusion":"CANCELLED"}]'

green()   { state last sha1 "$ROLLUP_GREEN"; }
red()     { state last sha1 "$ROLLUP_RED"; }
pending() { state last sha1 "$ROLLUP_PENDING"; }
green_with_cancelled_approver() { state last sha1 "$ROLLUP_GREEN_CANCELLED_APPROVER"; }

# rejection_at <review-oid> [<file>] — a CHANGES_REQUESTED review pinned to
# <review-oid> on a PR whose head is sha1, as `--json headRefOid,reviews`
# returns it. Write to reviews-after.json to stage the post-/approve state.
rejection_at() {
  printf '{"headRefOid":"sha1","reviews":[{"state":"CHANGES_REQUESTED","commit":{"oid":"%s"},"submittedAt":"2026-07-03T06:00:00Z"}]}' \
    "$1" > "$BATS_TEST_TMPDIR/${2:-reviews.json}"
}

@test "usage: missing pr -> exit 2" {
  run zsh "$S"
  [ "$status" -eq 2 ]
}

@test "usage: non-numeric pr -> exit 2" {
  run zsh "$S" not-a-number
  [ "$status" -eq 2 ]
}

@test "usage: unknown flag -> exit 2" {
  run zsh "$S" --nope 99
  [ "$status" -eq 2 ]
}

@test "green + already APPROVED -> READY (exit 0), no re-trigger posted" {
  green; export GH_DECISION=APPROVED
  cycle
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "result: READY"
  [ ! -s "$COMMENT_LOG" ]   # never commented
}

@test "green + REVIEW_REQUIRED, no --retrigger -> AWAITING-APPROVAL (exit 4)" {
  green; export GH_DECISION=REVIEW_REQUIRED
  cycle
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "result: AWAITING-APPROVAL"
  [ ! -s "$COMMENT_LOG" ]
}

@test "green + CHANGES_REQUESTED at the current head -> CHANGES-REQUESTED (exit 5), does not spin" {
  green; rejection_at sha1; export GH_DECISION=CHANGES_REQUESTED
  cycle
  [ "$status" -eq 5 ]
  echo "$output" | grep -q "result: CHANGES-REQUESTED"
}

@test "#523 rejection at the current head stays terminal even with --retrigger (no /approve wasted)" {
  green; rejection_at sha1; export GH_DECISION=CHANGES_REQUESTED
  cycle --retrigger
  [ "$status" -eq 5 ]
  echo "$output" | grep -q "result: CHANGES-REQUESTED"
  [ ! -s "$COMMENT_LOG" ]
}

@test "#523 stale changes-requested (superseded head), no --retrigger -> AWAITING-APPROVAL (exit 4) with stale note" {
  # A request-changes review survives branch updates (only approvals get
  # auto-dismissed on push), so reviewDecision alone can carry a rejection of a
  # long-gone commit. That is re-review territory, not a terminal verdict.
  green; rejection_at 0ld5ha0000000000; export GH_DECISION=CHANGES_REQUESTED
  cycle
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "result: AWAITING-APPROVAL"
  echo "$output" | grep -qi "stale changes-requested"
  echo "$output" | grep -q "0ld5ha000000"   # names the superseded commit (12 chars)
}

@test "#523 stale changes-requested + --retrigger -> /approve fires, fresh approval supersedes -> READY" {
  # The money path: the stale rejection must not block the re-trigger; the
  # fresh Approver review at the new head supersedes it and the PR is READY.
  green; rejection_at 0ld5ha0000000000
  export GH_DECISION=CHANGES_REQUESTED GH_DECISION_AFTER=APPROVED
  cycle --retrigger
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "result: READY"
  [ "$(wc -l < "$COMMENT_LOG")" -eq 1 ]
}

@test "#523 stale + --retrigger, Approver re-rejects at the NEW head -> exit 5 (genuine, surfaced)" {
  green; rejection_at 0ld5ha0000000000
  rejection_at sha1 reviews-after.json    # the re-review rejects the current head
  export GH_DECISION=CHANGES_REQUESTED    # decision stays CHANGES_REQUESTED throughout
  cycle --retrigger
  [ "$status" -eq 5 ]
  echo "$output" | grep -q "result: CHANGES-REQUESTED"
  [ "$(wc -l < "$COMMENT_LOG")" -eq 1 ]
}

@test "#523 the LATEST rejection decides staleness (old stale + newer current-head one -> exit 5)" {
  green; export GH_DECISION=CHANGES_REQUESTED
  printf '%s' '{"headRefOid":"sha1","reviews":[
    {"state":"CHANGES_REQUESTED","commit":{"oid":"sha1"},"submittedAt":"2026-07-03T07:00:00Z"},
    {"state":"CHANGES_REQUESTED","commit":{"oid":"0ld5ha0000000000"},"submittedAt":"2026-07-03T05:00:00Z"}
  ]}' > "$BATS_TEST_TMPDIR/reviews.json"
  cycle
  [ "$status" -eq 5 ]
  echo "$output" | grep -q "result: CHANGES-REQUESTED"
}

@test "red checks -> NOT-GREEN (exit 6), approval never consulted" {
  red; export GH_DECISION=APPROVED
  cycle
  [ "$status" -eq 6 ]
  echo "$output" | grep -q "result: NOT-GREEN"
}

@test "failing legacy StatusContext -> NOT-GREEN (exit 6)" {
  state last sha1 '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"sonar","state":"ERROR"}]'
  export GH_DECISION=APPROVED
  cycle
  [ "$status" -eq 6 ]
  echo "$output" | grep -q "result: NOT-GREEN"
}

@test "cancelled Approver-gate jobs are not failures -> green, reaches approval (exit 4)" {
  # Regression for the tick-client-snapper run: required contexts all pass but
  # the approve/approver-gate jobs are CANCELLED by design. The helper must NOT
  # count cancelled runs as failures (else it exits 6 NOT-GREEN before the
  # /approve re-trigger ever fires). With no --retrigger it reaches the approval
  # gate and reports AWAITING-APPROVAL.
  green_with_cancelled_approver; export GH_DECISION=REVIEW_REQUIRED
  cycle
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "result: AWAITING-APPROVAL"
}

@test "cancelled Approver-gate jobs + --retrigger -> posts /approve, approval lands -> READY" {
  # The whole point of the fix: a green PR whose only non-pass checks are the
  # cancelled Approver jobs must be allowed to reach (and fire) the re-trigger.
  green_with_cancelled_approver; export GH_DECISION=REVIEW_REQUIRED GH_DECISION_AFTER=APPROVED
  cycle --retrigger
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "result: READY"
  [ "$(wc -l < "$COMMENT_LOG")" -eq 1 ]
}

@test "#521 STALE runs of a superseded suite are neutral, never failed" {
  # After a rebase GitHub marks the superseded suite's runs STALE (or CANCELLED).
  # Neither conclusion is a failure — only FAILURE/TIMED_OUT/ACTION_REQUIRED/
  # STARTUP_FAILURE (and StatusContext FAILURE/ERROR) flip the verdict.
  state last sha1 '[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"old-suite","status":"COMPLETED","conclusion":"STALE"},{"__typename":"CheckRun","name":"old-approve","status":"COMPLETED","conclusion":"CANCELLED"}]'
  export GH_DECISION=APPROVED
  cycle
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "result: READY"
}

@test "#521 a wait iteration before settle must not corrupt the verdict (pending -> green -> READY)" {
  # THE observed bug: progress lines went to stdout, which the caller captures
  # as the verdict — so any poll that printed "waiting:" before the checks
  # settled made a green PR read NOT-GREEN (exit 6).
  state 1 sha1 "$ROLLUP_PENDING"
  state last sha1 "$ROLLUP_GREEN"
  export GH_DECISION=APPROVED
  cycle
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "result: READY"
}

@test "#521 head SHA moves mid-wait, new suite registers and greens -> READY, not NOT-GREEN" {
  # The full trace from the four tick-client-snapper occurrences: a rebase or
  # update-branch lands mid-wait ("head SHA moved … restarting wait."), the new
  # SHA's set is briefly empty (register grace), then settles all green. Every
  # one of those must end READY — never "NOT-GREEN — a required check failed".
  state 1 sha1 "$ROLLUP_PENDING"
  state 2 sha2 '[]'
  state last sha2 "$ROLLUP_GREEN"
  export GH_DECISION=APPROVED
  run zsh "$S" --timeout 5 --interval 0 --register-grace 5 99
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "head SHA moved (sha1 -> sha2)"
  echo "$output" | grep -q "result: READY"
}

@test "pending + timeout -> TIMED-OUT (exit 3)" {
  pending
  run zsh "$S" --timeout 0 --interval 0 --register-grace 5 99
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "result: TIMED-OUT"
}

@test "#431 re-trigger after settle, approval then lands -> READY, exactly one /approve" {
  green; export GH_DECISION=REVIEW_REQUIRED GH_DECISION_AFTER=APPROVED
  cycle --retrigger
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "result: READY"
  [ "$(wc -l < "$COMMENT_LOG")" -eq 1 ]   # re-triggered exactly ONCE
}

@test "--retrigger but Approver still won't approve -> AWAITING-APPROVAL, re-triggered once only" {
  green; export GH_DECISION=REVIEW_REQUIRED    # no GH_DECISION_AFTER: stays REVIEW_REQUIRED
  cycle --retrigger
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "result: AWAITING-APPROVAL"
  [ "$(wc -l < "$COMMENT_LOG")" -eq 1 ]   # exactly one re-trigger, never spins
}

@test "no checks on PR -> treated as green, decides on approval" {
  state last sha1 '[]'
  export GH_DECISION=APPROVED
  cycle
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "result: READY"
}

@test "gh auth error during settle -> exit 1" {
  green; export GH_ERROR=1
  cycle
  [ "$status" -eq 1 ]
}

@test "--update on a conflicting branch -> NOT-GREEN (exit 6), needs a human" {
  green; export GH_UPDATE_CONFLICT=1
  cycle --update
  [ "$status" -eq 6 ]
  echo "$output" | grep -q "merge conflict"
}

@test "--update clean then green + APPROVED -> READY" {
  green; export GH_DECISION=APPROVED
  cycle --update
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "result: READY"
}
