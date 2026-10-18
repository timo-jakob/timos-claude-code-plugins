#!/usr/bin/env bats
#
# Acceptance cases for "tokens-for-window sums real token usage per model from
# session transcripts" (#2719, part 1 of #1974) — the `cli`-tooled
# test_cases[] of its story-spec, one test per `tc-*` id:
#
#   tc-happy-session-and-subagents     #2749
#   tc-corner-duplicate-message-id     #2383
#   tc-corner-worktree-launch          #2384
#   tc-error-ambiguous-session-match   #2750
#   tc-error-unrecognised-line-shape   #2751
#
# The use case: the telemetry pipeline, running in a worktree, wants the
# per-model token totals of session 92468615-cf61-43ca-bbf7-1dcc78e90b7c over
# [1792231865, 1792232465). Transcripts are built with printf under a fixture
# CLAUDE_CONFIG_DIR, so the real ~/.claude is never read. The default gate's
# tests/tokens-for-window.bats covers the same criteria in more depth.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  S="$REPO_ROOT/development/scripts/telemetry/tokens-for-window.zsh"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  export CLAUDE_CODE_SESSION_ID=92468615-cf61-43ca-bbf7-1dcc78e90b7c
  MAIN_SLUG=-Users-timo-repositories-timos-claude-code-plugins
  PROJ="$CLAUDE_CONFIG_DIR/projects/$MAIN_SLUG"
  T="$PROJ/$CLAUDE_CODE_SESSION_ID.jsonl"
  mkdir -p "$PROJ/$CLAUDE_CODE_SESSION_ID/subagents"
  START=1792231865
  END=1792232465
}

# assistant <file> <id> <model> <epoch> <input> <cw5m> <cw1h> <cache_read> <output> <thinking>
assistant() {
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"%s","content":[{"type":"text","text":"Readiness verdict written."}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s,"output_tokens_details":{"thinking_tokens":%s},"cache_creation":{"ephemeral_5m_input_tokens":%s,"ephemeral_1h_input_tokens":%s}}}}\n' \
    "$(jq -nr --argjson t "$4" '$t | todate | sub("Z$"; ".671Z")')" "$2" "$3" "$5" $(($6 + $7)) "$8" "$9" "${10}" "$6" "$7" >> "$1"
}

reader() {
  run --separate-stderr zsh "$S" --start "$START" --end "$END"
}

@test "tc-happy-session-and-subagents (#2749): one model in the session, a second in a subagent" {
  assistant "$T" msg_011Cg7naDc3y1qKMALESbtM5 claude-opus-5-5 $((START + 30)) 2 0 73996 30038 251 16
  assistant "$PROJ/$CLAUDE_CODE_SESSION_ID/subagents/agent-a94b7ae5be3aa2f7d.jsonl" \
    msg_01Ar7Kq2mVZt5bTqXc8pLwEd claude-haiku-5-5 $((START + 90)) 4 1200 0 18000 640 0
  reader
  [ "$status" -eq 0 ]
  [ "$(jq -c '.by_model | keys' <<<"$output")" = '["claude-haiku-5-5","claude-opus-5-5"]' ]
  [ "$(jq -c '{source, coverage}' <<<"$output")" = '{"source":"transcript","coverage":"session+subagents"}' ]
  # total = input + cache_write_5m + cache_write_1h + cache_read + output; thinking 16 not added
  [ "$(jq '.total' <<<"$output")" -eq $((104287 + 4 + 1200 + 18000 + 640)) ]
}

@test "tc-corner-duplicate-message-id (#2383): output 8, 8, 974 on one message.id counts 974 once" {
  local t
  for t in 8 8 974; do
    assistant "$T" msg_011Cg7naDc3y1qKMALESbtM5 claude-opus-5-5 $((START + 30)) 2 0 73996 30038 "$t" 16
  done
  reader
  [ "$status" -eq 0 ]
  [ "$(jq '.by_model["claude-opus-5-5"].output' <<<"$output")" -eq 974 ]
  [ "$(jq '.total' <<<"$output")" -eq $((2 + 73996 + 30038 + 974)) ]
}

@test "tc-corner-worktree-launch (#2384): run from a worktree, the main checkout's transcript is found" {
  assistant "$T" msg_011Cg7naDc3y1qKMALESbtM5 claude-opus-5-5 $((START + 30)) 2 0 73996 30038 251 16
  local wt="$BATS_TEST_TMPDIR/timos-claude-code-plugins/.claude/worktrees/sequential-snacking-bumblebee"
  mkdir -p "$wt"
  cd "$wt"
  reader
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 104287 ]
}

@test "tc-error-ambiguous-session-match (#2750): two projects/ entries for the session id is null" {
  assistant "$T" msg_011Cg7naDc3y1qKMALESbtM5 claude-opus-5-5 $((START + 30)) 2 0 73996 30038 251 16
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/-Users-timo-repositories-ai-doc-organizer"
  assistant "$CLAUDE_CONFIG_DIR/projects/-Users-timo-repositories-ai-doc-organizer/$CLAUDE_CODE_SESSION_ID.jsonl" \
    msg_01Bq9Lw3nXa6cUrYd9qMxFe2 claude-opus-5-5 $((START + 40)) 2 0 500 9000 120 0
  reader
  [ "$status" -eq 0 ]
  [ "$output" = null ]
  [ "${#stderr_lines[@]}" -eq 1 ]
}

@test "tc-error-unrecognised-line-shape (#2751): a usage without ephemeral_5m_input_tokens is null, not a partial sum" {
  assistant "$T" msg_011Cg7naDc3y1qKMALESbtM5 claude-opus-5-5 $((START + 30)) 2 0 73996 30038 251 16
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"msg_01Cx4Mp7rYb2dVsZe1rNyGf3","model":"claude-opus-5-5","usage":{"input_tokens":3,"cache_read_input_tokens":41000,"output_tokens":88,"cache_creation":{"ephemeral_1h_input_tokens":2048}}}}\n' \
    "$(jq -nr --argjson t $((START + 60)) '$t | todate')" >> "$T"
  reader
  [ "$status" -eq 0 ]
  [ "$output" = null ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  contains "$stderr" "unrecognised shape"
}
