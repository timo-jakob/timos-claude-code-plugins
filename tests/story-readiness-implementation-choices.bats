#!/usr/bin/env bats
#
# story-readiness judges what is required, not how it is built (#2902, epic
# #2898). The gate's borderline tie-break ("lean toward NEEDS_REFINEMENT") is
# scoped to `intent` and `gap` questions of the decision-rights taxonomy
# (ARCHITECTURE.md, #2899); an unpinned implementation choice passes every
# check and yields no refinement question; and an acceptance criterion that
# pins an implementation detail is an `implementation-pinned` advisory, never a
# failure. These pins are prose pins: the agent is a model, so the suite holds
# the rule's text in place, sentence by sentence.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AGENT="$REPO_ROOT/development/agents/story-readiness.md"
  # hard wraps joined, so a sentence is pinned whole wherever it wraps
  FLAT="$(tr '\n' ' ' < "$AGENT" | tr -s ' ')"
}

# The #2902 block: its heading line to the next blank-line-separated
# paragraph that is not part of the three-bullet list.
rule_block() {
  awk '/^\*\*What is required, not how it is built \(#2902\)\.\*\*/ { on = 1 }
       on && /^## / { exit }
       on { print }' "$AGENT" | tr '\n' ' ' | tr -s ' '
}

@test "the rule sorts open items by the decision-rights taxonomy, naming the contract (#2902)" {
  contains "$FLAT" '**What is required, not how it is built (#2902).** Before you treat anything as open, sort it by the question taxonomy of ARCHITECTURE.md, *Decision rights — question taxonomy and the Decisions-taken record* (#2899): `intent`, `gap` or `implementation`, with that section'"'"'s tie-break when you are unsure.'
}

@test "the contract the rule names exists in ARCHITECTURE.md (#2902)" {
  grep -qxF '## Decision rights — question taxonomy and the Decisions-taken record (#2899)' "$REPO_ROOT/ARCHITECTURE.md"
}

@test "the borderline tie-break is scoped to intent and gap (#2902)" {
  contains "$FLAT" '**The borderline tie-break applies only to `intent` and `gap`.** When a check is genuinely borderline because of an `intent` or `gap` question, lean toward `NEEDS_REFINEMENT` — a cheap clarifying question now beats a wrong PR later, which is the entire point of this gate.'
}

@test "the unscoped tie-break is gone (#2902)" {
  # the pre-#2902 sentence leaned toward NEEDS_REFINEMENT on ANY borderline check
  lacks "$FLAT" 'When a check is genuinely borderline, lean toward `NEEDS_REFINEMENT`'
}

@test "an unpinned implementation choice passes every check and asks nothing (#2902)" {
  contains "$FLAT" '**An unpinned `implementation` choice passes every check.** A story that leaves open only how to build it — which helper to reuse, which CIDR to pick, how to name an internal function — is not under-specified: the builder decides it and records it under *Decisions taken*. It never fails a check and never produces a `refinement_questions` entry.'
}

@test "refinement_questions carries intent and gap questions only (#2902)" {
  contains "$FLAT" '- `refinement_questions` is a list of concrete, answerable questions — one per gap you found, each an `intent` or `gap` question, never an implementation choice (#2902). Empty (`[]`) when `verdict` is `READY`.'
}

@test "an implementation-pinning criterion is an advisory, never a failure (#2902)" {
  contains "$FLAT" '**An acceptance criterion that pins an implementation detail is an advisory, never a failure.** When a criterion fixes a detail that no architecture position, requirement or external interface requires (a specific CIDR, an exact-set check on internal config), add an `implementation-pinned` advisory naming the criterion (below), and judge the checks as if the criterion stated its observable behaviour. Such a criterion is still testable, so it does not fail check 1.'
}

@test "the advisories field lists implementation-pinned among its kinds (#2902)" {
  contains "$FLAT" '{ "kind": "persona-unknown" | "persona-registry-stale" | "persona-registry-missing" | "implementation-pinned", "message": "…" }'
  contains "$FLAT" 'and acceptance criteria that pin an implementation detail (#2902).'
}

@test "the implementation-pinned advisory's message is fixed (#2902)" {
  contains "$FLAT" 'an `implementation-pinned` advisory'"'"'s `message` reads `criterion <N> pins implementation; consider stating the observable behaviour`, with `<N>` the criterion'"'"'s 1-based number in the story.'
}

@test "advisories still never change the verdict (#2902)" {
  contains "$FLAT" '**Advisories never change the verdict** — a `READY` story with advisories is still `READY`.'
}

@test "the rule sits before the risk classification, inside the checks section (#2902)" {
  local rule risk
  rule="$(grep -n '^\*\*What is required, not how it is built (#2902)\.\*\*' "$AGENT" | cut -d: -f1)"
  risk="$(grep -n '^## Risk classification' "$AGENT" | cut -d: -f1)"
  [ -n "$rule" ]
  [ -n "$risk" ]
  [ "$rule" -lt "$risk" ]
  # and the block carries exactly its three bullets
  run grep -c '^- \*\*\(The borderline tie-break\|An unpinned `implementation`\|An acceptance criterion that pins\)' "$AGENT"
  [ "$output" = "3" ]
}

@test "checks 3 and 5 are untouched by the rule (#2902)" {
  local block
  block="$(rule_block)"
  [ -n "$block" ]
  lacks "$block" 'check 3'
  lacks "$block" 'check 5'
  lacks "$block" 'dependencies_resolved'
  lacks "$block" 'outside_in_testable'
}
