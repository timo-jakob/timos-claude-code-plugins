#!/usr/bin/env bats
#
# Behavioral tests for plan-user-docs.zsh (#767, epic #745): turn a
# story-spec/v1 block into the same-PR user-docs plan — one entry per
# classified runtime surface, mapping the surface to its #766 how-to page.
# The contract:
#   - a story with interface_surfaces -> a plan naming kind + page per surface;
#   - a no-surface story (empty/none/library) -> exit 0 with [] (no docs duty);
#   - no block at all (empty input) -> exit 1 (prose-only fallback);
#   - an unknown surface value is a hard error naming the value.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/plan-user-docs.zsh"
  SPEC="$BATS_TEST_TMPDIR/spec.json"
}
put() { printf '%s' "$1" > "$SPEC"; }

@test "a surface-touching story produces one plan entry per surface (AC1)" {
  put '{"schema":"story-spec/v1","interface_surfaces":["cli","rest","web-ui","grpc"]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 4' >/dev/null
  echo "$output" | jq -e 'all(.[]; .kind == "how-to")' >/dev/null
}

@test "each surface maps to its #766 how-to page" {
  put '{"interface_surfaces":["cli","rest","web-ui","grpc"]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[] | select(.surface=="cli").page')" = "docs/how-to/use-the-cli.md" ]
  [ "$(echo "$output" | jq -r '.[] | select(.surface=="rest").page')" = "docs/how-to/use-the-rest-api.md" ]
  [ "$(echo "$output" | jq -r '.[] | select(.surface=="web-ui").page')" = "docs/how-to/use-the-web-ui.md" ]
  [ "$(echo "$output" | jq -r '.[] | select(.surface=="grpc").page')" = "docs/how-to/use-the-grpc-api.md" ]
}

@test "a no-surface story yields an empty plan, exit 0 (AC2 — no docs step, not an error)" {
  put '{"interface_surfaces":[]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "absent interface_surfaces key behaves like a no-surface story" {
  put '{"schema":"story-spec/v1"}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "none/library surface values carry no docs duty and are dropped" {
  put '{"interface_surfaces":["none","library","cli"]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].surface == "cli"' >/dev/null
}

@test "no block (empty stdin) -> exit 1, the prose-only fallback (AC3)" {
  run zsh -c "printf '' | zsh '$S'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "whitespace-only input is the no-block fallback too, not bad JSON" {
  run zsh -c "printf '  \n ' | zsh '$S'"
  [ "$status" -eq 1 ]
}

@test "stdin works like --file (the read-story-spec pipe)" {
  run zsh -c "printf '%s' '{\"interface_surfaces\":[\"rest\"]}' | zsh '$S'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].page == "docs/how-to/use-the-rest-api.md"' >/dev/null
}

@test "an unknown surface value is a hard error naming it" {
  put '{"interface_surfaces":["cli","carrier-pigeon"]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 3 ]
  contains "$output" "carrier-pigeon"
}

@test "a non-string surface value is a hard error, not a crash" {
  put '{"interface_surfaces":[42]}'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 3 ]
  contains "$output" "unknown surface"
}

@test "invalid JSON -> runtime error (exit 3)" {
  put '{not json'
  run zsh "$S" --file "$SPEC"
  [ "$status" -eq 3 ]
  contains "$output" "not valid JSON"
}

@test "missing --file target -> exit 3 naming it; unknown flag -> usage (exit 2)" {
  run zsh "$S" --file "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 3 ]
  run zsh "$S" --frobnicate
  [ "$status" -eq 2 ]
}
