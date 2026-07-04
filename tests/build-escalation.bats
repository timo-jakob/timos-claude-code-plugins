#!/usr/bin/env bats
#
# Behavioral tests for build-escalation.zsh (#564): every non-CONVERGED review
# loop exit must produce ONE typed, decision-ready escalation comment — the
# escalation type, a summary, the round history, and 2-3 concrete options — so a
# human interruption costs two minutes, not an afternoon (epic #557).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/build-escalation.zsh"
  ST="$BATS_TEST_TMPDIR/status.json"
}

@test "ESCALATE_NO_CONVERGENCE: typed header, options, round history, marker" {
  cat > "$ST" <<'EOF'
{"status":"ESCALATE_NO_CONVERGENCE","rounds":2,"max_rounds":3,
 "history":[{"round":1,"blocking":1,"conflicts":0,"non_converging":false},
            {"round":2,"blocking":1,"conflicts":0,"non_converging":true}],
 "final_changelist":{"blocking":[{"priority":"Critical","dimension":"bugs","file":"app.py","line":42,"title":"Race","non_converging":true}]}}
EOF
  run zsh "$S" --status "$ST" --issue 601
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ESCALATE_NO_CONVERGENCE'
  echo "$output" | grep -q 'How to proceed'
  # numbered options present (at least 2)
  [ "$(echo "$output" | grep -cE '^[0-9]+\. ')" -ge 2 ]
  # round history one line each, round 2 flagged non-converging
  echo "$output" | grep -q '^- Round 2:.*non-converging'
  # machine-greppable marker of the type
  echo "$output" | grep -q '<!-- review-loop-escalation: ESCALATE_NO_CONVERGENCE -->'
}

@test "ESCALATE_CONFLICT: names the conflicting dimensions + pick-a-winner option" {
  cat > "$ST" <<'EOF'
{"status":"ESCALATE_CONFLICT","rounds":1,"max_rounds":3,
 "history":[{"round":1,"blocking":2,"conflicts":1,"non_converging":false}],
 "final_changelist":{"conflicts":[{"file":"d.py","line":20,"between":["performance","code_quality"]}]}}
EOF
  run zsh "$S" --status "$ST" --issue 602
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ESCALATE_CONFLICT'
  echo "$output" | grep -q 'performance vs code_quality'
  echo "$output" | grep -qi 'Pick a winner'
}

@test "BUDGET_EXHAUSTED: names the budget and lists remaining blockers" {
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":3,"max_rounds":3,
 "history":[{"round":1,"blocking":1,"conflicts":0,"non_converging":false},
            {"round":2,"blocking":1,"conflicts":0,"non_converging":false},
            {"round":3,"blocking":1,"conflicts":0,"non_converging":false}],
 "final_changelist":{"blocking":[{"priority":"High","dimension":"performance","file":"b.py","line":5,"title":"N+1"}]}}
EOF
  run zsh "$S" --status "$ST" --issue 603
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'BUDGET_EXHAUSTED'
  echo "$output" | grep -q 'b.py:5'
  echo "$output" | grep -q '<!-- review-loop-escalation: BUDGET_EXHAUSTED -->'
}

@test "ESCALATE_AMBIGUOUS: surfaces the dispatch error and name-the-language option" {
  cat > "$ST" <<'EOF'
{"status":"ESCALATE_AMBIGUOUS","rounds":0,"max_rounds":3,"history":[],
 "final_changelist":{"dispatch_error":{"error":"ambiguous_repo_type","detail":"set .maintenance.yml primary"}}}
EOF
  run zsh "$S" --status "$ST" --issue 604
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ESCALATE_AMBIGUOUS'
  echo "$output" | grep -q 'ambiguous_repo_type'
  echo "$output" | grep -qi 'Name the language'
  # no rounds ran -> history placeholder
  echo "$output" | grep -q '(no rounds ran)'
}

@test "branch/compare link is included when provided, with the no-PR note" {
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":3,"max_rounds":3,"history":[],"final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST" --issue 605 --branch feat/605-x --compare-url 'https://github.com/o/r/tree/feat/605-x'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'no PR opened'
  echo "$output" | grep -q 'feat/605-x'
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
