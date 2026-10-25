#!/usr/bin/env bats
#
# refine-issue's Decisions-taken renderer (#2900):
# scripts/render-decisions-taken.zsh turns one split-refiner-questions.zsh
# output into the `## Decisions taken` section of ARCHITECTURE.md's
# *Decision rights* record (#2899) — one entry per `implementation` auto answer,
# with its question, choice, evidence and how to overrule it, and nothing at all
# when there is none. An intent or gap answer is never rendered.
#
# Anchored by content, never by line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  R="$REPO_ROOT/development/skills/refine-issue/scripts/render-decisions-taken.zsh"
  SPLIT="$BATS_TEST_TMPDIR/split.json"
}

# auto <kind> <question> <answer> <rationale> — one split auto entry
auto() {
  jq -nc --arg k "$1" --arg q "$2" --arg a "$3" --arg r "$4" \
    '{question: $q, kind: $k, answer: $a, confidence: "0.90", weakest: [], rationale: $r}'
}

@test "a split with no implementation answer renders nothing" {
  jq -nc --argjson i "$(auto intent 'Target?' 'p95 < 200 ms' 'tests/load says so')" '{threshold: "0.500", auto: [$i], ask: []}' > "$SPLIT"
  run -0 zsh "$R" --split "$SPLIT"
  [ -z "$output" ]
  printf '%s\n' '{"threshold": "1.000", "auto": [], "ask": []}' > "$SPLIT"
  run -0 zsh "$R" --split "$SPLIT"
  [ -z "$output" ]
}

@test "mixed answers render one entry per implementation answer, with all four fields" {
  jq -nc --argjson m "$(auto implementation 'Which helper?' 'jq' 'every script here uses jq')" \
    --argjson i "$(auto intent 'Target?' 'p95 < 200 ms' 'tests/load says so')" \
    '{threshold: "0.500", auto: [$m, $i], ask: []}' > "$SPLIT"
  run -0 zsh "$R" --split "$SPLIT"
  [ "${lines[0]}" = "## Decisions taken" ]
  contains "$output" '- **question:** Which helper?'
  contains "$output" '  **choice:** jq'
  contains "$output" '  **evidence:** every script here uses jq'
  contains "$output" '  **how to overrule:** edit this entry and the story text that rests on it in the issue body.'
  lacks "$output" 'Target?'
  [ "$(grep -c '^- \*\*question:\*\*' <<<"$output")" -eq 1 ]
}

@test "two implementation answers render two entries, in input order" {
  jq -nc --argjson a "$(auto implementation 'First?' 'jq' 'r1')" --argjson i "$(auto intent 'Target?' 'p95' 'r2')" --argjson b "$(auto implementation 'Second?' 'zsh' 'r3')" '{threshold: "0.500", auto: [$a, $i, $b], ask: []}' > "$SPLIT"
  run -0 zsh "$R" --split "$SPLIT"
  [ "$(grep '^- \*\*question:\*\*' <<<"$output" | tr '\n' '|')" = '- **question:** First?|- **question:** Second?|' ]
}

@test "a multi-line answer renders on one line" {
  jq -nc --argjson m "$(auto implementation 'Which helper?' $'jq,\n  not awk' 'every script here uses jq')" \
    '{threshold: "0.500", auto: [$m], ask: []}' > "$SPLIT"
  run -0 zsh "$R" --split "$SPLIT"
  contains "$output" '  **choice:** jq, not awk'
}

@test "an unknown flag, a missing flag, an absent file or a split without an auto array is exit 2" {
  run -2 --separate-stderr zsh "$R" --bogus
  contains "$stderr" "usage: render-decisions-taken.zsh --split <file>"
  run -2 --separate-stderr zsh "$R"
  contains "$stderr" "--split file missing or unreadable"
  run -2 --separate-stderr zsh "$R" --split "$BATS_TEST_TMPDIR/absent.json"
  contains "$stderr" "--split file missing or unreadable"
  printf '%s\n' '{"ask": []}' > "$SPLIT"
  run -2 --separate-stderr zsh "$R" --split "$SPLIT"
  contains "$stderr" "--split is not one JSON object with an auto array"
}
