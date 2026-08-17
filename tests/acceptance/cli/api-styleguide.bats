#!/usr/bin/env bats
#
# Acceptance cases for the org API styleguide ruleset (#689, extended by #944)
# — the `cli`-tooled test_cases[] of its story-spec, one test per `tc-*` id:
#
#   tc-happy-conforming-spec-passes         #945, and #944's #1290
#   tc-error-missing-operationid            #946
#   tc-error-missing-descriptions           #947
#   tc-error-missing-tags                   #948
#   tc-error-deprecated-op-missing-sunset   #949
#   tc-error-verb-singular-path             #950
#   tc-error-non-problem-json-error-body    #951
#   tc-corner-deprecated-schema-not-flagged #952
#   tc-corner-path-params-exempt            #953
#
# The conforming case carries TWO ids because #944 extended the fixture rather
# than adding a second happy path: the same "exit 0, zero error findings" claim
# now covers the pagination and header conventions too, and splitting it would
# have produced two tests running the identical command.
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
# …to which #944 adds NINE more of the same kind. One reuses an existing
# fixture; the other eight lint the two clause-isolating fixtures
# (nonconforming-pagination, nonconforming-headers) that exist because the main
# non-conforming fixture violates several clauses AT ONCE and so cannot tell
# them apart:
#
#   (corner-deprecated-schema, re-asserted)  org-deprecation-sunset-headers
#                                            reuses the operation anchor and can
#                                            regress into the same $.. over-match
#   …cursor-params-missing isolates…         the cursor and limit clauses
#   …envelope-bare-array also covers…        clause (b), items without next_cursor
#   …offset-params-banned reaches…           components, path items, in: header
#   …retry-after has a 503 twin…             the otherwise-unproven 503 branch
#   …idempotency rejects a WRONG key…        the `in` and `required` consts
#   …sunset-headers covers the 2XX key…      the range half of patternProperties
#   …correlation reaches components…         four givens, and the /i flag
#   the fixtures fire NOTHING beyond…        each fixture's whole code set, so
#                                            an over-fire by an unrelated rule
#                                            on their conforming parts is seen
#
# …and TWO #1330 premise cases, which belong to neither group: they assert the
# ops fragment's relationship to org-problem-json-errors (v2 clears it, v1 still
# fires it), i.e. the reason ops v2 had to land before the pin shipped.
#
# #944's thirteen further ids — the pagination and header conventions:
#
#   tc-error-pagination-cursor-params-missing              #1291
#   tc-error-pagination-offset-params-banned               #1292
#   tc-error-pagination-envelope-bare-array                #1293
#   tc-error-idempotency-key-missing-on-post               #1294
#   tc-error-idempotency-key-missing-on-patch              #1295
#   tc-error-retry-after-missing-on-429                    #1296
#   tc-error-deprecation-sunset-headers-missing            #1297
#   tc-error-bespoke-correlation-header                    #1298
#   tc-corner-ops-fragment-lints-clean                     #1299
#   tc-corner-object-array-not-named-items-not-a-collection #1300
#   tc-corner-put-delete-exempt-from-idempotency-key       #1301
#   tc-corner-traceparent-allowed                          #1302
#   tc-corner-ops-v1-frozen-major-no-new-rule-findings     #1397
#   tc-corner-business-seed-lints-clean                    (PR-B, no issue)
#
# 9 + 15 + 2 + 14 = 40 @test blocks. Keep this roster and the count in
# ../README.md in step with the file.
#
# The three through-the-pin cases (#1304-#1306) are NOT in this lane. PR-B
# realised them as scripts/check-styleguide-pin.zsh, run by
# .github/workflows/styleguide-pin.yml, and unit-tested in
# tests/check-styleguide-pin.bats — that is where to look for their coverage.
#
# Why they moved: the property those ids name is "a dead pin FAILS", and this
# lane is outside the default gate, so its coverage is simply ABSENT whenever
# spectral cannot be fetched (setup_file fails the file loudly rather than
# skipping — see below; do not convert that `return 1` to a `skip`, which would
# make the whole lane vacuous on a network blip). Coverage that can be absent
# exactly when it matters cannot assert a network-dependent failure. The checker
# instead asserts POSITIVELY that every id in its roster fires through the pin, so a
# pin that 404s (or resolves but loads no rules) exits non-zero rather than
# reporting a clean run.
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
# The arity guard is an explicit check, NOT `${1:?…}`: a parameter-expansion
# error terminates the subshell with status 1, which is indistinguishable from a
# real lint failure and would satisfy every tc-error status assertion in the
# file — exactly the confusion the documented 2 exists to prevent.
lint_fixture() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || {
    printf 'lint_fixture: exactly one fixture name required\n' >&2
    return 2
  }
  local fixture="$FIXTURES/$1/openapi.yaml"
  if [ ! -f "$fixture" ]; then
    printf 'lint_fixture: no such fixture: %s\n' "$fixture" >&2
    return 2
  fi
  npx --yes "$SPECTRAL" lint \
    --ruleset "$RULESET" \
    --fail-severity error \
    "$fixture"
}

# The same invocation in JSON. #944's cases assert MESSAGE substrings and the
# JSON `path` of a finding, and the stylish formatter pads and wraps to a
# terminal width — so a `contains` on a fix hint near the end of a long message
# is a formatting bet, not an assertion. JSON is exact.
#
# stderr is dropped rather than merged into `$output`: bats' `run` merges the
# two, and every caller feeds `$output` straight to jq — so one `npm warn exec`
# notice on a cold cache would prefix the document and red every JSON-based case
# at once, for a reason having nothing to do with the ruleset.
lint_fixture_json() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || {
    printf 'lint_fixture_json: exactly one fixture name required\n' >&2
    return 2
  }
  lint_path_json "$FIXTURES/$1/openapi.yaml"
}

# The same invocation again, against an arbitrary spec PATH — the shipped ops
# fragments, which are linted IN PLACE rather than copied. Having it here is
# what keeps the file's one-invocation-in-one-helper rule true: every spectral
# call in the file now routes through these three.
#
# stderr is CAPTURED, not discarded, and its tail is surfaced on the TOOLING-
# FAILURE branch only: setup_file proves the toolchain once, so a later cache
# eviction, registry error or spectral crash otherwise yields an empty $output
# and a failure reading `expected "…", got ""` — indistinguishable from a real
# ruleset regression. scripts/check-styleguide-pin.zsh built the same mechanism
# for the same reason. See the `case` below for why the placement matters:
# bats' plain `run` merges stderr into $output, so surfacing it on a verdict
# path would corrupt the JSON every caller parses.
lint_path_json() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || {
    printf 'lint_path_json: exactly one spec path required\n' >&2
    return 2
  }
  if [ ! -f "$1" ]; then
    printf 'lint_path_json: no such spec: %s\n' "$1" >&2
    return 2
  fi
  local err="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/spectral.err"
  npx --yes "$SPECTRAL" lint \
    --ruleset "$RULESET" \
    --fail-severity error \
    --format json "$1" 2>"$err"
  local rc=$?
  # 0 (clean) and 1 (findings) are both verdicts; anything else is spectral
  # failing to run, and must not be reported as an empty finding set.
  #
  # The stderr tail is surfaced ONLY on the failure branch, and that placement is
  # load-bearing: bats' plain `run` merges a command's stderr INTO `$output`, and
  # every caller feeds `$output` straight to jq. Printing it on a VERDICT path
  # would append the diagnostic to the JSON document, so one `npm warn exec` on a
  # cold cache would break every jq reduction in the lane at once — the exact
  # failure this helper's design exists to prevent. On the failure branch the
  # document is unusable anyway, and bats prints `$output` on failure, so there
  # the diagnostic is what the reader needs.
  case "$rc" in
    0 | 1) return 0 ;;
    *)
      if [ -s "$err" ]; then
        printf 'lint_path_json: spectral stderr (last 5 lines):\n%s\n' \
          "$(tail -n 5 "$err")" >&2
      fi
      printf 'lint_path_json: spectral exited %d for %s\n' "$rc" "$1" >&2
      return "$rc"
      ;;
  esac
}

# Builds the jq program that reduces a `--format json` document to the SORTED,
# space-joined `path` of every error-severity finding for one rule id. The
# assertion is then a plain string equality, which prints both sides on failure
# — a `jq -e … == [...]` boolean prints neither, so a drifted path costs a
# manual re-run to diagnose.
#
# Written as a builder returning one LINE. A multi-line single-quoted jq program
# is legal shell but not something a line-oriented scanner can model: the
# closing line carries a lone `'` and reads as OPENING a fresh literal, which
# silently swallows the rest of the file (tests/find-inert-bracket-assertions.zsh
# refuses such a scan outright, and it is right to).
paths_of() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || {
    printf 'paths_of: exactly one rule id required\n' >&2
    return 2
  }
  printf '[.[] | select(.severity == 0 and .code == "%s") | .path | join(".")] | sort | join(" ")' "$1"
}

# The same reduction over the whole document: every DISTINCT error-severity rule
# id, sorted. Used to pin that a fixture fires nothing beyond what it isolates.
codes_of() {
  [ "$#" -eq 0 ] || {
    printf 'codes_of: takes no arguments\n' >&2
    return 2
  }
  printf '[.[] | select(.severity == 0) | .code] | unique | sort | join(" ")'
}

# The same reduction, keeping the MESSAGE instead of the path — for the cases
# whose subject is the fix hint rather than where the finding landed.
messages_of() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || {
    printf 'messages_of: exactly one rule id required\n' >&2
    return 2
  }
  printf '[.[] | select(.severity == 0 and .code == "%s") | .message] | sort | join(" | ")' "$1"
}

# The seven ids #944 adds. Named once rather than per-test, because a copied
# list drifts. Used only by the ops v2 case, which asserts the absence of every
# one of them; the v1 case pins the exact code set instead (see there for why
# the two differ).
NEW_RULE_IDS_JSON='[
  "org-pagination-cursor-params",
  "org-pagination-no-offset-params",
  "org-pagination-envelope",
  "org-idempotency-key-on-post-patch",
  "org-retry-after-on-throttled",
  "org-deprecation-sunset-headers",
  "org-no-bespoke-correlation-headers"
]'

@test "tc-happy-conforming-spec-passes: the conforming fixture exits 0 with no error findings" {
  run lint_fixture conforming
  [ "$status" -eq 0 ]
  # Asserted from structured output, not the human summary: spectral prints the
  # "✖ N problems (0 errors, …)" tally only when SOME result exists, so a
  # `contains "0 errors"` check silently depends on inherited spectral:oas
  # warnings the fixture does not control and this test does not care about.
  run lint_fixture_json conforming
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
  # Absence asserted over the STRUCTURED document, severity-agnostic: a
  # `lacks` on the stylish output is the fail-OPEN half of the formatting
  # bet this file rejects for positive assertions, and it would also miss
  # a WARN-severity firing, which is its only value beyond the exit-0 above.
  run lint_fixture_json corner-deprecated-schema
  run jq -r '[.[] | select(.code == "org-deprecated-operation-has-sunset")] | length' <<<"$output"
  [ "$output" -eq 0 ]
}

@test "tc-corner-path-params-exempt: {param} segments are NOT flagged by org-resource-naming" {
  run lint_fixture corner-path-params
  [ "$status" -eq 0 ]
  # Absence asserted over the STRUCTURED document, severity-agnostic: a
  # `lacks` on the stylish output is the fail-OPEN half of the formatting
  # bet this file rejects for positive assertions, and it would also miss
  # a WARN-severity firing, which is its only value beyond the exit-0 above.
  run lint_fixture_json corner-path-params
  run jq -r '[.[] | select(.code == "org-resource-naming")] | length' <<<"$output"
  [ "$output" -eq 0 ]
}

@test "the ops v2 fragment CLEARS org-problem-json-errors — the premise of #1330" {
  # #1330 exists because this rule reddens the ops/v1 fragment in every
  # bootstrapped repo. Nothing else anywhere verifies that v2 actually fixes it:
  # the conformance checker validates a live SERVICE, and the payload suites grep
  # source. Without this case the whole major could ship still-red and the first
  # person to find out would be an adopter.
  local frag="$REPO_ROOT/development/skills/bootstrap/templates/common/contracts/ops/v2/openapi.yaml"
  [ -f "$frag" ]
  run lint_path_json "$frag"
  run jq -e '[.[] | select(.severity == 0)] | length == 0' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "the ops v1 fragment still FAILS org-problem-json-errors — the premise, in the negative" {
  # The mirror image, and the half that keeps the case above honest: if the rule
  # stopped firing altogether (a ruleset edit, a spectral change), the v2 test
  # would go green for the wrong reason and the major would look unnecessary.
  local frag="$REPO_ROOT/development/skills/bootstrap/templates/common/contracts/ops/v1/openapi.yaml"
  [ -f "$frag" ]
  run lint_path_json "$frag"
  run jq -e '[.[] | select(.severity == 0 and .code == "org-problem-json-errors")] | length == 2' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "tc-corner-verb-prefixed-nouns-pass: /addresses, /searches and /deleted-items stay clean" {
  # The verb guard is scoped by trailing context; a regression widening it to
  # bare prefixes would redden downstream repos on ordinary nouns.
  run lint_fixture conforming
  [ "$status" -eq 0 ]
  # Absence asserted over the STRUCTURED document, severity-agnostic: a
  # `lacks` on the stylish output is the fail-OPEN half of the formatting
  # bet this file rejects for positive assertions, and it would also miss
  # a WARN-severity firing, which is its only value beyond the exit-0 above.
  run lint_fixture_json conforming
  run jq -r '[.[] | select(.code == "org-resource-naming")] | length' <<<"$output"
  [ "$output" -eq 0 ]
}

# --- #944: pagination -------------------------------------------------------

@test "tc-error-pagination-cursor-params-missing: org-pagination-cursor-params fires with its fix hint" {
  # GET /tenants DOES return the envelope, so org-pagination-envelope is
  # satisfied there — which is what isolates this rule from that one. Without
  # the envelope the fixture would fire both and either could be deleted.
  run lint_fixture_json nonconforming
  local doc="$output"   # `run` overwrites $output; both reductions need the JSON
  run jq -r "$(paths_of org-pagination-cursor-params)" <<<"$doc"
  [ "$output" = "paths./tenants.get.parameters" ]
  run jq -r "$(messages_of org-pagination-cursor-params)" <<<"$doc"
  contains "$output" 'cursor'
  contains "$output" 'default 50, max 200'
}

@test "tc-error-pagination-offset-params-banned: both banned parameter names are flagged" {
  # BOTH, not just one: the notMatch is a single alternation, so a regression
  # that dropped every name but the first would still fire once and satisfy a
  # length > 0 assertion.
  run lint_fixture_json nonconforming
  local doc="$output"   # `run` overwrites $output; both reductions need the JSON
  run jq -r "$(paths_of org-pagination-no-offset-params)" <<<"$doc"
  [ "$output" = "paths./tenants.get.parameters.0.name paths./tenants.get.parameters.1.name" ]
  run jq -r "$(messages_of org-pagination-no-offset-params)" <<<"$doc"
  contains "$output" 'cursor pagination'
}

@test "tc-error-pagination-envelope-bare-array: a bare-array 200 is flagged" {
  run lint_fixture_json nonconforming
  local doc="$output"   # `run` overwrites $output; both reductions need the JSON
  run jq -r "$(paths_of org-pagination-envelope)" <<<"$doc"
  [ "$output" = "paths./orders.get.responses.200.content.application/json.schema" ]
  run jq -r "$(messages_of org-pagination-envelope)" <<<"$doc"
  contains "$output" 'items'
  contains "$output" 'next_cursor'
  contains "$output" '(null on the last page)'
}

@test "tc-corner-object-array-not-named-items-not-a-collection: the /info shape is not a collection" {
  # An object with a REQUIRED array named `api` rather than `items`. If this
  # reddens, detection has widened to "an object with an array anywhere" and
  # every bootstrapped repo's ops fragment reddens with it.
  run lint_fixture corner-collection-detection
  [ "$status" -eq 0 ]
  # Both absences asserted over the STRUCTURED document, severity-agnostic: a
  # `lacks` on the stylish output is the fail-OPEN half of the formatting bet
  # this file rejects for positive assertions, and it would also miss a
  # WARN-severity firing, which is its only value beyond the exit-0 above.
  # Captured ONCE — `run` overwrites $output, and a second lint would double the
  # case's runtime and its exposure to a cold-cache flake.
  run lint_fixture_json corner-collection-detection
  local doc="$output"
  run jq -r '[.[] | select(.code == "org-pagination-cursor-params")] | length' <<<"$doc"
  [ "$output" -eq 0 ]
  run jq -r '[.[] | select(.code == "org-pagination-envelope")] | length' <<<"$doc"
  [ "$output" -eq 0 ]
}

# --- #944: header conventions -----------------------------------------------

@test "tc-error-idempotency-key-missing-on-post: a POST without the key is flagged" {
  # Asserted on the finding's PATH, not merely on the id: the same id also
  # fires for PATCH in this fixture, so an id-only assertion would pass with
  # the POST half of the given deleted.
  run lint_fixture_json nonconforming
  local doc="$output"   # `run` overwrites $output; both reductions need the JSON
  run jq -r "$(paths_of org-idempotency-key-on-post-patch)" <<<"$doc"
  contains "$output" 'paths./tenants.post'
  run jq -r "$(messages_of org-idempotency-key-on-post-patch)" <<<"$doc"
  contains "$output" 'Idempotency-Key'
  contains "$output" 'required: true'
}

@test "tc-error-idempotency-key-missing-on-patch: a PATCH without the key is flagged too" {
  # The half the rule id promises and nothing else proves. With a POST-only
  # given every other assertion in this file stays green.
  run lint_fixture_json nonconforming
  run jq -r "$(paths_of org-idempotency-key-on-post-patch)" <<<"$output"
  contains "$output" 'paths./tenants/{tenantId}.patch'
}

@test "tc-corner-put-delete-exempt-from-idempotency-key: PUT and DELETE are spared" {
  # Idempotent by method. Widening the given to "every write method" reddens
  # this fixture, which is the point of it existing.
  run lint_fixture corner-idempotent-methods
  [ "$status" -eq 0 ]
  # Absence asserted over the STRUCTURED document, severity-agnostic: a
  # `lacks` on the stylish output is the fail-OPEN half of the formatting
  # bet this file rejects for positive assertions, and it would also miss
  # a WARN-severity firing, which is its only value beyond the exit-0 above.
  run lint_fixture_json corner-idempotent-methods
  run jq -r '[.[] | select(.code == "org-idempotency-key-on-post-patch")] | length' <<<"$output"
  [ "$output" -eq 0 ]
}

@test "tc-error-retry-after-missing-on-429: org-retry-after-on-throttled fires on the 429" {
  # The ONLY coverage of the rule's 429 half anywhere: ops v2 declares no 429,
  # and the conforming fixture's 429 declares the header.
  run lint_fixture_json nonconforming
  local doc="$output"   # `run` overwrites $output; both reductions need the JSON
  run jq -r "$(paths_of org-retry-after-on-throttled)" <<<"$doc"
  [ "$output" = "paths./tenants.post.responses.429" ]
  run jq -r "$(messages_of org-retry-after-on-throttled)" <<<"$doc"
  contains "$output" 'Retry-After'
  contains "$output" 'delta-seconds'
}

@test "tc-error-deprecation-sunset-headers-missing: a deprecated 2xx without the headers is flagged" {
  run lint_fixture_json nonconforming
  local doc="$output"   # `run` overwrites $output; both reductions need the JSON
  run jq -r "$(paths_of org-deprecation-sunset-headers)" <<<"$doc"
  [ "$output" = "paths./users/{userId}.get.responses.200" ]
  run jq -r "$(messages_of org-deprecation-sunset-headers)" <<<"$doc"
  contains "$output" 'Deprecation'
  contains "$output" 'Sunset'
}

@test "tc-corner-deprecated-schema-not-flagged also holds for the SUNSET-HEADER rule" {
  # #944's AC names this fixture explicitly. The new rule reuses the operation
  # anchor, so a document-wide `$..` regression would fire here on a deprecated
  # schema property and a deprecated parameter — the exact over-match that
  # forced the #692 starter down to a warning.
  run lint_fixture corner-deprecated-schema
  [ "$status" -eq 0 ]
  # Absence asserted over the STRUCTURED document, severity-agnostic: a
  # `lacks` on the stylish output is the fail-OPEN half of the formatting
  # bet this file rejects for positive assertions, and it would also miss
  # a WARN-severity firing, which is its only value beyond the exit-0 above.
  run lint_fixture_json corner-deprecated-schema
  run jq -r '[.[] | select(.code == "org-deprecation-sunset-headers")] | length' <<<"$output"
  [ "$output" -eq 0 ]
}

@test "tc-error-bespoke-correlation-header: both the parameter and the response-header shape are flagged" {
  # TWO shapes, TWO `then` clauses in the rule (`name` on a parameter, the KEY
  # on a headers map). Asserting one occurrence would leave either clause
  # deletable.
  run lint_fixture_json nonconforming
  local doc="$output"   # `run` overwrites $output; both reductions need the JSON
  run jq -r "$(paths_of org-no-bespoke-correlation-headers)" <<<"$doc"
  [ "$output" = "paths./orders.get.responses.200.headers.X-Correlation-Id paths./tenants.get.parameters.2.name" ]
  run jq -r "$(messages_of org-no-bespoke-correlation-headers)" <<<"$doc"
  contains "$output" 'traceparent'
}

@test "tc-corner-traceparent-allowed: traceparent and tracestate are not bespoke" {
  # Declared BOTH as request parameters and as response header keys, so a
  # widened notMatch is caught in whichever clause it was widened in.
  run lint_fixture corner-trace-headers
  [ "$status" -eq 0 ]
  # Absence asserted over the STRUCTURED document, severity-agnostic: a
  # `lacks` on the stylish output is the fail-OPEN half of the formatting
  # bet this file rejects for positive assertions, and it would also miss
  # a WARN-severity firing, which is its only value beyond the exit-0 above.
  run lint_fixture_json corner-trace-headers
  run jq -r '[.[] | select(.code == "org-no-bespoke-correlation-headers")] | length' <<<"$output"
  [ "$output" -eq 0 ]
}

# --- #944: the shared ops fragment, linted IN PLACE -------------------------
#
# By path, never as a copied fixture: a verbatim copy stops tracking the
# shipped template the day ops v3 lands, and would then go green for the wrong
# reason.

@test "tc-corner-ops-fragment-lints-clean: ops v2 produces no finding from any of the seven new rules" {
  # contracts-lint feeds this fragment into the same invocation as the business
  # contract, so a mis-scoped rule reddens every bootstrapped repo's ops surface
  # on a spec it did not write. The fix is correct scoping, proven here — never
  # an `overrides:` block, whose absence is asserted below.
  local frag="$REPO_ROOT/development/skills/bootstrap/templates/common/contracts/ops/v2/openapi.yaml"
  [ -f "$frag" ]
  run lint_path_json "$frag"
  run jq -e --argjson new "$NEW_RULE_IDS_JSON" \
    '[.[] | select(.severity == 0 and (.code as $c | $new | index($c)))] | length == 0' \
    <<<"$output"
  [ "$status" -eq 0 ]
  # The premise that makes the assertion above non-vacuous — this fragment DOES
  # declare the 503s a naive Retry-After rule would flag. Without it the case
  # would also pass against a fragment that had quietly dropped them.
  # `grep`, not `yq`: this lane's toolchain is node + npx + jq (see
  # ../README.md), and yq is not in it. Anchored on "an indented key", not on a
  # fixed column: a reindent changes no contract, and a premise that reds on one
  # is a premise that gets deleted rather than fixed.
  run grep -cE '^[[:space:]]+["'"'"']?503["'"'"']?:' "$frag"
  [ "$output" -eq 2 ]
  # …and they must still LACK Retry-After, and still be ops-TAGGED. Those two
  # facts are the exemption's only behavioural proof anywhere: nothing else in
  # the repo has an ops-tagged 503. Add a Retry-After to the probes — a
  # plausible, even desirable ops change — and without this the `not: tags
  # contains ops` sub-clause becomes unexercised while this case stays green.
  run grep -c 'Retry-After' "$frag"
  [ "$output" -eq 0 ]
  run grep -cE '^[[:space:]]+tags:.*\bops\b|^[[:space:]]+-[[:space:]]*ops[[:space:]]*$' "$frag"
  [ "$output" -eq 5 ]
  # The ops-tag exemption's SHAPE and the absence of any `overrides:` block are
  # asserted in tests/api-styleguide-ruleset.bats, which is ALWAYS-ON and has yq.
}

@test "tc-corner-business-seed-lints-clean: the seed business contract is not born red" {
  # The BUSINESS twin of the ops-fragment case above. contracts-lint feeds both
  # halves into the same invocation, and the ops half has been pinned since
  # #1330 — but the seed spec every bootstrapped repo actually starts from was
  # linted by nothing. PR-B is exactly when that bites: it advances the shim's
  # pin, so seven new error-severity rules start applying to this template in
  # every new repo at once. A seed that violates any of them means every repo is
  # BORN RED on its first contracts-lint run, on a spec it did not write.
  #
  # Rendered into the tmpdir with sed rather than driven through render.zsh:
  # this lane's declared toolchain is node + npx + jq (see ../README.md), and
  # adding a zsh dependency to reach the renderer would be a bigger change than
  # the case is worth. The substitution set is the seed's only placeholder.
  local tmpl="$REPO_ROOT/development/skills/bootstrap/templates/common/contracts/v1/openapi.yaml.tmpl"
  [ -f "$tmpl" ]
  local spec="$BATS_TEST_TMPDIR/seed.yaml"
  sed 's/{{PROJECT_NAME}}/Demo Project/g' "$tmpl" > "$spec"
  # An unsubstituted placeholder would make the lint below vacuous or wrong.
  run ! grep -q '{{' "$spec"
  # Render-fidelity guard. sed models render.zsh's PLACEHOLDER substitution and
  # nothing else — render.zsh also strips non-applicable `# --- TAG-START ---` /
  # `-END ---` blocks. The seed carries none today, so this asserts the stand-in
  # is still faithful: the day the template grows a conditional block, sed emits
  # every branch at once and this case would lint an artifact no bootstrapped
  # repo ever receives — in either direction (a spurious red, or a green while
  # every new repo is born red, which is the defect this case exists to catch).
  run ! grep -qE -- '# --- [A-Z_-]+-(START|END) ---' "$spec"
  # Premise, so the assertion cannot go green against an empty or emptied spec.
  run grep -cE '^[[:space:]]+get:' "$spec"
  [ "$output" -ge 1 ]
  # Zero ERROR findings from the whole ruleset, not just the seven: the seed is
  # what a new repo inherits, so any error-severity rule firing on it is the
  # same born-red defect regardless of which release minted the rule.
  #
  # SCOPE LIMIT, stated rather than implied: this lints the LOCAL ruleset, not
  # the pinned artifact a bootstrapped repo actually extends — and this lane is
  # outside the default gate and needs the network. So it proves the seed is
  # clean against the ruleset in this tree, which is the drift that arrives with
  # a rule change here; it does not prove it THROUGH the pin. Closing that would
  # mean giving check-styleguide-pin.zsh a third subject (a follow-up, not PR-B).
  run lint_path_json "$spec"
  run jq -e '[.[] | select(.severity == 0)] | length == 0' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "tc-corner-ops-v1-frozen-major-no-new-rule-findings: the frozen major is untouched by them too" {
  # Scoped per-id, and deliberately NOT asserting exit 0: org-problem-json-errors
  # fires on both of v1's 503s by design — that is #1330's premise, asserted in
  # the negative by the case above this block. A total-count assertion here
  # would contradict it.
  local frag="$REPO_ROOT/development/skills/bootstrap/templates/common/contracts/ops/v1/openapi.yaml"
  [ -f "$frag" ]
  run lint_path_json "$frag"
  # The EXACT code set, not "none of a hand-kept list of seven": an eighth org
  # rule added later and mis-scoped so that it fires here would leave an id-list
  # assertion green while every bootstrapped repo's ops surface reddened. This
  # form also states #1330's premise — org-problem-json-errors DOES fire on v1 —
  # in the same line, which is why v1 cannot simply assert zero findings the way
  # its v2 twin does.
  run jq -r "$(codes_of)" <<<"$output"
  [ "$output" = "org-problem-json-errors" ]
  # The same premise its v2 twin carries, and for the same reason: an absence
  # assertion also passes against a fragment that quietly lost the shape being
  # exempted, so bind it to a file that still has the 503s and the ops tag.
  run grep -cE '^[[:space:]]+["'"'"']?503["'"'"']?:' "$frag"
  [ "$output" -eq 2 ]
  run grep -c 'Retry-After' "$frag"
  [ "$output" -eq 0 ]
  # Anchored on the KEY and the value, not on the inline-array spelling: a
  # block-sequence `tags:` / `  - ops` changes no contract, and a premise that
  # reds on one is a premise that gets deleted rather than fixed — the same rule
  # the 503 grep above follows.
  run grep -cE '^[[:space:]]+tags:.*\bops\b|^[[:space:]]+-[[:space:]]*ops[[:space:]]*$' "$frag"
  [ "$output" -eq 5 ]
}

# --- #944: the clause-isolating fixtures ------------------------------------
#
# The main non-conforming fixture violates several clauses AT ONCE, so it cannot
# discriminate them: the surviving clause keeps firing and every id-only
# assertion stays green. These two fixtures trip exactly one clause per path.

@test "tc-error-pagination-cursor-params-missing isolates the cursor and limit clauses" {
  # /invoices declares cursor but no limit; /receipts the reverse. Delete either
  # `contains` clause from the rule and exactly one of these two stops firing.
  # /ledgers declares NO `parameters` key at all — the third, separate clause
  # (`required: ["parameters"]`), and the commonest real un-paginated
  # collection. Note its finding lands on the OPERATION rather than on a
  # parameters array, which is what distinguishes it from the other two.
  run lint_fixture_json nonconforming-pagination
  run jq -r "$(paths_of org-pagination-cursor-params)" <<<"$output"
  [ "$output" = "paths./invoices.get.parameters paths./ledgers.get paths./receipts.get.parameters" ]
}

@test "tc-error-pagination-envelope-bare-array also covers clause (b): items without next_cursor" {
  # Clause (a) — the bare array — is covered by the main fixture. Every envelope
  # elsewhere requires BOTH names, so clause (b)'s `then` is never evaluated in
  # the firing direction without this.
  run lint_fixture_json nonconforming-pagination
  run jq -r "$(paths_of org-pagination-envelope)" <<<"$output"
  [ "$output" = "components.schemas.HalfEnvelope.required" ]
}

@test "tc-error-pagination-offset-params-banned reaches components, path items and headers" {
  # The three shapes the main fixture cannot reach: a reusable
  # components.parameters entry, a path-item-level declaration, and a banned name
  # in a NON-query location — the last being the only proof the rule does not
  # filter on `in:`.
  run lint_fixture_json nonconforming-pagination
  run jq -r "$(paths_of org-pagination-no-offset-params)" <<<"$output"
  [ "$output" = "components.parameters.OffsetParam.name paths./receipts.get.parameters.1.name paths./statements.parameters.0.name" ]
}

@test "every clause-isolating fixture fires NOTHING beyond the rules it isolates" {
  # Each per-rule case reduces the document to ONE id, so an over-fire by any
  # OTHER rule landing on a fixture's conforming parts would be invisible — and
  # all four of these fixture headers promise exactly that no other rule fires.
  # Pin the whole set for each.
  #
  # The two #944 fixtures are not linted by styleguide-pin.yml either, so this
  # lane is their only cover. The two #689 fixtures matter here for a different
  # reason: #944 added cursor/limit and a *Page envelope to every GET in them
  # precisely to keep the new pagination rules quiet, and nothing else asserts
  # that it worked.
  run lint_fixture_json nonconforming-pagination
  run jq -r "$(codes_of)" <<<"$output"
  [ "$output" = "org-pagination-cursor-params org-pagination-envelope org-pagination-no-offset-params" ]
  run lint_fixture_json nonconforming-headers
  run jq -r "$(codes_of)" <<<"$output"
  [ "$output" = "org-deprecation-sunset-headers org-idempotency-key-on-post-patch org-no-bespoke-correlation-headers org-retry-after-on-throttled" ]
  run lint_fixture_json nonconforming-naming
  run jq -r "$(codes_of)" <<<"$output"
  [ "$output" = "org-resource-naming" ]
  run lint_fixture_json nonconforming-error-bodies
  run jq -r "$(codes_of)" <<<"$output"
  [ "$output" = "org-problem-json-errors" ]
}

@test "tc-error-retry-after-missing-on-429 has a 503 twin: a NON-ops 503 without the header" {
  # The rule's entire 503 branch is otherwise unproven — no other fixture has a
  # 503 that should fire, so the branch could be replaced with {} and every test
  # would stay green.
  run lint_fixture_json nonconforming-headers
  run jq -r "$(paths_of org-retry-after-on-throttled)" <<<"$output"
  [ "$output" = "paths./shipments.get.responses.503" ]
}

@test "tc-error-idempotency-key-missing-on-post also rejects a key in the WRONG place" {
  # Present-but-wrong, twice: `in: query` on the POST and `required: false` on
  # the PATCH. Absence alone cannot catch the deletion of either const.
  run lint_fixture_json nonconforming-headers
  run jq -r "$(paths_of org-idempotency-key-on-post-patch)" <<<"$output"
  [ "$output" = "paths./shipments.post.parameters paths./shipments/{shipmentId}.patch.parameters" ]
}

@test "tc-error-deprecation-sunset-headers-missing covers the 2XX RANGE key too" {
  # The same gap tc-error-range-status-key closes for org-problem-json-errors:
  # narrowing the patternProperties key to ^200$ passes every numeric-key
  # fixture while a 2XX-only spec escapes the rule entirely.
  run lint_fixture_json nonconforming-headers
  run jq -r "$(paths_of org-deprecation-sunset-headers)" <<<"$output"
  [ "$output" = "paths./shipments/{shipmentId}.get.responses.2XX" ]
}

@test "tc-error-bespoke-correlation-header reaches components and any casing" {
  # FOUR witnesses, one per `given` entry the rule inspects here, each reachable
  # by exactly one of them:
  #   components.headers      an UNREFERENCED banned component header key
  #   components.parameters   an UNREFERENCED banned component parameter
  #   path-item parameters    the lowercase x-request-id
  #   responses headers       an INLINE Request-Id on the PATCH 200
  # The two component definitions are unreferenced on purpose: spectral maps a
  # finding inside resolved $ref content back to the $ref target, so a
  # REFERENCED component yields the same `components.…` path whether or not the
  # rule carries a `$.components.*` given — the entry could be deleted and this
  # assertion would still pass. Unreferenced, it cannot.
  #
  # X-Trace-Id and the bare Request-Id also keep the alternation honest: without
  # them it could be trimmed to its first two members with everything green. The
  # lowercase spelling is the only proof the pattern's /i flag survived an edit.
  run lint_fixture_json nonconforming-headers
  run jq -r "$(paths_of org-no-bespoke-correlation-headers)" <<<"$output"
  [ "$output" = "components.headers.X-Correlation-Id components.parameters.TraceIdParam.name paths./shipments.parameters.0.name paths./shipments/{shipmentId}.patch.responses.200.headers.Request-Id" ]
}
