#!/usr/bin/env bats
#
# refine-issue's all-auto write-back (#2938): a refinement in which every
# round's ask set was empty, every size check passed or was skipped and no
# refiner turn proposed a split is written back with no approval prompt.
# scripts/all-auto-check.zsh decides it from the run's split, turn and
# size-check verdict files; SKILL.md, ARCHITECTURE.md and the two docs pages
# state the exception wherever they used to say auto-accept never approves a
# rewrite.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/all-auto-check.zsh"
  SKILL="$REPO_ROOT/development/skills/refine-issue/SKILL.md"
  D="$BATS_TEST_TMPDIR/rounds"
  mkdir -p "$D"
  # Fixtures every test may use.
  printf '{"threshold":"0.900","auto":[{"question":"q","kind":"intent","answer":"a","confidence":"0.95","weakest":["evidence"],"rationale":"r"}],"ask":[]}\n' > "$D/split-empty.json"
  printf '{"threshold":"0.900","auto":[],"ask":[{"question":"q","kind":"gap","recommended_answer":"a","confidence":"0.50","weakest":["uniqueness"],"rationale":"r","reason":"below-threshold"}]}\n' > "$D/split-ask.json"
  printf '{"questions":[],"proposed_split":null}\n' > "$D/turn-null.json"
  printf '{"questions":[]}\n' > "$D/turn-nokey.json"
  printf '{"questions":[],"proposed_split":[{"title":"t","body":"b","files":["x"]}]}\n' > "$D/turn-split.json"
  printf '{"verdict":"pass","triggers":[],"files":2,"plugins":1}\n' > "$D/pass.json"
  printf '{"verdict":"skipped"}\n' > "$D/skipped.json"
  printf '{"verdict":"stop","triggers":["files"],"files":40,"plugins":1}\n' > "$D/stop.json"
  printf '{"verdict":"unjudged"}\n' > "$D/unjudged.json"
}

# --- the check -----------------------------------------------------------------

@test "every round's ask set empty, every sizing pass or skipped, every proposed_split null: all-auto" {
  run -0 zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-null.json" \
    --split "$D/split-empty.json" --turn "$D/turn-nokey.json" \
    --split "$D/split-empty.json" --turn "$D/turn-null.json" \
    --size-check "$D/pass.json" --size-check "$D/skipped.json"
  [ "$output" = '{"all_auto":true,"reason":"all-auto"}' ]
}

@test "no --split file: no-rounds, exit 0, even with other files or no flags at all" {
  run -0 zsh "$S" --turn "$D/turn-null.json" --size-check "$D/pass.json"
  [ "$output" = '{"all_auto":false,"reason":"no-rounds"}' ]
  run -0 zsh "$S"
  [ "$output" = '{"all_auto":false,"reason":"no-rounds"}' ]
}

@test "one ask entry in a later round: ask-question" {
  run -0 zsh "$S" --split "$D/split-empty.json" --split "$D/split-empty.json" --split "$D/split-ask.json" \
    --turn "$D/turn-null.json" --turn "$D/turn-null.json" --turn "$D/turn-null.json" --size-check "$D/pass.json"
  [ "$output" = '{"all_auto":false,"reason":"ask-question"}' ]
}

@test "a size-check stop in an earlier sizing, though the last one passed: size-check-stop" {
  run -0 zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-null.json" \
    --size-check "$D/stop.json" --size-check "$D/pass.json"
  [ "$output" = '{"all_auto":false,"reason":"size-check-stop"}' ]
}

@test "an unjudged sizing (the conductor's one-line sentinel): size-check-unjudged" {
  run -0 zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-null.json" \
    --size-check "$D/pass.json" --size-check "$D/unjudged.json"
  [ "$output" = '{"all_auto":false,"reason":"size-check-unjudged"}' ]
}

@test "a non-null proposed_split in a non-final turn: proposed-split" {
  run -0 zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-split.json" \
    --split "$D/split-empty.json" --turn "$D/turn-null.json" --size-check "$D/pass.json"
  [ "$output" = '{"all_auto":false,"reason":"proposed-split"}' ]
}

@test "two failing conditions report the first in the documented order" {
  # ask-question beats size-check-stop
  run -0 zsh "$S" --split "$D/split-ask.json" --turn "$D/turn-null.json" --size-check "$D/stop.json"
  [ "$output" = '{"all_auto":false,"reason":"ask-question"}' ]
  # size-check-stop beats size-check-unjudged, whichever file comes first
  run -0 zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-null.json" \
    --size-check "$D/unjudged.json" --size-check "$D/stop.json"
  [ "$output" = '{"all_auto":false,"reason":"size-check-stop"}' ]
  # size-check-unjudged beats proposed-split
  run -0 zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-split.json" --size-check "$D/unjudged.json"
  [ "$output" = '{"all_auto":false,"reason":"size-check-unjudged"}' ]
  # no-rounds beats everything
  run -0 zsh "$S" --turn "$D/turn-split.json" --size-check "$D/stop.json"
  [ "$output" = '{"all_auto":false,"reason":"no-rounds"}' ]
}

@test "a falsy but non-null proposed_split ([], {}, false, \"\", 0) still counts as a proposed split" {
  local v
  for v in '[]' '{}' 'false' '""' '0'; do
    printf '{"questions":[],"proposed_split":%s}\n' "$v" > "$D/turn-falsy.json"
    run -0 zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-falsy.json" --size-check "$D/pass.json"
    [ "$output" = '{"all_auto":false,"reason":"proposed-split"}' ]
  done
}

# --- exit 2 --------------------------------------------------------------------

@test "a malformed split file is exit 2 and named on stderr" {
  printf '{"auto": []}\n' > "$D/bad-split.json"
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --split "$D/bad-split.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--split is not one JSON object with auto and ask arrays: $D/bad-split.json"
  printf 'not json\n' > "$D/bad-split.json"
  run -2 --separate-stderr zsh "$S" --split "$D/bad-split.json"
  contains "$stderr" "$D/bad-split.json"
}

@test "a malformed turn file is exit 2 and named on stderr" {
  printf '[{"questions": []}]\n' > "$D/bad-turn.json"
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --turn "$D/bad-turn.json"
  [ -z "$output" ]
  contains "$stderr" "--turn is not one JSON object with a questions array: $D/bad-turn.json"
}

@test "an unknown verdict value, or a verdict file with no verdict, is exit 2 and named on stderr" {
  printf '{"verdict":"overridden"}\n' > "$D/bad-verdict.json"
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --size-check "$D/bad-verdict.json"
  [ -z "$output" ]
  contains "$stderr" "--size-check is not one JSON object whose verdict is pass, skipped, stop or unjudged: $D/bad-verdict.json"
  printf '{"triggers":[]}\n' > "$D/bad-verdict.json"
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --size-check "$D/bad-verdict.json"
  contains "$stderr" "$D/bad-verdict.json"
}

@test "a malformed file is exit 2 even when an earlier condition already fails" {
  printf '{"verdict":"maybe"}\n' > "$D/bad-verdict.json"
  run -2 --separate-stderr zsh "$S" --split "$D/split-ask.json" --size-check "$D/bad-verdict.json"
  contains "$stderr" "$D/bad-verdict.json"
}

@test "usage errors are exit 2: an unknown flag, a dangling flag, a missing file" {
  run -2 --separate-stderr zsh "$S" --round 1
  contains "$stderr" "all-auto-check: unknown argument: --round"
  run -2 --separate-stderr zsh "$S" --split
  contains "$stderr" "all-auto-check: --split needs a file"
  run -2 --separate-stderr zsh "$S" --turn "$D/nope.json"
  contains "$stderr" "all-auto-check: --turn file missing or unreadable: $D/nope.json"
}

@test "a forgotten --turn file fails closed: exit 2 naming the counts, never all-auto" {
  # The reviewer's case: the only turn proposed a split, and it was left out.
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --size-check "$D/pass.json"
  [ -z "$output" ]
  contains "$stderr" "all-auto-check: one --turn per --split: got 1 --split and 0 --turn"
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --split "$D/split-empty.json" \
    --turn "$D/turn-null.json" --size-check "$D/pass.json"
  [ -z "$output" ]
  contains "$stderr" "all-auto-check: one --turn per --split: got 2 --split and 1 --turn"
  # One turn too many is incomplete too.
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" \
    --turn "$D/turn-null.json" --turn "$D/turn-null.json" --size-check "$D/pass.json"
  contains "$stderr" "got 1 --split and 2 --turn"
}

@test "a forgotten --size-check file fails closed: exit 2 when any --split is given with no sizing" {
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-null.json"
  [ -z "$output" ]
  contains "$stderr" "all-auto-check: --split given but no --size-check: got 1 --split and 0 --size-check"
}

@test "the header documents both fail-closed exits" {
  local h; h="$(flat "$S")"
  contains "$h" '# 2 also when any --split is given and the call is incomplete: the # --turn count differs from the --split count (one turn per round), # or no --size-check is given (every converged draft was sized).'
  contains "$h" 'A # file the conductor forgot can never read as all-auto; stderr names # the counts. With no --split at all the result stays no-rounds.'
}

@test "--help prints the usage and exits 0" {
  run -0 --separate-stderr zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$stderr" "usage: all-auto-check.zsh"
}

@test "jq missing from PATH is exit 2, nothing judged" {
  local zsh_bin; zsh_bin="$(command -v zsh)"
  mkdir -p "$BATS_TEST_TMPDIR/nobin"
  run -2 --separate-stderr env PATH="$BATS_TEST_TMPDIR/nobin" "$zsh_bin" "$S" --split "$D/split-empty.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "all-auto-check: jq not found on PATH"
}


@test "each file must hold exactly one JSON document: a second document is exit 2, never all-auto" {
  # Every other part of each call is valid, so only the one-document rule can reject it.
  cat "$D/split-empty.json" "$D/split-empty.json" > "$D/two-splits.json"
  run -2 --separate-stderr zsh "$S" --split "$D/two-splits.json" --turn "$D/turn-null.json" --size-check "$D/pass.json"
  [ -z "$output" ]
  contains "$stderr" "--split is not one JSON object with auto and ask arrays: $D/two-splits.json"
  cat "$D/turn-null.json" "$D/turn-null.json" > "$D/two-turns.json"
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --turn "$D/two-turns.json" --size-check "$D/pass.json"
  [ -z "$output" ]
  contains "$stderr" "--turn is not one JSON object with a questions array: $D/two-turns.json"
  cat "$D/pass.json" "$D/pass.json" > "$D/two-verdicts.json"
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-null.json" --size-check "$D/two-verdicts.json"
  [ -z "$output" ]
  contains "$stderr" "--size-check is not one JSON object whose verdict is pass, skipped, stop or unjudged: $D/two-verdicts.json"
}

@test "a split's auto and a turn's questions must be arrays: any other type is exit 2" {
  printf '{"auto":{},"ask":[]}\n' > "$D/auto-object.json"
  run -2 --separate-stderr zsh "$S" --split "$D/auto-object.json" --turn "$D/turn-null.json" --size-check "$D/pass.json"
  [ -z "$output" ]
  contains "$stderr" "--split is not one JSON object with auto and ask arrays: $D/auto-object.json"
  printf '{"ask":[]}\n' > "$D/auto-missing.json"
  run -2 --separate-stderr zsh "$S" --split "$D/auto-missing.json" --turn "$D/turn-null.json" --size-check "$D/pass.json"
  contains "$stderr" "$D/auto-missing.json"
  printf '{"questions":{},"proposed_split":null}\n' > "$D/questions-object.json"
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --turn "$D/questions-object.json" --size-check "$D/pass.json"
  [ -z "$output" ]
  contains "$stderr" "--turn is not one JSON object with a questions array: $D/questions-object.json"
  printf '{"proposed_split":null}\n' > "$D/questions-missing.json"
  run -2 --separate-stderr zsh "$S" --split "$D/split-empty.json" --turn "$D/questions-missing.json" --size-check "$D/pass.json"
  contains "$stderr" "$D/questions-missing.json"
}

@test "an unreadable file is exit 2, named on stderr" {
  [ "$(id -u)" -ne 0 ] || skip "root reads a mode-000 file"
  cp "$D/split-empty.json" "$D/locked.json"
  chmod 000 "$D/locked.json"
  run -2 --separate-stderr zsh "$S" --split "$D/locked.json" --turn "$D/turn-null.json" --size-check "$D/pass.json"
  chmod 600 "$D/locked.json"
  [ -z "$output" ]
  contains "$stderr" "all-auto-check: --split file missing or unreadable: $D/locked.json"
}

# --- the wiring ----------------------------------------------------------------

@test "SKILL.md runs the check and writes an all-auto refinement back with no approval prompt" {
  local t; t="$(flat "$SKILL")"
  contains "$t" '### Step 2 — the all-auto check (#2938)'
  contains "$t" '"<skill-base-dir>/scripts/all-auto-check.zsh"'
  contains "$t" 'For a sizing that ended in exit 3, or in a second exit 2, write the one-line file `{"verdict":"unjudged"}` and pass that.'
  contains "$t" '- **`all-auto`** — no approval prompt. Add the Decisions taken section as for an approved rewrite and run Step 2.5 and Step 3 at once, with `provenance.generated_by` set to `issue-refiner via /development:refine-issue (all answers auto-accepted)`.'
  contains "$t" '- **Any other reason** — present the exact rewrite for the human'"'"'s approval, as above. A refinement in which any intent or gap question reached the human is never all-auto.'
  contains "$t" 'The unattended follow-up mode never runs this check: its `accept` stands in for the approval, with its own provenance string.'
  contains "$t" 'Once the human approves the rewrite, or the all-auto check reports `all-auto` (#2938), and **before** you write the block back'
  contains "$t" 'rm -rf /tmp/refine-issue-rounds && mkdir -p /tmp/refine-issue-rounds'
}

@test "SKILL.md: Step 6's all-auto trail lists every answer with confidence, weakest criterion and the threshold's source" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'Carry `<milli>` in your notes for Step 2, and `<source>` for Step 6'"'"'s trail of an all-auto refinement.'
  contains "$t" '**An all-auto refinement'"'"'s trail (#2938)** says that the rewrite was written back without an approval prompt because every answer was auto-accepted. It lists every auto-taken answer of the run, `implementation` ones included, each with its question, answer, confidence and weakest criterion, and states the threshold with its source'
}

@test "SKILL.md: an epic walk writes an all-auto child back in phase A and batches only the others" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'An all-auto child (*Step 2 — the all-auto check*, #2938) needs no approval, so it never enters a batch: it is written back in phase A, and only the others are batched.'
  contains "$t" 'a typed park, a filed split, and an all-auto write-back.'
  contains "$t" 'When it reports `all-auto`, add its Decisions taken section and run its Steps 2.5, 3, 4, 5, 6 and 7 at once, in this phase A'
  contains "$t" 'its `phase` becomes `ended`, or `drafting` when its re-gate loops it back, and then it redrafts at once, still in this phase A, with no wait recorded.'
  contains "$t" 'a child written back all-auto in phase A redrafts at once instead (#2938).'
}

@test "SKILL.md states the all-auto rule, the inputs and the two outcomes" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'A refinement is **all-auto** when, across the whole run, every round'"'"'s split file had an empty `ask` set (intent and gap questions only), every size check passed or was skipped, and no round'"'"'s refiner turn carried a non-null `proposed_split`.'
  contains "$t" 'Pass one `--split` and one `--turn` per round of this run, and one `--size-check` per `size-check.zsh` run of this run, Step 1'"'"'s included: its stdout on exit 0 or 1.'
  contains "$t" 'It prints `{all_auto, reason}`, the reason the first that fails of `no-rounds`, `ask-question`, `size-check-stop`, `size-check-unjudged` and `proposed-split`, else `all-auto`.'
  contains "$t" '**`all-auto`** — no approval prompt.'
  contains "$t" 'A refinement in which any intent or gap question reached the human is never all-auto.'
}

@test "SKILL.md guardrails name the all-auto exception" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'It approves the rewrite only when it answered everything, as `scripts/all-auto-check.zsh` decides'
  lacks "$t" 'It never approves the rewrite'
  lacks "$t" 'Auto-accept never approves the rewrite'
}

@test "ARCHITECTURE.md's auto-accept scope states the all-auto rule" {
  local a; a="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$a" '- **Scope:** questions, and the approval of an all-auto refinement (#2938). Auto-accept approves the rewrite only when it answered everything.'
  contains "$a" 'reports the first failing reason in the order `no-rounds`, `ask-question`, `size-check-stop`, `size-check-unjudged`, `proposed-split`, else `all-auto`.'
  contains "$a" 'Any other refinement still presents the exact rewrite for the human'"'"'s approval before the Step 3 write-back.'
  lacks "$a" 'still never approves a rewrite'
}

@test "the docs pages state the all-auto exception" {
  local e h
  e="$(flat "$REPO_ROOT/docs/explanation/workflow-refine-issue.md")"
  h="$(flat "$REPO_ROOT/docs/how-to/let-refine-issue-answer-confident-questions.md")"
  contains "$e" 'Only your explicit approval of that exact text moves the run on, unless the refinement is all-auto. Auto-accept approves the rewrite only when it answered everything'
  contains "$e" 'An all-auto child, one whose questions were all answered automatically, is written back there too and never joins the batch.'
  lacks "$e" 'Auto-accept never approves a rewrite.'
  contains "$h" 'You still approve the finished rewrite before anything is written to the issue, unless the threshold answered every question.'
  contains "$h" 'Auto-accept approves the rewrite only when it answered everything. When no intent or gap question reached you'
  lacks "$h" 'It never approves the rewrite for you.'
}

@test "ask-branches.md's RF-05 row states the all-auto exception" {
  contains "$(cat "$REPO_ROOT/development/skills/refine-issue/reference/ask-branches.md")" \
    '| RF-05 | SKILL.md | `explicit approval of the exact rewrite` | intent | human-owned: auto-accept approves the rewrite only when it answered everything (#2898) — the all-auto exception:'
}

# --- every new or changed sentence is pinned (#2938 round 1) ---------------------

@test "SKILL.md: every sizing's verdict file, Step 1's included, is kept in the run's rounds directory" {
  local t; t="$(flat "$SKILL")"
  contains "$t" 'Keep this run'"'"'s turn and split files of every round, and every sizing'"'"'s verdict file, Step 1'"'"'s and Step 2'"'"'s, in its rounds directory for the all-auto check: `/tmp/refine-issue-rounds/`, or a child'"'"'s `/tmp/refine-issue-epic-<E>/<N>.rounds/` in an epic walk, which a redraft keeps.'
  contains "$t" 'Keep this sizing'"'"'s verdict file in the rounds directory for the all-auto check: its stdout on exit 0 or 1, else the one-line file `{"verdict":"unjudged"}`.'
  contains "$t" 'On every other converged draft that the size check did not stop, judge the whole run so far, from the repository root:'
  contains "$t" 'Pass no other file: the conductor'"'"'s defaults file and a resumed park'"'"'s decisions file are not split files here. A run that loops back from Step 5 keeps every earlier round'"'"'s files.'
  contains "$t" '# The all-auto check'"'"'s inputs (#2938) are this run'"'"'s alone: a single-issue # run keeps them here, an epic walk child in its own directory (Step 2).'
}

@test "SKILL.md: the size check's exits route through the all-auto check before any approval" {
  local t; t="$(flat "$SKILL")"
  contains "$t" '- **Exit 0** — `pass` or `skipped`: keep its stdout as this sizing'"'"'s verdict file, run the all-auto check (below), and present the draft for approval as above only if it is not all-auto.'
  contains "$t" '- **Exit 3, or a second 2** — the inventory could not be judged. Write the one-line file `{"verdict":"unjudged"}` as this sizing'"'"'s verdict file, run the all-auto check (below), tell the human in one line and present the draft: resolve-issue §2'"'"'s pre-flight remains the backstop.'
  contains "$t" '- **Exit 1** — `stop`. Do **not** present the draft for approval. Keep its stdout as this sizing'"'"'s verdict file. Relay the'
  lacks "$t" '`pass` or `skipped`: present the draft for approval as above.'
  contains "$t" 'then run **the all-auto check** (*Step 2 — the all-auto check*, below), and only a draft that does not stop and is not all-auto is presented: the **final `proposed_prose` + `proposed_story_spec`**, for the human'"'"'s **explicit approval of the exact rewrite**.'
}

@test "SKILL.md: the all-auto loop is bounded at two rejected all-auto write-backs" {
  local t; t="$(flat "$SKILL")"
  contains "$t" '**The all-auto loop is bounded.** On a Step 5 `NEEDS_REFINEMENT` re-gate after an all-auto write-back, append one line to `all-auto-rejections` in the run'"'"'s rounds directory. Once that file holds two lines, the re-gate has rejected two all-auto write-backs: the next draft and every later one of this run go to the human for approval as for any other reason, whatever the check reports, so the human can stop the loop. In an epic walk such a child'"'"'s draft is pending and joins the next batch.'
  contains "$t" 'A second rejected all-auto write-back sends the next draft to the human (*The all-auto loop is bounded*, Step 2).'
  contains "$t" 'Once the all-auto loop'"'"'s bound (Step 2) is reached, its next draft is pending like any other.'
  contains "$t" 'An all-auto child is never pending: phase A writes it back, until *The all-auto loop is bounded* (below) sends its next draft to the batch.'
  contains "$t" '| The label stays, and the human can stop from inside the loop; after a second rejected all-auto write-back, the next draft goes to the human (#2938). |'
}

@test "SKILL.md: the all-auto exception's other mentions" {
  local t s3; t="$(flat "$SKILL")"
  contains "$t" 'Then Steps 4 to 7 as written; Step 6'"'"'s trail names every answer the run took for the human.'
  contains "$t" '| Nothing is written without Step 2'"'"'s approval of the exact rewrite, or a run that asked the human nothing (the all-auto check, #2938). |'
  contains "$t" 'nothing is written without Step 2'"'"'s approval of the exact rewrite, unless no question reaches the human at all (*Step 2 — the all-auto check*).'
  contains "$t" 'Run the all-auto check on its own rounds and sizings first.'
  contains "$t" 'An all-auto write-back is one such ending.'
  contains "$t" 'An all-auto refinement shows no approval, and its trail lists every one.'
  contains "$t" '**Auto-accept approves the rewrite only when it answered everything.** The threshold only answers the refiner'"'"'s questions. The approval of the exact rewrite is the human'"'"'s, whatever the threshold, unless the refinement is all-auto (*Step 2 — the all-auto check*, below): no question reached the human, so there is no choice left to approve.'
  contains "$t" '— the two exceptions are an all-auto refinement (#2938), in which no question reached the human, and the unattended follow-up mode'"'"'s `accept`.'
  s3="$(sed -n '/^## Step 3 /,/^## Step 4 /p' "$SKILL" > "$BATS_TEST_TMPDIR/s3.md"; flat "$BATS_TEST_TMPDIR/s3.md")"
  contains "$s3" '`"issue-refiner via /development:refine-issue"`, or `"issue-refiner via /development:refine-issue (all answers auto-accepted)"` for an all-auto refinement'
}

@test "ask-branches.md's RF-02 and RF-10 outcome cells state the all-auto exception in full" {
  local a; a="$(cat "$REPO_ROOT/development/skills/refine-issue/reference/ask-branches.md")"
  contains "$a" '| implementation | **default:** proceed without the label, with a notice; nothing is written without the approval of the exact rewrite, or an all-auto refinement (#2938) |'
  contains "$a" '| intent | human-owned: the batch approval of an epic walk'"'"'s rewrites (#2904) is RF-05'"'"'s approval, asked once per batch instead of once per child; an all-auto child is written back in phase A and never batched (#2938) |'
}

@test "ARCHITECTURE.md and the docs pages state the fail-closed call and the loop's bound" {
  local a e h
  a="$(flat "$REPO_ROOT/ARCHITECTURE.md")"
  e="$(flat "$REPO_ROOT/docs/explanation/workflow-refine-issue.md")"
  h="$(flat "$REPO_ROOT/docs/how-to/let-refine-issue-answer-confident-questions.md")"
  contains "$a" 'It fails closed on a forgotten file: a call with `--split` files whose `--turn` count differs, or with no `--size-check`, is exit 2, which the conductor counts as not all-auto. Step 1'"'"'s sizing is kept as a verdict file too. The loop is bounded: once the re-gate has rejected two all-auto write-backs, every later draft of the run goes to the human for approval.'
  contains "$e" 'If the readiness gate rejects two such rewrites, the next draft waits for your approval.'
  contains "$h" 'If the readiness gate rejects two such rewrites, the next draft waits for your approval.'
}

@test "phase A's pending branch keeps its Decisions-taken step, and a relayed or re-spawned round keeps one split and one turn file" {
  local s; s="$(tr '\n' ' ' < "$REPO_ROOT/development/skills/refine-issue/SKILL.md" | tr -s ' ')"
  contains "$s" 'Any other reason: add its Decisions taken section to the draft as Step 2 says, re-read the issue'"'"'s current block into `old_block`, write its rewrite to `rewrite_path`, set `phase` to `pending`, and go on to the next child.'
  contains "$s" 'The re-spawned turn supersedes the failed one: delete the failed turn'"'"'s file, so the round keeps one turn file. When the questions are relayed as they are, write the round'"'"'s split file yourself, as `{"auto":[],"ask":[<the relayed questions>]}`, so the all-auto check sees that the round reached the human (#2938).'
  contains "$s" 'A `--split` and `--turn` count mismatch is fixed only by deleting a re-spawned round'"'"'s superseded turn file or by writing a relayed round'"'"'s split file (Step 2), never by dropping the turn file of a round whose questions went to the human.'
}

@test "a resumed parked session is never all-auto, and a second exit 2 from the check counts as not all-auto" {
  local s; s="$(tr '\n' ' ' < "$REPO_ROOT/development/skills/refine-issue/SKILL.md" | tr -s ' ')"
  contains "$s" 'A resumed session is **never all-auto** (#2938): its parked questions already reached the human, and Step 0 emptied the rounds directory that would have shown it, so its rewrite is always presented for approval.'
  contains "$s" '# only when a parked state was read; an epic walk child uses its own # /tmp/refine-issue-epic-<E>/<N>.rounds/ instead, created here if missing mkdir -p /tmp/refine-issue-rounds && touch /tmp/refine-issue-rounds/resumed'
  contains "$s" 'fix it and re-run once. A `--split` and `--turn` count mismatch'
  contains "$s" 'A resumed parked session (its rounds directory holds `resumed`, Step 0) is never all-auto: skip the check and take *Any other reason* below.'
  contains "$s" 'never by dropping the turn file of a round whose questions went to the human. A second exit 2 counts as not all-auto.'
}

@test "the docs pages say a resumed refinement always asks for approval" {
  contains "$(flat "$REPO_ROOT/docs/how-to/let-refine-issue-answer-confident-questions.md")" 'A refinement resumed from a parked comment always waits for it too, since its earlier questions already reached you.'
  contains "$(flat "$REPO_ROOT/docs/explanation/workflow-refine-issue.md")" 'A refinement resumed from a parked comment always waits for it too, since its earlier questions already reached you.'
}

@test "the header documents --help as exit 0" {
  contains "$(flat "$S")" '# 0 also for -h/--help, which prints the usage on stderr and judges nothing.'
}
