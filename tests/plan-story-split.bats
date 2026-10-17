#!/usr/bin/env bats
#
# #2584: plan-story-split.zsh — validate a proposed split of an oversized story.
# The grouping is a subagent's judgement; the script enforces the invariants of
# any split: every criterion exactly once, every child under the size
# pre-flight, every original file somewhere, and an acyclic order. Driven
# directly, each invariant on its own, plus the shape refusals and exit codes.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  export HOME="$BATS_TEST_TMPDIR/home"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  P="$REPO_ROOT/development/skills/resolve-issue/scripts/plan-story-split.zsh"
  D="$BATS_TEST_TMPDIR"
  # run from a dir with no marketplace manifest: every path is unowned, so only
  # the files threshold can stop a child
  cd "$D"
  jq -n '{number: 9, title: "Big story",
          body: "## Problem\n\nx\n\n## Acceptance criteria\n\n- [ ] A one\n- [x] B two\n- [ ] C three\n\n## Out of scope\n\n- [ ] not a criterion\n"}' > "$D/story.json"
  jq -n '{children: [
            {title: "child one", body: "b1", criteria: ["A one", "B two"], files: ["a.md", "b.md"], blocked_by: []},
            {title: "child two", body: "b2", criteria: ["C three"], files: ["c.md", "b.md"], blocked_by: [1]}]}' > "$D/ok.json"
  jq -n '{files: ["a.md", "b.md", "c.md"]}' > "$D/inv.json"
}

# --- a valid plan -------------------------------------------------------------

@test "a valid proposal emits the plan: every child sized, criteria and order carried, no errors (exit 0)" {
  run -0 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/ok.json" --inventory "$D/inv.json"
  [ -z "$stderr" ]
  printf '%s' "$output" | jq -e '.parent == 9 and .valid == true and .criteria_total == 3 and .errors == []' >/dev/null
  printf '%s' "$output" | jq -e '[.children[] | .index] == [1, 2] and [.children[].size.verdict] == ["pass", "pass"]' >/dev/null
  printf '%s' "$output" | jq -e '.children[1] | .criteria == ["C three"] and .blocked_by == [1] and .files == ["c.md", "b.md"] and .body == "b2"' >/dev/null
}

@test "the criteria come from the story-spec block when the story has one" {
  jq -n '{number: 9, title: "t", body: "prose\n\n```json\n{\"schema\":\"story-spec/v1\",\"acceptance_criteria\":[\"X\",\"Y\"]}\n```\n"}' > "$D/spec-story.json"
  jq -n '{children: [{title: "a", body: "", criteria: ["X"], files: ["a.md"]}, {title: "b", body: "", criteria: ["Y"], files: ["b.md"]}]}' > "$D/p.json"
  run -0 zsh "$P" --story "$D/spec-story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.criteria_total == 2 and .valid == true' >/dev/null
}

@test "without --inventory the file-coverage check is skipped" {
  jq '.children[0].files = ["only.md"]' "$D/ok.json" > "$D/p.json"
  run -0 zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.valid == true' >/dev/null
}

# --- each invariant, refused by name ------------------------------------------

@test "a criterion assigned to no child is refused by name (exit 1)" {
  jq '.children[0].criteria = ["A one"]' "$D/ok.json" > "$D/p.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.valid == false and .errors == ["criterion assigned to no child: B two"]' >/dev/null
  contains "$stderr" "plan-story-split: criterion assigned to no child: B two"
}

@test "a child that carries no criterion is refused by index and title, even when every criterion lands elsewhere (exit 1)" {
  jq '.children[0].criteria = ["A one", "B two", "C three"] | .children[1].criteria = []' "$D/ok.json" > "$D/p.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.valid == false and .errors == ["child 2 (child two) carries no acceptance criterion"]' >/dev/null
  contains "$stderr" "plan-story-split: child 2 (child two) carries no acceptance criterion"
}

@test "a criterion assigned to two children is refused by name (exit 1)" {
  jq '.children[1].criteria = ["C three", "A one"]' "$D/ok.json" > "$D/p.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.errors == ["criterion assigned to children 1 and 2: A one"]' >/dev/null
}

@test "a criterion the story does not have is refused, and a reworded one counts as missing (exit 1)" {
  jq '.children[1].criteria = ["C three, reworded"]' "$D/ok.json" > "$D/p.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.errors | index("criterion assigned to no child: C three") != null' >/dev/null
  printf '%s' "$output" | jq -e '.errors | index("child 2 carries a criterion the story does not have: C three, reworded") != null' >/dev/null
}

@test "a child that stops the size pre-flight is refused by index and title (exit 1)" {
  jq '.children[0].files = [range(0; 21) | "f\(.).md"]' "$D/ok.json" > "$D/p.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.errors == ["child 1 (child one) stops the size pre-flight: files"]' >/dev/null
  printf '%s' "$output" | jq -e '.children[0].size.verdict == "stop" and .children[1].size.verdict == "pass"' >/dev/null
}

@test "a child at exactly the file limit passes the pre-flight" {
  jq '.children[0].files = [range(0; 20) | "f\(.).md"]' "$D/ok.json" > "$D/p.json"
  run -0 zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.children[0].size.verdict == "pass"' >/dev/null
}

@test "a file of the original inventory in no child is refused by name (exit 1)" {
  jq '{files: (.files + ["d.md"])}' "$D/inv.json" > "$D/inv2.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/ok.json" --inventory "$D/inv2.json"
  printf '%s' "$output" | jq -e '.errors == ["file in the original inventory assigned to no child: d.md"]' >/dev/null
}

@test "a child blocked by itself or a later child is refused: the order stays acyclic (exit 1)" {
  jq '.children[0].blocked_by = [2]' "$D/ok.json" > "$D/p.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.errors == ["child 1 is blocked by child 2, which is not an earlier child"]' >/dev/null
  jq '.children[1].blocked_by = [2]' "$D/ok.json" > "$D/p.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.errors == ["child 2 is blocked by child 2, which is not an earlier child"]' >/dev/null
}

@test "every gap is reported at once, not only the first" {
  jq '.children[1].criteria = ["A one"] | .children[0].blocked_by = [2]' "$D/ok.json" > "$D/p.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  printf '%s' "$output" | jq -e '.errors | length == 3' >/dev/null
}

# --- input refusals -----------------------------------------------------------

@test "a proposal with fewer than two children, or a malformed child, is a runtime error with nothing on stdout (exit 3)" {
  jq '.children = [.children[0]]' "$D/ok.json" > "$D/p.json"
  run -3 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  contains "$stderr" "a split needs at least two children"
  [ -z "$output" ]
  jq '.children[1].files = "c.md"' "$D/ok.json" > "$D/p.json"
  run -3 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  contains "$stderr" "child 2 files must be an array of non-empty strings"
  jq '.children[0].title = ""' "$D/ok.json" > "$D/p.json"
  run -3 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  contains "$stderr" "child 1 has no title"
  jq '.children[0].criteria = "A one"' "$D/ok.json" > "$D/p.json"
  run -3 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  contains "$stderr" "child 1 criteria must be an array of non-empty strings"
  [ -z "$output" ]
  jq '.children[1].criteria = [""]' "$D/ok.json" > "$D/p.json"
  run -3 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  contains "$stderr" "child 2 criteria must be an array of non-empty strings"
  printf 'not json\n' > "$D/p.json"
  run -3 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  contains "$stderr" "is not JSON"
}

@test "a size pre-flight that errors on a child is a runtime error naming the child and carrying its reason (exit 3)" {
  jq '.children[1].files = ["../x.md"]' "$D/ok.json" > "$D/p.json"
  run -3 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json"
  [ -z "$output" ]
  contains "$stderr" "size-preflight.zsh failed on child 2"
  contains "$stderr" "files must not contain a .. segment"
}

@test "a story with no criteria to assign, or one listing a criterion twice, is a runtime error (exit 3)" {
  jq '.body = "## Problem\n\nno criteria here\n"' "$D/story.json" > "$D/s.json"
  run -3 --separate-stderr zsh "$P" --story "$D/s.json" --proposal "$D/ok.json"
  contains "$stderr" "the story has no acceptance criteria to assign"
  jq '.body = "## Acceptance criteria\n\n- [ ] A one\n- [ ] A one\n"' "$D/story.json" > "$D/s.json"
  run -3 --separate-stderr zsh "$P" --story "$D/s.json" --proposal "$D/ok.json"
  contains "$stderr" "lists the same acceptance criterion twice"
  printf '{"title":"t"}\n' > "$D/s.json"
  run -3 --separate-stderr zsh "$P" --story "$D/s.json" --proposal "$D/ok.json"
  contains "$stderr" "--story must be an issue object with number and body"
}

@test "a malformed inventory is a runtime error (exit 3)" {
  printf '{"paths":["a.md"]}\n' > "$D/i.json"
  run -3 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/ok.json" --inventory "$D/i.json"
  contains "$stderr" "--inventory must be an object with a files array"
}

@test "usage errors exit 2 with nothing on stdout: a missing file, an unknown or dangling flag" {
  run -2 --separate-stderr zsh "$P" --proposal "$D/ok.json"
  contains "$stderr" "--story is required"
  [ -z "$output" ]
  run -2 --separate-stderr zsh "$P" --story "$D/missing.json" --proposal "$D/ok.json"
  contains "$stderr" "cannot read --story"
  run -2 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/ok.json" --bogus x
  contains "$stderr" "unknown argument: --bogus"
  run -2 --separate-stderr zsh "$P" --story "$D/story.json" --proposal
  contains "$stderr" "--proposal requires a value"
}

@test "ARCHITECTURE.md states the split validator and its four invariants" {
  local t; t="$(tr '\n' ' ' < "$REPO_ROOT/ARCHITECTURE.md" | tr -s ' ')"
  grep -qF '**Validating a split (#2584).**' <<< "$t"
  grep -qF 'every acceptance criterion of the original, from its story-spec block or else its `## Acceptance criteria` checkboxes, lands in exactly one child, verbatim, and every child carries at least one;' <<< "$t"
  grep -qF 'a child is blocked only by an earlier one, so the order is acyclic.' <<< "$t"
  grep -qF 'It never invents a grouping and files nothing.' <<< "$t"
}

@test "--manifest is passed through to the size pre-flight, and -h prints usage on stderr only" {
  printf '%s\n' '{"plugins":[{"name":"alpha","source":"./alpha"},{"name":"beta","source":"./beta"}]}' > "$D/mk.json"
  jq '.children[0].files = ["alpha/x.md", "beta/y.md"]' "$D/ok.json" > "$D/p.json"
  run -1 --separate-stderr zsh "$P" --story "$D/story.json" --proposal "$D/p.json" --manifest "$D/mk.json"
  printf '%s' "$output" | jq -e '.children[0].size.triggers == ["plugin"]' >/dev/null
  run -0 --separate-stderr zsh "$P" -h
  [ -z "$output" ]
  contains "$stderr" "usage: plan-story-split.zsh --story FILE --proposal FILE"
}
