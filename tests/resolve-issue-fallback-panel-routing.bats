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
  contains "$t" 'If the fallback reviewed something, go on to steps 3–5; the verdict is `ok`, and the marker records that the fallback is engaged.'
}

@test "the panel brief keeps the fallback engaged for the rest of the run (#2909)" {
  local t; t="$(flat "$BRIEF")"
  contains "$t" 'While `<work_dir>/.fallback-engaged` exists, add `--fallback` on every round (#2909, below).'
  contains "$t" 'Once engaged, the fallback stays for the rest of the run: every later round plans with `--fallback` and dispatches only the fallback, and a fallback is never followed by another fallback.'
}

@test "the panel brief returns not-applicable only when the fallback is NOT APPLICABLE or unavailable (#2909)" {
  local t; t="$(flat "$BRIEF")"
  contains "$t" 'Return `not_applicable` / `not-applicable` only when the fallback is NOT APPLICABLE or unavailable.'
  contains "$t" 'an unresolvable fallback `review_skill` is never `render-failed`.'
  contains "$t" '| on a full round, the fallback panel is NOT APPLICABLE or unavailable, after the repo-type panel reported NOT APPLICABLE | `not_applicable` / `not-applicable` |'
  lacks "$t" '| the language panel reported NOT APPLICABLE on a full round |'
}

@test "the subagents.md not-applicable row fires only when the fallback is NOT APPLICABLE or unavailable (#2909)" {
  run grep -F '| `not-applicable` | `not_applicable` |' "$SUB"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  contains "$output" 'fires only when the fallback panel is NOT APPLICABLE or unavailable (#2909)'
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
}

@test "the note after the exit-2 frozen span states the routing and which panels report NOT APPLICABLE on a non-empty diff (#2909)" {
  local after
  after="$(sed -n '/^<!-- \/moved: round-protocol-recover -->$/,$p' "$EXIT2" | tr '\n' ' ' | tr -s ' ')"
  contains "$after" '**A full round'"'"'s NOT APPLICABLE goes to the fallback panel first (#2909).**'
  contains "$after" 'Today the `kubernetes` and `javascript` panels report NOT APPLICABLE on a non-empty diff'
  contains "$after" '- **step mode** — the panel brief re-plans with `review-dispatch.zsh plan --fallback`'
  contains "$after" '- **hook mode** — `resolve-story-loop.zsh` sees a `--review-cmd` that wrote no findings file'
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
  contains "$t" '**Fallback unavailable** — `development-claude-plugin` not installed'
  contains "$t" 'never the `render-failed` FAILED arm.'
}
