#!/usr/bin/env bats
#
# Behavioral tests for build-telemetry-record.zsh (#566): one JSONL record per
# review-loop run, and the documented jq one-liners that turn a file of records
# into the three headline metrics (convergence rate, mean rounds, escalation
# breakdown). Epic #557.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/build-telemetry-record.zsh"
  ST="$BATS_TEST_TMPDIR/status.json"
  cat > "$ST" <<'EOF'
{"status":"CONVERGED","rounds":2,"max_rounds":3,"repo_type":"python","escalation_reasons":[],
 "round_changelists":[
  {"round":1,"blocking":[{"priority":"Critical","dimension":"bugs","file":"a.py","line":1,"title":"B"}],
   "suggestions":[{"priority":"Low","dimension":"code_quality","file":"a.py","line":2,"title":"tidy"}]},
  {"round":2,"blocking":[],"suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
}

@test "one run produces exactly one valid JSONL record with the expected fields" {
  run zsh "$S" --status "$ST" --issue 601 --ts 1720000000 --wall-s 42
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]     # single line
  echo "$output" | jq -e '.' >/dev/null                  # valid JSON
  [ "$(echo "$output" | jq -r '.issue')" = "601" ]
  [ "$(echo "$output" | jq -r '.repo_type')" = "python" ]
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq -r '.escalation')" = "null" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.fixed')" -eq 1 ]            # the blocker was fixed
  [ "$(echo "$output" | jq '.waived')" -eq 1 ]           # the Low was logged/waived
  [ "$(echo "$output" | jq -r '.tokens')" = "null" ]     # reserved in v1
  [ "$(echo "$output" | jq '.wall_s')" -eq 42 ]
  # findings per round by severity + dimension
  [ "$(echo "$output" | jq '.findings_by_round[0].by_priority.Critical')" -eq 1 ]
  [ "$(echo "$output" | jq '.findings_by_round[0].by_dimension.bugs')" -eq 1 ]
}

@test "an escalated run records the escalation type and fixed=0 (blocker still open)" {
  cat > "$ST" <<'EOF'
{"status":"ESCALATE_NO_CONVERGENCE","rounds":2,"max_rounds":3,"repo_type":"java",
 "round_changelists":[
  {"round":1,"blocking":[{"priority":"High","dimension":"performance","file":"b.java","line":5,"title":"N+1"}],"suggestions":[]},
  {"round":2,"blocking":[{"priority":"High","dimension":"performance","file":"b.java","line":5,"title":"N+1"}],"suggestions":[]}],
 "final_changelist":{"blocking":[{"priority":"High","dimension":"performance","file":"b.java","line":5,"title":"N+1"}]}}
EOF
  run zsh "$S" --status "$ST" --issue 602 --ts 1720000001
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.escalation')" = "ESCALATE_NO_CONVERGENCE" ]
  [ "$(echo "$output" | jq '.fixed')" -eq 0 ]
}

@test "documented jq one-liners produce the three summary metrics" {
  local F="$BATS_TEST_TMPDIR/review-loop.jsonl"
  zsh "$S" --status "$ST" --issue 601 --ts 1720000000 >> "$F"     # CONVERGED, 2 rounds
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":3,"max_rounds":3,"repo_type":"python","round_changelists":[],"final_changelist":{"blocking":[]}}
EOF
  zsh "$S" --status "$ST" --issue 602 --ts 1720000002 >> "$F"     # escalated, 3 rounds

  # convergence rate
  [ "$(jq -s '([.[]|select(.status=="CONVERGED")]|length) / length' "$F")" = "0.5" ]
  # mean rounds
  [ "$(jq -s '([.[].rounds]|add) / length' "$F")" = "2.5" ]
  # escalation breakdown
  run jq -s 'group_by(.escalation) | map({(.[0].escalation|tostring): length}) | add' "$F"
  echo "$output" | jq -e '.BUDGET_EXHAUSTED == 1' >/dev/null
}

@test "usage: --status is required (exit 2)" {
  run zsh "$S" --issue 1
  [ "$status" -eq 2 ]
}

@test "internal: invalid status JSON is exit 1, not a crash" {
  echo 'not json' > "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 1 ]
}
