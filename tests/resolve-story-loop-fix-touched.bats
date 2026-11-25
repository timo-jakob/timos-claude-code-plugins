#!/usr/bin/env bats
#
# The fix-touched capture and residue-shaped runs (#1435, #1571, #2580), in hook
# mode and in step mode (the snapshot/diff pair), the review-scope path rule they
# share, and the loop-state exclusions.
#
# One of the resolve-story-loop.zsh suites #3085 split by concern; the shared
# setup, the omniscient-panel wrapper and the helpers more than one suite uses
# are tests/resolve-story-loop-fixture.bash.

bats_require_minimum_version 1.5.0
load assertions
load resolve-story-loop-fixture

setup_file() { loop_fixture_setup_file "$BATS_TEST_DIRNAME/../development/skills/resolve-issue/scripts/resolve-story-loop.zsh"; }
setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  loop_fixture_setup
}
teardown() { loop_fixture_teardown; }

# --- #1435: the fix-touched capture, and residue-shaped runs (#2580) ---------
#
# #1435 added CONVERGED_WITH_RESIDUE (exit 14) here: a zero-CRITICAL window on a
# full sweep opened the PR with non-critical blockers still open. #2580 retired
# it, so every residue-shaped run below ends 12 or 13 like any other
# non-converging run, and the fix-touched capture #1435 built for it stays,
# feeding the `class` stamp.
#
# The fixtures below share one shape, defined once so a half-applied edit cannot
# make the positive and negative cases exercise different things: `touched.py`
# exists BEFORE the loop starts (so a round-1 finding in it survives
# scope-findings, which scopes against the story diff), and every fix pass
# rewrites it — making `touched.py` the fix-touched set from round 1 onward,
# while `app.py` stays a file no fix pass ever wrote.
residue_setup() {
  echo "v0" > "$R/touched.py"
}

# a WARNING (never a CRITICAL) in $1, with a per-round title so consecutive
# rounds are neither byte-identical (#974) nor read as one carried blocker (#983)
residue_review() {  # $1 = file
  printf '%s' 'printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"'"$1"'\",\"line\":$((REVIEW_ROUND*100)),\"title\":\"round $REVIEW_ROUND unquoted expansion\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"'
}

residue_fix='echo "v$REVIEW_ROUND" > "$REVIEW_REPO/touched.py"'

# a review hook that records each round's scope mode in $1/mode-r<N>.txt, then
# writes $2 (a review-cmd body) — so a test can assert which round was a FULL
# sweep, the shape #1435 required before it would declare exit 14
scoped_review() {  # $1 = snapshot dir, $2 = review-cmd body
  printf '%s' 'printf "%s" "$REVIEW_SCOPE_MODE" > "'"$1"'/mode-r$REVIEW_ROUND.txt"; '"$2"
}

@test "#2580 AC1 a residue-shaped run whose closing FULL sweep is at the ceiling ends BUDGET_EXHAUSTED (13), never 14" {
  residue_setup
  # The exact shape the retired CONVERGED_WITH_RESIDUE (exit 14) shipped: the
  # last two rounds are zero-CRITICAL, the closing round is a FULL sweep, and a
  # non-critical blocker remains. Round 1 raises a WARNING; round 2, a delta
  # round, finds nothing and so promotes the closing sweep under the one-round
  # grant; round 3, the sweep, raises a fresh WARNING at the ceiling.
  local SNAP="$BATS_TEST_TMPDIR/snap"
  mkdir -p "$SNAP"
  # the body is held in a variable: a literal `{…,…}` inside "$( … '…' )" is
  # brace-expanded by bash and splits the argument
  local body='if [ "$REVIEW_ROUND" = 2 ]; then printf "[]" > "$REVIEW_FINDINGS"; else printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":$((REVIEW_ROUND*100)),\"title\":\"round $REVIEW_ROUND unquoted expansion\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; fi'
  loop --max-rounds 2 --review-cmd "$(scoped_review "$SNAP" "$body")" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  # the fixture really is residue-shaped: three rounds, the last a FULL sweep,
  # zero CRITICAL in the last two, blockers left
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(cat "$SNAP/mode-r2.txt")" = "delta" ]
  [ "$(cat "$SNAP/mode-r3.txt")" = "full" ]
  echo "$output" | jq -e '[.round_changelists[1:][].summary.critical] == [0, 0]' >/dev/null
  echo "$output" | jq -e '.final_changelist.summary.blocking > 0' >/dev/null
  # ...and it routes to the escalation shard, never to the residue branch
  [ "$(echo "$output" | jq -r '.next_ref')" = "reference/escalation.md" ]
  grep -q '^\*\*Final:\*\* BUDGET_EXHAUSTED' "$BATS_TEST_TMPDIR/wd/progress.md"
  run ! grep -q 'CONVERGED_WITH_RESIDUE' "$BATS_TEST_TMPDIR/wd/progress.md"
}

@test "#2580 AC1 a residue-shaped FULL round with a non-converging blocker ends ESCALATE_NO_CONVERGENCE (12), never 14" {
  residue_setup
  # The non-converging rung of the same shape. The fix hook changes nothing, so
  # round 2's delta is empty and, carrying round 1's blocker, it runs as a FULL
  # sweep; the same WARNING at the same line makes it non-converging. Both rounds
  # are zero-CRITICAL — the round the retired residue rung turned into exit 14.
  local SNAP="$BATS_TEST_TMPDIR/snap"
  mkdir -p "$SNAP"
  local body='printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":10,\"title\":\"unquoted expansion in the matcher\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"'
  loop --max-rounds 5 --review-cmd "$(scoped_review "$SNAP" "$body")" --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(cat "$SNAP/mode-r2.txt")" = "full" ]
  echo "$output" | jq -e '[.round_changelists[].summary.critical] == [0, 0]' >/dev/null
  echo "$output" | jq -e '.final_changelist.non_converging == true' >/dev/null
  # escalation_reasons carries the reason again: nothing relabels it
  echo "$output" | jq -e '.escalation_reasons == ["non_converging_blocker"]' >/dev/null
  echo "$output" | jq -e '.residue_replaced_reasons == []' >/dev/null
  [ "$(echo "$output" | jq -r '.next_ref')" = "reference/escalation.md" ]
  grep -q '^\*\*Final:\*\* ESCALATE_NO_CONVERGENCE — non_converging_blocker' "$BATS_TEST_TMPDIR/wd/progress.md"
  run ! grep -q 'residue replaced' "$BATS_TEST_TMPDIR/wd/progress.md"
}

@test "#1435 residue_replaced_reasons is ALWAYS present, and [] since #2580" {
  residue_setup
  # Nothing replaces an escalation since #2580, so the key is always `[]` — but
  # it stays present, so a consumer never has to tell [] from an older status.
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  echo "$output" | jq -e '.residue_replaced_reasons == []' >/dev/null
  clean_loop
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.residue_replaced_reasons == []' >/dev/null
}

@test "#2580 AC2 hook mode: a residue-shaped DELTA round at the non-converging rung ends 12 and promotes no sweep" {
  residue_setup
  # The SAME title every round, so round 2 stamps non_converging. Round 2 is a
  # DELTA round (the fix pass moved touched.py) with both rounds zero-CRITICAL —
  # the round that, under #1435, promoted the closing sweep instead of ending.
  # Since #2580 it ends like any other non-converging round.
  loop --max-rounds 5 \
    --review-cmd 'printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":10,\"title\":\"unquoted expansion in the matcher\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq -r '.rounds')" = "2" ]
  echo "$output" | jq -e '.final_changelist.non_converging == true' >/dev/null
  echo "$output" | jq -e '[.round_changelists[].summary.critical] == [0, 0]' >/dev/null
  # no closing sweep was promoted, and the trail says nothing about one
  [ ! -e "$BATS_TEST_TMPDIR/wd/.closing-sweep" ]
  echo "$output" | jq -e '.closing_sweep_granted == false' >/dev/null
  run ! grep -q 'promoting round' "$BATS_TEST_TMPDIR/wd/progress.md"
}

@test "#1571 a mixed round's fix-touched split survives as a class stamp" {
  residue_setup
  # The fix-touched split must reach the changelist as `class`, because the
  # progress histogram and the grant decision read it. The class assertion is
  # the whole point; the exit code is scaffolding — 13, since #2580 retired the
  # residue terminal that used to ship this round. Both blockers are in the
  # story diff (`scope-findings` would have dropped either otherwise).
  loop --max-rounds 2 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":200,\"title\":\"round 2 unquoted expansion\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":300,\"title\":\"round 2 stale cache never invalidated\",\"description\":\"d3\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  # the round really is MIXED, or this pins nothing a single blocker would not
  [ "$(jq '.blocking | length' "$BATS_TEST_TMPDIR/wd/changelist-2.json")" -eq 2 ]
  [ "$(jq -r '[.blocking[].class] | sort | join(",")' "$BATS_TEST_TMPDIR/wd/changelist-2.json")" = "incomplete_propagation,new_defect" ]
}

@test "#1435 tc-error-conflict-still-escalates: a surviving conflict still exits 11 under residue conditions" {
  residue_setup
  # Round 2 carries an opposed pair at one location in touched.py, so the
  # residue conditions hold (zero CRITICALs both rounds) and the conflict rung
  # must still win — no automated ending can
  # pick between two opposed recommendations.
  loop --max-rounds 3 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"performance\",\"file\":\"touched.py\",\"line\":200,\"title\":\"hoist the allocation\",\"description\":\"d\",\"reviewer\":\"p\"},{\"severity\":\"WARNING\",\"dimension\":\"code_quality\",\"file\":\"touched.py\",\"line\":200,\"title\":\"keep the helper readable\",\"description\":\"d\",\"reviewer\":\"q\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 11 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_CONFLICT" ]
}

@test "#1435 AC3: zero blockers still exits CONVERGED (0) even with a fix-touched set on disk" {
  residue_setup
  # round 1 finds a fix-touched blocker, round 2 finds nothing: the zero-blocker
  # arm is evaluated FIRST, so it promotes the closing sweep and converges —
  # residue never pre-empts it.
  loop --max-rounds 4 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "[]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
}

@test "#1435 tc-corner-round1-unreachable: --max-rounds 1 exits 13, never 14" {
  residue_setup
  # Zero CRITICALs and a blocker in the story diff — every surface condition of
  # residue except the one round 1 structurally cannot meet: there is no second
  # changelist, so the two-round zero-CRITICAL window cannot exist. (Before #1571
  # it also failed for want of a previous fix pass to attribute the blocker to;
  # that half went with condition 2, and the round-1 guard survives on this one.)
  loop --max-rounds 1 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ ! -e "$BATS_TEST_TMPDIR/wd/fix-touched-0.txt" ]
}

@test "#1435 AC5 hook mode: fix-touched-N.txt lists exactly what the fix pass created and modified" {
  residue_setup
  echo "tracked" > "$R/lib.zsh"
  git -C "$R" add lib.zsh
  git -C "$R" commit -qm lib
  # --max-rounds 2, not 1: the fix hook runs only on a round that CONTINUES, so
  # a single-round run captures nothing at all. Round 2 then exits 13 at the
  # ceiling. The set this test pins is purely the `class` input — no verdict
  # reads it (#1571, #2580).
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'echo modified >> "$REVIEW_REPO/lib.zsh"; echo new > "$REVIEW_REPO/created.zsh"'
  [ "$status" -eq 13 ]
  # sorted, repo-relative, and nothing else: not the loop's own state, not the
  # findings sink, not README.md
  [ "$(cat "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt")" = "created.zsh
lib.zsh" ]
}

@test "#1435 AC5 hook mode: a fix confined to .review/ or .claude/telemetry/ yields an EMPTY set" {
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'mkdir -p "$REVIEW_REPO/.review" "$REVIEW_REPO/.claude/telemetry"; echo x > "$REVIEW_REPO/.review/scratch.json"; echo y > "$REVIEW_REPO/.claude/telemetry/telemetry.jsonl"'
  [ "$status" -eq 13 ]
  # present but empty — "the fix pass touched nothing REVIEWABLE" is a real
  # answer, and a distinct one from "no capture ran" (no file at all)
  [ -f "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt" ]
  [ ! -s "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt" ]
}

@test "#1571 an empty fix-touched set classes every blocker new_defect" {
  residue_setup
  # The fix pass only ever writes under .review/, so nothing reviewable is ever
  # attributable to it and the set comes out EMPTY. The exclusion list is
  # load-bearing for the CLASS, which is what the last assertion pins.
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'mkdir -p "$REVIEW_REPO/.review"; echo x > "$REVIEW_REPO/.review/scratch.json"'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(jq -r '[.blocking[].class] | join(",")' "$BATS_TEST_TMPDIR/wd/changelist-2.json")" = "new_defect" ]
}

@test "#1435 tc-corner-history-line-no-residue-key: the per-round history line gains NO residue key" {
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  H="$BATS_TEST_TMPDIR/wd/history.jsonl"
  # the five pre-existing keys are all still there...
  jq -es 'all(.[]; has("round") and has("blocking") and has("conflicts")
                   and has("non_converging") and has("false_trips"))' "$H" >/dev/null
  # ...alongside the key sibling #1973 legitimately adds to the same line, which
  # is exactly why this is a negative on the residue keys and NOT a closed-key-set
  # assertion (#1463). (#1434's drop count left the line with #3169.)
  jq -es 'all(.[]; has("gate") and (has("adjudicated_dropped") | not))' "$H" >/dev/null
  # ...and nothing residue-derived joined them. A REGEX FAMILY over the key
  # names, not a guess-list of four literals: a fifth spelling (`residue_class`,
  # `fix_touched_files`, `by_class`) would slip straight through a closed list,
  # which is the rot this repo has already paid for once. Still not a closed KEY
  # SET, which #1463 rules out — a sibling may legitimately add its own key.
  jq -es 'all(.[]; [keys[] | select(test("residue|fix.?touched|class"))] | length == 0)' "$H" >/dev/null
}

@test "#1435 the history-line regex family really catches a residue-derived key" {
  # Non-vacuity for the negative above: a regex nobody can trip passes forever.
  # Each spelling the family is meant to cover is shown to red on a probe line.
  local probe="$BATS_TEST_TMPDIR/history-probe.jsonl"
  local k
  for k in class fix_touched fix-touched residue_class residue_blocking by_class; do
    jq -nc --arg k "$k" '{round:1, blocking:0, conflicts:0, non_converging:false,
                          false_trips:0, gate:null} + {($k): 1}' > "$probe"
    # the family assertion must FAIL on a probe carrying the key — asserted on
    # jq's own exit rather than through `run !`, so the message names the key
    jq -es 'all(.[]; [keys[] | select(test("residue|fix.?touched|class"))] | length == 0)' \
      "$probe" >/dev/null && { echo "family missed the key: $k"; return 1; }
  done
  # ...and it does NOT red on the six legitimate keys, so it is a filter and not
  # a blanket refusal
  jq -nc '{round:1, blocking:0, conflicts:0, non_converging:false,
           false_trips:0, gate:null}' > "$probe"
  jq -es 'all(.[]; [keys[] | select(test("residue|fix.?touched|class"))] | length == 0)' "$probe" >/dev/null
}

@test "#2580 outcome mapping: a residue-shaped run's record is escalated BUDGET_EXHAUSTED, never a success" {
  residue_setup
  T="$BATS_TEST_TMPDIR/residue.jsonl"
  loop --max-rounds 2 --telemetry-file "$T" --issue 2580 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  # the retired CONVERGED_WITH_RESIDUE record was a `success`; the same run is
  # now an escalation, and its record says which
  assert_envelope "$T" escalated BUDGET_EXHAUSTED
  jq -es 'all(.[]; .payload.escalation == "BUDGET_EXHAUSTED")' "$T" >/dev/null
  # ...and the per-round class histogram still rides along (round 1 has no
  # fix-touched set to classify against, hence null)
  jq -es 'all(.[]; (.payload.findings_by_round[0].by_class == null) and (.payload.findings_by_round[1].by_class.incomplete_propagation == 1))' "$T" >/dev/null
}

@test "#1435 a failed tree identity leaves NO fix-touched set, says so, and does not fail the run" {
  residue_setup
  # A stub that is real git EXCEPT for `diff-tree`, which is the one call the
  # capture makes on its own. Pointing the seam at a missing binary instead would
  # also break git-tree-id.zsh — which mints the identities the whole round needs
  # — and abort the run at round 1 for an unrelated reason, testing nothing about
  # this arm. review-dispatch reads GIT_BIN for its own delta, and passes that
  # down to git-tree-id.zsh, so its scope computation is unaffected.
  #
  # The rule under test is fail-CLOSED-but-not-fatal: no set on disk (so no
  # blocker is stamped from a guess), a named diagnostic (so a round whose
  # by-class row is dark is distinguishable from one whose fix pass genuinely
  # touched nothing), and a run that still reaches its terminal. No verdict reads
  # the set (#1571, #2580), so the terminal is the ordinary ceiling exit.
  GITSTUB="$BATS_TEST_TMPDIR/git-no-difftree"
  cat > "$GITSTUB" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "diff-tree" ]; then
    echo "stub: diff-tree refused" >&2
    exit 1
  fi
done
exec git "$@"
STUB_EOF
  chmod +x "$GITSTUB"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$GITSTUB" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-nogit" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  # the run is NOT aborted by the capture failure — it reaches a real terminal
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  # ...leaving no set, so no blocker could be classed from a stale one
  [ ! -e "$BATS_TEST_TMPDIR/wd-nogit/fix-touched-1.txt" ]
  # ...and it said which arm failed, rather than going dark
  contains "$stderr" "fix-touched set (#1435)"
  # The diagnostic names the consequence that is REAL: a dark class row. It once
  # promised a residue consequence, and no residue verdict exists since #2580.
  contains "$stderr" "will carry no class"
  contains "$stderr" "no verdict reads the set"
  lacks "$stderr" "residue"
}

@test "#1435 each capture failure names ITS OWN arm, so an operator can tell which went dark" {
  residue_setup
  # The three arms print three distinct diagnostics precisely so a round whose
  # class stamps went dark for a capture failure is distinguishable from one
  # whose fix pass touched nothing — and from each other. A shared tail cannot establish that;
  # each needle here is arm-unique.
  #
  # The stub is counter-keyed, because both identities in a round are minted by
  # the same binary: failing the Nth call is the only way to reach one arm
  # without also breaking the round's own tree-id (which aborts at exit 1).
  local CTR="$BATS_TEST_TMPDIR/mint-count"
  _mk_counting_stub() {  # $1 = 1-based call number to fail on
    printf '0' > "$CTR"
    cat > "$BATS_TEST_TMPDIR/git-nth" <<STUB_EOF
#!/usr/bin/env bash
# only WRITE-TREE calls are counted: that is the last step of a mint, so
# failing the Nth of them fails exactly the Nth identity
for a in "\$@"; do
  if [ "\$a" = "write-tree" ]; then
    n=\$(( \$(cat "$CTR") + 1 ))
    printf '%s' "\$n" > "$CTR"
    if [ "\$n" = "$1" ]; then exit 1; fi
  fi
done
exec git "\$@"
STUB_EOF
    chmod +x "$BATS_TEST_TMPDIR/git-nth"
  }

  # Round 1 mints, in order: (1) the round's own tree identity, (2) the cadence
  # guard's re-read of the working tree (#1435 §10), (3) the hook-mode pre-fix
  # stamp, (4) the post-fix identity inside the capture. Failing #3 empties
  # `fix_base_tree`; failing #4 empties `cur`. (#2 is deliberately absent from
  # the arms below: the cadence guard is silent when it cannot mint an identity,
  # by the same fail-quiet rule as every other missing-state path here — losing
  # the detection, never the run.)
  _mk_counting_stub 3
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$BATS_TEST_TMPDIR/git-nth" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-arm2" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  contains "$stderr" "no pre-fix tree identity for round 1"
  [ ! -e "$BATS_TEST_TMPDIR/wd-arm2/fix-touched-1.txt" ]

  _mk_counting_stub 4
  run --separate-stderr env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$BATS_TEST_TMPDIR/git-nth" \
    zsh "$S" --repo "$R" --base main --work-dir "$BATS_TEST_TMPDIR/wd-arm3" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  contains "$stderr" "could not compute the post-fix tree identity for round 1"
  [ ! -e "$BATS_TEST_TMPDIR/wd-arm3/fix-touched-1.txt" ]
}

@test "#1435 a capture failure CLEARS any stale set, so no blocker is classed from a previous round's" {
  residue_setup
  # The `rm -f` at the top of the capture is what makes the fail-closed promise
  # absolute rather than likely: without it a set left by an earlier round could
  # be read as this round's.
  WD4="$BATS_TEST_TMPDIR/wd-stale"
  mkdir -p "$WD4"
  printf 'planted-stale.py\n' > "$WD4/fix-touched-1.txt"
  GITSTUB2="$BATS_TEST_TMPDIR/git-no-dt2"
  cat > "$GITSTUB2" <<'STUB_EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "diff-tree" ]; then exit 1; fi
done
exec git "$@"
STUB_EOF
  chmod +x "$GITSTUB2"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    GIT_TREE_ID_BIN="$GITSTUB2" \
    zsh "$S" --repo "$R" --base main --work-dir "$WD4" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ ! -e "$WD4/fix-touched-1.txt" ]
}

@test "#1435 every tree identity is minted through the ONE bridged helper" {
  # `GIT_TREE_ID_BIN` is one name in two scopes: this script reads it as a shell
  # parameter, git-tree-id.zsh only as an exported env var. `_tree_id` sets it on
  # the invocation so both halves of every comparison provably run one binary. A
  # future call site that invokes $TREE_ID directly would silently reopen that,
  # and no behavioural test can see it (a caller that exports the seam works
  # either way) — so the invariant is pinned structurally.
  grep -q 'GIT_TREE_ID_BIN="\${GIT_TREE_ID_BIN:-git}" "\$TREE_ID"' "$LOOP_REAL"
  # exactly two mentions of "$TREE_ID" as a command: the helper body and the
  # `-x` executability guard beside the gate attestation
  [ "$(grep -c '"\$TREE_ID"' "$LOOP_REAL")" -eq 2 ]
  # ...and every mint goes through the helper
  [ "$(grep -c '_tree_id "\$repo"' "$LOOP_REAL")" -eq 7 ]
}

@test "#1435 the fix-touched set and the review scope share ONE path rule" {
  # _capture_fix_touched hand-copies review-dispatch.zsh's _normalise_paths, and
  # the header calls the two "deliberately identical". A one-sided edit would
  # make the `class` stamp and the review scope disagree about the same file,
  # whose only symptom is a blocker misclassified `new_defect` and a by-class
  # row nobody can trust. Pin the copies against each other rather than trusting
  # the comment.
  D="$REPO_ROOT/development/skills/resolve-issue/scripts/review-dispatch.zsh"
  # the ./-strip, the two artifact exclusions and the blank-line drop, in both
  for needle in "sed -E 's#^\./##'" \
                "\\#^\\.review/#d" \
                "\\#^\\.claude/telemetry/#d" \
                "/^\$/d"; do
    grep -qF -- "$needle" "$LOOP_REAL" || { echo "loop lost the path rule: $needle"; return 1; }
    grep -qF -- "$needle" "$D" || { echo "dispatch lost the path rule: $needle"; return 1; }
  done
  # ...and the quotePath flag both need so a non-ASCII path is spelled the same
  # way on both sides (#1435).
  #
  # EXACT counts, not `-ge`: dispatch has EIGHT git invocations that list paths
  # (`diff --name-only`, the `--others` listing of untracked files, the delta
  # `diff-tree`, the #2011 hunk `diff-tree -p`, and the four `diff-tree` calls
  # that build the #2009 contract selector's inputs), and a tolerance below
  # that let any ONE of them lose the flag with this test still green — while
  # that one invocation then
  # C-quotes a non-ASCII path and the two sides stop agreeing about the same
  # file. The counts here are LINE counts and each script mentions the flag in
  # a comment above its call sites, hence 8 calls + 3 comments in dispatch, 1
  # call + 1 comment in the loop. The behavioural pin is the test below; this
  # one localises a deletion to the line that lost it.
  [ "$(grep -cF -- 'core.quotePath=false' "$LOOP_REAL")" -eq 3 ]
  [ "$(grep -cF -- 'core.quotePath=false' "$D")" -eq 11 ]
}

@test "#1435 a NON-ASCII path is spelled identically in the review scope and the fix-touched set" {
  # The behavioural half of the pin above. git's default `core.quotePath=true`
  # renders `café.zsh` as the C-quoted, DOUBLE-QUOTE-WRAPPED `"caf\303\251.zsh"`.
  # If either side keeps that default, the review scope and the fix-touched set
  # carry two different spellings of one file — so `consolidate-findings
  # --fix-touched` finds no match, a blocker the fix pass just wrote is classed
  # `new_defect` instead of `incomplete_propagation` — silently mis-stamping
  # every `class` for a repo with a non-ASCII filename.
  # seeded like residue_setup, but with the non-ASCII name the flag is about
  printf 'v0\n' > "$R/café.py"
  local WD="$BATS_TEST_TMPDIR/wd"
  loop --max-rounds 2 --review-cmd "$(residue_review café.py)" \
       --fix-cmd 'echo "v$REVIEW_ROUND" > "$REVIEW_REPO/café.py"'

  # the fix-touched set carries the PLAIN spelling — no backslash escapes, no
  # wrapping double quotes
  [ -f "$WD/fix-touched-1.txt" ]
  grep -qxF 'café.py' "$WD/fix-touched-1.txt"
  run ! grep -q '303' "$WD/fix-touched-1.txt"
  run ! grep -q '^"' "$WD/fix-touched-1.txt"

  # ...and the classification agrees, which is the consequence that matters: the
  # round-2 blocker sits in the file round 1's fix pass wrote, so it is
  # incomplete_propagation and NOT new_defect
  [ "$(jq -r '.blocking[0].class' "$WD/changelist-2.json")" = "incomplete_propagation" ]
  [ "$(jq -r '.blocking[0].file' "$WD/changelist-2.json")" = "café.py" ]
}

@test "#1435 an ESCALATING round stamps its pre-fix tree too, so a granted round is still classified" {
  residue_setup
  # §3.5 step 5 requires a fix pass BEFORE the resume a grant buys, so a fix pass
  # really does follow an escalation. Without a stamp there its touched set is
  # unrecoverable and the round after the grant carries no class at all — the
  # histogram the grant decision reads, dark one round after the grant was spent.
  WD3="$BATS_TEST_TMPDIR/wd-escalate"
  # the SAME blocker every round trips non-convergence at round 2
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD3" --max-rounds 5 \
    --review-cmd 'printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":10,\"title\":\"unquoted expansion in the matcher\",\"description\":\"d$REVIEW_ROUND\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 12 ]
  [ "$(echo "$output" | jq -r '.status')" = "ESCALATE_NO_CONVERGENCE" ]
  # the escalating round left the stamp a granted resume needs
  [ -s "$WD3/fix-base-2.txt" ]
}

@test "#1435 the stamp covers every GRANTABLE terminal — and not the one a grant cannot resume" {
  residue_setup
  # Three-of-four membership, not presence alone. BUDGET_EXHAUSTED is the other
  # terminal the interactive extension can grant from, so dropping it leaves a
  # granted resume with no base to diff and the class histogram dark exactly one
  # round after the grant was spent.
  WD5="$BATS_TEST_TMPDIR/wd-budget-stamp"
  # (A CRITICAL in round 1 once kept this fixture off the residue terminal,
  # retired by #2580; it is kept so the fixture is unchanged.)
  loop --max-rounds 2 --work-dir "$WD5" \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"app.py\",\"line\":10,\"title\":\"round 1 null dereference\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"tests\",\"file\":\"app.py\",\"line\":900,\"title\":\"missing pipefail on download\",\"description\":\"d2\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ -s "$WD5/fix-base-2.txt" ]

  # ESCALATE_CONFLICT IS in the list, on the same reasoning: the interactive
  # extension covers it too, a human picks the winner, and a fix pass follows the
  # grant — so without a stamp that round is consolidated with no `--fix-touched`
  # at all, stamping no `class` and blanking the histogram on the round after a
  # grant was spent — which is when it is most wanted. (This test previously
  # asserted the opposite, on the mistaken premise that no grant resumes from a
  # conflict.)
  WD6="$BATS_TEST_TMPDIR/wd-conflict-stamp"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD6" --max-rounds 3 \
    --review-cmd 'printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"performance\",\"file\":\"touched.py\",\"line\":200,\"title\":\"hoist the allocation\",\"description\":\"d\",\"reviewer\":\"p\"},{\"severity\":\"WARNING\",\"dimension\":\"code_quality\",\"file\":\"touched.py\",\"line\":200,\"title\":\"keep the helper readable\",\"description\":\"d\",\"reviewer\":\"q\"}]" > "$REVIEW_FINDINGS"' \
    --fix-cmd 'true'
  [ "$status" -eq 11 ]
  [ -s "$WD6/fix-base-1.txt" ]

  # ESCALATE_AMBIGUOUS remains OUT, and for a different reason — `emit_ambiguous`
  # exits before the round produces any findings to classify, so a stamp would
  # serve nothing. That exclusion is what keeps this a membership test rather
  # than "stamp everything".
  run ! grep -qE 'ESCALATE_AMBIGUOUS' <<< "$(sed -n '/pre-fix tree identity/,/^  fi$/p' "$LOOP_REAL")"
}

@test "#1435 a fresh (non---resume) run clears a previous run's fix-touched state" {
  residue_setup
  WD2="$BATS_TEST_TMPDIR/wd-reuse"
  # run 1 goes three rounds, so it leaves BOTH fix-touched-1 and fix-touched-2
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD2" --max-rounds 3 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ -s "$WD2/fix-touched-1.txt" ]
  [ -s "$WD2/fix-touched-2.txt" ]
  # run 2 re-uses the work-dir WITHOUT --resume and stops at round 2, so it
  # never writes a fix-touched-2 of its own. Run 1's must be gone: left behind,
  # it would attribute a later round's blockers to a fix pass from a different
  # run entirely, stamping `incomplete_propagation` against edits that are not
  # ours and corrupting the by-class histogram the grant decision reads.
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WD2" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" --fix-cmd 'true'
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ ! -e "$WD2/fix-touched-2.txt" ]
}

@test "#1435 AC5 hook mode: a REPO-INTERNAL work-dir is not charged to the fix pass" {
  # The loop mints its pre-fix identity AFTER the round writes its own
  # bookkeeping, precisely so a work-dir living inside the repo cannot make the
  # loop's changelist/history/progress files look like the session's edits. The
  # exclusion list strips only `.review/` and `.claude/telemetry/`, so a work-dir
  # at any OTHER in-repo path is not filtered — the ordering is the only thing
  # protecting it, and a repo-internal work-dir is a supported configuration
  # used elsewhere in this very file.
  #
  # Every other #1435 test puts the work-dir outside the repo, where the
  # ordering cannot matter. Surviving mutation: hoist the `fix_base_tree`
  # assignment above the `append_progress_round` write of that same round. The
  # `_tree_id` occurrence count is unchanged, so the structural test stays
  # green, while `fix-touched-1.txt` silently grows `.loop-wd/changelist-1.json`,
  # `.loop-wd/history.jsonl` and `.loop-wd/progress.md` — inflating the set that
  # stamps `class`, on a side effect whose exact contents this AC pins.
  # (NB: no stray apostrophes in these comments — the inert-assertion scanner
  # tracks quote parity across lines and an odd one desyncs the whole scan.)
  residue_setup
  local IWD="$R/.loop-wd"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --max-rounds 2 \
    --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'echo modified >> "$REVIEW_REPO/lib.zsh"; echo new > "$REVIEW_REPO/created.zsh"'
  [ "$status" -eq 13 ]
  # the work-dir really is inside the repo, or this pins nothing
  [ -f "$IWD/changelist-1.json" ]
  # ...and the set is EXACTLY the two edits the fix hook made — the same
  # contents the outside-the-repo case above pins.
  #
  # Newlines folded to spaces so the expectation fits on ONE line. That is not
  # cosmetic: the repo inert-assertion scanner mis-tracks quote parity across a
  # two-line quoted literal, and the sibling tests only scan clean because an
  # EVEN number of such literals cancel out. Adding a third would desync the
  # scan and silently stop the rest of this file from being checked at all.
  [ "$(tr '\n' ' ' < "$IWD/fix-touched-1.txt")" = "created.zsh lib.zsh " ]
  # stated separately, because a future exclusion rule could strip the work-dir
  # by name and still leave the ordering broken for some other in-repo writer
  run ! grep -q '\.loop-wd' "$IWD/fix-touched-1.txt"
}

@test "#1435 HOOK mode: the fix-touched capture runs BEFORE --test-cmd too" {
  # The step-mode twin of this exists; the hook-mode call site had the same
  # ordering and no coverage, because no #1435 hook fixture ever passed a
  # --test-cmd and no --test-cmd test ever looked at fix-touched-N.txt.
  #
  # Surviving mutation: move the hook-mode `_capture_fix_touched` call below the
  # gate block. Every file the gate writes — a regenerated fixture, a formatter
  # run from a test, a coverage report — then joins the set and is attributed to
  # the fix pass, so a blocker in one is stamped `incomplete_propagation` instead
  # of `new_defect`. That is exactly the input the by-class histogram — and so the
  # grant decision — reads, and the whole suite stayed green through it.
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd "$residue_fix" \
    --test-cmd 'echo gate > "'"$R"'/gate-artifact.txt"'
  # the gate really wrote it, or the absence below proves nothing
  [ -f "$R/gate-artifact.txt" ]
  # ...and the set is exactly the fix pass, with no gate artifact in it
  [ "$(cat "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt")" = "touched.py" ]
}

@test "#1435 an OUTSIDE-the-repo work-dir excludes NOTHING, even on a basename collision" {
  # The documented normal configuration, and the direction no test covered: every
  # outside fixture uses a work-dir named `wd`/`wd2`/... and no fixture repo has a
  # directory of that name, so an OVER-BROAD rule was invisible.
  #
  # Surviving mutation: replace the whole prefix computation with an
  # unconditional `wd_rel="${work_dir:t}/"` (just the basename). Every
  # repo-internal test still passes — the basename IS the right prefix there —
  # and every outside test still passes, because nothing collides. In production
  # it silently deletes every fix-pass edit under any repo directory whose name
  # matches the work-dir basename (`--work-dir /tmp/tests`, `$TMPDIR/src`), so
  # those blockers are classed `new_defect` on evidence nobody produced, and the
  # class histogram the grant decision reads is confidently wrong.
  #
  # So: force the collision. The work-dir is OUTSIDE the repo and named `wd`,
  # and the repo has a tracked `wd/` directory the fix hook edits.
  # the colliding directory is committed FIRST, so the story's own uncommitted
  # edits (touched.py) stay in the review scope — committing after residue_setup
  # would sweep them into main and the round would converge with nothing to fix
  mkdir -p "$R/wd"
  echo tracked > "$R/wd/keep.zsh"
  git -C "$R" add -A
  git -C "$R" commit -qm wd
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" \
    --fix-cmd 'echo modified >> "$REVIEW_REPO/wd/keep.zsh"; echo "v$REVIEW_ROUND" > "$REVIEW_REPO/touched.py"'
  # the edit under the colliding directory IS in the set — an outside work-dir
  # excludes nothing
  grep -qxF 'wd/keep.zsh' "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt"
  # ...alongside the ordinary edit, so the set is not simply unfiltered garbage
  grep -qxF 'touched.py' "$BATS_TEST_TMPDIR/wd/fix-touched-1.txt"
}

# --- #1435 §9 / #2580: only a zero-blocker delta round promotes the sweep -----

@test "#2580 AC2 hook mode: a residue-shaped DELTA round at the ceiling ends 13 and promotes no sweep" {
  # Round 2 is the ceiling, a DELTA round, and residue-shaped (both rounds
  # zero-CRITICAL, a blocker left). #1435 §9 promoted round 3 to the closing
  # sweep here so that the sweep could declare exit 14; #2580 retired that
  # trigger, so the round ends on the ceiling like any other.
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  [ "$(echo "$output" | jq -r '.rounds')" = "2" ]
  echo "$output" | jq -e '[.round_changelists[].summary.critical] == [0, 0]' >/dev/null
  echo "$output" | jq -e '.closing_sweep_granted == false' >/dev/null
  [ ! -e "$BATS_TEST_TMPDIR/wd/.closing-sweep" ]
  run ! grep -q 'promoting round' "$BATS_TEST_TMPDIR/wd/progress.md"
}

@test "#1435 AC19 the zero-blocker promotion trigger is UNCHANGED (#1434 non-goal)" {
  # #2580 removed §9's second trigger; the first must be undisturbed. A delta
  # round that returns zero blockers still promotes the sweep exactly as
  # before, and the sweep still converges.
  residue_setup
  loop --max-rounds 3 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "[]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  grep -q 'no blockers in the delta' "$BATS_TEST_TMPDIR/wd/progress.md"
  [ "$(cat "$BATS_TEST_TMPDIR/wd/.closing-sweep")" = "3" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
}


@test "#1435 §10 HOOK mode: a --review-cmd that rewrites the tree is refused by the per-round stamp" {
  # The stamp arm of the cadence guard, which no test reached: every AC21 case
  # attests via --findings-tree, and in step mode the early call refuses first,
  # so this branch ran but never refused. Surviving mutation: return early unless
  # the source is the attested one — hook mode then loses cadence detection
  # entirely and a panel that rewrites the tree mid-round is consumed as if its
  # findings described the tree the loop is looking at.
  residue_setup
  loop --max-rounds 2 \
    --review-cmd 'printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"r1\",\"description\":\"d\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"; echo mutated > "$REVIEW_REPO/app.py"' \
    --fix-cmd 'true'
  [ "$status" -eq 2 ]
  # `loop` merges stderr into $output, and the refusal writes its diagnostic
  # there BEFORE the status JSON — so assert on the durable artifacts and on the
  # emitted status string rather than parsing the stream as JSON.
  echo "$output" | grep -q '"status":"STALE_FINDINGS"'
  # the message names THIS arm, so an operator can tell which source refused
  grep -q "this round's recorded dispatch tree" "$BATS_TEST_TMPDIR/wd/progress.md"
  grep -q 'app.py' "$BATS_TEST_TMPDIR/wd/progress.md"
}

@test "#1435 §10 HOOK mode non-vacuity: a panel that writes ONLY its findings sink is fine" {
  # Pins the guard to REVIEWABLE files. The panel writes $REVIEW_FINDINGS on
  # every healthy round and that moves the raw tree identity, so a guard keyed on
  # bare inequality would refuse every hook-mode run ever — which is how the
  # first draft of this check behaved.
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix"
  [ "$status" -ne 2 ]
  [ "$(echo "$output" | jq -r '.status')" != "STALE_FINDINGS" ]
}

@test "#1435 §10 --findings-tree is refused in HOOK mode, where one value cannot attest many rounds" {
  # It attests ONE round's panel; hook mode runs every round in a single
  # invocation. Left accepted, round 2 would be compared against round 1's
  # attestation — which round 1's own fix pass has legitimately moved — so every
  # multi-round hook run would be refused for a cadence mistake that did not
  # happen, and the per-round stamp that DOES cover hook mode would be displaced
  # by it.
  residue_setup
  loop --max-rounds 2 --review-cmd "$(residue_review touched.py)" --fix-cmd "$residue_fix" \
    --findings-tree deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'step-mode flag'
}

@test "#1435 §10 --findings-tree requires a value, and rejects a following flag" {
  # It is parsed with the STRICT value guard, not the --gate-attest exception:
  # there an empty value is fail-CLOSED (run the gate anyway), here it would be
  # fail-OPEN — the guard silently disarmed while the caller believes it is on.
  # The documented `PANEL_TREE=$(git-tree-id.zsh .)` has no error check and that
  # command prints nothing when it fails, so the empty value is a live slip.
  residue_setup
  loop --max-rounds 1 --review-cmd "$(residue_review touched.py)" --fix-cmd 'true' --findings-tree ""
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'requires a non-empty value'

  residue_setup
  loop --max-rounds 1 --review-cmd "$(residue_review touched.py)" --fix-cmd 'true' --findings-tree --resume
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'got the flag'
}

@test "#1571 the upstream rail holds AT THE LOOP: an out-of-diff blocker never reaches the changelist" {
  # `scope-findings` confines every round's findings to the story diff and
  # `$scoped` is the ONLY input to the changelist's `.blocking` — the guarantee
  # #1571 leaned on, and still the reason no blocker the loop reports (to the
  # fix pass, the dossier or an escalation) is in code this story never touched.
  # Nothing else tests that JOIN: tests/review-dispatch.bats pins the filter as a
  # unit, and every loop fixture files against app.py/touched.py, which are in
  # the story diff anyway. Mutation this closes: replace the loop's
  # `scope-findings` call with `cp "$findings_path" "$scoped"`.
  residue_setup
  # README.md is committed at base and never modified, so it is OUTSIDE the story
  # diff — unlike every other file these fixtures use.
  loop --max-rounds 2 \
    --review-cmd 'if [ "$REVIEW_ROUND" = 1 ]; then
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":100,\"title\":\"round 1 unquoted expansion\",\"description\":\"d1\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      else
        printf "%s" "[{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"touched.py\",\"line\":200,\"title\":\"round 2 unquoted expansion\",\"description\":\"d2\",\"reviewer\":\"r\"},{\"severity\":\"WARNING\",\"dimension\":\"bugs\",\"file\":\"README.md\",\"line\":1,\"title\":\"shipped behaviour this run never opened\",\"description\":\"d3\",\"reviewer\":\"r\"}]" > "$REVIEW_FINDINGS"
      fi' \
    --fix-cmd "$residue_fix"
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  # the run really did reach the terminal with blockers left...
  echo "$output" | jq -e '.final_changelist.summary.blocking > 0' >/dev/null
  # ...and the out-of-diff finding is NOT among them
  [ "$(echo "$output" | jq '[.final_changelist.blocking[] | select(.file == "README.md")] | length')" -eq 0 ]
  # non-vacuity: the IN-diff blocker of the same round did survive, so the
  # assertion above is the filter biting rather than an empty changelist
  [ "$(echo "$output" | jq '[.final_changelist.blocking[] | select(.file == "touched.py")] | length')" -eq 1 ]

  # ...and the claim is about EVERY round, not just the one that ends the run:
  # round 1 is the full round and round 2 a DELTA round, so assert it on both.
  [ "$(echo "$output" | jq '[.round_changelists[] | .blocking[]? | select(.file == "README.md")] | length')" -eq 0 ]
  [ "$(echo "$output" | jq '[.round_changelists[1].blocking[]? | select(.file == "touched.py")] | length')" -ge 1 ]
}

# --- #1435: residue and the step-mode fix-touched snapshot/diff pair ---------
#
# Step mode is the canonical wiring and the one where the capture is HARD: the
# fix pass happens between invocations, where the loop never observes it. So the
# set is stamped at AWAITING_FIX (`fix-base-<round>.txt`) and diffed at
# `--resume` start. Every case below drives that pair for real.
#
# `touched.py` exists before round 1 so a round-1 finding in it survives
# scope-findings (which scopes against the story diff); the in-session "fix" then
# rewrites it, making it the fix-touched set.

@test "#1435 tc-corner-fix-touched-step-mode: the AWAITING_FIX snapshot + --resume diff names only repo paths" {
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]
  # the SNAPSHOT half — written when the round handed the fix pass back to the
  # session, so the diff at --resume has something to diff against
  [ -s "$WD/fix-base-1.txt" ]
  [ ! -e "$WD/fix-touched-1.txt" ]

  # the in-session fix: one real edit, plus a write under .review/ that must NOT
  # be attributed to it
  echo "v1" > "$R/touched.py"
  mkdir -p "$R/.review"
  echo '[]' > "$R/.review/scratch.json"
  residue_findings 2 touched.py > "$F"
  step --resume --max-rounds 3
  [ "$status" -eq 20 ]
  # the DIFF half — exactly the session's edit, and nothing else
  [ "$(cat "$WD/fix-touched-1.txt")" = "touched.py" ]
}

@test "#2580 AC2 step mode: a residue-shaped DELTA round at the ceiling ends BUDGET_EXHAUSTED (13) and promotes no sweep" {
  # Rounds 1 and 2 are both zero-CRITICAL with a WARNING left, and round 2 is a
  # DELTA round at the ceiling — the shape that used to promote the closing sweep
  # so the retired residue terminal (exit 14) could be declared on it (#1435 §9).
  # #2580 retired both, so the round ends 13 like any other spent budget.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 2
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  step --resume --max-rounds 2
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  echo "$output" | jq -e '[.round_changelists[].summary.critical] == [0, 0]' >/dev/null
  echo "$output" | jq -e '.final_changelist.summary.blocking > 0' >/dev/null
  # no sweep was promoted and no grant taken
  [ ! -e "$WD/.closing-sweep" ]
  echo "$output" | jq -e '.closing_sweep_granted == false' >/dev/null
  [ "$(echo "$output" | jq -r '.next_ref')" = "reference/escalation.md" ]
  run ! grep -q 'residue conditions hold' "$WD/progress.md"
}

@test "#1435 step mode AC3: blockers with budget left still exit AWAITING_FIX (20), not 14" {
  # Round 2 satisfies BOTH residue conditions, but the ceiling is 3 — the loop
  # keeps FIXING while it has budget, and residue only ever replaces an ENDING.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  step --resume --max-rounds 3
  [ "$status" -eq 20 ]
  [ "$(echo "$output" | jq -r '.status')" = "AWAITING_FIX" ]
}

@test "#1435 tc-error-critical-in-window, step mode: a CRITICAL in the window exits 13, never 14" {
  echo "v0" > "$R/touched.py"
  printf '[{"severity":"CRITICAL","dimension":"bugs","file":"touched.py","line":100,"title":"round 1 null dereference","description":"d1","reviewer":"r"}]' > "$F"
  step --max-rounds 2
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  step --resume --max-rounds 2
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
}

@test "#1435 tc-error-critical-in-window, step mode: a CRITICAL in the FINAL round exits 13 too" {
  # The other half of the window, in the other wiring: with the CRITICAL only
  # ever in round 1, dropping the `c_cur == 0` half of the condition passes both
  # modes' cases.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 2
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  printf '[{"severity":"CRITICAL","dimension":"bugs","file":"touched.py","line":200,"title":"round 2 null dereference","description":"d2","reviewer":"r"}]' > "$F"
  step --resume --max-rounds 2
  [ "$status" -eq 13 ]
  [ "$(echo "$output" | jq -r '.status')" = "BUDGET_EXHAUSTED" ]
  echo "$output" | jq -e '.final_changelist.summary.critical == 1' >/dev/null
  # ...and the blocker really was fix-touched, so only the c_cur half refused it
  [ "$(cat "$WD/fix-touched-1.txt")" = "touched.py" ]
}

@test "#1571 step mode: a mixed round's fix-touched split survives as a class stamp" {
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]

  echo "v1" > "$R/touched.py"
  # one inside the fix-touched set, one outside it — both in the story diff. The
  # split must reach the changelist as `class`: the capture and its consumers
  # outlived the residue predicate that once also read it (#1571, #2580)
  printf '[{"severity":"WARNING","dimension":"bugs","file":"touched.py","line":200,"title":"round 2 unquoted expansion","description":"d2","reviewer":"r"},{"severity":"WARNING","dimension":"bugs","file":"app.py","line":300,"title":"round 2 stale cache never invalidated","description":"d3","reviewer":"r"}]' > "$F"
  step --resume --max-rounds 3
  [ "$status" -eq 20 ]
  # the round really is MIXED, or this pins nothing the single-blocker case did not
  [ "$(jq '.blocking | length' "$WD/changelist-2.json")" -eq 2 ]
  [ "$(jq -r '[.blocking[].class] | sort | join(",")' "$WD/changelist-2.json")" = "incomplete_propagation,new_defect" ]
}

@test "#1435 the fix-touched capture runs BEFORE --test-cmd, so a gate artifact is not the fix pass" {
  # The loop takes the capture before running the gate ON PURPOSE: a suite that
  # writes into the tree — a regenerated fixture, a formatter invoked from a
  # test, a coverage report — would otherwise land in the set as though the
  # session's fix pass had made the edit.
  #
  # No test combined `--test-cmd` with the residue fixtures, so the ordering was
  # free: move the capture block after the gate block and the whole suite stays
  # green, while every gate-written file joins fix-touched-N.txt. That is not
  # cosmetic — a blocker in such a file is then classed `incomplete_propagation`
  # rather than `new_defect` — and since #1571 `class` is reporting-only, so what
  # that corrupts is the by-class histogram the fix-pass rule and the grant
  # decision read, not the terminal itself.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3 --test-cmd 'true'
  [ "$status" -eq 20 ]

  # the in-session fix touches ONE file; the gate then writes a second one
  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  step --resume --max-rounds 3 --test-cmd 'echo gate > "'"$R"'/gate-artifact.txt"'
  [ "$status" -eq 20 ]
  # the gate really did write it, or the absence below proves nothing
  [ -f "$R/gate-artifact.txt" ]
  # ...and the set is exactly the fix pass's edit
  [ "$(cat "$WD/fix-touched-1.txt")" = "touched.py" ]
}

@test "#1571 step mode: an ABSENT fix-base stamp still clears a stale fix-touched set" {
  # When --resume finds no `fix-base-<round>.txt`, the loop cannot compute what
  # the fix pass touched, so no `class` may be stamped. It deletes any
  # `fix-touched-<round>.txt` sitting at that path to make that ABSOLUTE rather
  # than merely likely. Hook mode pins this; step mode did not.
  #
  # Surviving mutation: drop the `rm -f`. A stale set — from an earlier run, or
  # a reused scratch dir — is then consumed by `consolidate-findings
  # --fix-touched`, so blockers are classed against a fix pass that never ran in
  # this run.
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  step --max-rounds 3
  [ "$status" -eq 20 ]
  [ -s "$WD/fix-base-1.txt" ]

  # Simulate the lost stamp, and plant a stale set naming `app.py` — the story's
  # own in-scope file, which NO fix pass in this run touched. The round-2 blocker
  # below sits in that same file, so the planted set is exactly what would stamp
  # it `incomplete_propagation`. Honour the planted set and the blocker is
  # classed against a fix pass that never ran; clear it and no class is stamped
  # at all. That makes the assertion a real fork rather than a file-existence
  # check. (Before #1571 the fork was the residue VERDICT's; the predicate no
  # longer reads the set, so what the clear protects is the class.)
  #
  # `app.py`, not an invented name: a blocker in a file outside the round's scope
  # is dropped before the ladder is ever reached, so the run would end
  # AWAITING_FIX with zero blockers and prove nothing about the class.
  rm -f "$WD/fix-base-1.txt"
  printf 'app.py\n' > "$WD/fix-touched-1.txt"

  echo "v1" > "$R/touched.py"
  residue_findings 2 app.py > "$F"
  step --resume --max-rounds 3
  # the stale set is GONE, not merely ignored
  [ ! -e "$WD/fix-touched-1.txt" ]
  # What this protects is the CLASS: `consolidate-findings --fix-touched`
  # still reads the set (the residue predicate that once also did is retired,
  # #2580), so a planted set would
  # class this round's blockers against a fix pass that never ran in this run.
  # The clearing is therefore still load-bearing, for the CLASS.
  #
  # An ABSENT set is not an empty one: the loop omits `--fix-touched` entirely,
  # so NO item is stamped — which is exactly how a reader tells "no fix-touched
  # information" from "the fix pass touched nothing". Had the stale set been
  # honoured, this blocker would carry `incomplete_propagation` instead.
  [ "$(jq -r '[.blocking[] | .class // "unstamped"] | join(",")' "$WD/changelist-2.json")" = "unstamped" ]
  # an ordinary fix turn with budget left: nothing promotes a sweep (#2580)
  [ "$status" -eq 20 ]
  [ ! -e "$WD/.closing-sweep" ]
  # it really did still have the blocker, so this is a real round and not a zero
  echo "$output" | jq -e '.final_changelist.summary.blocking > 0' >/dev/null
}


@test "#1435 step mode: a REPO-INTERNAL work-dir is not charged to the fix pass either" {
  # The step-mode twin of the hook-mode AC5 variant. Step mode mints its pre-fix
  # snapshot at the AWAITING_FIX exit, AFTER the round writes its own
  # bookkeeping, for the same reason — and had no coverage: every #1435 step test
  # puts the work-dir outside the repo, where the ordering cannot matter.
  #
  # Surviving mutation: hoist the step-mode `fix_base_tree` mint above the
  # `append_progress_round` write. With a repo-internal work-dir the loop own
  # progress.md then lands in the diff computed at --resume, inflating the very
  # set that stamps `class`. The `_tree_id` occurrence count
  # is unchanged, so the structural pin does not see it.
  # (NB: no stray apostrophes in these comments — the inert-assertion scanner
  # tracks quote parity across lines and an odd one desyncs the whole scan.)
  local IWD="$R/.loop-wd"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --findings-file "$F" --max-rounds 3
  [ "$status" -eq 20 ]
  # the work-dir really is inside the repo, or this pins nothing
  [ -f "$IWD/changelist-1.json" ]

  # exactly ONE in-session edit
  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  # the diff is the session edit and nothing the loop wrote about itself
  [ "$(cat "$IWD/fix-touched-1.txt")" = "touched.py" ]
  run ! grep -q 'loop-wd' "$IWD/fix-touched-1.txt"
}


@test "#1435 the work-dir exclusion is COMPUTED, not a hardcoded .loop-wd" {
  # Both repo-internal fixtures so far name the work-dir `.loop-wd`, so nothing
  # tells a computed prefix from a constant. Surviving mutation: assign the
  # literal `.loop-wd`, or narrow the match to dot-prefixed names only. The whole
  # suite stays green while a repo-internal work-dir with any other name goes
  # back to leaking fix-base, history.jsonl and changelist-N.json into the set.
  #
  # So: a NESTED, NON-dot path, which no plausible hardcoding covers.
  # (NB: no stray apostrophes in these comments — the inert-assertion scanner
  # tracks quote parity across lines and an odd one desyncs the whole scan.)
  local IWD="$R/state/loopwd"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --findings-file "$F" --max-rounds 3
  [ "$status" -eq 20 ]
  [ -f "$IWD/changelist-1.json" ]

  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$IWD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  [ "$(cat "$IWD/fix-touched-1.txt")" = "touched.py" ]
  run ! grep -q 'state/' "$IWD/fix-touched-1.txt"
}

@test "#1435 the exclusion is about PATHS, not spellings: trailing slashes and dot segments" {
  # The loop never normalises --work-dir or --repo, and the two are compared
  # after `:A` resolution precisely so the caller can spell them however they
  # like. Surviving mutations without this: drop the `:A` on either side, or
  # drop the trailing-slash handling — a caller passing `--work-dir "$R/wd2/"`
  # or `--repo "$R/"` then matches nothing and the full leak returns silently,
  # with no diagnostic, because an empty prefix is indistinguishable from an
  # out-of-repo work-dir.
  local IWD="$R/./wd2/"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R/" --base main --work-dir "$IWD" --findings-file "$F" --max-rounds 3
  [ "$status" -eq 20 ]
  [ -f "$R/wd2/changelist-1.json" ]

  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$F"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R/" --base main --work-dir "$IWD" --findings-file "$F" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  [ "$(cat "$R/wd2/fix-touched-1.txt")" = "touched.py" ]
  run ! grep -q 'wd2' "$R/wd2/fix-touched-1.txt"
}

@test "#1435 a repo-internal --findings-file is excluded too, not just the work-dir" {
  # --status-file and --findings-file are caller-chosen and loop-written just
  # like the work-dir, and both are written AFTER the pre-fix identity is minted
  # — so an in-repo one lands in the resume diff as a file the session edited.
  # The work-dir-only exclusion missed them, and the docs invite exactly this
  # shape by telling callers where to put the work-dir and saying nothing about
  # the other two.
  local IF="$R/findings.json"
  local WDO="$BATS_TEST_TMPDIR/wd-ff"
  echo "v0" > "$R/touched.py"
  residue_findings 1 touched.py > "$IF"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDO" --findings-file "$IF" --max-rounds 3
  [ "$status" -eq 20 ]

  # the session edits ONE file; the loop then rewrites the in-repo findings file
  echo "v1" > "$R/touched.py"
  residue_findings 2 touched.py > "$IF"
  run env DETECT_STACK_BIN="$STUB" DETECT_LANGS_JSON='{"languages":["python"]}' \
    zsh "$S" --repo "$R" --base main --work-dir "$WDO" --findings-file "$IF" --resume --max-rounds 3
  [ "$status" -eq 20 ]
  [ "$(cat "$WDO/fix-touched-1.txt")" = "touched.py" ]
  run ! grep -q 'findings.json' "$WDO/fix-touched-1.txt"
}
