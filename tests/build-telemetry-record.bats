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
  # findings per round in the USER-FACING severity vocabulary (#969)
  [ "$(echo "$output" | jq '.findings_by_round[0].by_severity.Critical')" -eq 1 ]
  [ "$(echo "$output" | jq '.findings_by_round[0].by_severity.Warning')" -eq 0 ]
  [ "$(echo "$output" | jq '.findings_by_round[0].by_severity.Suggestion')" -eq 1 ]
  [ "$(echo "$output" | jq '.findings_by_round[0].by_dimension.bugs')" -eq 1 ]
}

@test "per-round new/carried/fixed_from_prev + convergence_assessment are recorded (#969)" {
  cat > "$ST" <<'EOF'
{"status":"ESCALATE_NO_CONVERGENCE","rounds":2,"max_rounds":3,"repo_type":"python",
 "round_changelists":[
  {"round":1,"blocking":[{"priority":"Critical","dimension":"bugs","file":"a.py","line":1,"title":"b1","non_converging":false},
                         {"priority":"High","dimension":"tests","file":"t.py","line":1,"title":"t1","non_converging":false}],
   "suggestions":[]},
  {"round":2,"blocking":[{"priority":"Critical","dimension":"bugs","file":"a.py","line":3,"title":"new finding","non_converging":true,"possible_false_trip":true,"matched_prior":{"line":1,"title":"b1"}}],
   "suggestions":[]}],
 "final_changelist":{"blocking":[{"priority":"Critical","dimension":"bugs","file":"a.py","line":3,"title":"new finding","non_converging":true,"possible_false_trip":true,"matched_prior":{"line":1,"title":"b1"}}]}}
EOF
  run zsh "$S" --status "$ST" --issue 969 --ts 1720000000
  [ "$status" -eq 0 ]
  # round 1: all new, nothing prior to have fixed
  [ "$(echo "$output" | jq '.findings_by_round[0].new')" -eq 2 ]
  [ "$(echo "$output" | jq '.findings_by_round[0].carried')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.findings_by_round[0].fixed_from_prev')" = "null" ]
  # round 2: 1 blocking, 1 carried -> 0 new; 2 prior - 1 carried -> 1 fixed
  [ "$(echo "$output" | jq '.findings_by_round[1].new')" -eq 0 ]
  [ "$(echo "$output" | jq '.findings_by_round[1].carried')" -eq 1 ]
  [ "$(echo "$output" | jq '.findings_by_round[1].fixed_from_prev')" -eq 1 ]
  # the per-loop assessment: trend, blockers moving, false-trip count
  [ "$(echo "$output" | jq -c '.convergence_assessment.blocking_by_round')" = "[2,1]" ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.trend')" = "improving" ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.blockers_moving')" = "true" ]
  [ "$(echo "$output" | jq '.convergence_assessment.carried_final')" -eq 1 ]
  [ "$(echo "$output" | jq '.convergence_assessment.possible_false_trips')" -eq 1 ]
}

@test "fixed_from_prev counts DISTINCT matched priors, not carried items (#969)" {
  # two round-2 carried blockers matched the SAME prior; the other prior was
  # fixed -> fixed_from_prev = 2 - 1 (distinct) = 1, never 2 - 2 (per-item) = 0
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":2,"max_rounds":2,"repo_type":"python",
 "round_changelists":[
  {"round":1,"blocking":[{"priority":"Critical","dimension":"bugs","file":"a.py","line":10,"title":"X","non_converging":false},
                         {"priority":"Critical","dimension":"bugs","file":"a.py","line":200,"title":"Y","non_converging":false}],
   "suggestions":[]},
  {"round":2,"blocking":[{"priority":"Critical","dimension":"bugs","file":"a.py","line":5,"title":"x2","non_converging":true,"possible_false_trip":true,"matched_prior":{"line":10,"title":"X"}},
                         {"priority":"Critical","dimension":"bugs","file":"a.py","line":15,"title":"x3","non_converging":true,"possible_false_trip":true,"matched_prior":{"line":10,"title":"X"}}],
   "suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST" --ts 1720000000
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.findings_by_round[1].carried')" -eq 2 ]
  [ "$(echo "$output" | jq '.findings_by_round[1].fixed_from_prev')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.blockers_moving')" = "true" ]
}

@test "fixed_from_prev keeps same-file/line/title priors in DIFFERENT dimensions distinct (#969)" {
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":2,"max_rounds":2,"repo_type":"python",
 "round_changelists":[
  {"round":1,"blocking":[{"priority":"Critical","dimension":"security","file":"a.py","line":10,"title":"Unsanitized input","non_converging":false},
                         {"priority":"Critical","dimension":"script_quality","file":"a.py","line":10,"title":"Unsanitized input","non_converging":false}],
   "suggestions":[]},
  {"round":2,"blocking":[{"priority":"Critical","dimension":"security","file":"a.py","line":11,"title":"Unsanitized input","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":10,"title":"Unsanitized input"}},
                         {"priority":"Critical","dimension":"script_quality","file":"a.py","line":11,"title":"Unsanitized input","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":10,"title":"Unsanitized input"}}],
   "suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST" --ts 1720000000
  [ "$status" -eq 0 ]
  # 2 distinct priors carried -> nothing fixed, nothing moving (collapses to
  # 1 distinct / fixed 1 / moving true if .dimension leaves the unique_by key)
  [ "$(echo "$output" | jq '.findings_by_round[1].carried')" -eq 2 ]
  [ "$(echo "$output" | jq '.findings_by_round[1].fixed_from_prev')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.blockers_moving')" = "false" ]
}

@test "convergence_assessment is null with no rounds; single round has null trend" {
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":3,"max_rounds":3,"repo_type":"python","round_changelists":[],"final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST" --ts 1720000000
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.convergence_assessment')" = "null" ]
  cat > "$ST" <<'EOF'
{"status":"AWAITING_FIX","rounds":1,"max_rounds":3,"repo_type":"python",
 "round_changelists":[{"round":1,"blocking":[{"priority":"High","dimension":"tests","file":"t.py","line":1,"title":"t1","non_converging":false}],"suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST" --ts 1720000000
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.trend')" = "null" ]
  [ "$(echo "$output" | jq -c '.convergence_assessment.blocking_by_round')" = "[1]" ]
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
  # these rounds lack the #913 per-item stamp -> honest nulls, never numbers (#969)
  [ "$(echo "$output" | jq -r '.findings_by_round[0].new')" = "null" ]
  [ "$(echo "$output" | jq -r '.findings_by_round[0].carried')" = "null" ]
  [ "$(echo "$output" | jq -r '.findings_by_round[1].fixed_from_prev')" = "null" ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.carried_final')" = "null" ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.blockers_moving')" = "null" ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.possible_false_trips')" = "null" ]
  # trend needs no stamps — the series alone determines it
  [ "$(echo "$output" | jq -r '.convergence_assessment.trend')" = "flat" ]
}

@test "convergence_assessment.trend reads 'regressing' when blocking rises (#969)" {
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":2,"max_rounds":2,"repo_type":"python",
 "round_changelists":[
  {"round":1,"blocking":[{"priority":"High","dimension":"tests","file":"t.py","line":1,"title":"t1","non_converging":false}],"suggestions":[]},
  {"round":2,"blocking":[{"priority":"High","dimension":"tests","file":"t.py","line":1,"title":"t1","non_converging":true,"possible_false_trip":false,"matched_prior":{"line":1,"title":"t1"}},
                         {"priority":"High","dimension":"bugs","file":"a.py","line":9,"title":"b1","non_converging":false}],"suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST" --ts 1720000000
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.trend')" = "regressing" ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.blockers_moving')" = "false" ]
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
