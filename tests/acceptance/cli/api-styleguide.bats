#!/usr/bin/env bats
#
# Acceptance cases for the org API styleguide ruleset (#689) — the `cli`-tooled
# test_cases[] of its story-spec, one test per `tc-*` id:
#
#   tc-happy-conforming-spec-passes         #945
#   tc-error-missing-operationid            #946
#   tc-error-missing-descriptions           #947
#   tc-error-missing-tags                   #948
#   tc-error-deprecated-op-missing-sunset   #949
#   tc-error-verb-singular-path             #950
#   tc-error-non-problem-json-error-body    #951
#   tc-corner-deprecated-schema-not-flagged #952
#   tc-corner-path-params-exempt            #953
#
# Plus SIX cases with no story-spec id of their own, each covering a clause the
# nine above leave undiscriminated — every one of them could be deleted from the
# ruleset with the story cases still green:
#
#   tc-error-operationid-unique           the eighth rule id (#689 AC 4)
#   tc-error-dual-error-body              `maxProperties: 1` (bare means bare)
#   tc-error-incomplete-problem-schema    the RFC 9457 required-members allOf
#   tc-error-range-status-key             the given's "4XX"/"5XX" half
#   tc-error-naming-clauses-isolated      each org-resource-naming pattern alone
#   tc-corner-verb-prefixed-nouns-pass    the verb guard's trailing context
#
# …and TWO #1330 premise cases, which belong to neither group: they assert the
# ops fragment's relationship to org-problem-json-errors (v2 clears it, v1 still
# fires it), i.e. the reason ops v2 had to land before the pin shipped.
#
# 9 + 6 + 2 = 17 @test blocks. Keep this roster and the count in
# ../README.md in step with the file.
#
# The three through-the-pin cases (#1304-#1306) are NOT in this lane. PR-B
# realised them as scripts/check-styleguide-pin.zsh, run by
# .github/workflows/styleguide-pin.yml, and unit-tested in
# tests/check-styleguide-pin.bats — that is where to look for their coverage.
#
# Why they moved: the property those ids name is "a dead pin FAILS", and this
# lane is skipped whenever spectral cannot be fetched. A case that skips on a
# network problem cannot assert a network-dependent failure — it would be absent
# exactly when it mattered. The checker instead asserts POSITIVELY that all eight
# rule ids fire through the pin, so a pin that 404s (or resolves but loads no
# rules) exits non-zero rather than reporting a clean run.
#
# NOT part of the default gate — `bats tests` does not recurse — see
# ../README.md. The always-on structural half is tests/api-styleguide-ruleset.bats.
#
# Requirements: `node` (20+, matching the node-version the shipped
# contracts-lint job pins), `npx`, `jq`, and network access on the first run.
# setup_file proves the toolchain once and fails the whole file loudly rather
# than letting a missing spectral masquerade as a lint finding.

bats_require_minimum_version 1.5.0
load ../../assertions

# Pinned EXACTLY, unlike the shipped workflow's floating `@6`. A spectral minor
# can retire or rename an inherited spectral:oas rule, which would change these
# fixtures' verdicts with no change in this repo — the same reasoning
# tests/README.md gives for pinning the IaC toolchain.
SPECTRAL="@stoplight/spectral-cli@6.16.3"

setup_file() {
  run npx --yes "$SPECTRAL" --version
  if [ "$status" -ne 0 ]; then
    printf 'spectral-cli could not be fetched — this lane needs node + network\n' >&2
    return 1
  fi
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RULESET="$REPO_ROOT/styleguide/spectral/ruleset.yaml"
  FIXTURES="$REPO_ROOT/tests/fixtures/api-styleguide"
}

# The one invocation under test — the shipped contracts-lint command line, kept
# in a single helper so no case can drift onto a laxer one. Returns 2 on misuse
# so a typo'd fixture name is distinguishable from a real lint failure (both
# would otherwise exit 1 and satisfy the tc-error status assertions).
lint_fixture() {
  local fixture="$FIXTURES/${1:?lint_fixture: fixture name required}/openapi.yaml"
  if [ ! -f "$fixture" ]; then
    printf 'lint_fixture: no such fixture: %s\n' "$fixture" >&2
    return 2
  fi
  npx --yes "$SPECTRAL" lint \
    --ruleset "$RULESET" \
    --fail-severity error \
    "$fixture"
}

@test "tc-happy-conforming-spec-passes: the conforming fixture exits 0 with no error findings" {
  run lint_fixture conforming
  [ "$status" -eq 0 ]
  # Asserted from structured output, not the human summary: spectral prints the
  # "✖ N problems (0 errors, …)" tally only when SOME result exists, so a
  # `contains "0 errors"` check silently depends on inherited spectral:oas
  # warnings the fixture does not control and this test does not care about.
  run npx --yes "$SPECTRAL" lint --ruleset "$RULESET" --format json \
    "$FIXTURES/conforming/openapi.yaml"
  run jq -e '[.[] | select(.severity == 0)] | length == 0' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "tc-error-missing-operationid: operation-operationId fires at error" {
  run lint_fixture nonconforming
  [ "$status" -eq 1 ]
  matches "$output" 'error[[:space:]]+operation-operationId[[:space:]]'
}

@test "tc-error-missing-descriptions: info-description and operation-description both fire at error" {
  run lint_fixture nonconforming
  [ "$status" -eq 1 ]
  # Both are warn in the #692 starter — this is the promotion, proven.
  matches "$output" 'error[[:space:]]+info-description[[:space:]]'
  matches "$output" 'error[[:space:]]+operation-description[[:space:]]'
}

@test "tc-error-missing-tags: operation-tags fires at error" {
  run lint_fixture nonconforming
  [ "$status" -eq 1 ]
  matches "$output" 'error[[:space:]]+operation-tags[[:space:]]'
}

@test "tc-error-deprecated-op-missing-sunset: org-deprecated-operation-has-sunset fires with its fix hint" {
  run lint_fixture nonconforming
  [ "$status" -eq 1 ]
  matches "$output" 'error[[:space:]]+org-deprecated-operation-has-sunset[[:space:]]'
  contains "$output" 'x-sunset'
}

@test "tc-error-verb-singular-path: org-resource-naming fires with its fix hint" {
  run lint_fixture nonconforming
  [ "$status" -eq 1 ]
  matches "$output" 'error[[:space:]]+org-resource-naming[[:space:]]'
  contains "$output" 'plural kebab-case'
}

@test "tc-error-non-problem-json-error-body: org-problem-json-errors fires with its fix hint" {
  run lint_fixture nonconforming
  [ "$status" -eq 1 ]
  matches "$output" 'error[[:space:]]+org-problem-json-errors[[:space:]]'
  contains "$output" 'application/problem+json'
}

@test "tc-error-operationid-unique: operation-operationId-unique fires at error" {
  # The eighth id. Without it the suite could pass while one normative rule
  # never fires at all.
  run lint_fixture nonconforming
  [ "$status" -eq 1 ]
  matches "$output" 'error[[:space:]]+operation-operationId-unique[[:space:]]'
}

@test "tc-error-dual-error-body: an error offering problem+json AND application/json is flagged" {
  # Proves `maxProperties: 1`. The main non-conforming fixture's 404 offers only
  # application/json, so it fires on the `required` clause alone — bare-ness
  # could be deleted with every other test still green.
  run lint_fixture nonconforming-error-bodies
  [ "$status" -eq 1 ]
  matches "$output" 'error[[:space:]]+org-problem-json-errors[[:space:]]'
  contains "$output" 'responses[404].content'
}

# NOTE: no backticks in @test names — bats command-substitutes them.
@test "tc-error-incomplete-problem-schema: a problem body missing the detail member is flagged" {
  # Proves the required-members allOf. Only the conforming fixture reaches this
  # clause otherwise, where it is proven never to fire.
  run lint_fixture nonconforming-error-bodies
  [ "$status" -eq 1 ]
  contains "$output" 'IncompleteProblem'
}

@test "tc-error-range-status-key: a 4XX range key is matched, not skipped" {
  # Proves the given's string half. `@property >= 400` alone coerces "4XX" to
  # NaN, so a spec declaring errors only as ranges would pass untouched.
  run lint_fixture nonconforming-error-bodies
  [ "$status" -eq 1 ]
  contains "$output" 'responses.4XX.content'
}

@test "tc-error-naming-clauses-isolated: each org-resource-naming pattern fires alone" {
  # /getUser violates BOTH clauses, so either could be deleted and the story
  # case would stay green. /list-orders is valid kebab-case (verb guard only);
  # /Tenant_List has no verb prefix (kebab pattern only).
  run lint_fixture nonconforming-naming
  [ "$status" -eq 1 ]
  contains "$output" '/list-orders is not a plural kebab-case noun path'
  contains "$output" '/Tenant_List is not a plural kebab-case noun path'
}

@test "tc-corner-deprecated-schema-not-flagged: deprecated non-operations are NOT flagged" {
  # Three shapes the starter's document-wide given wrongly matched: a deprecated
  # schema property, a deprecated parameter, and `deprecated: true` inside
  # example data. Operation scoping, proven against all three.
  run lint_fixture corner-deprecated-schema
  [ "$status" -eq 0 ]
  lacks "$output" "org-deprecated-operation-has-sunset"
}

@test "tc-corner-path-params-exempt: {param} segments are NOT flagged by org-resource-naming" {
  run lint_fixture corner-path-params
  [ "$status" -eq 0 ]
  lacks "$output" "org-resource-naming"
}

@test "the ops v2 fragment CLEARS org-problem-json-errors — the premise of #1330" {
  # #1330 exists because this rule reddens the ops/v1 fragment in every
  # bootstrapped repo. Nothing else anywhere verifies that v2 actually fixes it:
  # the conformance checker validates a live SERVICE, and the payload suites grep
  # source. Without this case the whole major could ship still-red and the first
  # person to find out would be an adopter.
  local frag="$REPO_ROOT/development/skills/bootstrap/templates/common/contracts/ops/v2/openapi.yaml"
  [ -f "$frag" ]
  run npx --yes "$SPECTRAL" lint --ruleset "$RULESET" --format json "$frag"
  run jq -e '[.[] | select(.severity == 0)] | length == 0' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "the ops v1 fragment still FAILS org-problem-json-errors — the premise, in the negative" {
  # The mirror image, and the half that keeps the case above honest: if the rule
  # stopped firing altogether (a ruleset edit, a spectral change), the v2 test
  # would go green for the wrong reason and the major would look unnecessary.
  local frag="$REPO_ROOT/development/skills/bootstrap/templates/common/contracts/ops/v1/openapi.yaml"
  [ -f "$frag" ]
  run npx --yes "$SPECTRAL" lint --ruleset "$RULESET" --format json "$frag"
  run jq -e '[.[] | select(.severity == 0 and .code == "org-problem-json-errors")] | length == 2' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "tc-corner-verb-prefixed-nouns-pass: /addresses, /searches and /deleted-items stay clean" {
  # The verb guard is scoped by trailing context; a regression widening it to
  # bare prefixes would redden downstream repos on ordinary nouns.
  run lint_fixture conforming
  [ "$status" -eq 0 ]
  lacks "$output" "org-resource-naming"
}
