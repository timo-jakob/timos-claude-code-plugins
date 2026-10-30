#!/usr/bin/env bats
#
# story-readiness judges WHAT is required, never HOW it is built (#2902, child 4
# of epic #2898). The gate's borderline tie-break ("lean toward
# NEEDS_REFINEMENT") applies only to an `intent` or `gap` item of #2899's
# question taxonomy; an unpinned `implementation` choice passes every check and
# never becomes a refinement question; and a criterion that pins implementation
# is reported in `advisories`, never as a failure.
#
# The deliverable is prose in development/agents/story-readiness.md and no
# script, so these needles are the only thing that stops the rule being
# softened or reverted with the suite green. Each clause is pinned on its own,
# so deleting any one of them reds this file. Anchored by content, never by
# line number (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  AGENT="$REPO_ROOT/development/agents/story-readiness.md"
  # whitespace-normalised, so a re-wrap of the prose never reds a needle
  A="$(tr -s '[:space:]' ' ' < "$AGENT")"
}

@test "#2902 the borderline tie-break is scoped to intent and gap, by the contract's section" {
  contains "$A" 'When a check is genuinely borderline **on an `intent` or `gap` item** — the question taxonomy of ARCHITECTURE.md'"'"'s *Decision rights — question taxonomy and the Decisions-taken record* (#2899) — lean toward `NEEDS_REFINEMENT`'
  # the unscoped wording is gone, so the old rule cannot survive beside the new one
  lacks "$A" 'When a check is genuinely borderline, lean toward'
}

@test "#2902 the contract section the tie-break names exists in ARCHITECTURE.md" {
  contains "$(cat "$REPO_ROOT/ARCHITECTURE.md")" '## Decision rights — question taxonomy and the Decisions-taken record'
}

@test "#2902 an unpinned implementation choice passes every check and asks nothing" {
  contains "$A" '**An unpinned `implementation` choice passes every check (#2902).**'
  contains "$A" 'is the builder'"'"'s to decide and record under **Decisions taken**, not the story'"'"'s to pin.'
  contains "$A" 'Such a choice is never borderline: it fails no check and never produces a `refinement_questions` entry.'
}

@test "#2902 an implementation-pinning criterion is an advisory, never a failure" {
  contains "$A" '**A criterion that pins implementation is an advisory, never a failure.**'
  contains "$A" 'that no position, requirement or external interface requires'
  contains "$A" 'record it in `advisories` as `implementation-pinned` ("criterion N pins implementation; consider stating the observable behaviour")'
  contains "$A" 'judge the checks as if the criterion stated that behaviour.'
}

@test "#2902 the advisories output field lists implementation-pinned among its kinds" {
  contains "$A" '"persona-registry-missing" | "implementation-pinned", "message": "…" }'
  contains "$A" 'for `implementation-pinned`, naming the criterion.'
  # the field's existing guarantee still covers the new kind
  contains "$A" '**Advisories never change the verdict**'
}
