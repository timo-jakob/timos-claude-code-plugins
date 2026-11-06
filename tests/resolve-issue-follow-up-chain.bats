#!/usr/bin/env bats
#
# The chain queue in a human-started resolve-issue run (#2942).
#
# The root of a human-started run keeps one queue of pending issues — the named
# issue's blockers, the named issue and every follow-up through every
# generation — in chain-queue.json (scripts/chain-queue.zsh, pinned by
# tests/chain-queue.bats). These cases pin the prose rules in SKILL.md,
# reference/chain-steps.md and reference/checkpoint.md, anchored by content,
# never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level telemetry default stays out of the real ~/.claude (#1972)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/development/skills/resolve-issue"
  SKILL="$SKILL_DIR/SKILL.md"
  STEPS="$SKILL_DIR/reference/chain-steps.md"
  CP="$SKILL_DIR/reference/checkpoint.md"
  ASK="$SKILL_DIR/reference/ask-branches.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
}

flat() { tr '\n' ' ' | tr -s ' '; }

# The chain-queue section of checkpoint.md, flattened.
cq() {
  awk 'index($0, "## The chain queue in a human-started run (#2942)") == 1 { f = 1; print; next }
    f && /^## / { exit } f' "$CP" | flat
}

# One numbered step of that section, flattened.
cq_step() {
  awk -v n="$1" '
    index($0, "## The chain queue in a human-started run (#2942)") == 1 { f = 1; next }
    !f { next }
    f && /^## / { exit }
    $0 ~ "^" n "\\. " { s = 1; print; next }
    s && (/^[0-9]+\. / || /^\*\*One status line/) { exit }
    s { print }' "$CP" | flat
}

@test "AC10: only a human-started root keeps a queue; a pipeline-started run keeps §7 and writes none" {
  t="$(cq)"
  contains "$t" "**Only the root of a human-started run keeps a queue.**"
  contains "$t" "A pipeline-started run writes no queue file and keeps §7's \`refine-issue --follow-up\` call and its rule that a follow-up that parks never stops the run."
  contains "$t" "\`clean-stop.zsh clear\` keeps it, so an entry's own run never deletes it"
  contains "$t" "whose \`--repo-dir\` and \`--issue\` always name the **named** issue."
  contains "$t" "An exit 1 or 5 stops the run (step 5) and keeps the file; never re-add an entry under another kind."
}

@test "AC10: SKILL.md §7 limits the never-stops rule to a pipeline-started run" {
  contains "$(flat < "$SKILL")" "**A follow-up that parks never stops this run or its epic walk**, if pipeline-started (#2942): name it and go on."
}

@test "AC10: ARCHITECTURE.md's follow-up mode and RS-09 state the chained exception" {
  t="$(awk '/^### The unattended follow-up mode/ { f = 1 } f && /^- \*\*Eligibility/ { exit } f' "$ARCH" | flat)"
  contains "$t" "**A human-started chain is the exception (#2942):** its root queues each follow-up in the chain queue, refines it in the chained mode and resolves it, through every generation, and a park there stops the run"
  contains "$t" "A pipeline-started run keeps this mode and writes no queue file."
  run grep -F '| RS-09 | SKILL.md |' "$ASK"
  contains "$output" "in a human-started chain (#2942), follow-ups are queued, refined in chained mode and resolved instead"
}

@test "AC2: follow-ups are queued after the entry that filed it, an E3 child's included, with their finding identity" {
  s="$(cq_step 2)"
  contains "$s" "When any step's verdict lists \`follow_ups\`, an E3 child's included, \`add\` each one \`--kind follow-up --after <the entry that filed it>\` with \`--finding\`"
  contains "$s" "the \`finding\` of its follow-up-origin/v1 comment (\`follow-up-origin.zsh parse\`)"
  contains "$s" "\`add\` each one \`--kind blocker --depth <its depth>\`; a blocker of a later entry is added \`--before <that entry>\`."
}

@test "AC2: a follow-up is refined in chained mode, then built, and that replaces §7's call; steps skip §7's call" {
  s="$(cq_step 3)"
  contains "$s" "A follow-up is first refined in chained mode (#2939, #2940) by the chained refinement step, then built by the issue step, through every generation."
  contains "$s" "This replaces §7's \`refine-issue --follow-up\` call in a human-started run."
  t="$(flat < "$STEPS")"
  contains "$t" "Skip §7's refine-issue --follow-up call: list the follow-ups only, since the root queues them (#2942)."
  contains "$t" "How the root handles each, once it has queued the verdict's \`follow_ups\` in the chain queue (#2942), which replaces §7's \`refine-issue --follow-up\` call in a human-started run:"
  contains "$t" "see \`reference/checkpoint.md\` § The chain queue in a human-started run (#2942)"
}

@test "AC3: each PR merges before the next entry branches; a PR that cannot advance is a paused stop" {
  s="$(cq_step 3)"
  contains "$s" "Each entry's PR merges before the next entry branches off fresh main: record it with \`add --entry <I> --pr <P>\` as soon as the step reports it, wait for it as blockers first's step 4 waits, then \`done --entry <I> --pr <P>\`."
  contains "$s" "Where the PR cannot advance by itself, stop (step 5) with \`--pause\` and the reason that PR #P awaits a merge: the report lists that stop as a pause, not a failure."
}

@test "AC3: an epic-kind entry, a follow-up or split included, is marked done without a PR once its epic closes" {
  contains "$(cq_step 2)" "the epic-kind entry it belongs to, a named issue, blocker or follow-up that runs the Epic flow, a refinement split's included, and its PR takes E3's own wait."
  s="$(cq_step 3)"
  contains "$s" "An epic-kind entry has no PR of its own: once the Epic flow closes its epic, \`done --entry <I>\` without \`--pr\`; an Epic flow that ends with the epic still open is a park (step 5)."
}

@test "AC3: chain-steps' arms route the queue: done follows queue step 3, blocked re-queues, ready starts a follow-up at §0a" {
  t="$(flat < "$STEPS")"
  contains "$t" "**\`done\`** → report the PR. In an epic, continue E3, and mark the epic-kind entry \`done\` only once the Epic flow ends; otherwise record the PR, wait for its merge and mark the entry \`done\` (queue step 3). Then take \`next\`."
  contains "$t" "On a follow-up's step, the root adds each open local blocker \`--before\` the follow-up, deepest first, and takes \`next\`; the re-run follow-up's §0a clears its label."
  contains "$t" "A cycle or an open foreign blocker parks it (queue step 5)."
  contains "$t" "A follow-up entry, whose step never passed §0a, gets \`start_at: \"0a\"\`."
}

@test "AC4: the run is done when the queue is empty, and clear deletes the queue file" {
  s="$(cq_step 4)"
  contains "$s" "\`next\`'s exit 4 means every queued issue is closed and the queue is empty."
  contains "$s" "The run is done: \`chain-queue.zsh clear\` deletes the queue file."
}

@test "AC5: the permanent failures stop the whole run, a park defined, no skipping ahead, E3's rule inside an epic" {
  s="$(cq_step 5)"
  contains "$s" "The run stops at an escalation, CI that will not go green, a \`blockedBy\` cycle, an open foreign blocker, a follow-up cycle, or a park."
  contains "$s" "A park is an entry whose own run ends without a merged PR on a needs-refinement, needs-split or blocked terminal, #2940's \`chained refinement stopped:\` outcome at §0b, §2 or E1b included, and an epic-kind entry that ends with a child still parked."
  contains "$s" "A finding the review loop parks as a follow-up is not a park: step 2 queues it."
  contains "$s" "The run never skips ahead to independent work in the queue."
  contains "$s" "E3 keeps #2940's rule and carries on with the children that do not depend on a parked child, and then the entry stops the run."
}

@test "AC6: the blocker-phase stop is #2941's; later stops post 'chain stopped:' with the report, no label" {
  s="$(cq_step 6)"
  contains "$s" "A stop before the named issue's precheck returns \`PROCEED\` is blockers first's step 6, unchanged"
  contains "$s" "Every later stop posts one comment on the named issue, open or closed, whose body is \`chain-queue.zsh report --stopped <I> --reason <why>\`, beginning \`chain stopped:\`, and prints the same text in the run's report."
  contains "$s" "It applies no label, because the stopping issue keeps what its own run posted."
  contains "$s" "Every record keeps its own run's outcome, and no telemetry outcome or field is added."
  contains "$s" "The queue file is kept."
}

@test "AC7: a re-run resumes from the queue: closed entries are done, an open PR is waited on, never rebuilt" {
  contains "$(cq_step 1)" "**With no queue file**, start one: \`add --entry <N> --kind named\`."
  contains "$(cq_step 1)" "**With one**, this run resumes (step 7) and starts nothing new."
  contains "$(cq_step 3)" "Take \`next\` and run its entry."
  contains "$(flat < "$SKILL")" "If \`state\` is not \`OPEN\`, stop — it's already handled — unless a human-started run kept a chain queue (#2942)."
  s="$(cq_step 7)"
  contains "$s" "A re-run on the named issue that finds the file resumes with \`next\`, the entry that stopped the run."
  contains "$s" "An entry that is now closed is marked \`done\`."
  contains "$s" "An entry whose recorded PR is still open is waited on as in step 3, never rebuilt."
  contains "$s" "Any other entry runs again."
}

@test "AC8: there is no numeric cap; a follow-up cycle is refused by add and stops the run" {
  s="$(cq_step 2)"
  contains "$s" "There is no numeric cap."
  contains "$s" "\`{\"file\": \"follow-up\", \"line\": null, \"dimension\": \"follow-up\", \"title\": <its title>}\`"
  contains "$s" "\`add\`'s exit 3 refuses a follow-up whose identity matches one already resolved in this run: that is a follow-up cycle, and it stops the run (step 5)."
}

@test "AC9: one status line per transition, naming the issue and queue length; answers in full, decisions as a count" {
  t="$(cq)"
  contains "$t" "**One status line per transition.** Print one line when a refinement starts or ends, a split is filed, a build starts, a PR merges, a follow-up is queued, and the run stops or is done."
  contains "$t" "Each line names the issue and the queue length, the entries not yet done."
  contains "$t" "An intent or gap answer appears in full, with who gave it"
  contains "$t" "Implementation decisions appear only as a count, with a pointer to the issue's *Decisions taken*."
}

@test "AC11: both docs pages describe the chain queue" {
  t="$(flat < "$REPO_ROOT/docs/how-to/run-resolve-issue-unattended.md")"
  contains "$t" "Every follow-up the build files joins the same run"
  contains "$t" "begins \`chain stopped:\`"
  contains "$t" "Run \`/development:resolve-issue\` on the story again to resume where it stopped."
  t="$(flat < "$REPO_ROOT/docs/explanation/workflow-resolve-issue.md")"
  contains "$t" "keeps going through every follow-up the build files"
  contains "$t" "one \`chain stopped:\` comment, and a re-run resumes the queue"
}
