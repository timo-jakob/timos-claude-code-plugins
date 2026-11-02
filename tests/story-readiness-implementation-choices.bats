#!/usr/bin/env bats
#
# story-readiness judges what is required, not how it is built (#2902, epic
# #2898). The gate's borderline tie-break ("lean toward NEEDS_REFINEMENT") is
# scoped to `intent` and `gap` questions of the decision-rights taxonomy
# (ARCHITECTURE.md, #2899), and an open one always fails a check; an unpinned implementation choice fails no check
# and yields no refinement question; and an acceptance criterion that
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

# The #2902 block: its heading paragraph and its bullet list, ending at the
# blank line after the bullets.
rule_block() {
  awk '/^\*\*What is required, not how it is built \(#2902\)\.\*\*/ { on = 1 }
       on && /^$/ && ++blank == 2 { exit }
       on { print }' "$AGENT" | tr '\n' ' ' | tr -s ' '
}

@test "the rule sorts open items by the decision-rights taxonomy, naming the contract (#2902)" {
  contains "$FLAT" '**What is required, not how it is built (#2902).** Sort what the story leaves open about the change itself — what to build and how — by the question taxonomy of ARCHITECTURE.md, *Decision rights — question taxonomy and the Decisions-taken record* (#2899): `intent`, `gap` or `implementation`, with that section'"'"'s tie-break when you are unsure. The questions checks 2–5 prescribe are not sorted by it: they still go in `refinement_questions` exactly as those checks state.'
}

@test "the contract the rule names exists in ARCHITECTURE.md (#2902)" {
  grep -qxF '## Decision rights — question taxonomy and the Decisions-taken record (#2899)' "$REPO_ROOT/ARCHITECTURE.md"
}

@test "the borderline tie-break is scoped to intent and gap (#2902)" {
  contains "$FLAT" '**The borderline tie-break applies only to `intent` and `gap`.** An open `intent` or `gap` question about the change is never waived: it fails check 1 (`acceptance_testable`), check 2 (`scope_bounded`) or check 4 (`no_contradictions`), whichever it bears on, and check 1 when it bears on none of them, because what done means is not settled until it is answered; it never fails check 3 or check 5, whose conditions stay exactly as those checks state. It yields one `refinement_questions` entry, and a `gap` question'"'"'s entry proposes the document change that would close it. When you are unsure whether such a question is open, lean toward `NEEDS_REFINEMENT` — a cheap clarifying question now beats a wrong PR later, which is the entire point of this gate.'
}

@test "the superseded check-borderline lean is gone (#2902)" {
  # the round-4 wording left an open intent or gap question bearing on no check with no outcome
  lacks "$FLAT" 'When a check is genuinely borderline because of an `intent` or `gap` question'
}

@test "the unscoped tie-break is gone (#2902)" {
  # the pre-#2902 sentence leaned toward NEEDS_REFINEMENT on ANY borderline check
  lacks "$FLAT" 'When a check is genuinely borderline, lean toward `NEEDS_REFINEMENT`'
}

@test "an unpinned implementation choice fails no check and asks nothing (#2902)" {
  contains "$FLAT" '**An unpinned `implementation` choice fails no check.** A story that leaves open only how to build it — which helper to reuse, which CIDR to pick, how to name an internal function — is not under-specified: the builder decides it and records it under *Decisions taken*. It never fails a check and never produces a `refinement_questions` entry. The `use_case` and the happy, corner and error `test_cases` a surface-touching story must carry are never such a choice: they describe observable behaviour, not implementation, so they stay required.'
}

@test "refinement_questions carries the checks' questions and intent and gap questions, never an implementation choice (#2902)" {
  contains "$FLAT" '- `refinement_questions` is a list of concrete, answerable questions — one per gap you found: a check'"'"'s prescribed question, or an open `intent` or `gap` question about the change, which always fails a check; never an unpinned implementation choice (#2902). Empty (`[]`) when `verdict` is `READY`.'
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
  contains "$FLAT" 'Empty (`[]`) when there is nothing to note, the common case; a persona-less story raises no persona advisory.'
  lacks "$FLAT" 'including every persona-less story).'
}

@test "the rule sits before the risk classification, inside the checks section (#2902)" {
  local rule risk
  rule="$(grep -n '^\*\*What is required, not how it is built (#2902)\.\*\*' "$AGENT" | cut -d: -f1)"
  risk="$(grep -n '^## Risk classification' "$AGENT" | cut -d: -f1)"
  [ -n "$rule" ]
  [ -n "$risk" ]
  [ "$rule" -lt "$risk" ]
  # and the block, ending at the blank line after its bullets, carries exactly its three bullets
  local block
  block="$(rule_block)"
  ends_with "$block" 'Such a criterion is still testable, so it does not fail check 1. '
  [ "$(grep -o ' - \*\*' <<<"$block" | wc -l | tr -d ' ')" = "3" ]
}

@test "checks 3 and 5 are untouched by the rule (#2902)" {
  local block
  block="$(rule_block)"
  [ -n "$block" ]
  # the rule names checks 3 and 5 only to exclude them, never as a check it fails
  contains "$block" 'it never fails check 3 or check 5, whose conditions stay exactly as those checks state.'
  # outside that one exclusion, checks 3 and 5 are never named
  local rest="${block//it never fails check 3 or check 5, whose conditions stay exactly as those checks state./}"
  lacks "$rest" 'check 3'
  lacks "$rest" 'check 5'
  lacks "$rest" 'dependencies_resolved'
  lacks "$rest" 'outside_in_testable'
  # the closed list of checks an open intent or gap question may fail
  contains "$block" 'it fails check 1 (`acceptance_testable`), check 2 (`scope_bounded`) or check 4 (`no_contradictions`), whichever it bears on'
}
