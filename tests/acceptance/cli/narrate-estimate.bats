#!/usr/bin/env bats
#
# Acceptance cases for "narrate a sourced estimate for every long wait" (#2198,
# epic #2195 child (c)) — the `cli`-tooled test_cases[] of its story-spec, one
# test per `tc-*` id:
#
#   tc-happy-gate-live                 #2251
#   tc-happy-panel-prior               #2252
#   tc-happy-gate-withheld-prior       #2253
#   tc-corner-no-plan-prior            #2254
#   tc-corner-gate-finished            #2255
#   tc-corner-no-start-line            #2256
#   tc-corner-repo-type-passthrough    #2257
#   tc-error-below-five                #2258
#   tc-error-unreadable-sink           #2259
#   tc-error-missing-gate-log          #2260
#   tc-error-usage                     #2261
#
# The use case: timo-platform-builder, at a long wait in a resolve-issue round,
# sees a sourced estimate or an explicit "no estimate", and decides whether to
# step away, free CPU or stop the run. At the round 2 boundary the gate log
# <work-dir>/gate-2.stderr holds `run-gate: start epoch=1791360000
# mode=parallel scope=full jobs=4`, `1..1830` and 412 results; at 1791360552 the
# conductor prints `estimate for gate: live — 412/1830 tests, 9m12s elapsed,
# ~31m40s left (jobs=4)`.
#
# narrate-estimate.zsh runs with the real gate-eta.zsh and estimate-step.zsh
# beside it, against fixture logs and sinks, with the clock pinned through
# GATE_ETA_NOW. Nothing reaches GitHub. The default gate's
# tests/narrate-estimate.bats covers the same criteria.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  N="$REPO_ROOT/development/skills/resolve-issue/scripts/narrate-estimate.zsh"
  START=1791360000
  LOG="$BATS_TEST_TMPDIR/gate-2.stderr"
  K="$BATS_TEST_TMPDIR/telemetry.jsonl"
  : > "$K"
  I=0
}

# the round gate's captured stderr: start line (when given a scope), plan, results
gate_log() {  # <total|-> <done> [<scope> <jobs>]
  local i
  {
    if [ -n "${3-}" ]; then
      echo "run-gate: start epoch=$START mode=parallel scope=$3 jobs=$4"
    fi
    if [ "$1" != "-" ]; then
      echo "1..$1"
    fi
    for ((i = 1; i <= $2; i++)); do echo "ok $i resolve-issue case $i"; done
  } > "$LOG"
}

# one review-loop record in the platform repo's sink
rec() {  # <step_wall_s_by_round json> [<gate_by_round json>] [<repo_type json>]
  I=$((I + 1))
  jq -cn --argjson i "$((2190 + I))" --argjson ts "$((START + I))" --argjson sw "$1" \
    --argjson g "${2:-[]}" --argjson rt "${3:-\"claude-plugin\"}" \
    '{schema:"telemetry/v1", kind:"run", pipeline:"review-loop", repo:"timo-jakob/timos-claude-code-plugins",
      repo_type:$rt, issue:$i, ts:$ts, wall_s:2400, payload:{step_wall_s_by_round:$sw, gate_by_round:$g}}' >> "$K"
}
sw() {  # <step> <seconds>
  jq -cn --arg s "$1" --argjson v "$2" \
    '[{round:1, step_wall_s:({panel:null, decide:null, risk:null, fix:null} | .[$s] = $v)}]'
}
gate() {  # <scope> <wall_s> <jobs>
  printf '[{"round":1,"gate":{"scope":"%s","attested":true,"wall_s":%s,"slowest":[],"jobs":%s}}]' "$1" "$2" "$3"
}

narrate() { run --separate-stderr env GATE_ETA_NOW="${AT:-1791360552}" zsh "$N" "$@"; }

@test "tc-happy-gate-live (#2251)" {
  gate_log 1830 412 full 4
  narrate --step gate --gate-log "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: live — 412/1830 tests, 9m12s elapsed, ~31m40s left (jobs=4)" ]
}

@test "tc-happy-panel-prior (#2252)" {
  local p
  for p in 600 660 700 720 900 1200; do rec "$(sw panel "$p")"; done
  narrate --step panel --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for panel: prior — median 11m40s, p80 15m00s over 6 past runs" ]
}

@test "tc-happy-gate-withheld-prior (#2253)" {
  local i
  for i in 1 2 3 4 5 6; do rec '[]' "$(gate full 1200 10)"; done
  gate_log 1830 12 full 5
  AT=$((START + 40)) narrate --step gate --gate-log "$LOG" --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: prior — median 40m00s, p80 40m00s over 6 past runs (full gate, scaled to jobs=5)" ]
}

@test "tc-corner-no-plan-prior (#2254)" {
  local i
  for i in 1 2 3 4 5; do rec '[]' "$(gate full 1800 4)"; done
  gate_log - 0 full 4
  narrate --step gate --gate-log "$LOG" --sink "$K"
  [ "$status" -eq 0 ]
  starts_with "$output" "estimate for gate: prior — "
  lacks "$output" "live"
}

@test "tc-corner-gate-finished (#2255)" {
  gate_log 1830 1830 full 4
  echo "run-gate: mode=parallel jobs=4 ok=1830 not_ok=0 total=1830 exit=0 wall_s=2463.512" >> "$LOG"
  narrate --step gate --gate-log "$LOG"
  [ "$status" -eq 0 ]
  starts_with "$output" "estimate for gate: live — "
  contains "$output" "finished"
}

@test "tc-corner-no-start-line (#2256)" {
  local i
  for i in 1 2 3 4 5; do rec '[]' "$(gate full 1200 10)"; done
  gate_log 1830 12
  narrate --step gate --gate-log "$LOG" --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: no estimate (no data)" ]
}

@test "tc-corner-repo-type-passthrough (#2257)" {
  local i
  for i in 1 2 3 4 5; do rec "$(sw risk 40)" '[]' null; done
  narrate --step risk --repo-type claude-plugin --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for risk: no estimate (no data)" ]
}

@test "tc-error-below-five (#2258)" {
  local i
  for i in 1 2 3 4; do rec "$(sw fix 300)"; done
  narrate --step fix --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for fix: no estimate (no data)" ]
}

@test "tc-error-unreadable-sink (#2259)" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 file"
  rec "$(sw decide 30)"
  chmod 000 "$K"
  narrate --step decide --sink "$K"
  chmod 600 "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for decide: no estimate (telemetry unreadable)" ]
}

@test "tc-error-missing-gate-log (#2260)" {
  narrate --step gate --gate-log /nonexistent/gate-2.stderr
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: no estimate (estimator error)" ]
}

@test "tc-error-usage (#2261)" {
  narrate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  narrate --step build
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  narrate --step gate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  narrate --step panel --gate-log "$LOG"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  narrate --step panel --frobnicate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}
