#!/usr/bin/env bats
#
# Acceptance cases for "the telemetry/v1 tokens field becomes a per-model
# object in emit and validate" (#2720, part 2 of #1974) — the `cli`-tooled
# test_cases[] of its story-spec, one test per `tc-*` id:
#
#   tc-happy-emit-tokens-file          #2378
#   tc-corner-tokens-omitted           #2752
#   tc-corner-tokens-stdin             #2753
#   tc-corner-empty-by-model           #2754
#   tc-error-malformed-tokens-object   #2386
#   tc-error-numeric-tokens            #2387
#   tc-error-double-stdin              #2388
#   tc-error-total-mismatch            #2755
#   tc-error-unknown-tokens-key        #2756
#
# The use case: the resolve-issue telemetry step (part 3 of #1974) runs
# emit-telemetry.zsh in a worktree and stores the real per-model token usage of
# one run — the object tokens-for-window.zsh prints — or null, never an
# estimate. The default gate's tests/telemetry-emit.bats and
# tests/telemetry-validate.bats cover the same criteria in more depth.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  EMIT="$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
  export HOME="$BATS_TEST_TMPDIR/home"  # the user-level default sink stays out of the real ~/.claude
  SINK="$BATS_TEST_TMPDIR/sink.jsonl"
  TOKENS="$BATS_TEST_TMPDIR/tokens.json"
  printf '%s\n' '{"source":"transcript","coverage":"session+subagents","by_model":{"claude-opus-5-5":{"input":2,"cache_write_5m":0,"cache_write_1h":73996,"cache_read":30038,"output":251,"thinking":16}},"total":104287}' > "$TOKENS"
}

emit() {
  run --separate-stderr zsh "$EMIT" --pipeline review-loop --outcome success --wall-s 60 \
    --issue 2720 --repo timo-jakob/timos-claude-code-plugins --telemetry-file "$SINK" "$@"
}

@test "tc-happy-emit-tokens-file (#2378): --tokens FILE embeds the object unchanged, and it validates" {
  emit --tokens "$TOKENS"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tokens' <<<"$output")" = "$(jq -c . "$TOKENS")" ]
  run zsh "$VALIDATE" "$SINK" --require-records
  [ "$status" -eq 0 ]
}

@test "tc-corner-tokens-omitted (#2752): no --tokens writes tokens: null, and it validates" {
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tokens' <<<"$output")" = null ]
  run zsh "$VALIDATE" "$SINK" --require-records
  [ "$status" -eq 0 ]
}

@test "tc-corner-tokens-stdin (#2753): --tokens - reads the object from stdin" {
  run --separate-stderr bash -c "zsh '$EMIT' --pipeline review-loop --outcome success --wall-s 60 --repo timo-jakob/timos-claude-code-plugins --telemetry-file '$SINK' --tokens - < '$TOKENS'"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tokens' <<<"$output")" = "$(jq -c . "$TOKENS")" ]
  run zsh "$VALIDATE" "$SINK" --require-records
  [ "$status" -eq 0 ]
}

@test "tc-corner-empty-by-model (#2754): by_model {} with total 0 is emitted and validated" {
  printf '%s\n' '{"source":"transcript","coverage":"session+subagents","by_model":{},"total":0}' > "$TOKENS"
  emit --tokens "$TOKENS"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.tokens.by_model' <<<"$output")" = '{}' ]
  run zsh "$VALIDATE" "$SINK" --require-records
  [ "$status" -eq 0 ]
}

@test "tc-error-malformed-tokens-object (#2386): a string count is refused, exit 2, nothing written" {
  jq -c '.by_model["claude-opus-5-5"].output = "251"' "$TOKENS" > "$BATS_TEST_TMPDIR/bad.json"
  emit --tokens "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "not a well-formed tokens object"
  [ ! -e "$SINK" ]
}

@test "tc-error-numeric-tokens (#2387): --tokens 4096 is a usage error, and the validator rejects tokens: 4096" {
  emit --tokens 4096
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ ! -e "$SINK" ]
  emit
  [ "$status" -eq 0 ]
  run bash -c "jq -c '.tokens = 4096' '$SINK' | zsh '$VALIDATE' - --require-records"
  [ "$status" -eq 1 ]
  contains "$output" "tokens must be null or an object"
}

@test "tc-error-double-stdin (#2388): --payload - with --tokens - is a usage error" {
  emit --payload - --tokens -
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "cannot both read stdin"
  [ ! -e "$SINK" ]
}

@test "tc-error-total-mismatch (#2755): a total that adds thinking is refused by emit and by the validator" {
  jq -c '.total = 104303' "$TOKENS" > "$BATS_TEST_TMPDIR/bad.json"
  emit --tokens "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  [ ! -e "$SINK" ]
  emit
  [ "$status" -eq 0 ]
  run bash -c "jq -c --slurpfile t '$BATS_TEST_TMPDIR/bad.json' '.tokens = \$t[0]' '$SINK' | zsh '$VALIDATE' - --require-records"
  [ "$status" -eq 1 ]
  contains "$output" "tokens.total must equal"
}

@test "tc-error-unknown-tokens-key (#2756): an extra key estimated is refused by the validator" {
  emit
  [ "$status" -eq 0 ]
  run bash -c "jq -c --slurpfile t '$TOKENS' '.tokens = (\$t[0] | .estimated = true)' '$SINK' | zsh '$VALIDATE' - --require-records"
  [ "$status" -eq 1 ]
  contains "$output" "tokens has unknown key(s): estimated"
}
