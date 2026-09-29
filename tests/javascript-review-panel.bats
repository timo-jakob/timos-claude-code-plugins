#!/usr/bin/env bats
#
# The development-javascript review panel's own loop contracts (#1071).
#
# The panel shares its loop duties with every other panel, and those are swept
# by review-loop-budget-consistency.bats. Two rules are this panel's own and
# are pinned here: what a round whose scope holds no JS/TS file does, and what
# a round with a failed dimension writes. Both decide whether the loop can
# converge on a review nobody performed.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PANEL="$REPO_ROOT/development-javascript/skills/review/SKILL.md"
}

# section <start-ere> <end-ere> — a sed-scoped slice of the panel, whitespace
# flattened (the prose is hard-wrapped, so a line-oriented needle is blind to a
# phrase the wrap splits). ERE, because BSD sed's BRE has no alternation.
section() { sed -nE "/$1/,/$2/p" "$PANEL" | tr -s '[:space:]' ' '; }

@test "a scope with no JS/TS file is NOT APPLICABLE on a full round, never a clean []" {
  local pre
  pre="$(section '^\*\*Scope:\*\*' '^## Step 1')"
  [ -n "$pre" ]
  contains "$pre" 'A non-empty scope with no in-scope file is NOT APPLICABLE, not clean.'
  # each outcome pinned WITH its round type: swapping the two qualifiers keeps
  # every bare phrase present while sending a full round down the [] arm
  contains "$pre" 'On a **full** round, report the round **not applicable** to the caller'
  contains "$pre" 'write **nothing** to the findings path'
  contains "$pre" 'On a **delta** round, apply the delta-round rules above unchanged'
  lacks "$pre" 'On a **full** round, apply the delta-round rules'
  # the delta half defers to the carry rules rather than writing a bare []
  contains "$pre" 'with a non-empty carry, launch the agents'
}

@test "a failed dimension writes NO findings file, and Step 4 aggregates only a complete panel" {
  local s2 s4
  s2="$(section '^## Step 2' '^## Step 3')"
  s4="$(section '^## Step 4' '^```bash')"
  [ -n "$s2" ]
  [ -n "$s4" ]
  contains "$s2" 'Do not write the findings file at all.'
  contains "$s2" 'Report the round as **failed** to the caller'
  contains "$s2" 'an empty-delta round that carries nothing launches none'
  contains "$s4" 'only when all six dimensions completed'
}
