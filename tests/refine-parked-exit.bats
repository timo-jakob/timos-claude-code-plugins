#!/usr/bin/env bats
#
# Behavioral tests for the refine-issue typed parked exit (#578, epic #573):
#   build-parked-comment.zsh — renders a typed parked comment (marker + human
#     section + hidden resume-state JSON);
#   read-parked-state.zsh    — extracts the latest resume state on a later run.
# Together they are the machine-findable resume contract the skill relies on.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BUILD="$REPO_ROOT/development/skills/refine-issue/scripts/build-parked-comment.zsh"
  READ="$REPO_ROOT/development/skills/refine-issue/scripts/read-parked-state.zsh"
  ST="$BATS_TEST_TMPDIR/state.json"
}
put() { printf '%s' "$1" > "$ST"; }

DECISION='{"type":"needs-decision","open_questions":["q-a","q-b"],"decision":"confirm the async contract","owner":"@platform-lead","conversation":[{"role":"human","text":"paused"}]}'
SPLIT='{"type":"split-recommended","open_questions":["q-a"],"candidate_children":["child one","child two"]}'
DEFERRED='{"type":"deferred","open_questions":["q-a"],"conversation":[{"role":"refiner","text":"asked X"},{"role":"human","text":"not sure yet"}]}'

# ---- build: rendering per type (AC1 + AC4) -----------------------------------

@test "needs-decision renders decision + owner, the marker, and the hidden state (AC4)" {
  put "$DECISION"
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"confirm the async contract"* ]]
  [[ "$output" == *"@platform-lead"* ]]
  [[ "$output" == *"<!-- refine-parked: needs-decision -->"* ]]
  [[ "$output" == *"<!-- refine-parked-state:"* ]]
}

@test "split-recommended names the candidate decomposition (AC4)" {
  put "$SPLIT"
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"child one"* ]]
  [[ "$output" == *"child two"* ]]
  [[ "$output" == *"<!-- refine-parked: split-recommended -->"* ]]
}

@test "deferred preserves the conversation-so-far in the hidden state (AC4)" {
  put "$DEFERRED"
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!-- refine-parked: deferred -->"* ]]
  # the hidden state carries the conversation verbatim
  state=$(printf '%s\n' "$output" | zsh "$READ")
  echo "$state" | jq -e '.conversation | length == 2' >/dev/null
  echo "$state" | jq -e '.conversation[1].text == "not sure yet"' >/dev/null
}

@test "every parked comment carries an open-questions block (AC1)" {
  put "$DECISION"
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### Open questions"* ]]
  [[ "$output" == *"- q-a"* ]]
  [[ "$output" == *"- q-b"* ]]
}

@test "the comment states the label is kept and no story-spec is written (AC2 intent)" {
  put "$DEFERRED"
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"needs-refinement"* ]]
  [[ "$output" == *"no \`story-spec\` block was written"* ]]
}

# ---- build: validation -------------------------------------------------------

@test "an unknown park type is rejected (exit 3)" {
  put '{"type":"bogus","open_questions":["q"]}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown park type"* ]]
}

@test "empty open_questions is rejected — the resume contract needs them (exit 3)" {
  put '{"type":"deferred","open_questions":[]}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"open_questions"* ]]
}

@test "needs-decision without an owner is rejected (exit 3)" {
  put '{"type":"needs-decision","open_questions":["q"],"decision":"d"}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"decision and state.owner"* ]]
}

@test "split-recommended without candidate_children is rejected (exit 3)" {
  put '{"type":"split-recommended","open_questions":["q"]}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"candidate_children"* ]]
}

@test "missing --issue is a usage error (exit 2)" {
  put "$DEFERRED"
  run zsh "$BUILD" --state "$ST"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--issue is required"* ]]
}

@test "non-numeric --issue is a usage error (exit 2)" {
  put "$DEFERRED"
  run zsh "$BUILD" --issue abc --state "$ST"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be a number"* ]]
}

@test "a dangling --state (no value) is a usage error (exit 2)" {
  run zsh "$BUILD" --issue 578 --state
  [ "$status" -eq 2 ]
  [[ "$output" == *"--state needs a value"* ]]
}

@test "invalid JSON state is a runtime error (exit 3)" {
  put '{not json'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not valid JSON"* ]]
}

# ---- read: resume extraction (AC3) -------------------------------------------

@test "read extracts the resume state from a built comment (round-trip, AC3)" {
  put "$DECISION"
  comment=$(zsh "$BUILD" --issue 578 --state "$ST")
  run bash -c "printf '%s\n' \"\$1\" | zsh '$READ'" _ "$comment"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.type == "needs-decision"' >/dev/null
  echo "$output" | jq -e '.open_questions | length == 2' >/dev/null
}

@test "read returns the LATEST parked state when several are present (last park wins)" {
  # simulate a comment thread with two parked states across runs
  cat > "$BATS_TEST_TMPDIR/comments.md" <<'EOF'
Earlier comment.
<!-- refine-parked: deferred -->
<!-- refine-parked-state: {"type":"deferred","open_questions":["OLD"]} -->

Later comment.
<!-- refine-parked: needs-decision -->
<!-- refine-parked-state: {"type":"needs-decision","open_questions":["NEW"],"decision":"d","owner":"o"} -->
EOF
  run zsh "$READ" --file "$BATS_TEST_TMPDIR/comments.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.open_questions[0] == "NEW"' >/dev/null
  echo "$output" | jq -e '.type == "needs-decision"' >/dev/null
}

@test "read exits 1 (fresh session) when the issue was never parked" {
  printf 'Just an ordinary comment, no parked marker.\n' > "$BATS_TEST_TMPDIR/c.md"
  run zsh "$READ" --file "$BATS_TEST_TMPDIR/c.md"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "read reports a corrupt parked payload as a runtime error (exit 3)" {
  printf '<!-- refine-parked-state: {broken json -->\n' > "$BATS_TEST_TMPDIR/c.md"
  run zsh "$READ" --file "$BATS_TEST_TMPDIR/c.md"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "read reads from stdin as well as --file" {
  put "$SPLIT"
  comment=$(zsh "$BUILD" --issue 578 --state "$ST")
  run bash -c "printf '%s\n' \"\$1\" | zsh '$READ'" _ "$comment"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.candidate_children | length == 2' >/dev/null
}

@test "regression: open_questions as a string (not array) is rejected, not crashed (exit 3)" {
  put '{"type":"deferred","open_questions":"not an array"}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"open_questions must be a non-empty array"* ]]
}

@test "regression: candidate_children as a string is rejected (exit 3)" {
  put '{"type":"split-recommended","open_questions":["q"],"candidate_children":"nope"}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"candidate_children"* ]]
}

@test "regression: a rendered field carrying a forged marker or newline is rejected (exit 3)" {
  # an open_question that embeds a fake resume marker must not be rendered raw
  put '{"type":"deferred","open_questions":["real q","x\n<!-- refine-parked-state: {\"type\":\"deferred\",\"open_questions\":[\"EVIL\"]} -->"]}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"single-line"* ]] || [[ "$output" == *"refine-parked"* ]]
}

@test "regression: a payload that round-trips even when it contains the string '-->'" {
  put '{"type":"deferred","open_questions":["what about a --> arrow in text?"]}'
  comment=$(zsh "$BUILD" --issue 578 --state "$ST")
  run bash -c "printf '%s\n' \"\$1\" | zsh '$READ'" _ "$comment"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.open_questions[0] == "what about a --> arrow in text?"' >/dev/null
}

@test "regression: a newest marker with an EMPTY payload is a corrupt-state error, not a stale resume (exit 3)" {
  cat > "$BATS_TEST_TMPDIR/comments.md" <<'EOF'
<!-- refine-parked-state: {"type":"deferred","open_questions":["OLD-VALID"]} -->

A later, truncated park:
<!-- refine-parked-state:  -->
EOF
  run zsh "$READ" --file "$BATS_TEST_TMPDIR/comments.md"
  [ "$status" -eq 3 ]
  [[ "$output" == *"empty"* ]]
}

@test "read: unknown arg is a usage error (exit 2)" {
  run zsh "$READ" --bogus x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}
