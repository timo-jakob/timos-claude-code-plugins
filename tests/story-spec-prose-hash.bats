#!/usr/bin/env bats
#
# Behavioral tests for story-spec-prose-hash.zsh (#576): the canonical provenance
# hash over a story-spec/personas prose region. The contract that matters is that
# the SAME logical prose always hashes the SAME (so the story-readiness gate and
# the refine-issue writer agree), while a real content edit changes the hash (so
# staleness is detectable). Epic #573.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/story-spec-prose-hash.zsh"
}

@test "prints a lowercase 64-hex SHA-256 for a simple region" {
  run bash -c "printf 'Hello world\n' | zsh '$S'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

# Golden (known-answer) vectors — pin the exact byte contract so a pipeline
# change that stays internally self-consistent but drifts from the recipe (and
# would silently disagree with the gate's recompute) is caught here.
@test "golden: 'Hello world' hashes to the known SHA-256" {
  run bash -c "printf 'Hello world\n' | zsh '$S'"
  [ "$output" = "1894a19c85ba153acbf743ac4e43fc004c891604b26f8c69e1e83ea2afc7c48f" ]
}

@test "golden: an empty region hashes to SHA-256 of a single LF" {
  # normalisation appends exactly one trailing LF, so empty/all-blank -> hash('\n')
  empty="$(printf ''            | zsh "$S")"
  blank="$(printf '\n  \n\n'    | zsh "$S")"
  [ "$empty" = "01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b" ]
  [ "$blank" = "$empty" ]
}

@test "UTF-8 prose is preserved byte-for-byte (not mangled)" {
  from_script="$(printf 'Herr Müller\n' | zsh "$S")"
  direct="$(printf 'Herr Müller\n' | shasum -a 256 | awk '{print $1}')"
  [ "$from_script" = "$direct" ]
}

@test "normalisation: CRLF, trailing whitespace, and leading/trailing blank framing are ignored" {
  printf '\r\n\n  \nHello world   \r\n\nSecond para\t\n\n\n' > "$BATS_TEST_TMPDIR/a.txt"
  printf 'Hello world\n\nSecond para\n'                       > "$BATS_TEST_TMPDIR/b.txt"
  a="$(zsh "$S" --file "$BATS_TEST_TMPDIR/a.txt")"
  b="$(zsh "$S" --file "$BATS_TEST_TMPDIR/b.txt")"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

@test "internal blank lines are significant (paragraph structure is real content)" {
  a="$(printf 'Hello world\n\nSecond para\n' | zsh "$S")"   # with paragraph break
  b="$(printf 'Hello world\nSecond para\n'   | zsh "$S")"   # without
  [ "$a" != "$b" ]
}

@test "a real content edit changes the hash (staleness is detectable)" {
  a="$(printf 'the acceptance criterion is p95 < 200 ms\n' | zsh "$S")"
  b="$(printf 'the acceptance criterion is p95 < 300 ms\n' | zsh "$S")"
  [ "$a" != "$b" ]
}

@test "stdin and --file produce the same hash for the same bytes" {
  printf 'Hello world\n\nSecond para\n' > "$BATS_TEST_TMPDIR/p.txt"
  f="$(zsh "$S" --file "$BATS_TEST_TMPDIR/p.txt")"
  s="$(printf 'Hello world\n\nSecond para\n' | zsh "$S")"
  [ "$f" = "$s" ]
}

@test "deterministic: the same input hashes the same across runs" {
  one="$(printf 'stable prose\n' | zsh "$S")"
  two="$(printf 'stable prose\n' | zsh "$S")"
  [ "$one" = "$two" ]
}

@test "unknown argument is a usage error (exit 2)" {
  run zsh "$S" --bogus
  [ "$status" -eq 2 ]
}

@test "unreadable --file is an error (exit 1)" {
  run zsh "$S" --file "$BATS_TEST_TMPDIR/does-not-exist.txt"
  [ "$status" -eq 1 ]
}

@test "--file with no value is a usage error (exit 2), not a raw shift crash" {
  run zsh "$S" --file
  [ "$status" -eq 2 ]
}

@test "--help exits 0 and prints usage" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage:"* ]]
}
