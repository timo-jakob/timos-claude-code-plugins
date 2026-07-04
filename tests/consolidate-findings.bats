#!/usr/bin/env bats
#
# Behavioral tests for consolidate-findings.zsh (#561): the deterministic engine
# that turns a review round's aggregate findings (issue #558 schema) into one
# prioritised changelist for the autonomous review loop (epic #557). Covers the
# four acceptance criteria — dedup, severity->blocking mapping, conflict
# detection, and cross-round non-convergence — plus edges.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/consolidate-findings.zsh"
  F="$BATS_TEST_TMPDIR/findings.json"
}

con() { run zsh "$S" --findings "$F" "$@"; }

@test "dedup: overlapping findings from two reviewers merge to one item" {
  cat > "$F" <<'EOF'
[
 {"severity":"WARNING","dimension":"bugs","file":"a.py","line":10,"title":"maybe None","description":"short","reviewer":"python-bug-hunter"},
 {"severity":"CRITICAL","dimension":"bugs","file":"a.py","line":10,"title":"None deref","description":"a considerably longer and more detailed description of the same defect","reviewer":"python-security-reviewer"}
]
EOF
  con
  [ "$status" -eq 0 ]
  # one consolidated item, highest severity wins, both reviewers credited,
  # most-detailed description kept
  [ "$(echo "$output" | jq '.blocking | length')" -eq 1 ]
  [ "$(echo "$output" | jq -r '.blocking[0].severity')" = "CRITICAL" ]
  [ "$(echo "$output" | jq '.blocking[0].agreement')" -eq 2 ]
  echo "$output" | jq -e '.blocking[0].description | test("considerably longer")' >/dev/null
}

@test "severity: WARNING maps to High and blocks; SUGGESTION maps to Low and never blocks" {
  cat > "$F" <<'EOF'
[
 {"severity":"WARNING","dimension":"performance","file":"b.py","line":5,"title":"N+1 query","description":"d","reviewer":"python-performance-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"c.py","line":8,"title":"rename var","description":"d","reviewer":"python-code-quality"}
]
EOF
  con
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.blocking[0].priority')" = "High" ]
  [ "$(echo "$output" | jq '.summary.blocking')" -eq 1 ]
  # the SUGGESTION is a logged suggestion, never in blocking
  [ "$(echo "$output" | jq -r '.suggestions[0].priority')" = "Low" ]
  echo "$output" | jq -e '.blocking | all(.title != "rename var")' >/dev/null
}

@test "conflict: co-located performance vs code_quality yields a conflict item + escalation" {
  cat > "$F" <<'EOF'
[
 {"severity":"WARNING","dimension":"performance","file":"d.py","line":20,"title":"inline the hot loop","description":"d","reviewer":"python-performance-reviewer"},
 {"severity":"SUGGESTION","dimension":"code_quality","file":"d.py","line":20,"title":"extract a helper for clarity","description":"d","reviewer":"python-code-quality"}
]
EOF
  con
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.conflicts | length')" -eq 1 ]
  echo "$output" | jq -e '.conflicts[0].between == ["performance","code_quality"]' >/dev/null
  echo "$output" | jq -e '.escalation_reasons | index("unresolved_conflict")' >/dev/null
}

@test "non-convergence: a blocker surviving two consecutive rounds sets non_converging" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  [ "$status" -eq 0 ]
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"
  [ "$(echo "$output" | jq '.non_converging')" = "false" ]

  # round 2: same defect (reworded title, shifted line) still blocks
  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":31,"title":"Race on shared counter!","description":"still here","reviewer":"python-security-reviewer"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "true" ]
  echo "$output" | jq -e '.escalation_reasons | index("non_converging_blocker")' >/dev/null
}

@test "non-convergence: a DIFFERENT blocker in round 2 does not set non_converging" {
  cat > "$F" <<'EOF'
[{"severity":"CRITICAL","dimension":"bugs","file":"e.py","line":30,"title":"Race on shared counter","description":"d","reviewer":"python-bug-hunter"}]
EOF
  run zsh "$S" --findings "$F" --round 1
  echo "$output" > "$BATS_TEST_TMPDIR/round1.json"
  cat > "$BATS_TEST_TMPDIR/r2.json" <<'EOF'
[{"severity":"CRITICAL","dimension":"security","file":"z.py","line":9,"title":"SQL injection","description":"d","reviewer":"python-security-reviewer"}]
EOF
  run zsh "$S" --findings "$BATS_TEST_TMPDIR/r2.json" --round 2 --prev "$BATS_TEST_TMPDIR/round1.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "false" ]
}

@test "empty findings: a clean empty changelist, nothing blocking" {
  echo '[]' > "$F"
  con
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.summary.blocking')" -eq 0 ]
  [ "$(echo "$output" | jq '.blocking | length')" -eq 0 ]
  [ "$(echo "$output" | jq '.non_converging')" = "false" ]
}

@test "usage: --findings is required (exit 2)" {
  run zsh "$S" --round 1
  [ "$status" -eq 2 ]
}

@test "internal: invalid JSON findings is exit 1, not a crash" {
  echo 'not json' > "$F"
  con
  [ "$status" -eq 1 ]
}
