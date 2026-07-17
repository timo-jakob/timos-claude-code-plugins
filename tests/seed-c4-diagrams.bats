#!/usr/bin/env bats
#
# Behavioral tests for seed-c4-diagrams.zsh (epic #746 child (b), #791): bootstrap
# C4 seeding. Generates docs/architecture/c4-context.md + c4-container.md from
# detect-stack's structural model (#799), conforming to the c4/v1 declared-
# container shape (#790) so extract-declared-containers.zsh parses the result.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SEED="$REPO_ROOT/development/skills/bootstrap/scripts/seed-c4-diagrams.zsh"
  EXTRACT="$REPO_ROOT/development/skills/bootstrap/scripts/extract-declared-containers.zsh"
  DJ="$BATS_TEST_TMPDIR/detect.json"
  OUT="$BATS_TEST_TMPDIR/out"
}
put() { printf '%s' "$1" > "$DJ"; }
seed() { zsh "$SEED" --project-name "$1" --detect-json "$DJ" --out "$OUT"; }
declared() { zsh "$EXTRACT" --file "$OUT/docs/architecture/c4-container.md"; }

DOCKERFILE_CLI='{"languages":["python"],"language_meta":{"python":{"version":"3.12"}},"containers":[{"name":"aido","source":"dockerfile","evidence":"./Dockerfile"}],"detection_confidence":"complete","interfaces":[{"interface":"cli","evidence":"x"}]}'

@test "seed: both required pages are written under docs/architecture/ (AC1)" {
  put "$DOCKERFILE_CLI"
  run seed "AI Doc Organizer"
  [ "$status" -eq 0 ]
  [ -f "$OUT/docs/architecture/c4-context.md" ]
  [ -f "$OUT/docs/architecture/c4-container.md" ]
}

@test "seed: the Context page carries a C4Context block naming the system" {
  put "$DOCKERFILE_CLI"
  seed "AI Doc Organizer"
  grep -Fq 'C4Context' "$OUT/docs/architecture/c4-context.md"
  grep -Fq 'AI Doc Organizer' "$OUT/docs/architecture/c4-context.md"
}

@test "seed: the emitted Container page is parseable by #790's extractor and names the detected container (AC3)" {
  put "$DOCKERFILE_CLI"
  seed "AI Doc Organizer"
  run declared
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].alias')" = "aido" ]
  [ "$(echo "$output" | jq -r '.[0].technology')" = "Python 3.12" ]
}

@test "seed: complete + containers [] yields exactly ONE synthesized container, label+technology asserted (AC4)" {
  put '{"languages":["python"],"language_meta":{"python":{"version":"3.12"}},"containers":[],"detection_confidence":"complete","interfaces":[{"interface":"cli","evidence":"x"}]}'
  seed "Libthing"
  run declared
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "1" ]
  [ "$(echo "$output" | jq -r '.[0].alias')" = "libthing" ]
  [ "$(echo "$output" | jq -r '.[0].label')" = "Libthing CLI" ]
  [ "$(echo "$output" | jq -r '.[0].technology')" = "Python 3.12" ]
}

@test "seed: the synthesized-minimum c4-container.md byte-matches the pinned fixture (AC4 — exact format)" {
  put '{"languages":["python"],"language_meta":{"python":{"version":"3.12"}},"containers":[],"detection_confidence":"complete","interfaces":[{"interface":"cli","evidence":"x"}]}'
  seed "Libthing"
  diff "$OUT/docs/architecture/c4-container.md" "$REPO_ROOT/tests/fixtures/c4/seeded-container-minimal.md"
}

@test "seed: inconclusive detection seeds NO fabricated container (AC5)" {
  put '{"languages":["java"],"language_meta":{"java":{"version":"21"}},"containers":[],"detection_confidence":"inconclusive","interfaces":[]}'
  seed "Mystery"
  # a valid, present C4Container block, but with zero in-scope containers
  run declared
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  # and no dangling Rel against an undefined alias (invalid mermaid)
  ! grep -q 'Rel(user,' "$OUT/docs/architecture/c4-container.md"
}

@test "seed: a bootBuildImage container (no Dockerfile) is seeded from detection, not synthesized" {
  put '{"languages":["java"],"language_meta":{"java":{"version":"21"}},"containers":[{"name":"tick-client-snapper","source":"bootBuildImage","evidence":"x"}],"detection_confidence":"complete","interfaces":[]}'
  seed "Tick Client Snapper"
  run declared
  [ "$status" -eq 0 ]
  # the detected name's hyphens are preserved — a valid c4/v1 alias (the join
  # folds -/_), and more faithful to the real deployable identifier
  [ "$(echo "$output" | jq -r '.[0].alias')" = "tick-client-snapper" ]
}

@test "seed: multiple detected containers all appear, title-cased labels asserted" {
  put '{"languages":["python"],"language_meta":{"python":{"version":"3.12"}},"containers":[{"name":"web","source":"compose","evidence":"x"},{"name":"worker","source":"compose","evidence":"y"}],"detection_confidence":"complete","interfaces":[{"interface":"rest","evidence":"x"}]}'
  seed "Multi"
  run declared
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '[.[].alias] | sort | join(",")')" = "web,worker" ]
  [ "$(echo "$output" | jq -r '.[] | select(.alias=="web").label')" = "Web" ]
  [ "$(echo "$output" | jq -r '.[] | select(.alias=="worker").technology')" = "Python 3.12" ]
}

@test "seed: a double quote in the project name is sanitized so the page stays parseable (never exit 3)" {
  put "$DOCKERFILE_CLI"
  seed 'My "Fast" CLI'
  run declared
  [ "$status" -eq 0 ]
  # the label carries no raw double-quote (which would break the quote-aware parse)
  echo "$output" | jq -e '.[0].label | contains("\"") | not' >/dev/null
}

@test "seed: two container names that fold to the same alias are uniquified (page stays parseable)" {
  put '{"languages":["go"],"language_meta":{"go":{"version":"1.22"}},"containers":[{"name":"web app","source":"compose","evidence":"x"},{"name":"web_app","source":"compose","evidence":"y"}],"detection_confidence":"complete","interfaces":[]}'
  seed "Collide"
  run declared
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "2" ]
  [ "$(echo "$output" | jq -r '[.[].alias] | unique | length')" = "2" ]
}

@test "seed: a detect JSON with no interfaces/language_meta keys does not crash (robust jq)" {
  put '{"containers":[],"detection_confidence":"complete"}'
  run seed "Bare"
  [ "$status" -eq 0 ]
  run declared
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].technology')" = "Unspecified" ]
}

@test "seed: the pages carry NO provenance marker (so #793's content drift check ignores them, AC6)" {
  put "$DOCKERFILE_CLI"
  seed "AI Doc Organizer"
  ! grep -Fq 'claude-bootstrap:' "$OUT/docs/architecture/c4-context.md"
  ! grep -Fq 'claude-bootstrap:' "$OUT/docs/architecture/c4-container.md"
}

@test "seed: a mixed-case container name folds to a valid lowercased c4/v1 alias, and a space-bearing name is sanitized" {
  put '{"languages":["go"],"language_meta":{"go":{"version":"1.22"}},"containers":[{"name":"My Web App","source":"dockerfile","evidence":"x"}],"detection_confidence":"complete","interfaces":[]}'
  seed "My Web App"
  run declared
  [ "$status" -eq 0 ]
  # spaces (illegal in an alias token) map to _, case is lowered
  [ "$(echo "$output" | jq -r '.[0].alias')" = "my_web_app" ]
}

@test "seed: no --detect-json is a reported no-op (exit 1), not an error" {
  run zsh "$SEED" --project-name "X" --out "$OUT"
  [ "$status" -eq 1 ]
}

@test "seed: a --detect-json path that does not exist is exit 1 (precondition absent)" {
  run zsh "$SEED" --project-name "X" --detect-json "$BATS_TEST_TMPDIR/nope.json" --out "$OUT"
  [ "$status" -eq 1 ]
}

@test "seed: an existing-but-unreadable --detect-json (a directory) is a runtime error (exit 3), not exit 1" {
  mkdir -p "$BATS_TEST_TMPDIR/adir"
  run zsh "$SEED" --project-name "X" --detect-json "$BATS_TEST_TMPDIR/adir" --out "$OUT"
  [ "$status" -eq 3 ]
}

@test "seed: a missing required flag is a usage error (exit 2)" {
  put "$DOCKERFILE_CLI"
  run zsh "$SEED" --detect-json "$DJ" --out "$OUT"
  [ "$status" -eq 2 ]
}

@test "seed: a flag given without a value is a usage error (exit 2)" {
  run zsh "$SEED" --project-name --detect-json "$DJ" --out "$OUT"
  [ "$status" -eq 2 ]
}

@test "seed: an unknown flag is a usage error (exit 2)" {
  put "$DOCKERFILE_CLI"
  run zsh "$SEED" --project-name "X" --detect-json "$DJ" --out "$OUT" --bogus
  [ "$status" -eq 2 ]
}

@test "seed: malformed detect JSON is a runtime error (exit 3)" {
  printf 'not json' > "$DJ"
  run seed "X"
  [ "$status" -eq 3 ]
}

@test "seed: valid JSON of the wrong shape (.containers is bare strings) is exit 3, never a fabricated container" {
  put '{"languages":["go"],"containers":["web","db"],"detection_confidence":"complete"}'
  run seed "X"
  [ "$status" -eq 3 ]
}

@test "seed: valid JSON of the wrong shape (.interfaces is a string) is exit 3, not jq's exit 5" {
  put '{"languages":["go"],"containers":[],"interfaces":"cli","detection_confidence":"complete"}'
  run seed "X"
  [ "$status" -eq 3 ]
}

@test "seed: a container named 'user' is uniquified away from the reserved Person id (no id collision)" {
  put '{"languages":["go"],"language_meta":{"go":{"version":"1.22"}},"containers":[{"name":"user","source":"compose","evidence":"x"}],"detection_confidence":"complete","interfaces":[]}'
  seed "App"
  run declared
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].alias')" != "user" ]
}
