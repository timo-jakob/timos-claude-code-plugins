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
    --size-check "$D/pass.json"
  [ "$output" = '{"all_auto":false,"reason":"ask-question"}' ]
}

@test "a size-check stop in an earlier sizing, though the last one passed: size-check-stop" {
  run -0 zsh "$S" --split "$D/split-empty.json" --size-check "$D/stop.json" --size-check "$D/pass.json"
  [ "$output" = '{"all_auto":false,"reason":"size-check-stop"}' ]
}

@test "an unjudged sizing (the conductor's one-line sentinel): size-check-unjudged" {
  run -0 zsh "$S" --split "$D/split-empty.json" --size-check "$D/pass.json" --size-check "$D/unjudged.json"
  [ "$output" = '{"all_auto":false,"reason":"size-check-unjudged"}' ]
}

@test "a non-null proposed_split in a non-final turn: proposed-split" {
  run -0 zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-split.json" \
    --split "$D/split-empty.json" --turn "$D/turn-null.json" --size-check "$D/pass.json"
  [ "$output" = '{"all_auto":false,"reason":"proposed-split"}' ]
}

@test "two failing conditions report the first in the documented order" {
  # ask-question beats size-check-stop
  run -0 zsh "$S" --split "$D/split-ask.json" --size-check "$D/stop.json"
  [ "$output" = '{"all_auto":false,"reason":"ask-question"}' ]
  # size-check-stop beats size-check-unjudged, whichever file comes first
  run -0 zsh "$S" --split "$D/split-empty.json" --size-check "$D/unjudged.json" --size-check "$D/stop.json"
  [ "$output" = '{"all_auto":false,"reason":"size-check-stop"}' ]
  # size-check-unjudged beats proposed-split
  run -0 zsh "$S" --split "$D/split-empty.json" --turn "$D/turn-split.json" --size-check "$D/unjudged.json"
  [ "$output" = '{"all_auto":false,"reason":"size-check-unjudged"}' ]
  # no-rounds beats everything
  run -0 zsh "$S" --turn "$D/turn-split.json" --size-check "$D/stop.json"
  [ "$output" = '{"all_auto":false,"reason":"no-rounds"}' ]
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
