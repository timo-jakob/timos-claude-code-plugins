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

# The three org-OWNED rules — full rule objects, each carrying message,
# documentationUrl, severity and given.
ORG_RULE_IDS=(
  org-deprecated-operation-has-sunset
  org-resource-naming
  org-problem-json-errors
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

@test "ruleset: declares exactly eight rules, and they are the eight normative ids" {
  run yq '.rules | keys | length' "$RULESET"
  [ "$status" -eq 0 ]
  [ "$output" -eq 8 ]
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
  [ "$output" -eq 3 ]
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
  [ "$n" -eq 3 ]
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

@test "the ruleset header and the how-to shim quote the SAME pinned URL" {
  local from_ruleset from_howto
  from_ruleset="$(grep -o 'https://cdn\.jsdelivr\.net[^ ]*ruleset\.yaml' "$RULESET" | head -1)"
  from_howto="$(grep -o 'https://cdn\.jsdelivr\.net[^ ]*ruleset\.yaml' "$HOWTO" | head -1)"
  [ -n "$from_ruleset" ]
  [ -n "$from_howto" ]
  [ "$from_ruleset" = "$from_howto" ]
}

@test "fixtures: the whole fixture set exists" {
  local f
  for f in conforming nonconforming nonconforming-error-bodies nonconforming-naming \
    corner-deprecated-schema corner-path-params; do
    [ -f "$FIXTURES/$f/openapi.yaml" ]
  done
}

@test "fixtures: the non-conforming fixture plants every normative violation" {
  local f="$FIXTURES/nonconforming/openapi.yaml"
  # All eight ids, asserted as document facts. Someone "tidying" the fixture by
  # adding a description or tags silently deletes a rule's only coverage, and
  # because the behavioural lane is outside the default gate, this test is the
  # only always-on protection against that.
  run yq '.info | has("description")' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/getUser".post | has("operationId")' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/getUser".post | has("description")' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/getUser".post | has("tags")' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/users/{userId}".get.deprecated' "$f"
  [ "$output" = "true" ]
  run yq '.paths."/users/{userId}".get | has("x-sunset")' "$f"
  [ "$output" = "false" ]
  run yq '[.paths."/users/{userId}"[].operationId] | unique | length' "$f"
  [ "$output" -eq 1 ]
  run yq '.paths."/getUser".post.responses."404".content | has("application/json")' "$f"
  [ "$output" = "true" ]
}

@test "fixtures: the error-bodies fixture carries all three planted error shapes" {
  local f="$FIXTURES/nonconforming-error-bodies/openapi.yaml"
  # dual media types -> maxProperties; missing member -> the allOf; range key ->
  # the given's string half. Each clause is deletable without this fixture.
  run yq '.paths."/orders".get.responses."404".content | keys | length' "$f"
  [ "$output" -eq 2 ]
  run yq '.components.schemas.IncompleteProblem.required | contains(["detail"])' "$f"
  [ "$output" = "false" ]
  run yq '.paths."/receipts".get.responses | has("4XX")' "$f"
  [ "$output" = "true" ]
}

@test "fixtures: the naming fixture isolates ONE resource-naming clause per path" {
  local f="$FIXTURES/nonconforming-naming/openapi.yaml"
  # /list-orders is valid kebab-case, so only the verb guard can catch it;
  # /Tenant_List has no verb prefix, so only the kebab pattern can.
  run yq '.paths | has("/list-orders")' "$f"
  [ "$output" = "true" ]
  run yq '.paths | has("/Tenant_List")' "$f"
  [ "$output" = "true" ]
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
  run yq '.paths."/users".get.responses."200".content."application/json".example[0].deprecated' "$f"
  [ "$output" = "true" ]
  # …and no OPERATION is deprecated, so any finding at all is a regression.
  run yq '[.paths[][] | select(has("deprecated"))] | length' "$f"
  [ "$output" -eq 0 ]
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
  [ "$output" -eq 4 ]
}

@test "bootstrap template: .spectral.yaml is untouched by PR-A (still the starter)" {
  # The switch to the pinned shim is PR-B's, and it cannot land before a human
  # cuts the styleguide tag. Asserting only `extends: ["spectral:oas"]` would
  # stay green if PR-B ADDED the jsDelivr URL as a second extends member, so
  # pin a starter-only marker and the absence of the CDN host.
  local tmpl="$REPO_ROOT/development/skills/bootstrap/templates/common/.spectral.yaml"
  run yq '.rules | has("deprecation-has-sunset")' "$tmpl"
  [ "$output" = "true" ]
  run yq '.rules."info-description"' "$tmpl"
  [ "$output" = "warn" ]
  run cat "$tmpl"
  lacks "$output" 'cdn.jsdelivr.net'
}
