#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load assertions

#
# Behavioral tests for check-c4-currency.zsh (epic #746 child (c), #792):
# resolve-issue's same-PR C4 currency check. Compares the declared containers
# (via #790's extract-declared-containers.zsh) against detect-stack's detected
# set (#799), emitting a revisit plan in plan-user-docs.zsh's idiom:
#   structural change (complete) → non-empty plan naming c4-container.md;
#   neutral / inconclusive        → empty plan + a reported reason;
#   no c4-container.md → exit 1; unparseable declared → exit 3; usage → exit 2.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$REPO_ROOT/development/skills/resolve-issue/scripts/check-c4-currency.zsh"
  REPO="$BATS_TEST_TMPDIR/repo"
  DJ="$BATS_TEST_TMPDIR/detect.json"
  mkdir -p "$REPO/docs/architecture"
}
# declare a container set in the repo's c4-container.md
declare_containers() {
  {
    printf '```mermaid\nC4Container\n    Container_Boundary(b, "Sys") {\n'
    local a
    for a in "$@"; do printf '        Container(%s, "%s label", "Python 3.12")\n' "$a" "$a"; done
    printf '    }\n```\n'
  } > "$REPO/docs/architecture/c4-container.md"
}
detect() { printf '%s' "$1" > "$DJ"; }
check() { zsh "$CHECK" --repo "$REPO" --detect-json "$DJ"; }

@test "structural: a DETECTED container absent from the diagram → non-empty plan naming c4-container.md (AC1)" {
  declare_containers aido
  detect '{"containers":[{"name":"aido"},{"name":"worker"}],"detection_confidence":"complete"}'
  run check
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].page')" = "docs/architecture/c4-container.md" ]
  echo "$output" | jq -e 'length == 1' >/dev/null
}

@test "structural (reverse): a DECLARED container absent from detection → non-empty plan (a removed/renamed unit still in the diagram)" {
  declare_containers aido worker
  detect '{"containers":[{"name":"aido"}],"detection_confidence":"complete"}'
  run check
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].page')" = "docs/architecture/c4-container.md" ]
}

@test "neutral: declared matches detected → empty plan, exit 0, no page touched (AC2)" {
  declare_containers aido
  detect '{"containers":[{"name":"aido"}],"detection_confidence":"complete"}'
  run --separate-stderr check
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  contains "$stderr" "no structural change"
}

@test "neutral folds case and -/_ : declared web_app matches detected WEB-APP" {
  declare_containers web_app
  detect '{"containers":[{"name":"WEB-APP"}],"detection_confidence":"complete"}'
  run --separate-stderr check
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "inconclusive: differing sets still emit an empty plan + reported reason, never a demand (AC3)" {
  declare_containers aido
  detect '{"containers":[{"name":"worker"}],"detection_confidence":"inconclusive"}'
  run --separate-stderr check
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  contains "$stderr" "inconclusive"
}

@test "no docs/architecture/c4-container.md → exit 1 (precondition absent), never a failure (AC4)" {
  rm -rf "$REPO/docs/architecture"
  detect '{"containers":[{"name":"x"}],"detection_confidence":"complete"}'
  run check
  [ "$status" -eq 1 ]
}

@test "an unparseable declared block → exit 3 NAMING the page (propagated from #790's parser), never a silent skip (AC6)" {
  # a bare (unquoted) label violates the c4/v1 shape
  printf '```mermaid\nC4Container\n    Container(x, Bad Label, "Y")\n```\n' > "$REPO/docs/architecture/c4-container.md"
  detect '{"containers":[{"name":"x"}],"detection_confidence":"complete"}'
  run --separate-stderr check
  [ "$status" -eq 3 ]
  contains "$stderr" "c4-container.md"
}

@test "missing --detect-json is a usage error (exit 2)" {
  declare_containers aido
  run zsh "$CHECK" --repo "$REPO"
  [ "$status" -eq 2 ]
}

@test "malformed --detect-json is a runtime error (exit 3) naming the JSON problem" {
  declare_containers aido
  printf 'not json' > "$DJ"
  run --separate-stderr check
  [ "$status" -eq 3 ]
  contains "$stderr" "not valid JSON"
}

@test "a detect JSON of the wrong shape (.containers is bare strings) is exit 3, not jq's exit 5" {
  declare_containers aido
  detect '{"containers":["web","db"],"detection_confidence":"complete"}'
  run check
  [ "$status" -eq 3 ]
}

@test "a detect JSON with NO detection_confidence key is treated as inconclusive (no false 'complete' demand)" {
  declare_containers aido
  detect '{"containers":[{"name":"worker"}]}'
  run --separate-stderr check
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  contains "$stderr" "inconclusive"
}

@test "round-trip: a diagram seeded from a detect JSON is NEUTRAL against that same JSON (fold matches #791's seeder)" {
  # a space-bearing detected name -> seeder alias my_web_app -> the comparator's
  # fold must collapse both to the same token, or it would demand a bogus revisit
  local seed="$REPO_ROOT/development/skills/bootstrap/scripts/seed-c4-diagrams.zsh"
  detect '{"languages":["python"],"language_meta":{"python":{"version":"3.12"}},"containers":[{"name":"My Web App","source":"dockerfile","evidence":"x"}],"detection_confidence":"complete","interfaces":[{"interface":"web-ui","evidence":"x"}]}'
  zsh "$seed" --project-name "Demo" --detect-json "$DJ" --out "$REPO"
  run --separate-stderr check
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "an unknown flag is a usage error (exit 2)" {
  run zsh "$CHECK" --detect-json "$DJ" --bogus
  [ "$status" -eq 2 ]
}

@test "--help exits 0" {
  run zsh "$CHECK" --help
  [ "$status" -eq 0 ]
}

@test "the comparator calls #790's parser and does not re-implement the parse (no entry-regex of its own)" {
  grep -Fq 'extract-declared-containers.zsh' "$CHECK"
  # a real assertion (no trailing `|| true`): the script must NOT carry its own
  # C4 entry-parsing regex — a `Container(` capture would mean a second parser.
  run grep -nE 'Container[[:space:]]*\\\(\[' "$CHECK"
  [ "$status" -ne 0 ]
}
