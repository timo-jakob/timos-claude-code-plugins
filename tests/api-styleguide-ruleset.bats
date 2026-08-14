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

@test "EVERY file quoting a styleguide pin quotes the SAME one" {
  # Swept repo-wide, not from a named file list. #689 shipped the pin in two
  # places (ruleset header, how-to) and PR-B added a third that outranks both —
  # the bootstrap shim, the only copy downstream repos actually consume. A closed
  # list would have silently stopped covering the file that matters most, so the
  # sweep enumerates tracked files instead and a fourth site is covered for free.
  local f url first="" first_file="" n=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    url="$(grep -oh 'https://cdn\.jsdelivr\.net/gh/[^ "]*ruleset\.yaml' "$f" 2>/dev/null | head -1 || true)"
    [ -n "$url" ] || continue
    n=$((n + 1))
    if [ -z "$first" ]; then
      first="$url"
      first_file="$f"
    elif [ "$url" != "$first" ]; then
      printf 'pin mismatch:\n  %s: %s\n  %s: %s\n' "$first_file" "$first" "$f" "$url" >&2
      return 1
    fi
  done < <(cd "$REPO_ROOT" && git ls-files)

  # Canary: the sweep must actually find the known sites. A broken glob or a
  # renamed path would otherwise make this pass by inspecting nothing.
  [ "$n" -ge 3 ]
  # And the shipped shim must be one of them — it is the copy that ships.
  run grep -c 'https://cdn\.jsdelivr\.net/gh/.*ruleset\.yaml' \
    "$REPO_ROOT/development/skills/bootstrap/templates/common/.spectral.yaml"
  [ "$output" -ge 1 ]
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

  local wf="$REPO_ROOT/.github/workflows/styleguide-pin.yml"
  [ -f "$wf" ]
  run cat "$wf"
  contains "$output" 'check-styleguide-pin.zsh'
  # Triggered by both files that can break the pin.
  contains "$output" 'templates/common/.spectral.yaml'
  contains "$output" 'styleguide/spectral/ruleset.yaml'
}
