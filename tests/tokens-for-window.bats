#!/usr/bin/env bats
#
# Behavioral tests for tokens-for-window.zsh (#2719, part 1 of #1974): the pure
# reader that sums one session's real token usage per model over a half-open
# window [start, end), from the session transcript and its subagent transcripts.
#
# Every transcript is built here with printf under BATS_TEST_TMPDIR, and
# CLAUDE_CONFIG_DIR points at it, so the suite never reads the real ~/.claude.
# The one result that is not a measurement is `null` plus exactly one advisory
# line on stderr, with exit 0 — never a partial sum — so each null case asserts
# all three.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/scripts/telemetry/tokens-for-window.zsh"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/claude"
  unset CLAUDE_CODE_SESSION_ID
  SID=92468615-cf61-43ca-bbf7-1dcc78e90b7c
  PROJ="$CLAUDE_CONFIG_DIR/projects/-Users-timo-repositories-timos-claude-code-plugins"
  T="$PROJ/$SID.jsonl"
  SUB="$PROJ/$SID/subagents"
  mkdir -p "$SUB"
  START=1792231865
  END=1792232465
}

# iso <epoch> — the ISO-8601 timestamp a transcript line carries (with millis).
iso() {
  jq -nr --argjson t "$1" '$t | todate | sub("Z$"; ".500Z")'
}

# aline <file> <id> <model> <epoch> <input> <cw5m> <cw1h> <cache_read> <output> [<thinking>]
# appends one assistant line; an omitted <thinking> leaves output_tokens_details out.
aline() {
  local f="$1" id="$2" model="$3" t="$4" details=""
  [ -z "${10-}" ] || details=",\"output_tokens_details\":{\"thinking_tokens\":${10}}"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"%s","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":%s,"output_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":%s,"ephemeral_1h_input_tokens":%s}%s}}}\n' \
    "$(iso "$t")" "$id" "$model" "$5" "$8" "$9" "$6" "$7" "$details" >> "$f"
}

# raw <file> <epoch> <usage-json> — an assistant line with a hand-written usage.
raw() {
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"msg_raw","model":"claude-opus-5-5","usage":%s}}\n' \
    "$(iso "$2")" "$3" >> "$1"
}

window() {  # window <start> <end> — runs the reader over the fixture session
  run --separate-stderr zsh "$S" --session-id "$SID" --start "$1" --end "$2"
}

# assert_null — the not-measured contract: null, one advisory line, exit 0.
assert_null() {
  [ "$status" -eq 0 ]
  [ "$output" = null ]
  [ "${#stderr_lines[@]}" -eq 1 ]
  contains "$stderr" "tokens not measured"
}

@test "one message.id on three streamed lines counts once, at its per-field maximum" {
  aline "$T" msg_011Cg7naDc3y1qKMALESbtM5 claude-opus-5-5 $((START + 10)) 2 0 73996 30038 8 0
  aline "$T" msg_011Cg7naDc3y1qKMALESbtM5 claude-opus-5-5 $((START + 11)) 2 0 73996 30038 8 0
  aline "$T" msg_011Cg7naDc3y1qKMALESbtM5 claude-opus-5-5 $((START + 12)) 2 0 73996 30038 974 16
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.by_model["claude-opus-5-5"]' <<<"$output")" = '{"input":2,"cache_write_5m":0,"cache_write_1h":73996,"cache_read":30038,"output":974,"thinking":16}' ]
  [ "$(jq '.total' <<<"$output")" -eq $((2 + 73996 + 30038 + 974)) ]
}

@test "two models in one session are summed separately and both count toward total" {
  aline "$T" msg_a claude-opus-5-5 $((START + 1)) 2 0 100 1000 50 5
  aline "$T" msg_b claude-sonnet-5-5 $((START + 2)) 3 7 0 2000 60 0
  aline "$T" msg_c claude-opus-5-5 $((START + 3)) 1 0 10 500 40 0
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.by_model | keys' <<<"$output")" = '["claude-opus-5-5","claude-sonnet-5-5"]' ]
  [ "$(jq '.by_model["claude-opus-5-5"].output' <<<"$output")" -eq 90 ]
  [ "$(jq '.by_model["claude-sonnet-5-5"].cache_write_5m' <<<"$output")" -eq 7 ]
  [ "$(jq '.total' <<<"$output")" -eq $((3 + 0 + 110 + 1500 + 90 + 3 + 7 + 0 + 2000 + 60)) ]
}

@test "subagent transcripts are read with the session transcript" {
  aline "$T" msg_main claude-opus-5-5 $((START + 1)) 1 0 0 0 10 0
  aline "$SUB/agent-a1.jsonl" msg_sub1 claude-haiku-5-5 $((START + 2)) 2 0 0 0 20 0
  aline "$SUB/agent-a2.jsonl" msg_sub2 claude-haiku-5-5 $((START + 3)) 3 0 0 0 30 0
  printf '{"agentType":"story-readiness"}\n' > "$SUB/agent-a1.meta.json"
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.coverage' <<<"$output")" = session+subagents ]
  [ "$(jq '.by_model["claude-haiku-5-5"].output' <<<"$output")" -eq 50 ]
  [ "$(jq '.total' <<<"$output")" -eq 66 ]
}

@test "a window excludes messages from before its start" {
  aline "$T" msg_old claude-opus-5-5 $((START - 600)) 9 0 0 0 500 0
  aline "$T" msg_new claude-opus-5-5 $((START + 5)) 1 0 0 0 10 0
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 11 ]
}

@test "the window is half-open: a line at start counts, a line at end does not" {
  aline "$T" msg_at_start claude-opus-5-5 "$START" 0 0 0 0 100 0
  aline "$T" msg_at_end claude-opus-5-5 "$END" 0 0 0 0 7 0
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 100 ]
  window "$END" $((END + 600))
  [ "$(jq '.total' <<<"$output")" -eq 7 ]
}

@test "a message streamed across end counts once, in the window of its first line" {
  local end2=$((END + 600))
  aline "$T" msg_early claude-opus-5-5 $((START + 1)) 1 0 0 0 10 0
  aline "$T" msg_cross claude-opus-5-5 $((END - 1)) 2 0 0 0 8 0
  aline "$T" msg_cross claude-opus-5-5 "$END" 2 0 0 0 300 0
  aline "$T" msg_late claude-opus-5-5 $((END + 5)) 4 0 0 0 40 0
  window "$START" "$END"
  local first; first="$(jq '.total' <<<"$output")"
  [ "$first" -eq $((11 + 302)) ]
  window "$END" "$end2"
  local second; second="$(jq '.total' <<<"$output")"
  [ "$second" -eq 44 ]
  window "$START" "$end2"
  [ "$(jq '.total' <<<"$output")" -eq $((first + second)) ]
}

@test "each transcript usage field lands in its own output field" {
  aline "$T" msg_map claude-opus-5-5 $((START + 1)) 11 22 33 44 55 6
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.by_model["claude-opus-5-5"]' <<<"$output")" = '{"input":11,"cache_write_5m":22,"cache_write_1h":33,"cache_read":44,"output":55,"thinking":6}' ]
}

@test "thinking is reported but never added to total" {
  aline "$T" msg_think claude-opus-5-5 $((START + 1)) 2 0 73996 30038 251 16
  window "$START" "$END"
  [ "$(jq '.by_model["claude-opus-5-5"].thinking' <<<"$output")" -eq 16 ]
  [ "$(jq '.total' <<<"$output")" -eq 104287 ]
}

@test "a line without output_tokens_details reports thinking 0, not null" {
  aline "$T" msg_nothink claude-opus-5-5 $((START + 1)) 1 0 0 0 10
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq '.by_model["claude-opus-5-5"].thinking' <<<"$output")" = 0 ]
}

@test "an output_tokens_details without thinking_tokens reports thinking 0, not null" {
  raw "$T" $((START + 1)) '{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":5,"output_tokens_details":{},"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}'
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq '.by_model["claude-opus-5-5"].thinking' <<<"$output")" = 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 6 ]
}

@test "a <synthetic> line adds no model and nothing to total" {
  aline "$T" msg_real claude-opus-5-5 $((START + 1)) 1 0 0 0 10 0
  aline "$T" msg_synth '<synthetic>' $((START + 2)) 0 0 0 0 0 0
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.by_model | keys' <<<"$output")" = '["claude-opus-5-5"]' ]
  [ "$(jq '.total' <<<"$output")" -eq 11 ]
}

@test "a window with no assistant lines is a measured zero, not null" {
  aline "$T" msg_old claude-opus-5-5 $((START - 60)) 1 0 0 0 10 0
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq -c '{by_model, total}' <<<"$output")" = '{"by_model":{},"total":0}' ]
}

@test "the transcript is found from a worktree cwd: the project dir is the main checkout's" {
  aline "$T" msg_wt claude-opus-5-5 $((START + 1)) 1 0 0 0 10 0
  local wt="$BATS_TEST_TMPDIR/timos-claude-code-plugins/.claude/worktrees/fancy-brewing-magpie"
  mkdir -p "$wt"
  cd "$wt"
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 11 ]
}

@test "--root overrides CLAUDE_CONFIG_DIR" {
  local other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other/projects/p"
  aline "$other/projects/p/$SID.jsonl" msg_other claude-opus-5-5 $((START + 1)) 0 0 0 0 5 0
  run --separate-stderr zsh "$S" --session-id "$SID" --start "$START" --end "$END" --root "$other"
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 5 ]
}

@test "the session id defaults to CLAUDE_CODE_SESSION_ID" {
  aline "$T" msg_env claude-opus-5-5 $((START + 1)) 0 0 0 0 3 0
  CLAUDE_CODE_SESSION_ID="$SID" run --separate-stderr zsh "$S" --start "$START" --end "$END"
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 3 ]
}

@test "no session id is null, one advisory, exit 0" {
  run --separate-stderr zsh "$S" --start "$START" --end "$END"
  assert_null
}

@test "a session id that is not a plain id is null, never a glob" {
  aline "$T" msg_x claude-opus-5-5 $((START + 1)) 0 0 0 0 3 0
  run --separate-stderr zsh "$S" --session-id '*' --start "$START" --end "$END"
  assert_null
}

@test "a missing transcript is null, one advisory, exit 0" {
  run --separate-stderr zsh "$S" --session-id 00000000-0000-0000-0000-000000000000 --start "$START" --end "$END"
  assert_null
}

@test "two projects/ entries matching the session id are null" {
  aline "$T" msg_one claude-opus-5-5 $((START + 1)) 0 0 0 0 3 0
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/-Users-timo-other"
  aline "$CLAUDE_CONFIG_DIR/projects/-Users-timo-other/$SID.jsonl" msg_two claude-opus-5-5 $((START + 1)) 0 0 0 0 3 0
  window "$START" "$END"
  assert_null
  contains "$stderr" "2 transcripts match"
}

@test "a missing cache_creation.ephemeral_5m_input_tokens is null, never a partial sum" {
  aline "$T" msg_ok claude-opus-5-5 $((START + 1)) 1 0 0 0 10 0
  raw "$T" $((START + 2)) '{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":5,"cache_creation":{"ephemeral_1h_input_tokens":0}}'
  window "$START" "$END"
  assert_null
}

@test "a string input_tokens is null" {
  raw "$T" $((START + 2)) '{"input_tokens":"1","cache_read_input_tokens":0,"output_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}'
  window "$START" "$END"
  assert_null
}

@test "a negative output_tokens is null" {
  raw "$T" $((START + 2)) '{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":-5,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}'
  window "$START" "$END"
  assert_null
}

@test "an unrecognised line outside the window does not void the window" {
  raw "$T" $((START - 60)) '{"input_tokens":"1"}'
  aline "$T" msg_ok claude-opus-5-5 $((START + 1)) 1 0 0 0 10 0
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 11 ]
}

@test "an in-window assistant line with no message.id is null" {
  printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}\n' \
    "$(iso $((START + 1)))" >> "$T"
  window "$START" "$END"
  assert_null
}

@test "an assistant line whose timestamp cannot be read is null" {
  printf '{"type":"assistant","timestamp":"yesterday","message":{"id":"msg_t","model":"claude-opus-5-5","usage":{}}}\n' >> "$T"
  window "$START" "$END"
  assert_null
}

@test "a non-JSON line before the end of a transcript is null" {
  aline "$T" msg_a claude-opus-5-5 $((START + 1)) 1 0 0 0 10 0
  printf '{"type":"assistant","timest\n' >> "$T"
  aline "$T" msg_b claude-opus-5-5 $((START + 2)) 1 0 0 0 10 0
  window "$START" "$END"
  assert_null
}

@test "a partly written last line of a live transcript is ignored" {
  aline "$T" msg_a claude-opus-5-5 $((START + 1)) 1 0 0 0 10 0
  printf '{"type":"assistant","timest' >> "$T"
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 11 ]
}

@test "non-assistant lines are ignored" {
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hi"}}\n' "$(iso $((START + 1)))" >> "$T"
  aline "$T" msg_a claude-opus-5-5 $((START + 2)) 1 0 0 0 10 0
  window "$START" "$END"
  [ "$status" -eq 0 ]
  [ "$(jq '.total' <<<"$output")" -eq 11 ]
}

@test "transcript content never reaches stdout or stderr" {
  # secret-shaped (a GitHub PAT's prefix and length), built at runtime so no
  # high-entropy literal sits in the repo for the secret scanners to flag
  local secret
  secret="ghp_$(printf 'Ab1%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"msg_s","model":"claude-opus-5-5","content":[{"type":"text","text":"%s"}],"usage":{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}\n' \
    "$(iso $((START + 1)))" "$secret" >> "$T"
  window "$START" "$END"
  [ "$status" -eq 0 ]
  lacks "$output$stderr" "$secret"
  # ...and on the null path, where an advisory is printed
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"claude-opus-5-5","usage":{"input_tokens":"x"}}}\n' \
    "$(iso $((START + 2)))" "$secret" >> "$T"
  window "$START" "$END"
  assert_null
  lacks "$output$stderr" "$secret"
}

@test "--help prints the usage on stdout and exits 0" {
  run --separate-stderr zsh "$S" --help
  [ "$status" -eq 0 ]
  starts_with "$output" "usage: tokens-for-window.zsh"
}

@test "usage: an unknown flag exits 2" {
  run --separate-stderr zsh "$S" --start "$START" --end "$END" --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "usage:"
}

@test "usage: a missing or non-integer --start or --end exits 2" {
  run --separate-stderr zsh "$S" --session-id "$SID" --end "$END"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --session-id "$SID" --start 17922318.5 --end "$END"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" --session-id "$SID" --start "$START" --end
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "usage: an end before the start exits 2" {
  run --separate-stderr zsh "$S" --session-id "$SID" --start "$END" --end "$START"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "is before --start"
}
