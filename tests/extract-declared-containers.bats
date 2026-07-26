#!/usr/bin/env bats
#
# Behavioral tests for extract-declared-containers.zsh (epic #746 child (a),
# #790): the canonical parser for the c4/v1 declared-container shape. The
# contract (ARCHITECTURE.md, "C4 architecture docs contract"):
#   - membership is Container / ContainerDb / ContainerQueue inside the
#     C4Container block, at any boundary nesting depth; _Ext / System* / Person*
#     / Component* are excluded;
#   - each entry is Container(<alias>, "<label>", "<technology>"[, "<description>"]),
#     quote-aware (commas legal inside quotes), one entry per line;
#   - stdout is a JSON array of {alias, label, technology, description};
#   - exit 0 success / 1 no c4-container.md / 2 usage / 3 unparseable-or-runtime;
#   - the worked example in the contract is byte-identical to the fixture, so the
#     contract and the parser cannot drift.

# `run --separate-stderr` (used below to assert an empty stdout on exit 3)
# requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/scripts/extract-declared-containers.zsh"
  FIX="$REPO_ROOT/tests/fixtures/c4"
}

@test "the canonical fixture extracts EXACTLY the four in-scope containers (AC8, exact set)" {
  run zsh "$S" --file "$FIX/c4-container.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 4' >/dev/null
  [ "$(echo "$output" | jq -r '[.[].alias] | sort | join(",")')" = "database,events,spa,web_app" ]
}

@test "a comma-bearing technology is recovered whole (quote-aware parse, not a naive comma split)" {
  run zsh "$S" --file "$FIX/c4-container.md"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[] | select(.alias=="web_app").technology')" = "Java, Spring MVC" ]
  [ "$(echo "$output" | jq -r '.[] | select(.alias=="spa").technology')" = "JavaScript, Angular" ]
}

@test "boundary nesting does not filter membership — ALL four nested containers are recovered" {
  # all four live inside Container_Boundary(c1, ...) { ... }; assert every one,
  # so a nesting regression that dropped some is localized here, not masked by
  # the exact-set count test above.
  run zsh "$S" --file "$FIX/c4-container.md"
  [ "$status" -eq 0 ]
  for a in web_app spa database events; do
    echo "$output" | jq -e --arg a "$a" 'any(.[]; .alias==$a)' >/dev/null
  done
}

@test "output is the documented array, in document order (AC10 output half — no silent output drift)" {
  run zsh "$S" --file "$FIX/c4-container.md"
  [ "$status" -eq 0 ]
  # exact ordered array, byte-checked against the canonical shape
  [ "$(echo "$output" | jq -c '[.[].alias]')" = '["web_app","spa","database","events"]' ]
  # and semantically identical to the expected-output JSON embedded in the contract
  expected="$BATS_TEST_TMPDIR/expected.json"
  awk '/<!-- c4\/v1:example-output:start -->/{f=1;next} /<!-- c4\/v1:example-output:end -->/{f=0} f' \
    "$REPO_ROOT/ARCHITECTURE.md" | sed '/^```/d' > "$expected"
  [ -s "$expected" ]
  diff <(echo "$output" | jq -S .) <(jq -S . "$expected")
}

@test "ContainerDb and ContainerQueue are in-scope" {
  run zsh "$S" --file "$FIX/c4-container.md"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[] | select(.alias=="database").label')" = "Database" ]
  [ "$(echo "$output" | jq -r '.[] | select(.alias=="events").label')" = "Event Bus" ]
}

@test "the _Ext variant is excluded (external = we do not build it)" {
  run zsh "$S" --file "$FIX/c4-container.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .alias != "backend_api")' >/dev/null
}

@test "System* and Person* entries never appear in the extracted set" {
  run zsh "$S" --file "$FIX/c4-container.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'all(.[]; .alias != "email_system" and .alias != "customer")' >/dev/null
}

@test "every excluded family is excluded — _Ext (all 3), Component*, System*, Person* — leaving only the real container" {
  # one fixture exercising Container_Ext, ContainerDb_Ext, ContainerQueue_Ext,
  # Component, ComponentDb, System, System_Ext, Person; none may leak, none may
  # trigger exit 3 (they are valid macros, just out of membership scope)
  run zsh "$S" --file "$FIX/c4-container-exclusions.md"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.[].alias]')" = '["real_one"]' ]
}

@test "description is null when the 4th arg is absent, recovered when present" {
  run zsh "$S" --file "$FIX/c4-container.md"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[] | select(.alias=="web_app").description')" = "Serves the SPA and the JSON API" ]
  echo "$output" | jq -e '.[] | select(.alias=="spa") | .description == null' >/dev/null
}

@test "a C4Container block with only _Ext/System entries yields an empty set, exit 0 (not exit 3)" {
  run zsh "$S" --file "$FIX/c4-container-empty.md"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a bare (unquoted) label is a hard error naming the page (AC9)" {
  run zsh "$S" --file "$FIX/c4-container-barelabel.md"
  [ "$status" -eq 3 ]
  contains "$output" "c4-container-barelabel.md"
}

@test "a line-broken entry is a hard error naming the page (AC9)" {
  run zsh "$S" --file "$FIX/c4-container-linebroken.md"
  [ "$status" -eq 3 ]
  contains "$output" "c4-container-linebroken.md"
}

@test "a page present but carrying no C4Container block is exit 3, never a silent empty set" {
  run zsh "$S" --file "$FIX/c4-container-noblock.md"
  [ "$status" -eq 3 ]
  contains "$output" "c4-container-noblock.md"
}

@test "pointing the parser at a c4-context.md (C4Context, not C4Container) is exit 3 naming the page — container-only" {
  run zsh "$S" --file "$FIX/c4-context.md"
  [ "$status" -eq 3 ]
  contains "$output" "c4-context.md"
}

@test "a repeated alias is a hard error naming the alias and the page (join-key integrity)" {
  run zsh "$S" --file "$FIX/c4-container-dupalias.md"
  [ "$status" -eq 3 ]
  contains "$output" "web_app"
  contains "$output" "c4-container-dupalias.md"
}

@test "a valid entry BEFORE a malformed one still exits 3 with an EMPTY stdout (never a partial set)" {
  # the malformed line has a paren typo'd to a space — it must error, not be
  # silently dropped, and the good entry parsed before it must never leak to stdout
  run --separate-stderr zsh "$S" --file "$FIX/c4-container-partial.md"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "c4-container-partial.md"
}

@test "a bare keyword at end-of-line is a hard error, not a silent drop (the prefix_re '\$' branch)" {
  # distinct from the paren-typo case: 'Container' alone, no args at all
  run zsh "$S" --file "$FIX/c4-container-bareword.md"
  [ "$status" -eq 3 ]
  contains "$output" "c4-container-bareword.md"
}

@test "a well-formed entry that omits the required technology arg is a hard error (AC: technology required)" {
  # Container(web_app, "Web Application") — label only, no technology; Mermaid
  # tolerates it, this contract does not
  run zsh "$S" --file "$FIX/c4-container-notech.md"
  [ "$status" -eq 3 ]
  contains "$output" "c4-container-notech.md"
}

@test "two C4Container blocks in one page is exit 3 — the declared set is singular" {
  run zsh "$S" --file "$FIX/c4-container-multiblock.md"
  [ "$status" -eq 3 ]
  contains "$output" "multiple C4Container"
}

@test "an illustrative block inside a longer (4-backtick) fence is not extracted; only the real one is" {
  run zsh "$S" --file "$FIX/c4-container-nested-fence.md"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.[].alias]')" = '["real_one"]' ]
}

@test "the default --repo target path resolves docs/architecture/c4-container.md (production entry point)" {
  mkdir -p "$BATS_TEST_TMPDIR/repo/docs/architecture"
  cp "$FIX/c4-container.md" "$BATS_TEST_TMPDIR/repo/docs/architecture/c4-container.md"
  run zsh "$S" --repo "$BATS_TEST_TMPDIR/repo"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 4' >/dev/null
}

@test "an unreadable target is exit 3 (runtime error) naming the cause, not exit 1 (precondition absent)" {
  # a directory at the target path exists but is not a readable c4-container.md
  mkdir -p "$BATS_TEST_TMPDIR/repo2/docs/architecture/c4-container.md"
  run zsh "$S" --repo "$BATS_TEST_TMPDIR/repo2"
  [ "$status" -eq 3 ]
  contains "$output" "cannot read"
}

@test "a dangling symlink at the target is exit 3 (cannot read), not exit 1 — a broken page is not non-adoption" {
  ln -s "$BATS_TEST_TMPDIR/does-not-exist.md" "$BATS_TEST_TMPDIR/dangling.md"
  run zsh "$S" --file "$BATS_TEST_TMPDIR/dangling.md"
  [ "$status" -eq 3 ]
  contains "$output" "cannot read"
}

@test "an unterminated mermaid fence is exit 3 naming the fence, not a misleading 'no C4Container block'" {
  run zsh "$S" --file "$FIX/c4-container-unterminated.md"
  [ "$status" -eq 3 ]
  contains "$output" "unterminated mermaid fence"
}

@test "no c4-container.md under the repo is exit 1 (precondition absent), not exit 3" {
  run zsh "$S" --repo "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an unknown flag is a usage error (exit 2) naming the offending arg" {
  run zsh "$S" --bogus
  [ "$status" -eq 2 ]
  contains "$output" "--bogus"
}

@test "--file with no value is a usage error (exit 2)" {
  run zsh "$S" --file
  [ "$status" -eq 2 ]
}

@test "--file with an EMPTY value is a usage error (exit 2), not a silent fallback to the default target" {
  run zsh "$S" --file ""
  [ "$status" -eq 2 ]
}

@test "--repo with no value is a usage error (exit 2)" {
  run zsh "$S" --repo
  [ "$status" -eq 2 ]
}

@test "--help prints the usage contract to stdout and exits 0 (long form)" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "usage"
}

@test "-h prints usage and exits 0 (short form)" {
  run zsh "$S" -h
  [ "$status" -eq 0 ]
  contains "$output" "usage"
}

@test "jq missing from PATH is a runtime error (exit 3), not a crash" {
  # absolute zsh path so env can exec it under the emptied PATH; inside, the
  # `command -v jq` guard fails first and exits 3 before any external is needed
  zbin="$(command -v zsh)"
  run env PATH="/var/empty" "$zbin" "$S" --file "$FIX/c4-container.md"
  [ "$status" -eq 3 ]
  contains "$output" "jq not found"
}

@test "the contract's worked example is byte-identical to the fixture (AC10 — no drift)" {
  # Extract the region between the c4/v1 example sentinels in ARCHITECTURE.md and
  # diff it against the checked-in fixture. Empty diff == contract and parser
  # cannot drift.
  extracted="$BATS_TEST_TMPDIR/example.md"
  awk '/<!-- c4\/v1:example:start -->/{f=1;next} /<!-- c4\/v1:example:end -->/{f=0} f' \
    "$REPO_ROOT/ARCHITECTURE.md" > "$extracted"
  # sanity: the region was found and is non-empty
  [ -s "$extracted" ]
  diff "$extracted" "$FIX/c4-container.md"
}
