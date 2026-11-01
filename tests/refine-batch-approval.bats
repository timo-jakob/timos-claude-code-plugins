#!/usr/bin/env bats
#
# refine-issue's one approval per epic walk (#2904): an interactive Epic walk
# drafts every needs-refinement child first (phase A) and asks ONE approval for
# the batch of children that reached a sized draft (phase B).
# scripts/batch-approval.zsh renders the batch (`summary`) and splits the
# human's answer (`partition`); SKILL.md states the two-phase order, the batch
# loop-back rule and the PAUSED_S that keeps the batch wait out of wall_s.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/batch-approval.zsh"
  SKILL="$REPO_ROOT/development/skills/refine-issue/SKILL.md"
  D="$BATS_TEST_TMPDIR/epic"
  mkdir -p "$D"
}

# pending <N> — a pending child with a changed block, two test cases and one
# auto-accepted answer
pending() {
  cat > "$D/$1.json" <<'EOF'
{"phase": "pending",
 "proposed_story_spec": {"acceptance_criteria": ["Keeps A", "Adds B"],
   "scope_boundaries": {"in": ["scripts/x.zsh"], "out": ["the web UI"]},
   "test_cases": [{"id": "TC-1"}, {"id": "TC-3"}]},
 "old_block": {"acceptance_criteria": ["Keeps A", "Drops C"],
   "scope_boundaries": {"in": ["scripts/x.zsh", "scripts/y.zsh"], "out": []},
   "test_cases": [{"id": "TC-1"}, {"id": "TC-2"}]},
 "auto_accepted": [{"question": "Which shell?", "answer": "zsh",
   "confidence": "0.85", "weakest": ["uniqueness"]}],
 "expected_docs_pages": ["docs/how-to/use-the-cli.md"],
 "rewrite_path": "/tmp/refine-issue-epic-1/rewrite.md",
 "draft_ready_at": 1793500000}
EOF
}

# fresh <N> — a pending child whose issue had no block yet
fresh() {
  printf '%s\n' '{"phase": "pending", "proposed_story_spec": {"acceptance_criteria": ["A"]}, "old_block": null, "auto_accepted": [], "expected_docs_pages": [], "rewrite_path": "/tmp/r.md"}' > "$D/$1.json"
}

@test "partition with no names approves every pending child, in number order" {
  pending 12; fresh 9
  printf '%s\n' '{"phase": "parked"}' > "$D/15.json"
  run -0 zsh "$S" partition --dir "$D"
  [ "$output" = '{"approve":[9,12],"revisit":[],"skip":[]}' ]
}

@test "partition approves every pending child except the ones named to revisit" {
  pending 12; fresh 9; fresh 20
  run -0 zsh "$S" partition --dir "$D" --revisit "12 20"
  [ "$output" = '{"approve":[9],"revisit":[12,20],"skip":[]}' ]
}

@test "partition moves named skips out of the approval, # prefix and commas accepted" {
  pending 12; fresh 9; fresh 20
  run -0 zsh "$S" partition --dir "$D" --skip "#9" --revisit "12,"
  [ "$output" = '{"approve":[20],"revisit":[12],"skip":[9]}' ]
}

@test "partition refuses a number that is not a pending child with exit 2" {
  pending 12
  printf '%s\n' '{"phase": "parked"}' > "$D/15.json"
  run -2 zsh "$S" partition --dir "$D" --skip 15
  contains "$output" '#15 is not a pending child'
  run -2 zsh "$S" partition --dir "$D" --revisit 99
  contains "$output" '#99 is not a pending child'
}

@test "partition refuses a child named both to revisit and to skip, and a non-number" {
  pending 12
  run -2 zsh "$S" partition --dir "$D" --revisit 12 --skip 12
  contains "$output" 'both to revisit and to skip'
  run -2 zsh "$S" partition --dir "$D" --skip abc
  contains "$output" "not an issue number: 'abc'"
}

@test "usage errors exit 2: unknown mode, unknown flag, missing dir, a summary flag given to partition only" {
  run -2 zsh "$S"
  run -2 zsh "$S" approve --dir "$D"
  run -2 zsh "$S" summary --dir "$D" --bogus
  run -2 zsh "$S" summary --dir "$BATS_TEST_TMPDIR/nope"
  run -2 zsh "$S" summary --dir "$D" --skip 1
}

@test "a malformed state file exits 1 and names the file" {
  printf 'not json\n' > "$D/7.json"
  run -1 zsh "$S" summary --dir "$D"
  contains "$output" "$D/7.json"
  printf '%s\n' '{"phase": "pending"}' > "$D/7.json"
  run -1 zsh "$S" partition --dir "$D"
  contains "$output" 'malformed pending state file'
}

@test "a pending state file missing any one field it reads, or with the wrong type, exits 1" {
  local field
  for field in proposed_story_spec old_block auto_accepted expected_docs_pages rewrite_path; do
    pending 7
    jq "del(.$field)" "$D/7.json" > "$D/x" && mv "$D/x" "$D/7.json"
    run -1 zsh "$S" partition --dir "$D"
    contains "$output" 'malformed pending state file'
    pending 7
    jq ".$field = true" "$D/7.json" > "$D/x" && mv "$D/x" "$D/7.json"
    run -1 zsh "$S" partition --dir "$D"
  done
}

@test "the summary carries the AC and scope diff, the test-case plan and the auto-accepted answers" {
  pending 12
  run -0 zsh "$S" summary --dir "$D"
  contains "$output" '### #12'
  contains "$output" 'acceptance criterion added: "Adds B"'
  contains "$output" 'acceptance criterion removed: "Drops C"'
  contains "$output" 'scope in removed: "scripts/y.zsh"'
  contains "$output" 'scope out added: "the web UI"'
  contains "$output" '**Test cases:** 2 — create: TC-3; edit: TC-1; close: TC-2'
  contains "$output" '**Answers taken automatically:**'
  contains "$output" 'Which shell? → zsh (confidence 0.85, weakest: uniqueness)'
  contains "$output" '**Expected docs pages:** docs/how-to/use-the-cli.md'
  contains "$output" '**Full rewrite:** /tmp/refine-issue-epic-1/rewrite.md'
  contains "$output" '`needs-refinement` is cleared if the re-gate is READY'
}

@test "the summary names no blockedBy edge, and marks a child with no block as a new block" {
  pending 12; fresh 9
  run -0 zsh "$S" summary --dir "$D"
  local sum="$output"
  contains "$sum" '### #9'
  contains "$sum" '  - new block'
  # number order: #9 before #12
  [ "$(grep -n '^### #9$' <<< "$sum" | cut -d: -f1)" -lt "$(grep -n '^### #12$' <<< "$sum" | cut -d: -f1)" ]
  run -1 grep -qi 'blockedBy' <<< "$sum"
}

@test "a summary with no pending child prints nothing" {
  printf '%s\n' '{"phase": "parked"}' > "$D/15.json"
  run -0 zsh "$S" summary --dir "$D"
  [ -z "$output" ]
}

@test "SKILL.md states the two-phase walk: phase A drafts every child, then phase B asks one approval" {
  local t; t="$(flat "$SKILL")"
  contains "$t" '**Walk the children in two phases (#2904)** — draft every child first, then ask **one** approval for the batch.'
  contains "$t" '**Phase A — draft each child, in sub-issue order.**'
  contains "$t" '**Phase B — one approval for the batch.**'
  contains "$t" 'batch-approval.zsh" summary --dir /tmp/refine-issue-epic-<E>'
  contains "$t" 'batch-approval.zsh" partition --dir /tmp/refine-issue-epic-<E>'
  contains "$t" 'never enters a batch: the READY shortcut'
  contains "$t" 're-read the issue'"'"'s current block into `old_block`, write its rewrite to `rewrite_path`, set `phase` to `pending` and `draft_ready_at` to `$(date +%s)`, and go on to the next child.'
  contains "$t" '`park_type`, `paused_s`), its `conversation`'
  contains "$t" '`draft_ready_at` and its `phase`: `pending` while its draft awaits a batch, and set to its outcome (`approved`, `skipped` or `drafting`) as soon as `partition` places it, so no child is in two batches.'
  contains "$t" 'A looped-back child already written back takes Step 5'"'"'s stop instead.'
  contains "$t" 'the child'"'"'s `/tmp/refine-issue-epic-<E>/<N>.defaults.json`'
  contains "$t" 'run Steps 2.5, 3, 4, 5, 6 and 7 for it. Its batch approval is the approval of its exact rewrite.'
  contains "$t" 'the child ends as *skipped (human declined)*'
  # phase A comes before phase B in the walk
  local a b
  a="$(grep -n 'Phase A — draft each child' "$SKILL" | cut -d: -f1)"
  b="$(grep -n 'Phase B — one approval for the batch' "$SKILL" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

@test "SKILL.md states the batch loop-back rule, from the walk and from Step 5" {
  local t; t="$(flat "$SKILL")"
  contains "$t" '**The batch loop-back rule.** A child whose re-gate is still `NEEDS_REFINEMENT` loops back to Step 2 (Step 5) like a revisit child.'
  contains "$t" 'they form the **next batch**, which gets one approval again. Batches repeat until no child is pending.'
  contains "$t" 'In an epic walk the looped-back child redrafts and joins the **next batch**'
  contains "$t" '**In an epic walk the approval is the batch'"'"'s (#2904).**'
}

@test "Step 0 initializes PAUSED_S to a measured zero and Step 7 subtracts it from wall_s" {
  local step0 step7
  step0="$(sed -n '/^## Step 0 /,/^## Step 1 /p' "$SKILL")"
  step7="$(sed -n '/^## Step 7 /,/^## Guardrails/p' "$SKILL")"
  contains "$step0" 'PAUSED_S=0'
  contains "$step7" 'WALL_S=$(( $(date +%s) - 10#$T0 - 10#$PAUSED_S ))'
  contains "$step7" '|| ! "${PAUSED_S:-}" =~ ^[0-9]+$'
  contains "$(flat "$SKILL")" 'When a child'"'"'s own work resumes — its Steps 2.5 to 7, or its redraft — add the wait to its paused time once: `paused_s += now - draft_ready_at`, then set `draft_ready_at` to null, so a loop-back redraft, which follows work that never paused, adds nothing.'
}

@test "the auto-accept guardrail is unchanged: a batch never lets auto-accept approve a rewrite" {
  local t; t="$(flat "$SKILL")"
  contains "$t" '**Auto-accept never approves the rewrite.** The threshold only answers the refiner'"'"'s questions.'
  contains "$t" 'The batch summary carries the same **Answers taken automatically** this step would show.'
}

@test "the batch approval is an inventoried intent ask (RF-10)" {
  contains "$(cat "$REPO_ROOT/development/skills/refine-issue/reference/ask-branches.md")" \
    '| RF-10 | SKILL.md | `` Show it, then ask once (`AskUserQuestion`): **Approve all** `` | intent |'
}

@test "SKILL.md states the batch's exit handling, the overturn-as-revisit rule and the per-outcome actions" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'Exit 1 is a malformed state file: fix it with `jq` and re-run.'
  contains "$t" 'An overturned answer makes its child a revisit, with the overturn as its `human_reply`.'
  contains "$t" 'It prints `{approve, revisit, skip}`.'
  contains "$t" 'The batch wait is not refinement work, so it never counts toward a child'"'"'s `wall_s`.'
  contains "$t" '**revisit** — the child re-enters Step 2 with the human'"'"'s reply as `human_reply`, and its `phase` goes back to drafting.'
}

@test "Step 7 sources PAUSED_S from the child state in an epic walk and from Step 0 elsewhere" {
  local step7; step7="$(sed -n '/^## Step 7 /,/^## Guardrails/p' "$SKILL" | tr '\n' ' ' | tr -s ' ')"
  contains "$step7" '`PAUSED_S` is its `paused_s`: the batch wait, which `WALL_S` excludes.'
  contains "$step7" 'Everywhere else it is Step 0'"'"'s measured `0`, and the guard requires it to be digits.'
}

@test "partition exits 2 on a dangling --dir, --revisit or --skip, and on a revisit/skip flag given to summary" {
  pending 12
  run -2 zsh "$S" partition --dir
  run -2 zsh "$S" partition --dir "$D" --revisit
  run -2 zsh "$S" partition --dir "$D" --skip
  run -2 zsh "$S" summary --dir "$D" --revisit 12
  run -2 zsh "$S" partition --dir "$D" --revisit "12 x"
  contains "$output" "not an issue number: 'x'"
}
