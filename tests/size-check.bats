#!/usr/bin/env bats
#
# size-check.zsh (#2589): the readiness gate's and refine-issue's entry to the
# size pre-flight. It must hold no threshold of its own, so every case here
# compares it with the pre-flight it wraps rather than with a number: the same
# inventory through both scripts must give the same stdout and the same exit.
# The one case the wrapper owns is the SKIPPED inventory — an empty `files`
# array — which the pre-flight itself refuses as malformed.
#
# The inventories reuse size-preflight.bats' shapes: one straddle per trigger is
# enough here, because the boundaries themselves are that suite's to pin.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/size-check.zsh"
  P="$REPO_ROOT/development/skills/resolve-issue/scripts/size-preflight.zsh"
  MANIFEST="$REPO_ROOT/.claude-plugin/marketplace.json"
  INV="$BATS_TEST_TMPDIR/inventory.json"
}

inventory() {
  printf '%s\n' "$@" | jq -R . | jq -s '{files: .}' > "$INV"
}

n_development_files() {
  local i
  for (( i = 1; i <= $1; i++ )); do
    printf 'development/skills/refine-issue/scripts/f%02d.zsh\n' "$i"
  done
}

# Run the wrapper, then the pre-flight on the same inventory, and require the
# two to agree on stdout and exit status. Leaves the wrapper's run in $status /
# $output for the caller's own assertions.
check_matches_preflight() {
  run --separate-stderr zsh "$P" --file "$INV" --manifest "$MANIFEST"
  local want_status="$status" want_output="$output"
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$MANIFEST"
  [ "$status" -eq "$want_status" ] || {
    printf 'size-check exited %s, the pre-flight %s\n' "$status" "$want_status" >&2; return 1; }
  [ "$output" = "$want_output" ] || {
    printf 'size-check printed %s, the pre-flight %s\n' "$output" "$want_output" >&2; return 1; }
}

@test "a pass is passed through: verdict and exit 0" {
  # shellcheck disable=SC2046
  inventory $(n_development_files 3)
  check_matches_preflight
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.verdict == "pass" and .triggers == []' >/dev/null
}

@test "the files trigger is passed through: stop and exit 1" {
  # shellcheck disable=SC2046
  inventory $(n_development_files 40)
  check_matches_preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.verdict == "stop" and .triggers == ["files"]' >/dev/null
}

@test "the plugin trigger is passed through: stop and exit 1" {
  inventory development/agents/story-readiness.md development-go/skills/review/SKILL.md
  check_matches_preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.verdict == "stop" and .triggers == ["plugin"]' >/dev/null
}

@test "the bootstrap-straddle trigger is passed through: stop and exit 1" {
  inventory development/skills/bootstrap/templates/go/Makefile.tmpl \
    development/skills/resolve-issue/SKILL.md
  check_matches_preflight
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.verdict == "stop" and .triggers == ["bootstrap-straddle"]' >/dev/null
}

@test "an empty inventory is skipped, never stopped: exit 0" {
  printf '%s' '{"files":[]}' > "$INV"
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = '{"verdict":"skipped"}' ]
  # the pre-flight itself refuses the same input — the skip is the wrapper's own
  run --separate-stderr zsh "$P" --file "$INV" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
}

@test "an empty inventory on stdin is skipped too" {
  run --separate-stderr zsh -c 'printf "%s" "{\"files\":[]}" | zsh "$1"' _ "$S"
  [ "$status" -eq 0 ]
  [ "$output" = '{"verdict":"skipped"}' ]
}

@test "a malformed inventory is never a pass: the pre-flight's exit 3, nothing on stdout" {
  printf '%s' '{"files":"not-an-array"}' > "$INV"
  check_matches_preflight
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "invalid JSON is never a pass: exit 3, nothing on stdout" {
  printf '%s' 'not json' > "$INV"
  run --separate-stderr zsh "$S" --file "$INV" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "an inventory read from stdin reaches the pre-flight" {
  # shellcheck disable=SC2046
  inventory $(n_development_files 40)
  run --separate-stderr zsh -c 'zsh "$1" --manifest "$2" < "$3"' _ "$S" "$MANIFEST" "$INV"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.verdict == "stop"' >/dev/null
}

@test "usage errors exit 2 with nothing on stdout" {
  run --separate-stderr zsh "$S" --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr zsh "$S" --file
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr zsh "$S" --file "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "-h prints usage on stderr, nothing on stdout, and exits 0" {
  run --separate-stderr zsh "$S" -h
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  contains "$stderr" "usage: size-check.zsh"
}

@test "a missing pre-flight script is a runtime error, never a pass" {
  # copy the wrapper somewhere its relative path to the pre-flight resolves to nothing
  local d="$BATS_TEST_TMPDIR/skills/refine-issue/scripts"
  mkdir -p "$d"
  cp "$S" "$d/size-check.zsh"
  printf '%s' '{"files":["development/a.md"]}' > "$INV"
  run --separate-stderr zsh "$d/size-check.zsh" --file "$INV" --manifest "$MANIFEST"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "size pre-flight not found"
}

@test "the wrapper holds no threshold of its own" {
  run -1 grep -nE 'MAX_FILES|more than [0-9a-z-]+ files|BOOTSTRAP_TEMPLATES' "$S"
}
