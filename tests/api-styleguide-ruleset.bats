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
    grep -oh "https://cdn\.jsdelivr\.net/gh/$OWNER_REPO@[^ \"]*ruleset\.yaml" "$f" 2>/dev/null >> "$hits" || true
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
  local all_urls stray
  all_urls="$(xargs -0 grep -oh 'https://cdn\.jsdelivr\.net/gh/[^ "]*ruleset\.yaml' \
    < <(tr '\n' '\0' < "$list") 2>/dev/null | sort -u || true)"
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
