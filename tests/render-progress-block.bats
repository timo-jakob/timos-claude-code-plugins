#!/usr/bin/env bats
#
# Tests for render-progress-block.zsh (#971): changelist JSON in, one
# human-readable progress.md block on stdout. The new/carried split must render
# ONLY when every blocker carries the #913 non_converging stamp — a stamp-less
# or mixed changelist gets totals only (no label rather than a confident wrong
# one).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/render-progress-block.zsh"
  CL="$BATS_TEST_TMPDIR/changelist.json"
}

@test "stamped blockers render the new/carried split and per-dimension counts" {
  cat > "$CL" <<'EOF'
{"round":2,"summary":{"critical":1,"high":1,"low":1,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":true},
             {"file":"b.py","line":2,"dimension":"tests","title":"y","non_converging":false}],
 "suggestions":[{}],"conflicts":[],"non_converging":true}
EOF
  run zsh "$S" --changelist "$CL" --round 2 --verdict "awaiting fix"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^## Round 2 — blockers remain'
  echo "$output" | grep -q -- '- blockers: 2 (new: 1, carried: 1), conflicts: 0, suggestions: 1'
  echo "$output" | grep -q -- '- by dimension: bugs 1, tests 1'
  echo "$output" | grep -q -- '- awaiting fix'
}

@test "a stamp-less changelist degrades to totals only (no new/carried label)" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x"},
             {"file":"b.py","line":2,"dimension":"bugs","title":"y"}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 1 --verdict "budget exhausted"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '- blockers: 2, conflicts: 0, suggestions: 0'
  run ! grep -q 'new:' <<< "$output"
}

@test "a MIXED changelist (one stamped, one not) also degrades to totals only" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":2,"high":0,"low":0,"blocking":2,"conflicts":0},
 "blocking":[{"file":"a.py","line":1,"dimension":"bugs","title":"x","non_converging":true},
             {"file":"b.py","line":2,"dimension":"bugs","title":"y"}],
 "suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 1 --verdict "v"
  [ "$status" -eq 0 ]
  run ! grep -q 'new:' <<< "$output"
}

@test "a converged round renders 'no blockers' and omits the dimension line" {
  cat > "$CL" <<'EOF'
{"round":3,"summary":{"critical":0,"high":0,"low":2,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[{},{}],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round 3 --verdict "converged"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^## Round 3 — no blockers'
  echo "$output" | grep -q -- '- blockers: 0, conflicts: 0, suggestions: 2'
  echo "$output" | grep -q -- '- converged'
  run ! grep -q 'by dimension' <<< "$output"
}

@test "missing required args is a usage error (exit 2)" {
  run zsh "$S" --changelist "$CL" --round 1
  [ "$status" -eq 2 ]
}

@test "a missing changelist file is an internal error (exit 1)" {
  run zsh "$S" --changelist "$BATS_TEST_TMPDIR/nope.json" --round 1 --verdict v
  [ "$status" -eq 1 ]
}

@test "invalid changelist JSON is an internal error (exit 1)" {
  printf 'not json' > "$CL"
  run zsh "$S" --changelist "$CL" --round 1 --verdict v
  [ "$status" -eq 1 ]
}

@test "a non-numeric --round is a usage error (exit 2), not a confusing jq failure" {
  cat > "$CL" <<'EOF'
{"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},
 "blocking":[],"suggestions":[],"conflicts":[],"non_converging":false}
EOF
  run zsh "$S" --changelist "$CL" --round abc --verdict v
  [ "$status" -eq 2 ]
}
