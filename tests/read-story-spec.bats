#!/usr/bin/env bats
#
# Behavioral tests for read-story-spec.zsh (#577, epic #573) — the primitive
# resolve-issue uses to pull the story-spec/v1 block out of an issue body. The
# contract that matters:
#   - when a block is present, print it (selected by content, not position);
#   - when absent, exit 1 with empty stdout so the caller falls back to prose;
#   - an unrelated ```json code block in the prose is never mistaken for the spec.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/read-story-spec.zsh"
  BODY="$BATS_TEST_TMPDIR/body.md"
}

# A realistic refined-issue body: prose, a DECOY json block, then the real
# story-spec/v1 block inside a <details>.
write_full_body() {
  cat > "$BODY" <<'EOF'
Some prose describing the story.

```json
{"unrelated": "decoy", "schema": "something-else/v9"}
```

<!-- story-spec:prose:start -->
The human-authoritative prose.
<!-- story-spec:prose:end -->

<details>
<summary>🤖 machine-readable story spec (story-spec/v1)</summary>

```json
{"schema":"story-spec/v1","acceptance_criteria":["files under 20s"],"scope_boundaries":{"in":["x"],"out":["y"]},"test_cases":[]}
```

</details>
EOF
}

@test "prints the story-spec/v1 block when present (exit 0)" {
  write_full_body
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema == "story-spec/v1"' >/dev/null
  echo "$output" | jq -e '.acceptance_criteria[0] == "files under 20s"' >/dev/null
}

@test "selects by content — the unrelated json code block is ignored" {
  write_full_body
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 0 ]
  # must NOT be the decoy
  echo "$output" | jq -e '.unrelated == null' >/dev/null
  echo "$output" | jq -e '.scope_boundaries.in[0] == "x"' >/dev/null
}

@test "output is compact valid JSON on a single line" {
  write_full_body
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -eq 0 ]  # no trailing newline inside → one line
  echo "$output" | jq -e . >/dev/null
}

@test "no block present -> exit 1 with empty stdout (fallback signal)" {
  printf 'An older issue with only prose, no story-spec block.\n' > "$BODY"
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "reads from stdin when no --file" {
  write_full_body
  run bash -c "cat '$BODY' | zsh '$S'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema == "story-spec/v1"' >/dev/null
}

@test "handles an indented fence inside the <details>" {
  cat > "$BODY" <<'EOF'
<details>
<summary>spec</summary>

    ```json
    {"schema":"story-spec/v1","acceptance_criteria":["indented"]}
    ```

</details>
EOF
  # NOTE: markdown indented-code fences are unusual; the extractor tolerates
  # leading whitespace on the fence lines but the JSON body must still parse.
  run zsh "$S" --file "$BODY"
  # Either it extracts (exit 0) or cleanly reports absent (exit 1) — never crash.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "a malformed story-spec json is treated as absent (safe fallback), not a crash" {
  cat > "$BODY" <<'EOF'
<details>

```json
{"schema":"story-spec/v1", broken json here
```

</details>
EOF
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "picks the story-spec block even when several json blocks precede it" {
  cat > "$BODY" <<'EOF'
```json
{"a": 1}
```
```json
{"b": 2}
```
```json
{"schema":"story-spec/v1","acceptance_criteria":["last"]}
```
EOF
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.acceptance_criteria[0] == "last"' >/dev/null
}

@test "regression: an illustrative json block nested inside a bash example is never consumed as the spec" {
  # A meta/documentation issue whose prose SHOWS a placeholder spec nested inside
  # a bash example (an unbalanced fence — pathological CommonMark), then carries
  # the real block below. The safety property (review finding 1): the extractor
  # must NEVER emit the placeholder as the authoritative spec. Falling back
  # (exit 1) is acceptable; picking the placeholder is not.
  cat > "$BODY" <<'EOF'
Here is how refine-issue writes the block:

```bash
cat <<SPEC
```json
{"schema":"story-spec/v1","acceptance_criteria":["PLACEHOLDER EXAMPLE"]}
```
SPEC
```

<details>
<summary>real spec</summary>

```json
{"schema":"story-spec/v1","acceptance_criteria":["THE REAL CRITERION"]}
```

</details>
EOF
  run zsh "$S" --file "$BODY"
  # Either the real block (exit 0) or a clean fallback (exit 1) — never the placeholder.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [[ "$output" != *"PLACEHOLDER EXAMPLE"* ]]
}

@test "regression: an illustrative balanced json block before the real block loses to it (last wins)" {
  # The realistic meta-issue case: a properly-fenced illustrative spec in the
  # prose, then the generated block appended below. Last-match picks the real one.
  cat > "$BODY" <<'EOF'
For example, a spec looks like:

```json
{"schema":"story-spec/v1","acceptance_criteria":["ILLUSTRATIVE"]}
```

<details>
<summary>generated</summary>

```json
{"schema":"story-spec/v1","acceptance_criteria":["THE REAL CRITERION"]}
```

</details>
EOF
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.acceptance_criteria[0] == "THE REAL CRITERION"' >/dev/null
}

@test "regression: an opening fence with a trailing info string is still recognised" {
  cat > "$BODY" <<'EOF'
<details>

```json title="spec"
{"schema":"story-spec/v1","acceptance_criteria":["info-string ok"]}
```

</details>
EOF
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.acceptance_criteria[0] == "info-string ok"' >/dev/null
}

@test "regression: the LAST story-spec block wins (the appended, authoritative one)" {
  cat > "$BODY" <<'EOF'
<details><summary>stale example</summary>

```json
{"schema":"story-spec/v1","acceptance_criteria":["OLD"]}
```

</details>

<details><summary>generated</summary>

```json
{"schema":"story-spec/v1","acceptance_criteria":["NEW"]}
```

</details>
EOF
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.acceptance_criteria[0] == "NEW"' >/dev/null
}

@test "output is a single JSON object even if the block holds trailing junk" {
  cat > "$BODY" <<'EOF'
```json
{"schema":"story-spec/v1","acceptance_criteria":["one"]}
{"stray": "second value"}
```
EOF
  run zsh "$S" --file "$BODY"
  [ "$status" -eq 0 ]
  # exactly one JSON document on stdout
  [ "$(printf '%s' "$output" | jq -s 'length')" -eq 1 ]
  echo "$output" | jq -e '.schema == "story-spec/v1"' >/dev/null
}

@test "a dangling --file (no value) is a usage error (exit 2), not a stdin read" {
  run zsh "$S" --file
  [ "$status" -eq 2 ]
  [[ "$output" == *"--file needs a value"* ]]
}

@test "unknown arg is a usage error (exit 2)" {
  run zsh "$S" --bogus x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}

@test "missing file is a runtime error (exit 3)" {
  run zsh "$S" --file "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 3 ]
  [[ "$output" == *"file not found"* ]]
}
