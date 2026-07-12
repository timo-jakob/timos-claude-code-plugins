#!/usr/bin/env bats
#
# Behavioral tests for plan-acceptance-tests.zsh (#696, epic #573): turn a
# story-spec/v1 block into the same-PR acceptance-test plan — one entry per
# LINKED test case, mapping tooling to its tests/acceptance/<surface>/ directory.
# The contract:
#   - a story with linked test cases -> a plan naming issue + dir per case;
#   - no linked test cases -> exit 1 (fall back to implementing only the story);
#   - an unlinked case (issue null) is not planned;
#   - an unknown tooling on a LINKED case is a hard error.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/plan-acceptance-tests.zsh"
  SPEC="$BATS_TEST_TMPDIR/spec.json"
}
put() { printf '%s' "$1" > "$SPEC"; }

FULL='{"schema":"story-spec/v1","test_cases":[
  {"id":"tc-happy","kind":"happy","tooling":"curl","issue":701},
  {"id":"tc-web","kind":"corner","tooling":"playwright","issue":702},
  {"id":"tc-grpc","kind":"error","tooling":"grpcurl","issue":703},
  {"id":"tc-cli","kind":"happy","tooling":"cli","issue":704},
  {"id":"tc-unlinked","kind":"corner","tooling":"curl","issue":null}]}'

@test "a story with linked test cases produces a plan, one entry per LINKED case (AC1)" {
  put "$FULL"
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 0 ]
  # 4 linked (701-704); the unlinked one (issue null) is excluded
  echo "$output" | jq -e 'length == 4' >/dev/null
  echo "$output" | jq -e 'all(.[]; .issue|type=="number")' >/dev/null
  echo "$output" | jq -e '[.[].issue] == [701,702,703,704]' >/dev/null
}

@test "tooling maps to the right tests/acceptance/<surface>/ directory (#243 convention)" {
  put "$FULL"
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[] | select(.tooling=="curl").dir')" = "tests/acceptance/rest" ]
  [ "$(echo "$output" | jq -r '.[] | select(.tooling=="playwright").dir')" = "tests/acceptance/web" ]
  [ "$(echo "$output" | jq -r '.[] | select(.tooling=="grpcurl").dir')" = "tests/acceptance/grpc" ]
  [ "$(echo "$output" | jq -r '.[] | select(.tooling=="cli").dir')" = "tests/acceptance/cli" ]
}

@test "the plan carries issue + id + kind so resolve-issue can place tests and close issues (AC1/AC2)" {
  put "$FULL"
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0] | has("issue") and has("id") and has("kind") and has("dir")' >/dev/null
  echo "$output" | jq -e '.[] | select(.issue==704) | .id == "tc-cli" and .kind == "happy"' >/dev/null
}

@test "no linked test cases -> exit 1 (fall back to story-only, AC4)" {
  put '{"test_cases":[{"id":"x","tooling":"curl","issue":null}]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an absent test_cases array -> exit 1 (story-only)" {
  put '{"schema":"story-spec/v1","acceptance_criteria":["x"]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 1 ]
}

@test "an unlinked case among linked ones is simply not planned" {
  put '{"test_cases":[{"id":"linked","tooling":"cli","issue":9},{"id":"unlinked","tooling":"cli","issue":null}]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].id == "linked"' >/dev/null
}

@test "a LINKED case with unknown tooling is a hard error naming it (exit 3)" {
  put '{"test_cases":[{"id":"bad","tooling":"telnet","issue":5}]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown tooling"* ]]
  [[ "$output" == *"bad:telnet"* ]]
}

@test "reads from stdin as well as --file" {
  run bash -c "printf '%s' '$FULL' | zsh '$S'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 4' >/dev/null
}

@test "invalid JSON is a runtime error (exit 3)" {
  put '{not json'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "regression: empty input is the story-only fallback (exit 1), not a bad-JSON error" {
  # read-story-spec.zsh writes nothing when there is no block; the planner must
  # treat that as story-only, so the caller does not abort on the common path.
  run bash -c "printf '' | zsh '$S'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "regression: a linked case with ABSENT tooling gets the friendly named error (exit 3)" {
  put '{"test_cases":[{"id":"bad","issue":5}]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown tooling"* ]]
  [[ "$output" == *"bad:"* ]]
}

@test "regression: a linked case with a NON-STRING tooling gets the friendly named error (exit 3)" {
  put '{"test_cases":[{"id":"bad","tooling":5,"issue":5}]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown tooling"* ]]
}

@test "a dangling --file (no value) is a usage error (exit 2)" {
  run zsh "$S" --file
  [ "$status" -eq 2 ]
  [[ "$output" == *"--file needs a value"* ]]
}

@test "unknown arg is a usage error (exit 2)" {
  run zsh "$S" --bogus x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}
