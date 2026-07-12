#!/usr/bin/env bats
#
# Behavioral tests for build-refine-telemetry-record.zsh (#579, epic #573): one
# JSONL record per refine-issue run, mirroring the review-loop telemetry (#566).
# The contract: exactly one well-formed line per run, capturing the outcome and
# per-round objection counts, using the same sink/convention as #566.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/refine-issue/scripts/build-refine-telemetry-record.zsh"
  ST="$BATS_TEST_TMPDIR/state.json"
}
put() { printf '%s' "$1" > "$ST"; }

READY='{"rounds":3,"objections_raised":4,"objections_resolved":4,"outcome":"refined-ready","risk_classification":"low"}'
PARKED='{"rounds":1,"objections_raised":2,"objections_resolved":0,"outcome":"parked","park_type":"needs-decision","risk_classification":"normal"}'

@test "a refined-ready run produces exactly one valid JSONL record with the expected fields (AC1/AC2)" {
  put "$READY"
  run zsh "$S" --state "$ST" --issue 579 --ts 1720000000 --wall-s 90
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]     # single line
  echo "$output" | jq -e '.' >/dev/null                  # valid JSON
  [ "$(echo "$output" | jq -r '.issue')" = "579" ]
  [ "$(echo "$output" | jq -r '.outcome')" = "refined-ready" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.objections_raised')" -eq 4 ]
  [ "$(echo "$output" | jq '.objections_resolved')" -eq 4 ]
  [ "$(echo "$output" | jq -r '.risk_classification')" = "low" ]
  [ "$(echo "$output" | jq '.wall_s')" -eq 90 ]
  [ "$(echo "$output" | jq -r '.tokens')" = "null" ]     # reserved, mirrors #566
  [ "$(echo "$output" | jq -r '.park_type')" = "null" ]  # not a park
  [ "$(echo "$output" | jq '.ts')" -eq 1720000000 ]
}

@test "a parked run records outcome=parked and the park type (AC2)" {
  put "$PARKED"
  run zsh "$S" --state "$ST" --issue 579 --ts 1720000000
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.outcome')" = "parked" ]
  [ "$(echo "$output" | jq -r '.park_type')" = "needs-decision" ]
  [ "$(echo "$output" | jq '.objections_resolved')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.wall_s')" = "null" ]     # not supplied -> null
}

@test "issue is null when not supplied (a JSON scalar, mirroring #566)" {
  put "$READY"
  run zsh "$S" --state "$ST" --ts 1720000000
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.issue')" = "null" ]
}

@test "missing fields default to 0 / null" {
  put '{"outcome":"parked"}'
  run zsh "$S" --state "$ST" --ts 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.rounds')" -eq 0 ]
  [ "$(echo "$output" | jq '.objections_raised')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.park_type')" = "null" ]
  [ "$(echo "$output" | jq -r '.risk_classification')" = "null" ]
}

@test "reads state from stdin as well as --state" {
  run bash -c "printf '%s' '$READY' | zsh '$S' --issue 579 --ts 1"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.outcome == "refined-ready"' >/dev/null
}

@test "appending N runs yields N well-formed JSONL lines (the sink is line-per-run)" {
  sink="$BATS_TEST_TMPDIR/refine-issue.jsonl"
  : > "$sink"
  put "$READY";  zsh "$S" --state "$ST" --issue 1 --ts 1 >> "$sink"
  put "$PARKED"; zsh "$S" --state "$ST" --issue 2 --ts 2 >> "$sink"
  [ "$(wc -l < "$sink" | tr -d ' ')" -eq 2 ]
  # every line parses, and the file is a valid JSONL stream
  run jq -c '.outcome' "$sink"
  [ "$status" -eq 0 ]
  [ "$(jq -s 'length' "$sink")" -eq 2 ]
}

@test "an unknown outcome is rejected (exit 1)" {
  put '{"outcome":"bogus"}'
  run zsh "$S" --state "$ST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown outcome"* ]]
}

@test "a missing outcome is rejected (exit 1)" {
  put '{"rounds":2}'
  run zsh "$S" --state "$ST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"outcome is required"* ]]
}

@test "invalid state JSON is rejected (exit 1)" {
  put '{not json'
  run zsh "$S" --state "$ST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"single JSON object"* ]]
}

@test "regression: a dangling trailing flag does not hang (no infinite loop)" {
  # --wall-s with no value (as the SKILL template's `--wall-s <seconds>` would be
  # if <seconds> rendered empty) must terminate, not spin forever. Use whatever
  # timeout binary exists (GNU `timeout` on CI, `gtimeout` on macOS+coreutils);
  # with neither, run directly — the fix means it completes anyway.
  put "$READY"
  local TO=""
  if command -v timeout >/dev/null 2>&1; then TO="timeout 10"
  elif command -v gtimeout >/dev/null 2>&1; then TO="gtimeout 10"; fi
  run $TO zsh "$S" --state "$ST" --issue 579 --wall-s
  [ "$status" -ne 124 ]           # 124 == timeout fired == it hung
  [ "$status" -eq 0 ]             # wall-s treated as absent -> null, clean record
  [ "$(echo "$output" | jq -r '.wall_s')" = "null" ]
}

@test "regression: concatenated JSON documents are rejected (one record per run)" {
  put '{"outcome":"parked"} {}'
  run zsh "$S" --state "$ST" --ts 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"single JSON object"* ]]
}

@test "regression: a string-typed count is coerced to a number" {
  put '{"outcome":"parked","rounds":"3","objections_raised":"2"}'
  run zsh "$S" --state "$ST" --ts 1
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.rounds')" -eq 3 ]          # numeric, not "3"
  echo "$output" | jq -e '.rounds | type == "number"' >/dev/null
  echo "$output" | jq -e '.objections_raised | type == "number"' >/dev/null
}

@test "regression: a non-numeric --ts falls back to a numeric stamp, not a crash" {
  put "$READY"
  run zsh "$S" --state "$ST" --ts notanumber
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ts | type == "number"' >/dev/null
}

@test "an unknown flag is a usage error (exit 2)" {
  put "$READY"
  run zsh "$S" --state "$ST" --bogus x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}
