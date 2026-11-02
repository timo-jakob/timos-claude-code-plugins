#!/usr/bin/env bats
#
# refine-issue's one approval per epic walk (#2904): an interactive Epic walk
# drafts every needs-refinement child first (phase A) and asks ONE approval for
# the batch of children that reached a sized draft (phase B).
# scripts/batch-approval.zsh renders the batch (`summary`) and splits the
# human's answer (`partition`); SKILL.md states the two-phase order, the batch
# loop-back rule and the PAUSED_S that keeps waits on others out of wall_s.
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
 "waiting_since": 1793500000}
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
  contains "$t" 're-read the issue'"'"'s current block into `old_block`, write its rewrite to `rewrite_path`, set `phase` to `pending`, and go on to the next child.'
  contains "$t" '`park_type`, `paused_s`), its `conversation`'
  contains "$t" '`waiting_since` and its `phase`: `pending` while its draft awaits a batch, and set to its outcome (`approved`, `skipped` or `drafting`) as soon as `partition` places it, so no child is in two batches.'
  contains "$t" 'A looped-back child already written back takes Step 5'"'"'s stop instead.'
  contains "$t" 'the child'"'"'s `/tmp/refine-issue-epic-<E>/<N>.defaults.json`'
  contains "$t" 'run Steps 2.5, 3, 4, 5, 6 and 7 for it. Its batch approval is the approval of its exact rewrite.'
  contains "$t" 'Steps 4 and 5 write what they decide into its state file `f` with `jq … "$f" > "$f.tmp" && mv "$f.tmp" "$f"` before Step 7 reads it: Step 4 the re-gate'"'"'s `size_preflight`, Step 5 `state_outcome` and `park_type`. `risk` stays Step 1'"'"'s, already there from phase A.'
  lacks "$t" 'Steps 4 and 5 write what they decide (`risk`'
  contains "$t" 're-record `SIZE_PREFLIGHT` from its `size` object (Step 1). In an epic walk (#2904), also write it as `size_preflight` into the child'"'"'s state file `/tmp/refine-issue-epic-<E>/<N>.json`.'
  contains "$t" '**In an epic walk (#2904)**, whichever branch below sets `STATE_OUTCOME` and `PARK_TYPE` also writes both into the child'"'"'s state file `/tmp/refine-issue-epic-<E>/<N>.json`, in the same invocation, since its Step 7 re-states the child'"'"'s literals from that file.'
  contains "$t" 'the child ends as *skipped (human declined)*'
  # phase A comes before phase B in the walk
  local a b
  a="$(grep -n 'Phase A — draft each child' "$SKILL" | cut -d: -f1)"
  b="$(grep -n 'Phase B — one approval for the batch' "$SKILL" | cut -d: -f1)"
  [ -n "$a" ]
  [ -n "$b" ]
  [ "$a" -lt "$b" ]
}

@test "SKILL.md states the batch loop-back rule, from the walk and from Step 5" {
  local t; t="$(flat "$SKILL")"
  contains "$t" '**The batch loop-back rule.** A child whose re-gate is still `NEEDS_REFINEMENT` loops back to Step 2 (Step 5) like a revisit child, and its `phase` goes back to `drafting`.'
  contains "$t" 'they form the **next batch**, which gets one approval again. Batches repeat until every child has ended — written back, skipped or parked — so none is pending or waiting to redraft: a revisit child (`drafting`) or a looped-back child keeps the walk going, and the next phase A redrafts it.'
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
  contains "$(flat "$SKILL")" 'whenever its work stops to wait — it becomes pending, or it loops back (it redrafts only in the next phase A) — set `waiting_since` to `$(date +%s)`; whenever its own work resumes (its Steps 2.5 to 7, or its redraft), first write the wait into its state file `f` (`/tmp/refine-issue-epic-<E>/<N>.json`) with `jq --argjson now "$(date +%s)" '"'"'.paused_s += ($now - .waiting_since) | .waiting_since = null'"'"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"`.'
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
  contains "$t" '**revisit** — the child re-enters Step 2 with the human'"'"'s reply as `human_reply`, and its `phase` goes back to drafting.'
}

@test "Step 7 sources PAUSED_S from the child state in an epic walk and from Step 0 elsewhere" {
  local step7; step7="$(sed -n '/^## Step 7 /,/^## Guardrails/p' "$SKILL" | tr '\n' ' ' | tr -s ' ')"
  contains "$step7" '`PAUSED_S` is its `paused_s`: its waits on others, which `WALL_S` excludes.'
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

@test "every step that assigns a Step 7 run variable writes it into the child's state file, in either phase" {
  local s; s="$(flat "$SKILL")"
  contains "$s" 'Every step that assigns one of those run variables — Step 0'"'"'s `t0`, `repo_root` and `paused_s`, Step 1'"'"'s verdict and its already-`READY` shortcut, Step 2'"'"'s typed park or filed split, Step 4'"'"'s re-gate and Step 5'"'"'s ending, in phase A or phase B alike — also writes it into that state file in the same invocation, so Step 7 finds every ending'"'"'s values there.'
  contains "$s" 'Step 7 re-states the child'"'"'s literals from that file in the same invocation as the fence.'
}

@test "phase B is skipped, asking nothing, when no child is pending" {
  local s; s="$(flat "$SKILL")"
  contains "$s" 'When no child is pending — every one ended in phase A — skip phase B, ask nothing, and go to step 3'"'"'s epic-level summary.'
}

@test "a repeated --revisit or --skip adds to its list, never replaces it" {
  pending 12; fresh 9; fresh 20; fresh 30
  run -0 zsh "$S" partition --dir "$D" --revisit 12 --revisit 20 --skip 9 --skip "#30"
  [ "$output" = '{"approve":[],"revisit":[12,20],"skip":[9,30]}' ]
}

@test "partition exits 2 on an unreadable --dir, and 1 on a valid-JSON state file without a string phase" {
  run -2 zsh "$S" partition --dir "$BATS_TEST_TMPDIR/no-such-dir"
  contains "$output" 'missing or unreadable'
  printf '%s\n' '{"phase": 3}' > "$D/7.json"
  run -1 zsh "$S" partition --dir "$D"
  contains "$output" 'not one JSON object with a string phase'
  printf '%s\n' '{"rewrite_path": "/tmp/r.md"}' > "$D/7.json"
  run -1 zsh "$S" summary --dir "$D"
  contains "$output" "$D/7.json"
}

@test "a redraft re-enters at Step 2 and keeps its state, never re-running Step 0 or Step 1" {
  local s; s="$(flat "$SKILL")"
  contains "$s" 'A redraft re-enters at Step 2 and keeps its state file: it never re-runs Step 0 or Step 1, so its `t0`, `rounds`, `raised` and `resolved` carry on across batches.'
}

@test "the user docs describe the epic walk's two phases and its one batch approval" {
  local d; d="$(flat "$REPO_ROOT/docs/explanation/workflow-refine-issue.md")"
  contains "$d" 'walks them in two phases. First it drafts every child in turn'
  contains "$d" 'Then it shows you every finished draft at once and asks one approval for the batch'
  contains "$d" 'approve all, or name the children to revisit, to skip, or whose automatic answer you overturn.'
  contains "$d" 'Revisited children, and any child the readiness gate still sends back after its rewrite, redraft and come back as the next batch.'
  contains "$d" 'which children are now ready, which were skipped, which are still parked and why, and any that failed.'
  lacks "$d" 'one child fully before the next'
}

@test "partition's exits: a bad answer is asked again, the conductor's own bad call and a malformed state file are fixed and re-run" {
  local s; s="$(flat "$SKILL")"
  contains "$s" 'Exit 2 means a number that is not a pending child, or one named in both lists: ask again with the pending numbers.'
  contains "$s" 'An exit 2 your own call caused (a missing `--dir`, an unknown flag) is fixed and re-run without asking. Exit 1 is a malformed state file: fix it with `jq` and re-run.'
}

@test "a child's phase is always a string, through its whole lifecycle, and a loop-back returns it to drafting" {
  local s; s="$(flat "$SKILL")"
  contains "$s" 'Its `phase` is always a string, from the moment its state file is created: `drafting` while it drafts or must redraft (a child created in phase A, a revisit, and an approved child whose re-gate loops it back), `pending` as above, `skipped` once skipped, and `ended` once it is written back, parked or split, so a walk is finished exactly when no child is `drafting`, `pending` or `approved`.'
  contains "$s" '`NEEDS_REFINEMENT` loops back to Step 2 (Step 5) like a revisit child, and its `phase` goes back to `drafting`.'
}

@test "partition and summary read only <N>.json, ignoring a child's other files and non-pending phases" {
  pending 12
  printf '%s\n' '{"phase": "drafting"}' > "$D/9.json"
  printf '%s\n' '{"phase": "ended"}' > "$D/15.json"
  printf 'not json\n' > "$D/12.defaults.json"
  run -0 zsh "$S" partition --dir "$D"
  [ "$output" = '{"approve":[12],"revisit":[],"skip":[]}' ]
  run -0 zsh "$S" summary --dir "$D"
  contains "$output" '12'
}

@test "a state file holding two JSON objects is malformed (exit 1)" {
  printf '%s\n%s\n' '{"phase": "ended"}' '{"phase": "ended"}' > "$D/7.json"
  run -1 zsh "$S" partition --dir "$D"
  contains "$output" 'not one JSON object with a string phase'
}
