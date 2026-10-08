#!/usr/bin/env bats
#
# Behavioural tests for narrate-estimate.zsh (#2198, epic #2195 child (c)): the
# one line the resolve-issue conductor prints before a long wait. It runs the
# REAL gate-eta.zsh and estimate-step.zsh beside it, against fixture gate logs and
# telemetry sinks, with the clock pinned through GATE_ETA_NOW. What these pin:
#   * the gate decision order: estimator error, live, prior from the start line,
#     no data;
#   * the prior for panel, decide, risk and fix, and the passthrough of
#     --repo-type and --sink;
#   * every line shape, and exit 0 whenever a line was printed;
#   * exit 2 with nothing on stdout for each usage error;
#   * the narration rule in reference/review-loop/estimates.md: its three
#     needles, each mutation-checked, no moved block, one heading.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  N="$SCRIPTS/narrate-estimate.zsh"
  RULE="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop/estimates.md"
  START=1791360000
  LOG="$BATS_TEST_TMPDIR/gate-2.stderr"
  K="$BATS_TEST_TMPDIR/telemetry.jsonl"
  : > "$K"
}

# gate_log <total|-> <done> [<scope> <jobs>]: a captured run-gate stderr, with a
# start line when a scope is given
gate_log() {
  local i
  {
    if [ -n "${3-}" ]; then
      echo "run-gate: start epoch=$START mode=parallel scope=$3 jobs=$4"
    fi
    if [ "$1" != "-" ]; then
      echo "1..$1"
    fi
    for ((i = 1; i <= $2; i++)); do echo "ok $i suite test $i"; done
  } > "$LOG"
}

# rec <issue> <step_wall_s_by_round json> [<gate_by_round json>] [<repo_type json>]
rec() {
  jq -cn --argjson i "$1" --argjson sw "$2" --argjson g "${3:-[]}" --argjson rt "${4:-\"claude-plugin\"}" \
    '{schema:"telemetry/v1", kind:"run", pipeline:"review-loop", repo:"timo-jakob/timos-claude-code-plugins",
      repo_type:$rt, issue:$i, ts:$i, wall_s:100, payload:{step_wall_s_by_round:$sw, gate_by_round:$g}}' >> "$K"
}
sw() {  # sw <step> <seconds> -> one round-1 step_wall_s list with only <step> set
  jq -cn --arg s "$1" --argjson v "$2" \
    '[{round:1, step_wall_s:({panel:null, decide:null, risk:null, fix:null} | .[$s] = $v)}]'
}
gate() {  # gate <scope> <wall_s> <jobs> -> one round-1 gate_by_round list
  printf '[{"round":1,"gate":{"scope":"%s","attested":true,"wall_s":%s,"slowest":[],"jobs":%s}}]' "$1" "$2" "$3"
}

narrate() { run --separate-stderr env GATE_ETA_NOW="${AT:-1791360552}" zsh "$N" "$@"; }

# ---- the gate ---------------------------------------------------------------

@test "gate, running with an ETA: the live line is gate-eta's own line" {
  gate_log 1830 412 full 4
  narrate --step gate --gate-log "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: live — 412/1830 tests, 9m12s elapsed, ~31m40s left (jobs=4)" ]
  [ -z "$stderr" ]
}

@test "gate, finished: live, followed by gate-eta's finished line" {
  gate_log 1830 1830 full 4
  echo "run-gate: mode=parallel jobs=4 ok=1830 not_ok=0 total=1830 exit=0 wall_s=2463.512" >> "$LOG"
  narrate --step gate --gate-log "$LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: live — 1830/1830 tests, finished in 41m04s (jobs=4)" ]
}

@test "gate, withheld: the prior for that scope, scaled to the start line's jobs" {
  local i
  for i in 1 2 3 4 5 6; do rec "$i" '[]' "$(gate full 1200 10)"; done
  gate_log 1830 12 full 5
  AT=$((START + 40)) narrate --step gate --gate-log "$LOG" --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: prior — median 40m00s, p80 40m00s over 6 past runs (full gate, scaled to jobs=5)" ]
}

@test "gate, no plan line yet: the prior, never a live line" {
  local i
  for i in 1 2 3 4 5; do rec "$i" '[]' "$(gate selected 120 4)"; done
  gate_log - 0 selected 4
  narrate --step gate --gate-log "$LOG" --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: prior — median 2m00s, p80 2m00s over 5 past runs (selected gate, scaled to jobs=4)" ]
}

@test "gate, no start line: no data, whether withheld or running with no ETA" {
  local i
  for i in 1 2 3 4 5; do rec "$i" '[]' "$(gate full 1200 10)"; done
  gate_log 1830 12
  narrate --step gate --gate-log "$LOG" --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: no estimate (no data)" ]
  gate_log 1830 412
  narrate --step gate --gate-log "$LOG" --sink "$K"
  [ "$output" = "estimate for gate: no estimate (no data)" ]
}

@test "gate, a log gate-eta cannot read: the estimator-error line, exit 0" {
  narrate --step gate --gate-log "$BATS_TEST_TMPDIR/no-such.stderr"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: no estimate (estimator error)" ]
}

@test "gate, a start line estimate-step refuses: the estimator-error line" {
  gate_log 1830 12 partial 4
  narrate --step gate --gate-log "$LOG" --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for gate: no estimate (estimator error)" ]
}

# ---- panel, decide, risk, fix -----------------------------------------------

@test "panel prior: median and p80 as <m>m<ss>s over n past runs" {
  local i=0 p
  for p in 600 660 700 720 900 1200; do i=$((i + 1)); rec "$i" "$(sw panel "$p")"; done
  narrate --step panel --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for panel: prior — median 11m40s, p80 15m00s over 6 past runs" ]
}

@test "fewer than 5 samples: no data, exit 0" {
  local i
  for i in 1 2 3 4; do rec "$i" "$(sw fix 300)"; done
  narrate --step fix --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for fix: no estimate (no data)" ]
}

@test "an unreadable sink: telemetry unreadable, exit 0" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 file"
  rec 1 "$(sw decide 30)"
  chmod 000 "$K"
  narrate --step decide --sink "$K"
  chmod 600 "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for decide: no estimate (telemetry unreadable)" ]
}

@test "--repo-type passes through: a repo type with no samples is no data" {
  local i
  for i in 1 2 3 4 5; do rec "$i" "$(sw risk 40)" '[]' null; done
  narrate --step risk --sink "$K" --repo-type claude-plugin
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for risk: no estimate (no data)" ]
  narrate --step risk --sink "$K"
  [ "$output" = "estimate for risk: prior — median 0m40s, p80 0m40s over 5 past runs" ]
}

@test "a helper missing beside the script: the estimator-error line" {
  local lone="$BATS_TEST_TMPDIR/lone"
  mkdir -p "$lone"
  cp "$N" "$lone/"
  run --separate-stderr zsh "$lone/narrate-estimate.zsh" --step panel --sink "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "estimate for panel: no estimate (estimator error)" ]
  gate_log 1830 412 full 4
  run --separate-stderr zsh "$lone/narrate-estimate.zsh" --step gate --gate-log "$LOG"
  [ "$output" = "estimate for gate: no estimate (estimator error)" ]
}

# ---- usage ------------------------------------------------------------------

@test "usage errors exit 2 with nothing on stdout and a message on stderr" {
  gate_log 1830 412 full 4
  local -a bad
  local args
  for args in "" "--step build" "--step gate" "--step panel --gate-log $LOG" \
              "--step panel --frobnicate" "--step" "--step panel --sink"; do
    read -ra bad <<< "$args"
    narrate "${bad[@]}"
    [ "$status" -eq 2 ] || { echo "args '$args' exited $status"; return 1; }
    [ -z "$output" ] || { echo "args '$args' printed on stdout"; return 1; }
    [ -n "$stderr" ] || { echo "args '$args' printed nothing on stderr"; return 1; }
  done
}

@test "--help prints the header and exits 0" {
  run zsh "$N" --help
  [ "$status" -eq 0 ]
  contains "$output" "narrate-estimate.zsh --step panel|decide|risk|fix|gate"
}

# ---- the narration rule: reference/review-loop/estimates.md ------------------

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# needle_held <file> <needle>: the whitespace-squeezed file contains the needle
needle_held() {
  local text; text="$(flat "$1")"
  contains "$text" "$2"
}

@test "estimates.md states the rule: its three needles" {
  needle_held "$RULE" "never states an unsourced figure"
  needle_held "$RULE" "no estimate (no data)"
  needle_held "$RULE" "its only sources are gate-eta.zsh and estimate-step.zsh"
}

@test "MUTATION: removing each needle sentence from estimates.md reds its check" {
  local cut="$BATS_TEST_TMPDIR/estimates.md" needle
  for needle in "never states an unsourced figure" "no estimate (no data)" \
                "its only sources are gate-eta.zsh and estimate-step.zsh"; do
    flat "$RULE" | NEEDLE="$needle" perl -pe 's/\Q$ENV{NEEDLE}\E//g' > "$cut"
    run needle_held "$cut" "$needle"
    [ "$status" -ne 0 ] || { echo "needle still held after removal: $needle"; return 1; }
  done
}

@test "estimates.md pins its inputs, its cadence and its error rule" {
  needle_held "$RULE" 'print its one stdout line verbatim — no paraphrase, no rounding, nothing added'
  needle_held "$RULE" 'not an estimate carried over from an earlier round, not one worked out from the progress block'
  needle_held "$RULE" 'When the line says `no estimate (no data)`, say exactly that.'
  needle_held "$RULE" '--step panel|decide|risk|fix'
  needle_held "$RULE" '--step gate \ --gate-log <work-dir>/gate-<R>.stderr'
  needle_held "$RULE" "is the round gate"
  needle_held "$RULE" "captured stderr. When you launch the gate at step 2"
  needle_held "$RULE" 'When `<full gate>` is not `run-gate.zsh`, there is no such log'
  needle_held "$RULE" 'printed without running the script.'
  needle_held "$RULE" 'is §1b'
  needle_held "$RULE" 'Omit it when §1b did not run or exited 3.'
  needle_held "$RULE" 'narrated once, immediately before their dispatch.'
  needle_held "$RULE" "narrated once in the boundary turn, after step 3"
  needle_held "$RULE" "s panel dispatch, and once more in each later turn the conductor is woken in anyway"
  needle_held "$RULE" "Never schedule a wake-up or poll in order to re-narrate"
  needle_held "$RULE" "a narration is never a reason to hold a turn open."
  needle_held "$RULE" "It never stops the round, and it never licenses a figure of your own in place of the line."
  needle_held "$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md" \
    "narrating long waits with a sourced estimate or none."
}

@test "estimates.md holds no moved block, and its heading appears exactly once under reference/" {
  run grep -c '<!-- moved:' "$RULE"
  [ "$output" = "0" ]
  local n
  n="$(grep -rlF '### Narrating long waits — a sourced estimate or none (#2198)' \
    "$REPO_ROOT/development/skills/resolve-issue/reference" | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ]
}

@test "review-loop.md lists estimates.md in its read order, after subagents.md" {
  local idx="$REPO_ROOT/development/skills/resolve-issue/reference/review-loop.md" s e
  s="$(grep -n 'reference/review-loop/subagents.md' "$idx" | cut -d: -f1)"
  e="$(grep -n 'reference/review-loop/estimates.md' "$idx" | cut -d: -f1)"
  [ -n "$e" ]
  [ "$e" -gt "$s" ]
}
