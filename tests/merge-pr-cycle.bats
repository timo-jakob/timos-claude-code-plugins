#!/usr/bin/env bats
#
# Behavioral tests for merge-pr-cycle.zsh (#431): the blessed merge-cycle
# helper that replaces the improvised background loops which carried two real
# bugs on the tick-client-snapper run —
#   (1) judging "settled" before the head SHA's checks had registered, and
#   (2) a zsh `$new:refs` refspec mangling from forcing fresh SHAs.
# This helper waits for checks to *register* before settling, and re-triggers
# the Approver via a `/approve` comment (no push, no refspec) — so both bug
# classes are gone by construction. Drives the script against a FAKE gh (the
# GH_BIN seam) so every exit path is deterministic.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/maintenance/scripts/merge-pr-cycle.zsh"
  CHECKS="$BATS_TEST_TMPDIR/checks.json"
  DECISION_FILE="$BATS_TEST_TMPDIR/decision"   # updated by `gh pr comment`
  COMMENT_LOG="$BATS_TEST_TMPDIR/comments"      # records /approve re-triggers
  FAKE_GH="$BATS_TEST_TMPDIR/gh"
  : > "$COMMENT_LOG"
  export GH_BIN="$FAKE_GH"

  # Fake gh dispatches on the subcommand. Env toggles drive the conditions:
  #   GH_HEAD_SHA       head SHA from `pr view --json headRefOid` (default sha1)
  #   GH_DECISION       initial reviewDecision (default REVIEW_REQUIRED)
  #   GH_DECISION_AFTER reviewDecision written by `pr comment` (re-trigger flips it)
  #   GH_NOCHECKS=1     `pr checks` reports "no checks reported"
  #   GH_ERROR=1        `pr checks` fails with an auth error
  #   GH_UPDATE_CONFLICT=1  `pr update-branch` reports a merge conflict
  cat > "$FAKE_GH" <<EOF
#!/usr/bin/env bash
sub="\$2"   # 'view' | 'checks' | 'comment' | 'update-branch'
case "\$sub" in
  view)
    if printf '%s ' "\$@" | grep -q headRefOid; then
      echo "\${GH_HEAD_SHA:-sha1}"; exit 0
    fi
    if printf '%s ' "\$@" | grep -q reviewDecision; then
      if [ -s "$DECISION_FILE" ]; then cat "$DECISION_FILE"; else echo "\${GH_DECISION:-REVIEW_REQUIRED}"; fi
      exit 0
    fi
    exit 0 ;;
  checks)
    if [ "\${GH_NOCHECKS:-}" = "1" ]; then echo "no checks reported on the 'main' branch" >&2; exit 8; fi
    if [ "\${GH_ERROR:-}" = "1" ]; then echo "HTTP 401: Bad credentials" >&2; exit 1; fi
    cat "$CHECKS"; exit 0 ;;
  comment)
    echo "approve" >> "$COMMENT_LOG"
    [ -n "\${GH_DECISION_AFTER:-}" ] && echo "\${GH_DECISION_AFTER}" > "$DECISION_FILE"
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

green() { printf '[{"name":"a","state":"SUCCESS","bucket":"pass"},{"name":"b","state":"SUCCESS","bucket":"pass"}]' > "$CHECKS"; }
red()   { printf '[{"name":"a","state":"FAILURE","bucket":"fail"},{"name":"b","state":"SUCCESS","bucket":"pass"}]' > "$CHECKS"; }
pending(){ printf '[{"name":"a","state":"IN_PROGRESS","bucket":"pending"}]' > "$CHECKS"; }

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

@test "green + CHANGES_REQUESTED -> CHANGES-REQUESTED (exit 5), does not spin" {
  green; export GH_DECISION=CHANGES_REQUESTED
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
  : > "$CHECKS"; export GH_NOCHECKS=1 GH_DECISION=APPROVED
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
