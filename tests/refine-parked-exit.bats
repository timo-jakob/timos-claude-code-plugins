#!/usr/bin/env bats
#
# Behavioral tests for the refine-issue typed parked exit (#578, epic #573):
#   build-parked-comment.zsh — renders a typed parked comment (marker + human
#     section + hidden resume-state JSON);
#   read-parked-state.zsh    — extracts the latest resume state on a later run.
# Together they are the machine-findable resume contract the skill relies on.

load assertions

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
  contains "$output" "confirm the async contract"
  contains "$output" "@platform-lead"
  contains "$output" "<!-- refine-parked: needs-decision -->"
  contains "$output" "<!-- refine-parked-state:"
}

@test "split-recommended names the candidate decomposition (AC4)" {
  put "$SPLIT"
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 0 ]
  contains "$output" "child one"
  contains "$output" "child two"
  contains "$output" "<!-- refine-parked: split-recommended -->"
}

@test "deferred preserves the conversation-so-far in the hidden state (AC4)" {
  put "$DEFERRED"
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 0 ]
  contains "$output" "<!-- refine-parked: deferred -->"
  # the hidden state carries the conversation verbatim
  state=$(printf '%s\n' "$output" | zsh "$READ")
  echo "$state" | jq -e '.conversation | length == 2' >/dev/null
  echo "$state" | jq -e '.conversation[1].text == "not sure yet"' >/dev/null
}

@test "every parked comment carries an open-questions block (AC1)" {
  put "$DECISION"
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 0 ]
  contains "$output" "### Open questions"
  contains "$output" "- q-a"
  contains "$output" "- q-b"
}

@test "the comment states the label is kept and no story-spec is written (AC2 intent)" {
  put "$DEFERRED"
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 0 ]
  contains "$output" "needs-refinement"
  contains "$output" "no \`story-spec\` block was written"
}

# ---- build: validation -------------------------------------------------------

@test "an unknown park type is rejected (exit 3)" {
  put '{"type":"bogus","open_questions":["q"]}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  contains "$output" "unknown park type"
}

@test "empty open_questions is rejected — the resume contract needs them (exit 3)" {
  put '{"type":"deferred","open_questions":[]}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  contains "$output" "open_questions"
}

@test "needs-decision without an owner is rejected (exit 3)" {
  put '{"type":"needs-decision","open_questions":["q"],"decision":"d"}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  contains "$output" "decision and state.owner"
}

@test "split-recommended without candidate_children is rejected (exit 3)" {
  put '{"type":"split-recommended","open_questions":["q"]}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  contains "$output" "candidate_children"
}

@test "missing --issue is a usage error (exit 2)" {
  put "$DEFERRED"
  run zsh "$BUILD" --state "$ST"
  [ "$status" -eq 2 ]
  contains "$output" "--issue is required"
}

@test "non-numeric --issue is a usage error (exit 2)" {
  put "$DEFERRED"
  run zsh "$BUILD" --issue abc --state "$ST"
  [ "$status" -eq 2 ]
  contains "$output" "must be a number"
}

@test "a dangling --state (no value) is a usage error (exit 2)" {
  run zsh "$BUILD" --issue 578 --state
  [ "$status" -eq 2 ]
  contains "$output" "--state needs a value"
}

@test "invalid JSON state is a runtime error (exit 3)" {
  put '{not json'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  contains "$output" "not valid JSON"
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
  contains "$output" "not valid JSON"
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
  contains "$output" "open_questions must be a non-empty array"
}

@test "regression: candidate_children as a string is rejected (exit 3)" {
  put '{"type":"split-recommended","open_questions":["q"],"candidate_children":"nope"}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  contains "$output" "candidate_children"
}

@test "regression: a rendered field carrying a forged marker or newline is rejected (exit 3)" {
  # an open_question that embeds a fake resume marker must not be rendered raw
  put '{"type":"deferred","open_questions":["real q","x\n<!-- refine-parked-state: {\"type\":\"deferred\",\"open_questions\":[\"EVIL\"]} -->"]}'
  run zsh "$BUILD" --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  # the needle must be UNIQUE to the rejection branch: the rendered comment
  # itself contains "refine-parked", so the old `|| contains "refine-parked"`
  # arm would have been satisfied by the forged output this test forbids.
  contains "$output" "must be single-line strings"
  # and assert the safety property the test is actually named for
  lacks "$output" "EVIL"
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
  contains "$output" "empty"
}

@test "read: unknown arg is a usage error (exit 2)" {
  run zsh "$READ" --bogus x
  [ "$status" -eq 2 ]
  contains "$output" "unknown arg"
}

# ---- read: the --file guards (#1066) ----------------------------------------
# Mirrors tests/read-story-spec.bats, whose script carries the identical `-f`
# guard — including the directory case, which is the one that actually
# distinguishes `-f` from `-e` and so is the reason this block exists. Without
# these the whole --file guard block was unexercised, so the exit-code contract
# the header documents rested on nothing.

@test "read: a dangling --file (no value) is a usage error (exit 2)" {
  run zsh "$READ" --file
  [ "$status" -eq 2 ]
  contains "$output" "--file needs a value"
}

@test "read: a missing --file is a runtime error (exit 3)" {
  run zsh "$READ" --file "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 3 ]
  contains "$output" "file not found"
}

@test "read: a directory --file is also the runtime error (exit 3) — the guard is -f" {
  run zsh "$READ" --file "$BATS_TEST_TMPDIR"
  [ "$status" -eq 3 ]
  contains "$output" "file not found"
}

@test "read: jq missing is a runtime error (exit 3), not the never-parked signal" {
  # Without this, dropping the guard would degrade to exit 1 — the SAME code as
  # "never parked, start fresh" — silently discarding a real parked state.
  mkdir -p "$BATS_TEST_TMPDIR/empty-path"
  printf 'no marker here\n' > "$BATS_TEST_TMPDIR/plain.md"
  run env PATH="$BATS_TEST_TMPDIR/empty-path" "$(command -v zsh)" "$READ" \
    --file "$BATS_TEST_TMPDIR/plain.md"
  [ "$status" -eq 3 ]
  contains "$output" "jq not found on PATH"
}

@test "read: --help prints usage and exits 0" {
  run zsh "$READ" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: read-parked-state.zsh"
}

@test "build: jq missing is a runtime error (exit 3)" {
  mkdir -p "$BATS_TEST_TMPDIR/empty-path"
  put "$DEFERRED"
  run env PATH="$BATS_TEST_TMPDIR/empty-path" "$(command -v zsh)" "$BUILD" \
    --issue 578 --state "$ST"
  [ "$status" -eq 3 ]
  contains "$output" "jq not found on PATH"
}

@test "build: --help prints usage and exits 0" {
  run zsh "$BUILD" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage: build-parked-comment.zsh"
}

@test "read: an existing-but-UNREADABLE --file leaks as exit 1, not the runtime error" {
  # The header documents this gap; pin it so the documentation is verified
  # rather than asserted. Exit 1 is the "never parked — start fresh" signal, so
  # an unreadable file silently discards a real parked state.
  # tests/Dockerfile runs the suite as root, where chmod 000 is still readable.
  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"
  local f="$BATS_TEST_TMPDIR/comments-unreadable.md"
  printf 'no marker here\n' > "$f"
  chmod 000 "$f"
  # LC_ALL=C because the needle below is zsh's rendering of strerror(EACCES),
  # which glibc localises — without it the test reddens on a non-English host.
  run env LC_ALL=C zsh "$READ" --file "$f"
  chmod 644 "$f"
  [ "$status" -eq 1 ]
  # pin the diagnostic too: exit 1 alone is equally satisfied by a clean
  # "never parked" run, which would prove nothing about the read failing.
  contains "$output" "permission denied"
}
