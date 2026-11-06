#!/usr/bin/env bats
#
# Blockers first in a human-started resolve-issue run (#2941).
#
# On a §0a shape (i) rejection, a run a human started takes remediation's
# "resolve the dependency AND the named issue" without asking, in either session
# mode. Its root clears the open blockers deepest-first, one step and one merged
# PR each, re-verifies with the precheck and then builds the named issue. The
# first blocker that cannot finish stops the whole run with one
# "blockers first stopped:" comment and the blocked label. A pipeline-started
# run is unchanged (#583).
#
# The procedure lives in its own shard, reference/interactive/blockers-first.md.
# remediation.md's moved span is byte-frozen, so the exception is stated in a
# paragraph after its closing marker; the span's hash is pinned below. Prose
# pins are anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/development/skills/resolve-issue"
  SKILL="$SKILL_DIR/SKILL.md"
  REM="$SKILL_DIR/reference/interactive/remediation.md"
  BF="$SKILL_DIR/reference/interactive/blockers-first.md"
  STEPS="$SKILL_DIR/reference/chain-steps.md"
  ASK="$SKILL_DIR/reference/ask-branches.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
}

# A text on one line, whitespace squeezed, so a wrapped phrase matches.
flat() { tr '\n' ' ' | tr -s ' '; }

# The blockers-first shard, flattened.
bf() { flat < "$BF"; }

# One numbered step of the procedure, flattened.
bf_step() {
  awk -v n="$1" '
    $0 ~ "^" n "\\. " { s = 1; print; next }
    s && /^[0-9]+\. / { exit }
    s { print }' "$BF" | flat
}

# The frozen moved span, markers included.
span() {
  awk '/<!-- moved: interactive-remediation -->/ { f = 1 } f { print } /<!-- \/moved: interactive-remediation -->/ { exit }' "$REM"
}

# remediation.md after the frozen span's closing marker, flattened.
after_span() {
  awk 'f { print } /<!-- \/moved: interactive-remediation -->/ { f = 1 }' "$REM" | flat
}

@test "AC10: the frozen moved span is byte-unchanged" {
  run --separate-stderr bash -c "$(declare -f span); REM='$REM'; span | shasum -a 256 | cut -d' ' -f1"
  [ "$status" -eq 0 ]
  [ "$output" = "38d0e84f127fb1ae85e18bb64e86f57e449928b4dcd39cab65d629c7a4142aa7" ]
}

@test "AC10: remediation.md states the exception after the closing marker and points at the shard" {
  t="$(after_span)"
  contains "$t" "**A human-started run never puts this offer (#2941).** In a run whose origin is \`human\` (§0a), whatever its session mode, a shape (i) rejection of the named issue takes option 1 above without asking"
  contains "$t" "The span is frozen, so the exception is stated here."
  contains "$t" "see \`reference/interactive/blockers-first.md\` § Blockers first in a human-started run (#2941)"
  run grep -qx '## Blockers first in a human-started run (#2941)' "$BF"
  [ "$status" -eq 0 ]
}

@test "AC1/AC10: a human-started run takes option 1 without asking, in either mode" {
  t="$(bf)"
  contains "$t" "In a run whose origin is \`human\` (§0a), whatever session mode \`scripts/resolve-session.zsh\` reports, a shape (i) rejection of the named issue takes remediation's option 1"
  contains "$t" "and never puts the choice to the human"
}

@test "AC9: a pipeline-started run posts, labels blocked and stops (#583)" {
  contains "$(bf)" "A pipeline-started run is unchanged: it posts \`comment_md\`, applies the \`blocked\` label and stops, as #583 requires."
  contains "$(after_span)" "A pipeline-started run is unchanged: it posts \`comment_md\`, applies the \`blocked\` label and stops, as #583 requires"
  run grep -qF 'Never auto-chain' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "who runs it: the root, on a blocked step, with BLOCKERS_FIRST=1 in the named issue's and every blocker's brief" {
  t="$(bf)"
  contains "$t" "The root runs this procedure when the named issue's step ends \`blocked\` (\`reference/chain-steps.md\` § The issue step (#2940))."
  contains "$t" "The root puts \`BLOCKERS_FIRST=1\` in the brief of the named issue's step and of every blocker step, and never in an E3 child's."
  contains "$t" "A step whose brief names it posts nothing and applies no label on a §0a rejection, so every comment and label this procedure needs is posted once, by the root, in step 6."
  contains "$t" "Every comment goes to the named issue, whatever the target."
}

@test "AC1: blockers clear deepest-first, each re-entering at its own §0a, Epic flow for a confirmed epic" {
  s="$(bf_step 3)"
  contains "$s" "Take the open entries of \`blockers\`, deepest \`depth\` first, and clear each one in turn, skipping one an earlier recursion already cleared."
  contains "$s" "A confirmed epic-kind blocker runs the Epic flow, and it is cleared only when the epic is closed: an Epic flow that ends with the epic still open stops the run (step 6)."
  contains "$s" "A blocker whose checkbox refs are only criteria takes the single-issue step."
  contains "$s" "an issue step with \`start_at\` \`\"0a\"\`, so the blocker re-enters at its own §0a"
  contains "$s" "Its handoff's \`chained_from\` is the blocker itself, so it parks and chains as a single-issue entry, never by E3's terminal (c)."
}

@test "a blocker with blockers of its own recurses and is built once, by the recursion's step 5" {
  s="$(bf_step 3)"
  contains "$s" "\`blocked\` → the blocker has open blockers of its own. Run this procedure from step 1 with the blocker as the target."
  contains "$s" "Its step 5 builds the blocker, so the blocker is cleared when that run ends: never dispatch its step a second time."
  contains "$(bf)" "The procedure works on a **target**: the named issue at first, and a blocker whose own step ended \`blocked\` when step 3 recurses."
}

@test "AC1/AC8: each blocker merges before the next branches; it advances only under auto-merge or override=on" {
  contains "$(bf_step 3)" "\`done\` → wait for its PR to merge (step 4); the blocker is then cleared."
  s="$(bf_step 4)"
  contains "$s" "Merge each blocker before the next one branches."
  contains "$s" "In an Approver repo, armed auto-merge merges it on green."
  contains "$s" "\`plugin-approver-override.zsh\` reports \`override=on\`, the step's §6 approves and advances it"
  contains "$s" "In both cases, wait for the PR as §6's approve-and-advance arm waits: \`await-pr-checks.zsh <pr>\`, then at most 30 re-reads of \`gh pr view <pr> --json state,autoMergeRequest\`, one a minute, until it reads \`MERGED\`."
  contains "$s" "Anywhere else, or when the wait ends unmerged, stop the run (step 6) with the reason that blocker PR #P is ready and awaits a human merge."
  contains "$s" "Re-running \`/development:resolve-issue\` on the named issue resumes the chain"
}

@test "AC2: an unready blocker goes through #2940's chained refinement, and every verdict has a path" {
  s="$(bf_step 3)"
  contains "$s" "\`needs-refinement\` → #2940's chained refinement step on the blocker."
  contains "$s" "Its \`ready\` dispatches the blocker's step again with \`start_at\` \`\"1\"\`"
  contains "$s" "its \`split\` makes the blocker a confirmed epic, which runs the Epic flow"
  contains "$s" "its \`questions-pending\` takes the relay; any other verdict stops the run (step 6)."
}

@test "AC3: the post-chain precheck must return PROCEED, and a second rejection stops without a second chain" {
  s="$(bf_step 5)"
  contains "$s" "Once every blocker from step 3 is cleared, run the precheck on the target again; exit 1 or 2 is handled as in step 1."
  contains "$s" "On \`PROCEED\`, dispatch the target's step with \`start_at\` \`\"0a\"\`: it re-runs §0a, clears the stale \`blocked\` label and builds the target"
  contains "$s" "A rejection here, or a \`blocked\` verdict from that step, stops the run (step 6). Never clear the chain a second time, because that loop has no bound."
}

@test "AC4: a cycle, a shape (ii) rejection and an open foreign blocker stop before anything is built" {
  s="$(bf_step 2)"
  contains "$s" "A \`REJECT_CYCLE\`, a shape (ii) rejection, and any \`foreign_blockers\` entry with \`open: true\` stop the run (step 6) before any blocker is built."
  contains "$s" "The open foreign blocker stops it even when open local blockers exist"
  contains "$s" "The stop names the cycle, the cause \`comment_md\` names, or the foreign ref."
}

@test "AC5: an unconfirmable epic-kind or unclassifiable blocker is a root gap question in both modes" {
  s="$(bf_step 3)"
  contains "$s" "An epic-kind blocker you cannot confirm, or a blocker you cannot classify, is a gap question."
  contains "$s" "The root asks the human, in both session modes, with AskUserQuestion: two options, *the Epic flow* and *the single-issue flow*, naming the blocker and what you could not judge."
  contains "$s" "The run waits for the answer and then takes the step picked. Declining both stops the run (step 6)."
}

@test "AC5: a near-miss blocker stops and names native sub-issues or a '- [ ] #N' rewrite" {
  contains "$(bf_step 3)" "A near-miss blocker stops the run (step 6), and the reason names the fix it needs: native sub-issues or a \`- [ ] #N\` rewrite."
}

@test "AC6: a blocker step that does not finish stops the named issue's run at once" {
  contains "$(bf_step 3)" "\`stopped\` → stop the run (step 6)."
  s="$(bf_step 6)"
  contains "$s" "it starts no further blocker step and does not build the named issue"
  contains "$s" "A stopped blocker keeps whatever its own run posted, and its own record keeps its own outcome."
}

@test "AC7: every stop posts one comment with a current comment_md, creates and applies the label" {
  s="$(bf_step 6)"
  contains "$s" "Every stop posts one comment and applies the label."
  contains "$s" "in either session mode"
  contains "$s" "Run the precheck on the named issue once more for a current \`comment_md\`, since earlier ones still list blockers this run merged."
  contains "$s" "On its exit 1 or 2 the comment carries no \`comment_md\`."
  contains "$s" "except after a precheck failure, which applies no label, as §0a applies none on those exits"
  contains "$s" "gh label create blocked --color b60205"
  contains "$s" "printf '%s\\n' \"\$COMMENT_MD\"; } | gh issue comment <N> --body-file -"
  contains "$s" "gh issue edit <N> --add-label blocked"
  contains "$s" "The named issue's own record is the one its first step emitted, with outcome \`precheck-parked\` (\`reference/telemetry.md\` step 4, the row for a rung that failed, halted or paused)."
  contains "$s" "No new outcome or field is added."
}

@test "AC7: the stop comment's body renders the prefix, the merged list and comment_md, in that order" {
  # The documented block with its gh calls cut off: what is left is the brace
  # group that writes the comment body.
  body="$(awk '/```bash/ { b = 1; next } b && /```/ { exit } b' "$BF" |
    sed -e 's/ | gh issue comment <N> --body-file -$//' -e '/^ *gh issue edit /d' \
      -e '/^ *gh label create /,/|| true$/d')"
  contains "$body" "printf '%s\\n' \"\$COMMENT_MD\"; }"
  body="${body//<the stopping blocker, or the foreign ref>/#7}"
  body="${body//<the reason>/its CI will not go green}"
  body="${body//<#PR, #PR …, or none>/#11}"
  run bash -c "COMMENT_MD='**Rejected** — #7 is open.'; $body"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' 'blockers first stopped: #7 — its CI will not go green' 'Merged in this run: #11' '' '**Rejected** — #7 is open.')"
  [ "$output" = "$expected" ]
}

@test "precheck failures: exit 2 is re-run once; exit 1 or a second 2 stops with 'precheck failed'" {
  s="$(bf_step 1)"
  contains "$s" "Run \`dependency-precheck.zsh\` on the target yourself."
  contains "$s" "\`PROCEED\` (a blocker closed meanwhile) goes straight to step 5."
  contains "$s" "Exit 2 is your own malformed call: fix it and re-run once. Exit 1, or a second 2, stops the run (step 6) with the reason \`precheck failed\`."
}

@test "chain-steps.md: the brief's BLOCKERS_FIRST=1 line, the blocked arm, and the blocker's role" {
  t="$(flat < "$STEPS")"
  contains "$t" "When this brief names BLOCKERS_FIRST=1, a §0a rejection posts no comment and applies no label: write verdict blocked and end, since the root posts (#2941)."
  contains "$t" "on the named issue's step, or a blocker's, the root runs the blockers-first procedure. The root puts \`BLOCKERS_FIRST=1\` in the brief of the named issue's first step and of every blocker step"
  contains "$t" "see \`reference/interactive/blockers-first.md\` § Blockers first in a human-started run (#2941)"
  contains "$t" "An E3 child's brief never names that line"
  contains "$t" "A blocker step's \`chained_from\` is the blocker itself (#2941)."
  contains "$t" "the single-issue entry, the E3 child and a blocker (#2941)"
  run grep -qF 'until #2941 lands' "$STEPS"
  [ "$status" -eq 1 ]
}

@test "AC10: SKILL.md §0a points a human-started run at the shard, keyed on BLOCKERS_FIRST=1" {
  t="$(flat < "$SKILL")"
  contains "$t" "human-started run (#2941), in either mode, takes \`reference/interactive/blockers-first.md\` and never asks:"
  contains "$t" "A step whose brief names \`BLOCKERS_FIRST=1\` is the exception (#2941): it posts nothing and ends \`blocked\` for its root."
}

@test "AC10: ARCHITECTURE.md's Issue-dependency model states the human-started exception" {
  t="$(awk '/^## Issue-dependency model \(#583\)/ { f = 1 } f && /^## Epic→child model/ { exit } f' "$ARCH" | flat)"
  contains "$t" "**A human-started run is the exception (#2941)**: whatever its session mode, it takes *resolve blocker + named issue* without asking."
  contains "$t" "Its root clears the chain deepest-first, one step per blocker, and builds the named issue after a re-verified \`PROCEED\`."
  contains "$t" "it stops the whole run with one \`blockers first stopped:\` comment and the \`blocked\` label (\`reference/interactive/blockers-first.md\`)"
}

@test "AC10: ask-branches.md's RS-02, RS-03 and RS-04 rows state the human-started exception" {
  run grep -F '| RS-02 | SKILL.md |' "$ASK"
  contains "$output" 'retired by #2941'
  run grep -F '| RS-02 | reference/interactive/blockers-first.md |' "$ASK"
  contains "$output" '`never puts the choice to the human`'
  run grep -F '| RS-03 | reference/interactive/blockers-first.md |' "$ASK"
  contains "$output" 'in a human-started run the root asks it in both session modes and waits (#2941)'
  run grep -F '| RS-04 | reference/interactive/remediation.md |' "$ASK"
  contains "$output" 'in a human-started run a near-miss blocker stops the run naming its fix'
}

@test "the interactive index lists the shard" {
  contains "$(flat < "$SKILL_DIR/reference/interactive.md")" "\`reference/interactive/blockers-first.md\` — \`## Blockers first\`: the root's procedure that replaces the offer in a human-started run (#2941)."
}

@test "AC11: both docs pages describe blockers first" {
  run grep -qF 'blockers first stopped:' "$REPO_ROOT/docs/explanation/workflow-resolve-issue.md"
  [ "$status" -eq 0 ]
  run grep -qF 'blockers first stopped:' "$REPO_ROOT/docs/how-to/run-resolve-issue-unattended.md"
  [ "$status" -eq 0 ]
}

@test "the self-check's sentences, each pinned verbatim" {
  b="$(bf)"
  contains "$b" '`PROCEED` (a blocker closed meanwhile) goes straight to step'
  contains "$b" 'Exit 1, or a second 2, stops the run (step 6) with the reason `precheck failed`.'
  contains "$b" '`blocked` → the blocker has open blockers of its own.'
  contains "$b" 'A rejection here, or a `blocked` verdict from that step, stops the run (step 6).'
  contains "$b" 'Never clear the chain a second time, because that loop has no bound.'
  r="$(after_span)"
  contains "$r" '**A human-started run never puts this offer (#2941).**'
  contains "$r" 'In a run whose origin is `human` (§0a), whatever its session mode, a shape (i) rejection of the named issue takes option 1 above without asking, and its root clears the chain by the blockers-first procedure.'
  contains "$(flat < "$STEPS")" 'That step skips §0a and §0b, carries `risk` from the `ready` verdict, and records `dependency_precheck: PROCEED` and `gate_verdict: READY`.'
  contains "$(flat < "$SKILL_DIR/reference/interactive.md")" 'It is split into shards under `reference/interactive/`, each at most 20,000 bytes (#2058).'
}
