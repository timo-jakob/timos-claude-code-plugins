#!/usr/bin/env bats
#
# A full round's NOT APPLICABLE routes to the fallback review panel (#2909,
# epic #2898). The script half — `review-dispatch.zsh plan --fallback` and the
# loop's hook-mode engagement — is pinned behaviourally in
# tests/review-dispatch.bats and tests/resolve-story-loop.bats. This suite pins
# the prose half: the panel brief's routing and fallback-unavailable sentences,
# the subagents.md `not-applicable` row, the RS-06a / RS-06b inventory rows,
# the note after the exit-2 frozen span, and that span's bytes.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"  # #1972: suites naming a telemetry-writing script isolate HOME
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REF="$REPO_ROOT/development/skills/resolve-issue/reference"
  BRIEF="$REF/review-loop/briefs/panel.md"
  SUB="$REF/review-loop/subagents.md"
  EXIT2="$REF/review-loop/exit-2-stale-findings.md"
  INV="$REF/ask-branches.md"
  flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
}

@test "the panel brief routes a full-round NOT APPLICABLE to the fallback in the same round (#2909)" {
  local t; t="$(flat "$BRIEF")"
  contains "$t" '**Route a full-round NOT APPLICABLE to the fallback panel (#2909).** When the plan'"'"'s `review_skill` panel reports NOT APPLICABLE on a full round whose story diff is not empty, dispatch the fallback panel in the same round:'
  contains "$t" 're-plan with step 1'"'"'s flags plus `--fallback`, and dispatch that descriptor'"'"'s `review_skill`, `development-claude-plugin:review`'
  contains "$t" 'Its descriptor carries `review_mode: "fallback"`, which puts that skill into its fallback mode, and no topic panels.'
  contains "$t" 'If the fallback reviewed something — it did not itself report NOT APPLICABLE — record the engagement with `printf '"'"'%s\n'"'"' <round> > <work_dir>/.fallback-engaged` and go on to steps 3–5; the verdict is `ok`, and the marker records that the fallback is engaged.'
  contains "$t" 'The fallback reviews the whole round alone: drop every topic panel'"'"'s findings from this round, and join only the fallback'"'"'s in step 4.'
  contains "$t" 'Three rounds never engage it, and their NOT APPLICABLE stays the stop below: a round whose repo-type panel is `development-claude-plugin:review` itself, a carried round (the fallback'"'"'s dimensions cannot own the repo-type panel'"'"'s carried entries), and a delta round.'
}

@test "the panel brief keeps the fallback engaged for the rest of the run (#2909)" {
  local t; t="$(flat "$BRIEF")"
  contains "$t" 'On round 1, first `rm -f <work_dir>/.fallback-engaged`, which an earlier run may have left: round 1 never inherits an engagement.'
  contains "$t" 'While `<work_dir>/.fallback-engaged` exists, add `--fallback` on every round (#2909, below).'
  contains "$t" 'Once engaged, the fallback stays for the rest of the run: every later round plans with `--fallback` and dispatches only the fallback, and a fallback is never followed by another fallback.'
}

@test "the panel brief returns not-applicable only when the fallback is NOT APPLICABLE or unavailable (#2909)" {
  local t; t="$(flat "$BRIEF")"
  contains "$t" 'Return `not_applicable` / `not-applicable` only when the fallback is NOT APPLICABLE or unavailable, or when the repo-type panel'"'"'s NOT APPLICABLE falls on a round that never engages the fallback.'
  contains "$t" 'an unresolvable fallback `review_skill` is never `render-failed`.'
  contains "$t" 'It is unavailable when its `SKILL.md` is not in the plugin cache because `development-claude-plugin` is not installed;'
  contains "$t" 'On the round it engages, return to the conductor, beside the verdict, one line naming the repo-type panel and the fallback.'
  contains "$t" 'Return to the conductor only that the verdict was written, plus, on the round the fallback engages, the one line naming both panels (#2909).'
  contains "$t" '| the repo-type panel reported NOT APPLICABLE, and the fallback panel is NOT APPLICABLE or unavailable or the round never engages it | `not_applicable` / `not-applicable` |'
  lacks "$t" '| the language panel reported NOT APPLICABLE on a full round |'
}

@test "the subagents.md not-applicable row fires only when the fallback is NOT APPLICABLE or unavailable (#2909)" {
  run grep -F '| `not-applicable` | `not_applicable` |' "$SUB"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  contains "$output" 'fires only when the fallback panel is NOT APPLICABLE or unavailable, or on a round that never engages it (#2909)'
  contains "$output" 'autonomous, stop with no commit and no PR; interactive, its three options, none taken without an explicit choice.'
}

@test "RS-06 is split into RS-06a (implementation, run the fallback) and RS-06b (intent) (#2909)" {
  run grep -E '^\| RS-06 \|' "$INV"
  [ "$status" -eq 1 ]
  run grep -E '^\| RS-06a \|' "$INV"
  [ "${#lines[@]}" -eq 2 ]
  contains "${lines[0]}" '| reference/review-loop/briefs/panel.md | `Route a full-round NOT APPLICABLE to the fallback panel (#2909)` | implementation | **default:** run the fallback panel'
  contains "${lines[1]}" '| reference/review-loop/subagents.md | `fires only when the fallback panel is NOT APPLICABLE or unavailable` | implementation |'
  run grep -E '^\| RS-06b \|' "$INV"
  [ "${#lines[@]}" -eq 2 ]
  contains "${lines[0]}" '| `put it to the human as three options` | intent | human-owned: the fallback is NOT APPLICABLE or unavailable'
  contains "${lines[1]}" '| `interactive, its three options, none taken without an explicit choice` | intent |'
}

@test "RS-06a's procedure prints one line and records a Decisions-taken entry (#2909)" {
  local t; t="$(flat "$INV")"
  contains "$t" '## RS-06a — the fallback review panel default (#2909)'
  contains "$t" '**Print one line** when the fallback engages, attended or unattended, naming both panels'
  contains "$t" 'how to overrule: request changes on the PR, or re-run deliberately with `--no-review`.'
  contains "$t" '`Decision taken (not asked): <repo-type review_skill> is NOT APPLICABLE on this diff, so development-claude-plugin:review reviews it in fallback mode`'
  contains "$t" '**Record it in the body (#2909).** When `<work-dir>/.fallback-engaged` exists as §6 opens the PR, the body'"'"'s `## Decisions taken` section'
  contains "$t" 'choice: the fallback panel, `development-claude-plugin:review` in fallback mode, from round `<the marker'"'"'s round>` on;'
  contains "$t" 'On an ending with no PR body, the entry goes in the run'"'"'s report.'
  # and §6 reaches the procedure
  contains "$(cat "$REPO_ROOT/development/skills/resolve-issue/SKILL.md")" '**When the fallback review panel engaged (#2909):** see `reference/ask-branches.md` § RS-06a — the fallback review panel default (#2909)'
}

@test "the note after the exit-2 frozen span states the routing and which panels report NOT APPLICABLE on a non-empty diff (#2909)" {
  local after
  after="$(sed -n '/^<!-- \/moved: round-protocol-recover -->$/,$p' "$EXIT2" | tr '\n' ' ' | tr -s ' ')"
  contains "$after" '**A full round'"'"'s NOT APPLICABLE goes to the fallback panel first (#2909).**'
  contains "$after" 'Today the `kubernetes` and `javascript` panels report NOT APPLICABLE on a non-empty diff'
  contains "$after" '- **step mode** — the panel brief re-plans with `review-dispatch.zsh plan --fallback`'
  contains "$after" '- **hook mode** — `resolve-story-loop.zsh` sees a `--review-cmd` that wrote no findings file'
  contains "$after" 'and records the same marker once that re-run wrote a findings file.'
  contains "$after" 'Step 2'"'"'s arm, its autonomous stop and its three interactive options, applies only when the fallback is NOT APPLICABLE or unavailable (`development-claude-plugin` not installed), or on a round that never engages it (a carried round, or a repo whose own panel is the fallback). Engaging the fallback asks nothing;'
}

@test "the exit-2 round-protocol-recover frozen span is byte-unchanged (#2909)" {
  local sum
  sum="$(sed -n '/^<!-- moved: round-protocol-recover -->$/,/^<!-- \/moved: round-protocol-recover -->$/p' "$EXIT2" | shasum -a 256 | cut -d' ' -f1)"
  [ "$sum" = "a34c0c6d74ad561daa442d2f895435d83a9d217b9a62e9cbe1ae4f5f86a610ac" ]
  # and the routing note sits outside it
  run sh -c "sed -n '/^<!-- moved: round-protocol-recover -->\$/,/^<!-- \\/moved: round-protocol-recover -->\$/p' '$EXIT2' | grep -c '#2909'"
  [ "$output" = "0" ]
}

@test "ARCHITECTURE.md's review-panel contract states the fallback panel (#2909)" {
  local t; t="$(awk '/^## Review-panel invocation contract/{on=1} on && /^## Review-findings consolidator/{exit} on' "$REPO_ROOT/ARCHITECTURE.md" | tr '\n' ' ' | tr -s ' ')"
  contains "$t" '**The fallback review panel (#2909).**'
  contains "$t" '`plan --fallback` plans it: the round'"'"'s normal descriptor with `review_skill` `"development-claude-plugin:review"`, `review_mode` `"fallback"`, `fallback_for` naming the repo-type `review_skill` it stands in for, and `topic_review_skills` `[]`'
  contains "$t" 'Hook mode exports `$REVIEW_MODE` beside `$REVIEW_SCOPE_MODE`'
  contains "$t" 'records the engagement in `<work-dir>/.fallback-engaged` once the fallback has reviewed something, and plans every later round of the run with `--fallback`, `--resume` included; a fresh run never inherits the marker — hook mode'"'"'s loop and step mode'"'"'s panel brief, on round 1, clear it.'
  contains "$t" '**Fallback unavailable** — `development-claude-plugin` not installed'
  contains "$t" 'never the `render-failed` FAILED arm.'
}

@test "the user-facing review-loop explanation describes the fallback panel (#2909)" {
  local t; t="$(flat "$REPO_ROOT/docs/explanation/review-loop.md")"
  contains "$t" 'goes to the **fallback panel** first (#2909): `/development-claude-plugin:review` in its fallback mode reviews the shell, bats and Markdown files in the same round'
  contains "$t" 'Only when the fallback cannot review the diff either, or `development-claude-plugin` is not installed, is it a decision for you'
}
