#!/usr/bin/env bats
#
# Structural tests for the org API styleguide ruleset (#689).
#
# These are the ALWAYS-ON half: they assert the artifact's shape without running
# spectral, so they run in the default `bats tests` gate with no network. The
# behavioural half — actually linting fixtures with spectral-cli — needs npx and
# the network, so it lives in tests/acceptance/cli/ (outside the default gate by
# construction, see tests/acceptance/README.md).
#
# The pairing is deliberate: a rule that loses its message, its documentationUrl,
# its severity or its scoping is caught on every PR here, even when the
# acceptance lane has not been run.
#
# Assertions go through `yq` (mikefarah, installed unguarded in tests/Dockerfile)
# rather than line-anchored greps wherever the claim is about the DOCUMENT. A
# grep on `    severity: error` never ties a severity to a rule id, and a grep at
# a fixed indentation breaks on a reindent that changes no contract.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RULESET="$REPO_ROOT/styleguide/spectral/ruleset.yaml"
  STYLEGUIDE="$REPO_ROOT/docs/reference/api-styleguide.md"
  HOWTO="$REPO_ROOT/docs/how-to/adopt-the-api-styleguide.md"
  FIXTURES="$REPO_ROOT/tests/fixtures/api-styleguide"
}

# The org-OWNED rules — full rule objects, each carrying message,
# documentationUrl, severity and given. Deliberately uncounted in prose: this
# array IS the count, and the documentationUrl canary below derives its
# expectation from nothing else.
ORG_RULE_IDS=(
  org-deprecated-operation-has-sunset
  org-resource-naming
  org-problem-json-errors
  org-pagination-cursor-params
  org-pagination-no-offset-params
  org-pagination-envelope
  org-idempotency-key-on-post-patch
  org-retry-after-on-throttled
  org-deprecation-sunset-headers
  org-no-bespoke-correlation-headers
)
# The five CODIFIED rules — inherited from spectral:oas by id, so they keep
# Spectral's own messages and documentation links.
CODIFIED_RULE_IDS=(
  operation-operationId
  operation-operationId-unique
  info-description
  operation-description
  operation-tags
)

@test "ruleset: exists at the published artifact path" {
  [ -f "$RULESET" ]
}

@test "ruleset: parses as YAML" {
  # An unparseable ruleset must red the DEFAULT gate, not only the acceptance
  # lane. The notMatch value is a double-quoted scalar continued with a trailing
  # backslash — exactly the shape a careless reformat breaks.
  run yq -e '.' "$RULESET"
  [ "$status" -eq 0 ]
}

@test "ruleset: declares exactly fifteen rules, and they are the fifteen normative ids" {
  run yq '.rules | keys | length' "$RULESET"
  [ "$status" -eq 0 ]
  [ "$output" -eq 15 ]
  local id
  for id in "${ORG_RULE_IDS[@]}" "${CODIFIED_RULE_IDS[@]}"; do
    run yq ".rules | has(\"$id\")" "$RULESET"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

@test "ruleset: every codified rule is promoted to error" {
  local id
  for id in "${CODIFIED_RULE_IDS[@]}"; do
    run yq ".rules.\"$id\"" "$RULESET"
    [ "$status" -eq 0 ]
    [ "$output" = "error" ]
  done
}

@test "ruleset: every org-owned rule declares severity error, by id" {
  local id
  for id in "${ORG_RULE_IDS[@]}"; do
    run yq ".rules.\"$id\".severity" "$RULESET"
    [ "$status" -eq 0 ]
    [ "$output" = "error" ]
  done
}

@test "ruleset: every org-owned rule carries a non-empty message and documentationUrl" {
  local id
  for id in "${ORG_RULE_IDS[@]}"; do
    run yq ".rules.\"$id\".message" "$RULESET"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [ "$output" != "null" ]
    run yq ".rules.\"$id\".documentationUrl" "$RULESET"
    [ "$status" -eq 0 ]
    starts_with "$output" "https://timo-jakob.github.io/timos-claude-code-plugins/reference/api-styleguide/#"
  done
}

@test "ruleset: each fix hint lives in the MESSAGE, not merely somewhere in the file" {
  # File-scoped greps passed with every message stripped: `x-sunset` also occurs
  # in the rule's description and in `field: x-sunset`, `plural kebab-case` in
  # its description, `application/problem+json` in the schema functionOptions.
  # Scoped to the message value, this test fails when the hint is removed.
  run yq '.rules."org-deprecated-operation-has-sunset".message' "$RULESET"
  contains "$output" 'x-sunset'
  run yq '.rules."org-resource-naming".message' "$RULESET"
  contains "$output" 'plural kebab-case'
  run yq '.rules."org-problem-json-errors".message' "$RULESET"
  contains "$output" 'application/problem+json'
  # #944's seven. Same reasoning, and it bites harder here: `cursor`, `limit`,
  # `Idempotency-Key`, `Retry-After`, `Deprecation`, `Sunset` and `traceparent`
  # all occur elsewhere in the file — in a description, a comment, or the
  # schema functionOptions — so only a message-scoped assertion can tell a
  # fix hint from a coincidence.
  run yq '.rules."org-pagination-cursor-params".message' "$RULESET"
  contains "$output" 'cursor'
  contains "$output" 'default 50, max 200'
  run yq '.rules."org-pagination-no-offset-params".message' "$RULESET"
  contains "$output" 'cursor pagination'
  run yq '.rules."org-pagination-envelope".message' "$RULESET"
  contains "$output" 'items'
  contains "$output" 'next_cursor'
  contains "$output" '(null on the last page)'
  run yq '.rules."org-idempotency-key-on-post-patch".message' "$RULESET"
  contains "$output" 'Idempotency-Key'
  contains "$output" 'required: true'
  run yq '.rules."org-retry-after-on-throttled".message' "$RULESET"
  contains "$output" 'Retry-After'
  contains "$output" 'delta-seconds'
  run yq '.rules."org-deprecation-sunset-headers".message' "$RULESET"
  contains "$output" 'Deprecation'
  contains "$output" 'Sunset'
  run yq '.rules."org-no-bespoke-correlation-headers".message' "$RULESET"
  contains "$output" 'traceparent'
}

@test "ruleset: carries NO overrides block — scoping is fixed by being correct" {
  # The shared ops fragment is linted by the same invocation as the business
  # contract, so the tempting fix for a mis-scoped rule is an `overrides:`
  # exclusion. It is banned outright: an exclusion hides a scoping bug rather
  # than fixing it, and the bug then reaches every bootstrapped repo that
  # writes a spec the exclusion does not cover. Asserted as a document fact, so
  # it cannot be reintroduced quietly under a plausible comment.
  run yq -r 'has("overrides")' "$RULESET"
  [ "$output" = "false" ]
}

@test "ruleset: every #944 rule pins its GIVEN by identity" {
  # A rule's `given` is its scope, and a scope that silently narrows is the
  # cheapest way to ship a dead rule: every fixture keeps passing, because the
  # shapes that no longer match were the ones that used to fire. Asserted for
  # all seven together rather than rule-by-rule, so a new rule cannot be added
  # with its scope unpinned.
  run yq -r '.rules."org-pagination-cursor-params".given' "$RULESET"
  [ "$output" = '$.paths[*].get' ]
  run yq -r '[.rules."org-pagination-no-offset-params".given[]] | sort | join(",")' "$RULESET"
  [ "$output" = '$.components.parameters[*],$.paths[*].parameters[*],$.paths[*][*].parameters[*]' ]
  run yq -r '.rules."org-pagination-envelope".given' "$RULESET"
  [ "$output" = "\$.paths[*].get.responses['200'].content['application/json'].schema" ]
  run yq -r '[.rules."org-idempotency-key-on-post-patch".given[]] | sort | join(",")' "$RULESET"
  [ "$output" = '$.paths[*].patch,$.paths[*].post' ]
  run yq -r '.rules."org-retry-after-on-throttled".given' "$RULESET"
  [ "$output" = '$.paths[*][?(@.responses)]' ]
  run yq -r '.rules."org-deprecation-sunset-headers".given' "$RULESET"
  [ "$output" = '$.paths[*][?(@.deprecated === true)]' ]
  run yq -r '[.rules."org-no-bespoke-correlation-headers".given[]] | sort | join(",")' "$RULESET"
  [ "$output" = '$.components.headers,$.components.parameters[*],$.paths[*].parameters[*],$.paths[*][*].parameters[*],$.paths[*][*].responses[*].headers' ]
}

@test "ruleset: every #944 schema-driven rule still declares function: schema" {
  # Every other assertion about these five navigates `.then.functionOptions
  # .schema…`, which survives deleting or renaming the `function:` key itself.
  # Spectral then refuses to load the ruleset — but `ruleset: parses as YAML`
  # only proves YAML validity, and check-styleguide-pin.zsh lints through the
  # PUBLISHED pin, so a working-tree edit is invisible to it. The break would
  # surface only in the out-of-gate acceptance lane, or downstream after the tag
  # is cut.
  local id
  for id in org-pagination-cursor-params org-pagination-envelope \
    org-idempotency-key-on-post-patch org-retry-after-on-throttled \
    org-deprecation-sunset-headers; do
    run yq -r ".rules.\"$id\".then.function" "$RULESET"
    [ "$output" = "schema" ]
  done
}

@test "ruleset: org-retry-after-on-throttled exempts ops-tagged operations from the 503 half ONLY" {
  # The exemption is what keeps the ops fragment's two probe 503s clean without
  # an overrides block — and it must stay confined to the 503 branch. Widened
  # to the 429 branch, an ops-tagged operation could declare a 429 with no
  # Retry-After and nothing anywhere would notice: ops v2 declares no 429, so
  # no fixture and no template would redden.
  local allof='.rules."org-retry-after-on-throttled".then.functionOptions.schema.allOf'
  run yq -r "${allof} | length" "$RULESET"
  [ "$output" -eq 2 ]
  # Branch 0 is the 429 half: it keys on the 429 response and carries NO tag
  # condition at all.
  run yq -r "${allof}[0].if.properties.responses.required | join(\",\")" "$RULESET"
  [ "$output" = "429" ]
  run yq -r "${allof}[0].if | has(\"allOf\")" "$RULESET"
  [ "$output" = "false" ]
  # Branch 1 is the 503 half: the response condition AND the not-ops-tagged
  # condition, together.
  run yq -r "${allof}[1].if.allOf[0].properties.responses.required | join(\",\")" "$RULESET"
  [ "$output" = "503" ]
  run yq -r "${allof}[1].if.allOf[1].not.properties.tags.contains.const" "$RULESET"
  [ "$output" = "ops" ]
  # …and the presence guard BESIDE it, which inverts in importance inside a
  # `not`: remove `required: ["tags"]` and an operation with NO tags key matches
  # the inner schema vacuously, so the `not` is false and the exemption widens
  # from "ops-tagged" to "every UNTAGGED operation" — the opposite of the
  # documented contract, and unreachable by any fixture (nothing in the set has
  # an untagged 503).
  run yq -r "${allof}[1].if.allOf[1].not.required | join(\",\")" "$RULESET"
  [ "$output" = "tags" ]
  # …and BOTH branches' `then` must actually demand the header. Asserting only
  # the `if` conditions leaves either branch replaceable with `{}` — half a
  # newly minted error-severity rule shipping dead, with every fixture green.
  local br
  for br in 0 1; do
    local key; key=$([ "$br" = 0 ] && echo 429 || echo 503)
    run yq -r "${allof}[${br}].then.properties.responses.properties.\"${key}\".required | join(\",\")" "$RULESET"
    [ "$output" = "headers" ]
    run yq -r "${allof}[${br}].then.properties.responses.properties.\"${key}\".properties.headers.required | join(\",\")" "$RULESET"
    [ "$output" = "Retry-After" ]
    run yq -r "${allof}[${br}].then.properties.responses.properties.\"${key}\".properties.headers.properties.\"Retry-After\".properties.schema.properties.type.const" "$RULESET"
    [ "$output" = "integer" ]
  done
}

@test "ruleset: org-deprecation-sunset-headers demands BOTH headers, on numeric AND range 2xx keys" {
  # Its operation anchor — the scoping that lets it be an error rather than the
  # #692 starter's warning — is pinned with the other six givens above.
  local req='.rules."org-deprecation-sunset-headers".then.functionOptions.schema.properties.responses.patternProperties'
  # The KEY itself, not just the value beneath it. A wildcard selector passes
  # against `^200$`, after which a spec declaring its success responses only as
  # `2XX` escapes the rule — the same gap /receipts and tc-error-range-status-key
  # exist to close for org-problem-json-errors.
  run yq -r "${req} | keys | .[0]" "$RULESET"
  [ "$output" = '^2([0-9]{2}|XX)$' ]
  run yq -r "${req} | keys | length" "$RULESET"
  [ "$output" -eq 1 ]
  # …and it demands BOTH headers. Dropping either leaves the acceptance case
  # green, because the fixture declares neither.
  run yq -r "${req}[].properties.headers.required | join(\",\")" "$RULESET"
  [ "$output" = "Deprecation,Sunset" ]
  # …and the guards that make a MISSING headers map a violation rather than a
  # vacuous pass. A `properties.headers` subschema applies only when the key is
  # present, so without `required: ["headers"]` the rule degrades to "if you
  # declare headers, declare both" — and the shape both fixtures actually plant
  # (a 2xx with no `headers` key at all) stops firing entirely.
  run yq -r "${req}[].required | join(\",\")" "$RULESET"
  [ "$output" = "headers" ]
  run yq -r '.rules."org-deprecation-sunset-headers".then.functionOptions.schema.required | join(",")' "$RULESET"
  [ "$output" = "responses" ]
}

@test "ruleset: the pagination rules key on the org COLLECTION definition, not on any array" {
  # Detection is (a) a top-level array or (b) an object with a REQUIRED `items`
  # array. Widening (b) to "an object with an array anywhere" reddens every
  # bootstrapped repo's ops fragment, whose /info returns required:[build, api].
  local anyof='.rules."org-pagination-cursor-params".then.functionOptions.schema.if.properties.responses.properties."200".properties.content.properties."application/json".properties.schema.anyOf'
  run yq -r "${anyof} | length" "$RULESET"
  [ "$output" -eq 2 ]
  run yq -r "${anyof}[0].properties.type.const" "$RULESET"
  [ "$output" = "array" ]
  run yq -r "${anyof}[1].properties.required.contains.const" "$RULESET"
  [ "$output" = "items" ]
  # …and the guards that keep shape (b) from matching a FREE-FORM object. Delete
  # `required: ["required", "properties"]` and a plain `{type: object}` body —
  # which real specs write — matches vacuously, becomes "a collection", and is
  # told to declare cursor + limit: an over-fire on an ordinary single-resource
  # GET. The `items` must also be an ARRAY, the half the ruleset header and the
  # corner fixture both state.
  run yq -r "${anyof}[1].required | join(\",\")" "$RULESET"
  [ "$output" = "required,properties" ]
  run yq -r "${anyof}[1].properties.properties.required | join(\",\")" "$RULESET"
  [ "$output" = "items" ]
  run yq -r "${anyof}[1].properties.properties.properties.items.properties.type.const" "$RULESET"
  [ "$output" = "array" ]
  # The envelope rule owes the cursor once a body opts into the name. BOTH the
  # `if` and the `then`: pinning only the `then` leaves the `if` re-keyable onto
  # `next_cursor`, after which clause (b) is unsatisfiable and permanently
  # vacuous with every fixture green.
  local envelope='.rules."org-pagination-envelope".then.functionOptions.schema.allOf'
  run yq -r "${envelope}[1].if.properties.required.contains.const" "$RULESET"
  [ "$output" = "items" ]
  run yq -r "${envelope}[1].then.properties.required.contains.const" "$RULESET"
  [ "$output" = "next_cursor" ]
  # …and rejects the bare array outright, which is the half a detection gate
  # would have made unreachable.
  run yq -r "${envelope}[0].not.properties.type.const" "$RULESET"
  [ "$output" = "array" ]
  # The presence guards on both clauses — the OVER-fire direction, and the one
  # no fixture reaches (every GET 200 schema in the set declares both keys).
  # Without `not.required: ["type"]`, a 200 schema with no `type` key — a plain
  # composed body, routine in real specs — matches the inner schema vacuously,
  # the `not` fails, and an ordinary single-resource GET is flagged. Without
  # `if.required: ["required"]`, any object schema with no `required` key is
  # dragged into clause (b) and told to declare `next_cursor`.
  run yq -r "${envelope}[0].not.required | join(\",\")" "$RULESET"
  [ "$output" = "type" ]
  run yq -r "${envelope}[1].if.required | join(\",\")" "$RULESET"
  [ "$output" = "required" ]
  # cursor-params demands BOTH names. The only fixture that violates both at
  # once cannot discriminate them, so without this either `contains` clause is
  # deletable — and dropping `limit` ships a ruleset that accepts an unbounded
  # page size. (nonconforming-pagination isolates them behaviourally too.)
  run yq -r '[.rules."org-pagination-cursor-params".then.functionOptions.schema.then.properties.parameters.allOf[].contains.properties.name.const] | sort | join(",")' "$RULESET"
  [ "$output" = "cursor,limit" ]
  run yq -r '[.rules."org-pagination-cursor-params".then.functionOptions.schema.then.properties.parameters.allOf[].contains.properties.in.const] | unique | join(",")' "$RULESET"
  [ "$output" = "query" ]
  # `required: ["parameters"]` is a THIRD, separate clause: without it a
  # collection GET declaring no `parameters` key at all — the commonest real
  # un-paginated collection — satisfies the rule, because an `allOf` of
  # `contains` over a missing array is vacuous. nonconforming-pagination's
  # /ledgers is its behavioural twin.
  run yq -r '.rules."org-pagination-cursor-params".then.functionOptions.schema.then.required | join(",")' "$RULESET"
  [ "$output" = "parameters" ]
  # …and each `contains` must REQUIRE the members it constrains: a `const` under
  # `properties` applies only when the key is present, so without this a bare
  # `- name: cursor` with no `in:` would satisfy the clause.
  run yq -r '[.rules."org-pagination-cursor-params".then.functionOptions.schema.then.properties.parameters.allOf[].contains.required | join(",")] | unique | join(";")' "$RULESET"
  [ "$output" = "name,in" ]
}

@test "ruleset: org-pagination-no-offset-params bans EVERY listed name, in any location" {
  # A single alternation, so a regression that trimmed it would still fire on
  # the survivors and satisfy every acceptance assertion that only checks the
  # id. Pin the membership; the three-entry `given` is pinned by identity in the
  # #944 given test above, and nonconforming-pagination exercises a banned name
  # declared `in: header` so "any location" is proven behaviourally rather than
  # by inspecting the given's spelling.
  run yq -r '.rules."org-pagination-no-offset-params".then.functionOptions.notMatch' "$RULESET"
  [ "$output" = '^(offset|page|page_size|per_page|skip|start|start_index)$' ]
  # The `then` SHAPE, not just its pattern. Delete `field: name` and the pattern
  # is applied to the whole parameter object, which matches nothing and ships the
  # rule dead — and only the out-of-gate acceptance lane would notice. Every
  # sibling rule in this file pins its then shape; this one was the exception.
  run yq -r '.rules."org-pagination-no-offset-params".then.field' "$RULESET"
  [ "$output" = "name" ]
  run yq -r '.rules."org-pagination-no-offset-params".then.function' "$RULESET"
  [ "$output" = "pattern" ]
}

@test "ruleset: org-no-bespoke-correlation-headers inspects BOTH the parameter and the header-key shape" {
  # The banned name lives in `name` on a parameter object and in the KEY of a
  # response-headers map. Two `then` clauses, and deleting either leaves a
  # whole shape unenforced while the other acceptance case stays green.
  run yq -r '.rules."org-no-bespoke-correlation-headers".then | length' "$RULESET"
  [ "$output" -eq 2 ]
  run yq -r '[.rules."org-no-bespoke-correlation-headers".then[].field] | sort | join(",")' "$RULESET"
  [ "$output" = "@key,name" ]
  run yq -r '[.rules."org-no-bespoke-correlation-headers".then[].function] | unique | join(",")' "$RULESET"
  [ "$output" = "pattern" ]
  # The pattern, by EXACT equality on both clauses at once.
  #
  # The earlier form — `unique | length == 1` plus a `lacks traceparent` — was
  # fail-OPEN: delete notMatch from both clauses and yq yields [null, null],
  # whose unique length is 1, while the literal string "null" contains no
  # "traceparent". This always-on file would then have stayed green against a
  # rule with no pattern at all. Pinning the value subsumes the uniqueness check.
  # The `/…/i` delimited form is load-bearing: it is what catches X-REQUEST-ID.
  #
  # The pinned value deliberately does not reach `traceparent` or `tracestate`,
  # which is what makes the sanctioned channel usable; corner-trace-headers
  # proves that end to end. Re-asserting it here with a `lacks` on this same
  # `$output` would be tautological — the equality above has already fixed the
  # string — and would invite a future editor to weaken the equality believing
  # the `lacks` still covered them.
  local ban='/^(x-(request|correlation|trace)|request)-id$/i'
  run yq -r '[.rules."org-no-bespoke-correlation-headers".then[].functionOptions.notMatch] | unique | join(",")' "$RULESET"
  [ "$output" = "$ban" ]
}

@test "ruleset: org-idempotency-key-on-post-patch demands the name, the LOCATION and required: true" {
  # PUT and DELETE are idempotent by method; the POST/PATCH given is pinned by
  # identity in the #944 given test above.
  #
  # All three consts, because each is separately load-bearing and each has a
  # behavioural twin in nonconforming-headers: drop `in` and an Idempotency-Key
  # declared as a QUERY parameter satisfies the rule; drop `required` and an
  # optional key does.
  local c='.rules."org-idempotency-key-on-post-patch".then.functionOptions.schema.properties.parameters.contains'
  run yq -r "${c}.properties.name.const" "$RULESET"
  [ "$output" = "Idempotency-Key" ]
  run yq -r "${c}.properties.in.const" "$RULESET"
  [ "$output" = "header" ]
  run yq -r "${c}.properties.required.const" "$RULESET"
  [ "$output" = "true" ]
  # The `required` LIST guarding those consts: a `const` under `properties`
  # applies only when the key is present, so without it a bare
  # `- name: Idempotency-Key` with no `in:` and no `required:` satisfies the rule.
  run yq -r "${c}.required | join(\",\")" "$RULESET"
  [ "$output" = "name,in,required" ]
  # The rule's OWN `required: ["parameters"]`. An `array.contains` over an
  # ABSENT key is vacuous, so without it a POST/PATCH declaring no `parameters`
  # key at all satisfies the rule — the main fixture's planted defect, and the
  # commonest real shape. The same guard org-pagination-cursor-params carries.
  run yq -r '.rules."org-idempotency-key-on-post-patch".then.functionOptions.schema.required | join(",")' "$RULESET"
  [ "$output" = "parameters" ]
}

@test "ruleset: extends spectral:oas rather than restating its rules" {
  run yq '.extends[0]' "$RULESET"
  [ "$status" -eq 0 ]
  [ "$output" = "spectral:oas" ]
}

@test "ruleset: states the tag-immutability rule in its own header" {
  run grep -i 'TAGS ARE IMMUTABLE' "$RULESET"
  [ "$status" -eq 0 ]
}

@test "ruleset: org-deprecated-operation-has-sunset is scoped to operations only" {
  run yq '.rules."org-deprecated-operation-has-sunset".given' "$RULESET"
  [ "$status" -eq 0 ]
  [ "$output" = '$.paths[*][?(@.deprecated === true)]' ]
}

@test "ruleset: org-resource-naming keeps BOTH pattern clauses" {
  # The id, severity, message, doc URL and `given` are all asserted elsewhere —
  # but not `.then`, which is a TWO-clause array. Delete either and every other
  # test here stays green: the count is still 15, the severity still error, the
  # message still says "plural kebab-case". Nothing else covers it offline:
  # check-styleguide-pin.zsh lints through the PUBLISHED pin, so a working-tree
  # ruleset edit is invisible to it, and it only asserts the id FIRES — which the
  # surviving clause would still do.
  run yq -r '.rules."org-resource-naming".then | length' "$RULESET"
  [ "$output" -eq 2 ]
  run yq -r '[.rules."org-resource-naming".then[].functionOptions | keys | .[]] | sort | join(",")' "$RULESET"
  [ "$output" = "match,notMatch" ]
  # The trailing-context guard specifically: it is the whole reason /addresses,
  # /searches and /deleted-items stay clean, so widening it to a bare prefix
  # alternation is the regression that reddens every downstream repo.
  run yq -r '.rules."org-resource-naming".then[1].functionOptions.notMatch' "$RULESET"
  contains "$output" '([A-Z_-]|$|/)'
}

@test "ruleset: org-deprecated-operation-has-sunset asserts the FIELD, truthily" {
  # `truthy` rather than `defined` is the load-bearing half — an empty
  # `x-sunset: ""` must fail. Changing `field` makes the rule fire on every
  # deprecated operation including the conforming fixture's correctly-sunset one.
  # Neither is covered by the message needle, which matches the message STRING.
  run yq -r '.rules."org-deprecated-operation-has-sunset".then.field' "$RULESET"
  [ "$output" = "x-sunset" ]
  run yq -r '.rules."org-deprecated-operation-has-sunset".then.function' "$RULESET"
  [ "$output" = "truthy" ]
}

@test "ruleset: org-resource-naming is scoped to the paths object" {
  run yq '.rules."org-resource-naming".given' "$RULESET"
  [ "$status" -eq 0 ]
  [ "$output" = '$.paths' ]
}

@test "ruleset: org-problem-json-errors matches numeric AND range status keys" {
  # `@property >= 400` alone never matches "4XX"/"5XX" (they coerce to NaN), so
  # a spec declaring only range keys would pass untouched. Pin both halves.
  run yq '.rules."org-problem-json-errors".given' "$RULESET"
  [ "$status" -eq 0 ]
  contains "$output" '@property >= 400'
  contains "$output" "@property === '4XX'"
  contains "$output" "@property === '5XX'"
}

@test "ruleset: org-problem-json-errors requires a BARE problem+json error body" {
  local content_schema='.rules."org-problem-json-errors".then.functionOptions.schema.properties.content'
  run yq "${content_schema}.required[0]" "$RULESET"
  [ "$status" -eq 0 ]
  [ "$output" = "application/problem+json" ]
  # maxProperties is what makes "bare" real: forbidding only application/json
  # would leave text/plain and application/xml free to reintroduce a second
  # error shape.
  run yq "${content_schema}.maxProperties" "$RULESET"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "ruleset: org-problem-json-errors requires all four RFC 9457 members" {
  local req='.rules."org-problem-json-errors".then.functionOptions.schema.properties.content.properties."application/problem+json".properties.schema.properties.required.allOf'
  run yq "${req} | length" "$RULESET"
  [ "$status" -eq 0 ]
  [ "$output" -eq 4 ]
  run yq "${req} | map(.contains.const) | join(\",\")" "$RULESET"
  [ "$status" -eq 0 ]
  [ "$output" = "type,title,status,detail" ]
}

@test "styleguide page: every documentationUrl anchor resolves to a real heading" {
  local urls anchor slugs n=0
  urls="$(grep -o 'https://[^"[:space:]]*api-styleguide/#[^"[:space:]]*' "$RULESET")"
  # Canary: a loop fed by an empty producer would report ok having asserted
  # nothing. Pin the count to the documentationUrl count asserted above.
  [ -n "$urls" ]
  run grep -c . <<<"$urls"
  [ "$output" -eq "${#ORG_RULE_IDS[@]}" ]
  # mkdocs slugifies a heading as: text lowercased, punctuation dropped, spaces
  # hyphenated. Fenced code blocks are stripped first — the page carries `# no`
  # and `# yes` inside a fence, and neither generates an anchor.
  slugs="$(awk '/^```/ {f = !f; next} !f' "$STYLEGUIDE" \
    | grep -E '^#+ ' \
    | sed -e 's/^#* *//' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9 -]//g' -e 's/  */-/g')"
  while read -r url; do
    anchor="${url##*#}"
    [ -n "$anchor" ]
    run grep -Fxc "$anchor" <<<"$slugs"
    [ "$output" -ge 1 ]
    n=$((n + 1))
  done <<<"$urls"
  [ "$n" -eq "${#ORG_RULE_IDS[@]}" ]
}

@test "styleguide page: its rule TABLE is the ruleset's id set, and its pending marks match" {
  # The anchor test above binds the ruleset's documentationUrls to the page's
  # headings — the only doc-to-ruleset binding there was. The page's normative
  # rule table is a FOURTH hand-kept copy of the roster (after this file's two
  # arrays, the checker's EXPECTED_RULES and PENDING_PIN_RULES), and nothing
  # read it: rename an id and the author fixes the two arrays, while the page
  # every red build points a developer at keeps naming an id that is gone.
  # Scoped to the "## The rules" section: the page carries other tables whose
  # first cell is also a backticked identifier (Pagination's `cursor`/`limit`
  # request table), and an unscoped grep silently folds them into the roster.
  # The id class allows UPPERCASE — `operation-operationId` is camelCase, and a
  # lowercase-only class matches it nowhere rather than partially, which reads
  # as "the page omits it".
  local declared documented rules_section
  rules_section="$(awk '/^## The rules$/ {f = 1; next} f && /^## / {f = 0} f' "$STYLEGUIDE")"
  declared="$(yq -r '.rules | keys | .[]' "$RULESET" | sort)"
  documented="$(printf '%s\n' "$rules_section" | grep -oE '^\| `[A-Za-z0-9-]+`' | tr -d '|` ' | sort)"
  # Canary FIRST: a regex that stops matching would otherwise compare two empty
  # strings and pass, which is the failure this whole test exists to prevent.
  run grep -c . <<<"$documented"
  [ "$output" -eq "$(yq -r '.rules | keys | length' "$RULESET")" ]
  [ "$declared" = "$documented" ]

  # …and the release-window marks. The page marks exactly the ids that are in
  # this repo but not yet in the published tag, so the count must track the
  # checker's parked list — the same window, stated in a third place.
  local pending_rows
  pending_rows="$(printf '%s\n' "$rules_section" \
    | grep -cE '^\| `[A-Za-z0-9-]+`.*\*\*pending\*\*' || true)"
  # awk, not a `sed` RANGE: sed only tests the end pattern on lines AFTER the
  # start, so `PENDING_PIN_RULES=()` — the one-liner PR-B will naturally write
  # when it empties the list — never closes the range, which then runs to EOF
  # and counts dozens of unrelated lines. That would red a perfectly correct
  # post-PR-B tree with a baffling number, on the very state these tests claim
  # to handle. This scoper yields 0 for the one-liner and the real count for the
  # multi-line form.
  local parked_ids marked_ids parked
  parked_ids="$(awk '/^PENDING_PIN_RULES=\(\)/ {exit}
                     /^PENDING_PIN_RULES=\(/ {f = 1; next}
                     f && /^\)/ {exit}
                     f' "$REPO_ROOT/tests/check-styleguide-pin.bats" \
    | tr -d ' \t' | sed '/^$/d; /^#/d' | sort)"
  parked="$(printf '%s\n' "$parked_ids" | grep -c . || true)"
  # Count, then IDENTITY. The count is NOT the empty-vs-empty canary — post-PR-B
  # both sides are empty and it compares 0 to 0; that job belongs to the
  # `documented` count assertion above, which fires before either comparison
  # here can be reached. It is kept because it names the discrepancy plainly
  # ("7 marked, 0 parked") where the identity below would print two lists.
  # The identity is what actually protects the marks: a count alone is satisfied
  # by any permutation, and moving a mark from one row to another makes the page
  # state the opposite of the truth for BOTH rules — the same doc-vs-ruleset rot
  # the id-set half above exists to close.
  [ "$pending_rows" -eq "$parked" ]
  marked_ids="$(printf '%s\n' "$rules_section" \
    | grep -E '^\| `[A-Za-z0-9-]+`.*\*\*pending\*\*' \
    | sed -E 's/^\| `([A-Za-z0-9-]+)`.*/\1/' | sort)"
  [ "$marked_ids" = "$parked_ids" ]
}

@test "the published jsDelivr URL points at a path that exists in this repo" {
  # A typo here ships a permanently-404 pin to every bootstrapped repo, and the
  # failure surfaces in consumers rather than here.
  local url path
  url="$(grep -o 'https://cdn\.jsdelivr\.net[^ ]*ruleset\.yaml' "$RULESET" | head -1)"
  [ -n "$url" ]
  path="${url#*@styleguide-v*/}"
  [ "$path" = "styleguide/spectral/ruleset.yaml" ]
  [ -f "$REPO_ROOT/$path" ]
}

@test "EVERY file quoting a styleguide pin quotes the SAME one" {
  # Swept repo-wide, not from a named file list. #689 shipped the pin in two
  # places (ruleset header, how-to) and PR-B added a third that outranks both —
  # the bootstrap shim, the only copy downstream repos actually consume. A closed
  # list would have silently stopped covering the file that matters most, so the
  # sweep enumerates tracked files instead and a fourth site is covered for free.
  # `find`, NOT `git ls-files`. Two reasons, both learned the hard way:
  #   - git ls-files skips UNTRACKED files, so a new doc quoting a stale pin
  #     passes locally and only reds in CI after `git add` (the #1189 lesson);
  #   - the Docker lane bind-mounts the repo, and in a git WORKTREE `.git` is a
  #     FILE pointing at a host path absent from the container, so git fatals and
  #     the sweep would inspect nothing while reporting success (the #1330 lesson).
  # Keyed on the REAL owner/repo. Test fixtures that deliberately carry a wrong
  # pin (tests/check-styleguide-pin.bats exercises a floating tag, a superseded
  # version and a two-pin shim) use gh/example/styleguide-fixture instead, so
  # they cannot collide with this sweep — and, unlike a file-exclusion list,
  # that distinction does not rot when a new fixture file appears.
  local OWNER_REPO='timo-jakob/timos-claude-code-plugins'
  local list="$BATS_TEST_TMPDIR/pin-sites.txt"
  local hits="$BATS_TEST_TMPDIR/pin-urls.txt"

  # Materialised through temp files rather than nested `< <(…)` process
  # substitutions: the nested form failed only under run-gate.zsh's parallel
  # runner, with an unattributable "line 0" error, while passing standalone.
  # EVERY occurrence per file is collected (grep without head), because a
  # bump/upgrade guide is the natural home for a stale "before" snippet that a
  # first-match-only sweep would never see.
  # `.claude/worktrees/` is excluded because this repo's whole workflow lives in
  # sibling worktrees: `git ls-files` skipped them implicitly, `find` does not.
  # Run from the main checkout, a sibling branch mid-bump to a newer pin would
  # red this test in a tree that is perfectly consistent — and, worse, a sibling's
  # three pin sites could satisfy the canary for a main tree that has none.
  #
  # ANCHORED to $REPO_ROOT, not '*/.claude/worktrees/*': the suite itself runs
  # from inside a worktree, so the unanchored form matches every path in the tree
  # and excludes the entire repo.
  find "$REPO_ROOT" -type f \
    -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/site/*' \
    -not -path "$REPO_ROOT/.claude/worktrees/*" > "$list"
  local files
  files="$(wc -l < "$list" | tr -d ' ')"

  : > "$hits"
  local f
  while IFS= read -r f; do
    grep -ohI "https://cdn\.jsdelivr\.net/gh/$OWNER_REPO@[^ \"]*ruleset\.yaml" "$f" 2>/dev/null >> "$hits" || true
  done < "$list"

  local n distinct
  n="$(wc -l < "$hits" | tr -d ' ')"
  distinct="$(sort -u "$hits" | wc -l | tr -d ' ')"
  if [ "$distinct" -gt 1 ]; then
    printf 'pin mismatch — %s distinct pins in the tree:\n' "$distinct" >&2
    sort -u "$hits" >&2
    printf 'quoted by:\n' >&2
    grep -rl "cdn\.jsdelivr\.net/gh/$OWNER_REPO@" "$REPO_ROOT" 2>/dev/null | grep -v '/\.git/' >&2 || true
    return 1
  fi
  local first
  first="$(sort -u "$hits" | head -1)"

  # A MISTYPED owner/repo is not a "hit" at all, so the distinctness check above
  # cannot see it — and it is the worst case, shipping a permanently-404 pin.
  # Second pass, owner-AGNOSTIC: every jsDelivr ruleset URL in the tree must be
  # either the real pin or the deliberate fixture sentinel.
  # Reuses pass 1's file list rather than a second `grep -r`, so both passes share
  # ONE exclusion policy — a second, differently-spelled exclusion set is how the
  # two halves drift apart.
  local all_urls stray nul="$BATS_TEST_TMPDIR/pin-sites.nul"
  tr '\n' '\0' < "$list" > "$nul"
  all_urls="$(xargs -0 grep -ohI 'https://cdn\.jsdelivr\.net/gh/[^ "]*ruleset\.yaml' \
    < "$nul" 2>/dev/null | sort -u || true)"
  # Canary FIRST: this pass is fully silenced, so without it a walk that inspected
  # nothing would report "no strays" — the same fail-open that made the renovate
  # helper's coverage check vacuous.
  case "$all_urls" in
    *"/gh/$OWNER_REPO@"*) ;;
    *) printf 'stray-pass canary: the real pin was not found at all\n' >&2; return 1 ;;
  esac
  case "$all_urls" in
    *'/gh/example/styleguide-fixture@'*) ;;
    *) printf 'stray-pass canary: the fixture sentinel was not found at all\n' >&2; return 1 ;;
  esac
  stray="$(printf '%s\n' "$all_urls" \
    | grep -v "/gh/$OWNER_REPO@" | grep -v '/gh/example/styleguide-fixture@' || true)"
  if [ -n "$stray" ]; then
    printf 'jsDelivr URL with an unexpected owner/repo (typo?):\n%s\n' "$stray" >&2
    return 1
  fi

  # Canaries. Without these the sweep passes by inspecting nothing.
  [ "$files" -gt 100 ]   # the walk actually walked
  [ "$n" -ge 3 ]         # and found the known pin sites

  # Identity, not just a count three unrelated files could satisfy: each known
  # site must itself carry the pin.
  local site
  for site in development/skills/bootstrap/templates/common/.spectral.yaml \
    styleguide/spectral/ruleset.yaml \
    docs/how-to/adopt-the-api-styleguide.md; do
    grep -q "https://cdn\.jsdelivr\.net/gh/$OWNER_REPO@" "$REPO_ROOT/$site" \
      || { printf 'known pin site no longer quotes the pin: %s\n' "$site" >&2; return 1; }
  done

  # Bind the canary to IDENTITY, not just a count three unrelated files could
  # satisfy: the shipped shim is the copy downstream repos consume, so it must be
  # one of the files swept.
  run grep -c 'https://cdn\.jsdelivr\.net/gh/.*ruleset\.yaml' \
    "$REPO_ROOT/development/skills/bootstrap/templates/common/.spectral.yaml"
  [ "$output" -ge 1 ]
  [ "$first" = "$(yq -r '.extends[0]' "$REPO_ROOT/development/skills/bootstrap/templates/common/.spectral.yaml")" ]
}

@test "fixtures: the fixture set is EXACTLY this roster, both directions" {
  # Checked both ways on purpose. A one-directional list rots the moment someone
  # adds a twelfth fixture — the natural thing to do when a future rule needs
  # clause isolation — and that fixture would then carry no integrity test and no
  # acceptance case with nothing reporting it. This is the closed-swept-list
  # lesson the pin sweep below already applies by enumerating the tree.
  local expected actual f
  expected="$(printf '%s\n' conforming nonconforming nonconforming-error-bodies \
    nonconforming-naming nonconforming-pagination nonconforming-headers \
    corner-deprecated-schema corner-path-params corner-collection-detection \
    corner-idempotent-methods corner-trace-headers | sort)"
  actual="$(cd "$FIXTURES" && printf '%s\n' */ | tr -d '/' | sort)"
  [ "$expected" = "$actual" ]
  # …and each must actually hold a spec, not just a directory.
  while IFS= read -r f; do
    [ -f "$FIXTURES/$f/openapi.yaml" ]
  done <<<"$actual"
}

@test "fixtures: the non-conforming fixture plants every normative violation" {
  local f="$FIXTURES/nonconforming/openapi.yaml"
  # All eight ids, asserted as document facts. Someone "tidying" the fixture by
  # adding a description or tags silently deletes a rule's only coverage, and
  # because the behavioural lane is outside the default gate, this test is the
  # only always-on protection against that.
  run yq '.info | has("description")' "$f"
  [ "$output" = "false" ]
  # Presence FIRST: `null | has(…)` is false, so every absence assertion below
  # would be satisfied by deleting the operation it is about — the very tidy
  # this block exists to catch. Pin the parent, then the absence.
  run yq '.paths."/getUser" | has("post")' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/getUser".post | has("operationId")' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/getUser".post | has("description")' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/getUser".post | has("tags")' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/users/{userId}".get.deprecated' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/users/{userId}" | has("get")' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/users/{userId}".get | has("x-sunset")' "$f"
  [ "$output" = "false" ]
  # TWO operations sharing ONE id — assert the collapse, not just the result.
  # `unique | length == 1` is equally true of a fixture with a single operation,
  # so deleting the duplicate `delete:` block (the natural tidy) would leave this
  # green while operation-operationId-unique lost its only offline coverage.
  run yq '[.paths."/users/{userId}"[].operationId] | length' "$f"
  [ "$output" -eq 2 ]
  run yq '[.paths."/users/{userId}"[].operationId] | unique | length' "$f"
  [ "$output" -eq 1 ]
  run yq '.paths."/getUser".post.responses | has("404")' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/getUser".post.responses."404".content | has("application/json")' "$f"
  [ "$output" = "true" ]
}

@test "fixtures: the non-conforming fixture plants every #944 violation too" {
  local f="$FIXTURES/nonconforming/openapi.yaml"
  # Same reasoning as the block above: the behavioural lane is outside the
  # default gate, so a fixture "tidied" into conformance would silently delete a
  # rule's only coverage and nothing would red until someone ran bats by hand.

  # GET /tenants — offset params present, cursor/limit absent, and the envelope
  # PRESENT so org-pagination-cursor-params is isolated from the envelope rule.
  run yq '[.paths."/tenants".get.parameters[].name] | sort | join(",")' "$f"
  [ "$output" = "X-Request-Id,page,page_size" ]
  run yq '.components.schemas.TenantPage.required | sort | join(",")' "$f"
  [ "$output" = "items,next_cursor" ]
  # …and /tenants must REACH it: the whole cursor-params isolation here depends
  # on that GET being DETECTED as a collection.
  run yq -r '.paths."/tenants".get.responses."200".content."application/json".schema."$ref"' "$f"
  [ "$output" = "#/components/schemas/TenantPage" ]

  # GET /orders — the bare array, and the response-header shape of the
  # correlation ban. Both live here and nowhere else in this fixture.
  run yq '.paths."/orders".get.responses."200".content."application/json".schema.type' "$f"
  [ "$output" = "array" ]
  run yq '.paths."/orders".get.responses."200".headers | keys | join(",")' "$f"
  [ "$output" = "X-Correlation-Id" ]

  # POST /tenants — no Idempotency-Key, and a 429 with no Retry-After. The 429
  # is the ONLY one in the repo: ops v2 declares none, so deleting it leaves
  # that half of org-retry-after-on-throttled untested everywhere.
  # Same presence-first rule as the block above: this POST is the only cover
  # for the idempotency rule's `required: ["parameters"]` clause, so its
  # deletion must red rather than satisfy the absence.
  run yq '.paths."/tenants" | has("post")' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/tenants".post | has("parameters")' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/tenants".post.responses | has("429")' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/tenants".post.responses."429" | has("headers")' "$f"
  [ "$output" = "false" ]

  # PATCH /tenants/{tenantId} — the half the rule id promises. Asserted as "no
  # Idempotency-Key among its parameters" rather than "no parameters", because
  # it legitimately declares the path parameter.
  run yq '[.paths."/tenants/{tenantId}".patch.parameters[].name] | join(",")' "$f"
  [ "$output" = "tenantId" ]

  # The deprecated GET's 2xx must declare NO headers — the planted defect for
  # org-deprecation-sunset-headers, distinct from its missing x-sunset.
  run yq '.paths."/users/{userId}".get.responses | has("200")' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/users/{userId}".get.responses."200" | has("headers")' "$f"
  [ "$output" = "false" ]

  # …and POST /getUser must KEEP its valid Idempotency-Key, which is what stops
  # it firing the rule a third time and blurring the two cases above.
  run yq '[.paths."/getUser".post.parameters[].name] | join(",")' "$f"
  [ "$output" = "Idempotency-Key" ]
}

@test "fixtures: the pagination fixture isolates ONE clause per path" {
  local f="$FIXTURES/nonconforming-pagination/openapi.yaml"
  # /invoices declares cursor and NOT limit; /receipts the reverse. "Fixing"
  # either — or adding the missing parameter — collapses the pair back into the
  # main fixture's both-at-once shape, where neither clause is discriminated.
  run yq '[.paths."/invoices".get.parameters[].name] | join(",")' "$f"
  [ "$output" = "cursor" ]
  run yq '[.paths."/receipts".get.parameters[].name] | sort | join(",")' "$f"
  [ "$output" = "limit,page" ]
  # …and that `page` is `in: header`, which is the ONLY proof anywhere that the
  # offset ban does not filter on location.
  run yq '.paths."/receipts".get.parameters[] | select(.name == "page") | .in' "$f"
  [ "$output" = "header" ]
  # The envelope rule's clause (b): required `items`, NO required `next_cursor`.
  run yq '.components.schemas.HalfEnvelope.required | join(",")' "$f"
  [ "$output" = "items" ]
  run yq '.components.schemas.HalfEnvelope.properties | has("next_cursor")' "$f"
  [ "$output" = "true" ]
  # A schema can stay perfectly shaped while the operation that reaches it is
  # repointed elsewhere — the always-on gate stays green and the clause loses
  # its only firing witness. Pin the $ref beside every schema pin, the way the
  # conforming and error-bodies blocks already do.
  local q
  for q in /invoices /receipts /ledgers; do
    run yq -r ".paths.\"$q\".get.responses.\"200\".content.\"application/json\".schema.\"\$ref\"" "$f"
    [ "$output" = "#/components/schemas/IdPage" ]
  done
  run yq -r '.paths."/statements".get.responses."200".content."application/json".schema."$ref"' "$f"
  [ "$output" = "#/components/schemas/HalfEnvelope" ]
  # The parameterless collection GET — the ONLY cover for the cursor rule's
  # `required: ["parameters"]` clause. Presence first: `null | has(…)` is false,
  # so the absence below would otherwise be satisfied by deleting the operation.
  run yq '.paths."/ledgers" | has("get")' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/ledgers".get | has("parameters")' "$f"
  [ "$output" = "false" ]

  # The two given entries the main fixture never reaches. OffsetParam must stay
  # UNREFERENCED: spectral attributes a finding inside resolved $ref content back
  # to the $ref target, so referencing it would make its finding reachable
  # through the path-level given too and the components given deletable.
  run yq '.components.parameters.OffsetParam.name' "$f"
  [ "$output" = "offset" ]
  run yq -r '[.. | select(tag == "!!str") | select(. == "#/components/parameters/OffsetParam")] | length' "$f"
  [ "$output" -eq 0 ]
  run yq '[.paths."/statements".parameters[].name] | join(",")' "$f"
  [ "$output" = "skip" ]
}

@test "fixtures: the headers fixture isolates ONE clause per defect" {
  local f="$FIXTURES/nonconforming-headers/openapi.yaml"
  # A NON-ops 503 with no Retry-After. Nothing else in the repo has one: the
  # conforming fixture declares the header and ops v2's 503s are exempt, so
  # without this the rule's whole 503 branch could be replaced with `{}`.
  run yq '.paths."/shipments".get.responses | has("503")' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/shipments".get.responses."503" | has("headers")' "$f"
  [ "$output" = "false" ]
  # Pinned POSITIVELY: `null | contains(…)` is false too, so deleting the tags
  # key would satisfy a bare absence check — the same fail-open the has() guards
  # above close. This operation is one of only two non-ops-503 witnesses anywhere.
  run yq -r '[.paths."/shipments".get.tags[]] | join(",")' "$f"
  [ "$output" = "shipments" ]
  # Present-but-WRONG idempotency keys — the only shapes that can catch the
  # deletion of the `in` and `required` consts.
  # BOTH attributes of each witness. Each is pinned on only one today, which
  # leaves the other free to drift: flip the POST's `required` to false and the
  # ruleset's `in: {const: header}` becomes deletable with everything green,
  # because the POST would then fire on the missing `required` instead. The
  # mirror holds for the PATCH's `in`.
  run yq '.paths."/shipments".post.parameters[] | select(.name == "Idempotency-Key") | .in' "$f"
  [ "$output" = "query" ]
  run yq '.paths."/shipments".post.parameters[] | select(.name == "Idempotency-Key") | .required' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/shipments/{shipmentId}".patch.parameters[] | select(.name == "Idempotency-Key") | .required' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/shipments/{shipmentId}".patch.parameters[] | select(.name == "Idempotency-Key") | .in' "$f"
  [ "$output" = "header" ]
  # The 2XX RANGE key on a deprecated operation, which declares its x-sunset
  # correctly so only the header rule can fire on it. The `deprecated: true`
  # anchor is pinned FIRST: without it the rule's given never selects this
  # operation and the range-key coverage silently vanishes. The x-sunset is
  # pinned to its exact value rather than "non-empty and not null", because yq
  # renders an empty scalar as "" — precisely the value the sibling rule's
  # `truthy` is documented to reject.
  run yq '.paths."/shipments/{shipmentId}".get.deprecated' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/shipments/{shipmentId}".get.responses | keys | join(",")' "$f"
  [ "$output" = "2XX" ]
  run yq -r '.paths."/shipments/{shipmentId}".get."x-sunset"' "$f"
  [ "$output" = "2027-06-30" ]
  # The FOUR correlation shapes, one per `given` entry, each reachable by exactly
  # one of them — and the LOWERCASE spelling, the only proof the pattern's /i
  # flag survived an edit.
  run yq '.paths."/shipments".parameters[0].name' "$f"
  [ "$output" = "x-request-id" ]
  run yq '.paths."/shipments/{shipmentId}".patch.responses."200".headers | keys | join(",")' "$f"
  [ "$output" = "Request-Id" ]
  run yq '.components.parameters.TraceIdParam.name' "$f"
  [ "$output" = "X-Trace-Id" ]
  # The component header's KEY must itself be banned — `RequestId` has no hyphen
  # and the pattern could never match it, which would leave the
  # `$.components.headers` given with no witness at all.
  run yq '.components.headers | keys | join(",")' "$f"
  [ "$output" = "X-Correlation-Id" ]
  # BOTH component definitions must stay UNREFERENCED, and the PATCH's response
  # header must stay INLINE. A $ref makes the finding reachable through a
  # path-level given as well, and the components entry becomes deletable with
  # every test green.
  local ref
  for ref in "#/components/parameters/TraceIdParam" "#/components/headers/X-Correlation-Id"; do
    run yq -r "[.. | select(tag == \"!!str\") | select(. == \"$ref\")] | length" "$f"
    [ "$output" -eq 0 ]
  done
}

@test "fixtures: the conforming fixture keeps every #944 over-fire premise" {
  local f="$FIXTURES/conforming/openapi.yaml"
  # This fixture is the ONLY over-fire coverage for all seven new rules, and its
  # acceptance twin asserts merely "zero error findings" — which a fixture that
  # no longer CONTAINS the shape also satisfies. Every property below could
  # therefore be deleted silently, and the acceptance lane is not in the default
  # gate, so nothing on a PR would notice.
  local p
  for p in /tenants "/tenants/{tenantId}/billing-accounts" /addresses /searches /deleted-items; do
    # EXACT membership, never `contains([…])`: yq/jq array containment is
    # SUBSTRING-based for strings, so `contains(["cursor","limit"])` is
    # satisfied by `cursor_token`/`limit_max` — names the rule's own
    # `const` would reject. That is the fail-OPEN direction on the only
    # always-on over-fire cover these rules have.
    run yq "[.paths.\"$p\".get.parameters[].name | select(. == \"cursor\" or . == \"limit\")] | sort | join(\",\")" "$f"
    [ "$output" = "cursor,limit" ]
    # …and the 200 must still be DETECTED as a collection. Without this,
    # repointing it at a non-envelope schema makes BOTH pagination rules vacuous
    # here while the parameters above are untouched — the fixture would remain
    # their only over-fire cover while covering neither.
    run yq -r ".paths.\"$p\".get.responses.\"200\".content.\"application/json\".schema.\"\$ref\"" "$f"
    case "$output" in
      "#/components/schemas/"*Page) ;;
      *) printf 'not a *Page envelope: %s -> %s\n' "$p" "$output" >&2; return 1 ;;
    esac
  done
  # The envelope schemas themselves — detection keys on a REQUIRED `items` of
  # type array, so dropping either half silently un-detects every collection.
  local sch
  for sch in TenantPage BillingAccountPage StringPage; do
    run yq "[.components.schemas.$sch.required[]] | sort | join(\",\")" "$f"
    [ "$output" = "items,next_cursor" ]
    run yq ".components.schemas.$sch.properties.items.type" "$f"
    [ "$output" = "array" ]
  done
  # A non-ops 503 that DOES declare Retry-After — the over-fire direction of the
  # rule's exempted branch.
  # Positively, for the same reason as its twin in the headers fixture.
  run yq -r '[.paths."/tenants/{tenantId}/billing-accounts".get.tags[]] | join(",")' "$f"
  [ "$output" = "tenants" ]
  run yq '.paths."/tenants/{tenantId}/billing-accounts".get.responses."503".headers | keys | join(",")' "$f"
  [ "$output" = "Retry-After" ]
  # The 429 half, which ops v2 cannot cover — it declares no 429 at all.
  run yq '.paths."/tenants".post.responses."429".headers | keys | join(",")' "$f"
  [ "$output" = "Retry-After" ]
  # The `deprecated: true` ANCHOR first — without it the operation drops out of
  # `$.paths[*][?(@.deprecated === true)]` entirely and BOTH deprecation rules
  # lose their only complies-and-must-not-fire witness, while the headers and the
  # x-sunset sit there on a now-undeprecated GET and every assertion stays green.
  run yq '.paths."/tenants/{tenantId}".get.deprecated' "$f"
  [ "$output" = "true" ]
  run yq -r '.paths."/tenants/{tenantId}".get."x-sunset"' "$f"
  [ "$output" = "2026-12-31" ]
  # Both sunset headers on the deprecated operation's 2xx.
  run yq '.paths."/tenants/{tenantId}".get.responses."200".headers | keys | sort | join(",")' "$f"
  [ "$output" = "Deprecation,Sunset" ]
  # Idempotency-Key on BOTH covered methods, and traceparent as the sanctioned
  # correlation channel.
  # Exact membership, for the same reason as the cursor/limit pin above.
  run yq '[.paths."/tenants".post.parameters[].name | select(. == "Idempotency-Key")] | length' "$f"
  [ "$output" -eq 1 ]
  run yq '[.paths."/tenants/{tenantId}".patch.parameters[].name | select(. == "Idempotency-Key")] | length' "$f"
  [ "$output" -eq 1 ]
  run yq '[.paths."/tenants".get.parameters[].name | select(. == "traceparent")] | length' "$f"
  [ "$output" -eq 1 ]
}

@test "fixtures: the collection-detection corner keeps BOTH sides of the boundary" {
  local f="$FIXTURES/corner-collection-detection/openapi.yaml"
  # /build-info is the /info shape — a REQUIRED array not named `items`. Rename
  # it to `items` and the corner starts asserting the opposite of its claim.
  run yq '.components.schemas.BuildInfo.required | sort | join(",")' "$f"
  [ "$output" = "api,build" ]
  run yq '.components.schemas.BuildInfo.properties.api.type' "$f"
  [ "$output" = "array" ]
  # …and /reports is the mirror: an object whose array IS the required `items`,
  # so it IS a collection and does declare cursor + limit. Without it detection
  # could collapse to "nothing is ever a collection" with this file still green.
  run yq '.components.schemas.ReportPage.required | sort | join(",")' "$f"
  [ "$output" = "items,next_cursor" ]
  run yq '[.paths."/reports".get.parameters[].name] | sort | join(",")' "$f"
  [ "$output" = "cursor,limit" ]
  # Both sides must REACH their schema, or the corner's boundary claim can be
  # inverted or voided without reddening this file.
  run yq -r '.paths."/build-info".get.responses."200".content."application/json".schema."$ref"' "$f"
  [ "$output" = "#/components/schemas/BuildInfo" ]
  run yq -r '.paths."/reports".get.responses."200".content."application/json".schema."$ref"' "$f"
  [ "$output" = "#/components/schemas/ReportPage" ]
}

@test "fixtures: the idempotent-methods corner keeps PUT and DELETE key-free" {
  local f="$FIXTURES/corner-idempotent-methods/openapi.yaml"
  # Its whole value is the ABSENCE of the key. "Fixing" either operation by
  # adding one makes the acceptance twin vacuous — it asserts only that the
  # rule does not fire, which a fixture that satisfies the rule also does.
  run yq '[.paths."/tenants/{tenantId}" | keys | .[]] | sort | join(",")' "$f"
  [ "$output" = "delete,put" ]
  run yq '[.paths."/tenants/{tenantId}"[].parameters[].name] | unique | join(",")' "$f"
  [ "$output" = "tenantId" ]
}

@test "fixtures: the trace-headers corner declares traceparent in BOTH inspected shapes" {
  local f="$FIXTURES/corner-trace-headers/openapi.yaml"
  # The rule has two `then` clauses; a fixture carrying only one shape leaves
  # the other widen-able with every test still green.
  run yq '[.paths."/tenants/{tenantId}".get.parameters[].name] | sort | join(",")' "$f"
  [ "$output" = "tenantId,traceparent,tracestate" ]
  run yq '.paths."/tenants/{tenantId}".get.responses."200".headers | keys | sort | join(",")' "$f"
  [ "$output" = "traceparent,tracestate" ]
}

@test "fixtures: the error-bodies fixture carries all three planted error shapes" {
  local f="$FIXTURES/nonconforming-error-bodies/openapi.yaml"
  # dual media types -> maxProperties; missing member -> the allOf; range key ->
  # the given's string half. Each clause is deletable without this fixture.
  # Count AND membership together: two non-problem media types would also be
  # length 2, but would fire the required-problem+json clause instead, leaving
  # maxProperties un-isolated.
  run yq '.paths."/orders".get.responses."404".content | keys | sort | join(",")' "$f"
  [ "$output" = "application/json,application/problem+json" ]

  # The schema must be REFERENCED by the 404, not merely present: repointing
  # /invoices at the complete `Problem` schema would leave the isolated-schema
  # assertion green while the RFC 9457 required-members clause lost its coverage.
  # This fixture is NOT linted by styleguide-pin.yml (that lints only
  # nonconforming + conforming), so the offline suite is the backstop.
  # `contains` is safe HERE, unlike the exact-membership pins elsewhere in this
  # file: it is asserted FALSE, and substring semantics only ever make it MORE
  # likely to be true, so this direction is fail-closed.
  run yq '.components.schemas.IncompleteProblem.required | contains(["detail"])' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/invoices".get.responses."404".content."application/problem+json".schema."$ref"' "$f"
  [ "$output" = "#/components/schemas/IncompleteProblem" ]

  # The 4XX response must still be NON-conforming, not merely present: quietly
  # fixing it to problem+json keeps `has("4XX")` true while the given's
  # range-key half stops being exercised anywhere offline.
  run yq '.paths."/receipts".get.responses | has("4XX")' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/receipts".get.responses."4XX".content | keys | join(",")' "$f"
  [ "$output" = "application/json" ]
  # Same #944 premise as the naming fixture: cursor/limit and the OrderPage
  # envelope are what keep the pagination rules silent on this error-body
  # fixture, and its header claims exactly that.
  local p
  for p in /orders /invoices /receipts; do
    run yq "[.paths.\"$p\".get.parameters[].name | select(. == \"cursor\" or . == \"limit\")] | sort | join(\",\")" "$f"
    [ "$output" = "cursor,limit" ]
    run yq -r ".paths.\"$p\".get.responses.\"200\".content.\"application/json\".schema.\"\$ref\"" "$f"
    [ "$output" = "#/components/schemas/OrderPage" ]
  done
}

@test "fixtures: the naming fixture isolates ONE resource-naming clause per path" {
  local f="$FIXTURES/nonconforming-naming/openapi.yaml"
  # /list-orders is valid kebab-case, so only the verb guard can catch it;
  # /Tenant_List has no verb prefix, so only the kebab pattern can.
  run yq '.paths | has("/list-orders")' "$f"
  [ "$output" = "true" ]
  run yq '.paths | has("/Tenant_List")' "$f"
  [ "$output" = "true" ]
  # #944 added cursor/limit and a *Page envelope to both GETs so the new
  # pagination rules stay quiet here — the premise of this fixture's "any finding
  # from another org-* rule is a scoping regression" claim. Strip either and
  # org-pagination-cursor-params starts firing on a naming fixture.
  local p
  for p in /list-orders /Tenant_List; do
    run yq "[.paths.\"$p\".get.parameters[].name | select(. == \"cursor\" or . == \"limit\")] | sort | join(\",\")" "$f"
    [ "$output" = "cursor,limit" ]
    run yq -r ".paths.\"$p\".get.responses.\"200\".content.\"application/json\".schema.\"\$ref\"" "$f"
    [ "$output" = "#/components/schemas/StringPage" ]
  done
}

@test "fixtures: the deprecation corner covers all three over-match shapes" {
  local f="$FIXTURES/corner-deprecated-schema/openapi.yaml"
  # The starter's document-wide given wrongly matched a deprecated schema
  # property, a deprecated PARAMETER, and `deprecated: true` inside example
  # DATA. All three must be present or the corner proves only one of them.
  run yq '.components.schemas.User.properties.legacyName.deprecated' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/users".get.parameters[0].deprecated' "$f"
  [ "$output" = "true" ]
  # Inside the ENVELOPE's `items` since #944 re-shaped the fixture to the org
  # collection convention — still example DATA, which is the point.
  run yq '.paths."/users".get.responses."200".content."application/json".example.items[0].deprecated' "$f"
  [ "$output" = "true" ]
  # …and no OPERATION is deprecated, so any finding at all is a regression.
  run yq '[.paths[][] | select(has("deprecated"))] | length' "$f"
  [ "$output" -eq 0 ]
}

@test "fixtures: the path-params corner keeps its camelCase {param} segments" {
  # The only fixture that had no integrity test. Its entire value is that the
  # path carries camelCase `{param}` segments which would trip the kebab `match`
  # clause were parameter segments not exempt — so tidying it to
  # `/users/{user-id}/...`, or flattening it to `/orders/{orderId}`, silently
  # stops proving the exemption. The acceptance twin is vacuous under the same
  # mutation (it asserts only that org-resource-naming does NOT fire, which a
  # fixture with no params also satisfies).
  local f="$FIXTURES/corner-path-params/openapi.yaml"
  run yq -r '.paths | keys | .[0]' "$f"
  [ "$output" = "/users/{userId}/orders/{orderId}" ]
  run yq -r '[.paths | keys | .[] | select(test("\\{[a-z]+[A-Z]"))] | length' "$f"
  [ "$output" -eq 1 ]
}

@test "fixtures: the conforming fixture pins the verb guard's trailing context" {
  local f="$FIXTURES/conforming/openapi.yaml"
  # Nouns that merely BEGIN with a verb must stay clean; a regression widening
  # the alternation to bare prefixes would redden downstream repos.
  local p
  for p in /addresses /searches /deleted-items; do
    run yq ".paths | has(\"$p\")" "$f"
    [ "$output" = "true" ]
  done
}

@test "fixtures: the conforming fixture declares problem+json on every error response" {
  run yq '[.. | select(has("application/problem+json")) ] | length' \
    "$FIXTURES/conforming/openapi.yaml"
  [ "$status" -eq 0 ]
  # Six since #944: the four #689 shipped, plus the 429 on POST /tenants and the
  # 404 on the new PATCH.
  [ "$output" -eq 6 ]
}

@test "bootstrap template: .spectral.yaml is the exact-pin shim, starter retired (PR-B)" {
  # The inverse of PR-A's guard, which asserted this file was still untouched.
  # PR-B is the switch, so the assertion flips: one extends member, the exact
  # pin, and none of the starter's own content left behind.
  local tmpl="$REPO_ROOT/development/skills/bootstrap/templates/common/.spectral.yaml"

  # No inline rules at all — the whole point is ONE artifact, not a local copy
  # that can drift from the published one.
  run yq -r '.rules // "none"' "$tmpl"
  [ "$output" = "none" ]

  # Exactly one extends member. A second one would let local rules creep back
  # in beside the pin without any other assertion here noticing.
  run yq -r '.extends | length' "$tmpl"
  [ "$output" = "1" ]

  run yq -r '.extends[0]' "$tmpl"
  matches "$output" \
    '^https://cdn\.jsdelivr\.net/gh/timo-jakob/timos-claude-code-plugins@styleguide-v[0-9]+\.[0-9]+\.[0-9]+/styleguide/spectral/ruleset\.yaml$'

  # Never a floating ref — the failure the story names outright, because it would
  # change what downstream CI enforces with no PR anywhere to review it.
  lacks "$output" '@latest'
  lacks "$output" '@main'

  # The starter's content is RETIRED, not merely overridden.
  run cat "$tmpl"
  lacks "$output" 'spectral:oas'
  lacks "$output" 'deprecation-has-sunset'
}

# --- PR-B: the pin must stay CURRENT, and bump on its own terms (#689 AC 7) ---
#
# The shim is exact by design, which means it is also stale by default. Renovate
# is the only thing that moves it, so the manager that finds it is part of the
# contract — an unmatched file pattern or a regex that stops matching would leave
# every bootstrapped repo pinned to v1.0.0 forever, silently and green.

@test "renovate: a customManager targets the shim and its regex MATCHES the real file" {
  # Asserted by EXECUTING the shipped regex against the shipped shim, not by
  # eyeballing both: they drift independently, and a manager that matches nothing
  # fails open — "no PR" is not an error Renovate reports anywhere.
  run python3 "$BATS_TEST_DIRNAME/helpers/check-renovate-styleguide.py" manager
  [ "$status" -eq 0 ]
  contains "$output" "ok"
}

@test "renovate: the pin bump is NOT swept into the batched github-actions PR" {
  # The pre-existing rule groups matchManagers ["github-actions", "custom.regex"]
  # — which covers EVERY custom manager, including this one. Without a later
  # override the pin would ride along in the weekly GitHub Actions PR, changing
  # what every bootstrapped repo enforces under a title about action bumps.
  run python3 "$BATS_TEST_DIRNAME/helpers/check-renovate-styleguide.py" grouping
  [ "$status" -eq 0 ]
  contains "$output" "api-styleguide"
}

@test "the through-the-pin checker exists, is executable, and is wired into CI" {
  local script="$REPO_ROOT/scripts/check-styleguide-pin.zsh"
  [ -f "$script" ]
  [ -x "$script" ]
  run zsh -n "$script"
  [ "$status" -eq 0 ]
  # It must lint through the SHIM, not the local ruleset — that is the whole
  # point of AC 8. Pointing it at styleguide/spectral/ruleset.yaml would make it
  # a duplicate of the acceptance lane while proving nothing about the pin.
  run cat "$script"
  contains "$output" '--ruleset "$SHIM"'

  # Read the workflow STRUCTURALLY. A whole-file `contains` is satisfied by the
  # workflow's own `paths:` filter, which quotes every one of these strings — so
  # the `run:` step could be deleted, or the pull_request trigger removed, and a
  # grep-based test would stay green while the gate ran nothing.
  local wf="$REPO_ROOT/.github/workflows/styleguide-pin.yml"
  [ -f "$wf" ]

  run yq -r '.jobs.check.steps[] | select(.run != null) | .run' "$wf"
  [ "$status" -eq 0 ]
  contains "$output" 'scripts/check-styleguide-pin.zsh'

  # The PR half specifically — a post-merge-only gate is not a gate.
  run yq -r '.on.pull_request.paths[]' "$wf"
  [ "$status" -eq 0 ]
  contains "$output" 'development/skills/bootstrap/templates/common/.spectral.yaml'
  contains "$output" 'styleguide/spectral/ruleset.yaml'

  # …and it cannot be neutered into an advisory. Step-level AND job-level: the
  # job-level knob is how a gate is actually made advisory, and "just set
  # continue-on-error" is the predictable response to the first CDN blip — which
  # this job's own header says it deliberately couples itself to.
  # PRESENCE, not truthiness. `select(. == true)` compares against the YAML
  # boolean, so `continue-on-error: ${{ … }}` and `continue-on-error: "true"`
  # are strings that slip past it — and an expression is exactly how someone
  # writes "advisory only when the CDN is flaky", the predictable response to
  # the first blip on a job that deliberately couples itself to jsDelivr.
  run yq -r '[.jobs.check.steps[] | select(has("continue-on-error"))] | length' "$wf"
  [ "$output" = "0" ]
  run yq -r '.jobs.check | has("continue-on-error")' "$wf"
  [ "$output" = "false" ]
  # STEP-level `if` too, not just the job's: a skipped step does not fail its
  # job, so `if: false` on the lint step reports success having run nothing —
  # the same parking trick as the job-level knob, one level down.
  run yq -r '[.jobs.check.steps[] | select(has("if"))] | length' "$wf"
  [ "$output" = "0" ]
  # …and the LINT step's run command is pinned exactly, because a `contains`
  # needle is equally satisfied by `./scripts/check-styleguide-pin.zsh || true`,
  # which neuters the gate inline without touching either knob. Selected by
  # name: the job also has an apt-get step, so an unfiltered `.run` emits both.
  # Cardinality first: a renamed step selects nothing and a duplicated one
  # selects two, and either way the equality below fails as a bare `[` with no
  # explanation. This says which.
  run yq -r '[.jobs.check.steps[] | select(.name == "Lint the non-conforming fixture THROUGH the pinned shim")] | length' "$wf"
  [ "$output" = "1" ]
  run yq -r '.jobs.check.steps[] | select(.name == "Lint the non-conforming fixture THROUGH the pinned shim") | .run' "$wf"
  [ "$status" -eq 0 ]
  [ "$output" = "./scripts/check-styleguide-pin.zsh" ]
  # `// "unset"` would also swallow `if: false` — the standard way to park a job
  # without deleting it — because yq's // fires on false as well as null.
  run yq -r '.jobs.check | has("if")' "$wf"
  [ "$output" = "false" ]

  # The EXACT path set, on both halves. Four `contains` needles left the fifth
  # (the workflow's own path) unpinned, so dropping it from both halves — which
  # stops the gate self-triggering on a PR that neuters it — stayed green.
  run yq -r '[.on.pull_request.paths[]] | sort | join(",")' "$wf"
  [ "$status" -eq 0 ]
  [ "$output" = ".github/workflows/styleguide-pin.yml,development/skills/bootstrap/templates/common/.spectral.yaml,scripts/check-styleguide-pin.zsh,styleguide/spectral/ruleset.yaml,tests/fixtures/api-styleguide/**" ]
  local pr_paths="$output"
  run yq -r '[.on.push.paths[]] | sort | join(",")' "$wf"
  [ "$output" = "$pr_paths" ]

  # Pin rot has causes outside this repo (a deleted tag, a CDN regression), so a
  # path-triggered-only gate would never see them.
  run yq -r '.on.schedule[0].cron' "$wf"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}
