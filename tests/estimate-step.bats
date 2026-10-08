#!/usr/bin/env bats
#
# Behavioural tests for estimate-step.zsh (#2197, epic #2195 child (b)): the
# read-only prior for how long one review-loop step usually takes, from the
# local telemetry sink. What these pin down:
#   * only kind "run", pipeline "review-loop" records count; a line that is not
#     JSON is skipped;
#   * records grouped by [repo, issue, ts] keep their largest-wall_s record, and
#     its per-round entries are deduplicated by round, last wins;
#   * a null or missing value is no sample, never 0;
#   * gate samples are filtered by --scope and scaled by --jobs, and a sample
#     with no recorded jobs is skipped when --jobs is given;
#   * --repo-type keeps only that envelope repo_type, never a null one;
#   * nearest-rank median and p80, rounded half-up, and the n >= 5 floor;
#   * exits 0 / 1 / 2 / 3 with nothing on stdout except on 0.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  E="$REPO_ROOT/development/skills/resolve-issue/scripts/estimate-step.zsh"
  K="$BATS_TEST_TMPDIR/telemetry.jsonl"
  : > "$K"
}

# rec <issue> <ts> <wall_s> <step_wall_s_by_round json> [<gate_by_round json>] [<repo_type json>]
rec() {
  jq -cn --argjson i "$1" --argjson ts "$2" --argjson w "$3" --argjson sw "$4" \
    --argjson g "${5:-[]}" --argjson rt "${6:-\"claude-plugin\"}" \
    '{schema:"telemetry/v1", kind:"run", pipeline:"review-loop", repo:"timo-jakob/plugins",
      repo_type:$rt, issue:$i, ts:$ts, wall_s:$w,
      payload:{step_wall_s_by_round:$sw, gate_by_round:$g}}' >> "$K"
}

# one record per value, one round each, for <step>
panel_recs() {  # $@ = panel seconds
  local i=0 p
  for p in "$@"; do
    i=$((i + 1))
    rec "$i" "$((1000 + i))" 100 "[{\"round\":1,\"step_wall_s\":{\"panel\":$p,\"decide\":null,\"risk\":null,\"fix\":null}}]"
  done
}

# one record per gate, one round each: <scope> <wall_s> <jobs|null>
gate_rec() {
  local i; i=$(( $(wc -l < "$K") + 1 ))
  rec "$i" "$((2000 + i))" 100 '[]' "[{\"round\":1,\"gate\":{\"scope\":\"$1\",\"attested\":true,\"wall_s\":$2,\"slowest\":[],\"jobs\":$3}}]"
}

est() { run --separate-stderr zsh "$E" --sink "$K" "$@"; }

# ---- the statistics ---------------------------------------------------------

@test "panel prior: nearest-rank median and p80 over six samples" {
  panel_recs 600 660 700 720 900 1200
  est --step panel
  [ "$status" -eq 0 ]
  [ "$output" = '{"step":"panel","scope":null,"jobs":null,"repo_type":null,"n":6,"median_s":700,"p80_s":900}' ]
}

@test "the n >= 5 floor: four samples are withheld, five are not" {
  panel_recs 600 660 700 720
  est --step panel
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "estimate-step: 4 samples, fewer than 5 — withheld" ]
  rec 9 1009 100 '[{"round":1,"step_wall_s":{"panel":900,"decide":null,"risk":null,"fix":null}}]'
  est --step panel
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 700 and .p80_s == 720' <<< "$output"
}

@test "values are rounded half-up after scaling" {
  local g
  for g in 100 100 100 101 101; do gate_rec full "$g" 3; done
  # 100 x 3 / 2 = 150 ; 101 x 3 / 2 = 151.5 -> 152
  est --step gate --scope full --jobs 2
  [ "$status" -eq 0 ]
  jq -e '.median_s == 150 and .p80_s == 152' <<< "$output"
}

# ---- what counts as a sample ------------------------------------------------

@test "overlapping records of one extended loop: the largest-wall_s record of the group wins" {
  local r3='[{"round":1,"step_wall_s":{"panel":10,"decide":null,"risk":null,"fix":null}},{"round":2,"step_wall_s":{"panel":20,"decide":null,"risk":null,"fix":null}},{"round":3,"step_wall_s":{"panel":30,"decide":null,"risk":null,"fix":null}}]'
  local r5='[{"round":1,"step_wall_s":{"panel":10,"decide":null,"risk":null,"fix":null}},{"round":2,"step_wall_s":{"panel":20,"decide":null,"risk":null,"fix":null}},{"round":3,"step_wall_s":{"panel":30,"decide":null,"risk":null,"fix":null}},{"round":4,"step_wall_s":{"panel":40,"decide":null,"risk":null,"fix":null}},{"round":5,"step_wall_s":{"panel":50,"decide":null,"risk":null,"fix":null}}]'
  rec 7 5000 3000 "$r3"
  rec 7 5000 5000 "$r5"
  est --step panel
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 30' <<< "$output"
}

@test "per-round entries are deduplicated by round, last wins" {
  local sw='[{"round":1,"step_wall_s":{"panel":999,"decide":null,"risk":null,"fix":null}},{"round":1,"step_wall_s":{"panel":10,"decide":null,"risk":null,"fix":null}},{"round":2,"step_wall_s":{"panel":20,"decide":null,"risk":null,"fix":null}},{"round":3,"step_wall_s":{"panel":30,"decide":null,"risk":null,"fix":null}},{"round":4,"step_wall_s":{"panel":40,"decide":null,"risk":null,"fix":null}},{"round":5,"step_wall_s":{"panel":50,"decide":null,"risk":null,"fix":null}}]'
  rec 1 1000 100 "$sw"
  est --step panel
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .p80_s == 40' <<< "$output"
}

@test "a null step is no sample, never 0" {
  local i
  for i in 1 2 3 4 5; do
    rec "$i" "$((1000 + i))" 100 '[{"round":1,"step_wall_s":{"panel":60,"decide":null,"risk":null,"fix":null}}]'
  done
  for i in 6 7 8 9 10; do
    rec "$i" "$((1000 + i))" 100 '[{"round":1,"step_wall_s":{"panel":60,"decide":30,"risk":null,"fix":null}}]'
  done
  est --step decide
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 30' <<< "$output"
}

@test "records written before #2197 contribute nothing" {
  local i
  for i in 1 2 3 4 5 6; do
    jq -cn --argjson i "$i" '{kind:"run", pipeline:"review-loop", repo:"o/r", issue:$i, ts:$i, wall_s:1,
      payload:{gate_by_round:[{round:1, gate:{scope:"full", attested:true, wall_s:100, slowest:[]}}]}}' >> "$K"
  done
  est --step panel
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "estimate-step: 0 samples, fewer than 5 — withheld" ]
}

@test "only kind run, pipeline review-loop records count; a non-JSON line is skipped" {
  panel_recs 10 20 30 40
  jq -cn '{kind:"enrichment", pipeline:"review-loop", repo:"o/r", issue:90, ts:1, wall_s:1,
    payload:{step_wall_s_by_round:[{round:1, step_wall_s:{panel:5000, decide:null, risk:null, fix:null}}]}}' >> "$K"
  jq -cn '{kind:"run", pipeline:"refine-issue", repo:"o/r", issue:91, ts:1, wall_s:1,
    payload:{step_wall_s_by_round:[{round:1, step_wall_s:{panel:5000, decide:null, risk:null, fix:null}}]}}' >> "$K"
  echo 'not json at all' >> "$K"
  est --step panel
  [ "$status" -eq 1 ]
  [ "$stderr" = "estimate-step: 4 samples, fewer than 5 — withheld" ]
}

# ---- the gate: scope and jobs -----------------------------------------------

@test "gate: five full gates of 1200 s at jobs 10, scaled to jobs 5" {
  local i
  for i in 1 2 3 4 5; do gate_rec full 1200 10; done
  est --step gate --scope full --jobs 5
  [ "$status" -eq 0 ]
  [ "$output" = '{"step":"gate","scope":"full","jobs":5,"repo_type":null,"n":5,"median_s":2400,"p80_s":2400}' ]
}

@test "gate: --scope keeps only gates of that scope" {
  local i
  for i in 1800 1810 1790 1805 1795; do gate_rec full "$i" 10; done
  for i in 120 118 122 119 121; do gate_rec selected "$i" 10; done
  est --step gate --scope selected
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 120 and .scope == "selected"' <<< "$output"
}

@test "gate: with --jobs, a sample with no recorded jobs is skipped; without it, it counts raw" {
  local i
  for i in 1 2 3; do gate_rec full 600 null; done
  for i in 1 2 3 4 5; do gate_rec full 1200 8; done
  est --step gate --scope full --jobs 4
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 2400' <<< "$output"
  est --step gate --scope full
  [ "$status" -eq 0 ]
  jq -e '.n == 8 and .jobs == null' <<< "$output"
}

# ---- --repo-type ------------------------------------------------------------

@test "--repo-type keeps only that repo_type and never a null one; omitted, both count" {
  local i
  for i in 1 2 3 4 5; do
    rec "$i" "$((3000 + i))" 100 '[{"round":1,"step_wall_s":{"panel":null,"decide":null,"risk":40,"fix":null}}]'
  done
  for i in 6 7 8 9 10; do
    rec "$i" "$((3000 + i))" 100 '[{"round":1,"step_wall_s":{"panel":null,"decide":null,"risk":80,"fix":null}}]' '[]' null
  done
  est --step risk --repo-type claude-plugin
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 40 and .repo_type == "claude-plugin"' <<< "$output"
  est --step risk
  [ "$status" -eq 0 ]
  jq -e '.n == 10' <<< "$output"
  est --step risk --repo-type go
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---- exits ------------------------------------------------------------------

@test "an absent sink is 0 samples, exit 1" {
  run --separate-stderr zsh "$E" --step fix --sink "$BATS_TEST_TMPDIR/no-such.jsonl"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "estimate-step: 0 samples, fewer than 5 — withheld" ]
}

@test "the default sink is .claude/telemetry/telemetry.jsonl under the current directory" {
  mkdir -p "$BATS_TEST_TMPDIR/proj/.claude/telemetry"
  panel_recs 600 660 700 720 900 1200
  cp "$K" "$BATS_TEST_TMPDIR/proj/.claude/telemetry/telemetry.jsonl"
  cd "$BATS_TEST_TMPDIR/proj"
  run --separate-stderr zsh "$E" --step panel
  [ "$status" -eq 0 ]
  jq -e '.n == 6' <<< "$output"
}

@test "an unreadable sink is exit 3, nothing on stdout" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 file"
  panel_recs 600 660 700 720 900
  chmod 000 "$K"
  est --step panel
  chmod 600 "$K"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  contains "$stderr" "cannot read the sink"
}

@test "a directory as the sink is exit 3" {
  run --separate-stderr zsh "$E" --step panel --sink "$BATS_TEST_TMPDIR"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

@test "usage errors are exit 2 with nothing on stdout" {
  local -a bad
  local args
  for args in "" "--step build" "--step gate" "--step gate --scope partial" \
              "--step panel --scope full" "--step fix --jobs 4" \
              "--step gate --scope full --jobs 0" "--step gate --scope full --jobs x" \
              "--step panel --frobnicate" "--step"; do
    read -ra bad <<< "$args"
    est "${bad[@]}"
    [ "$status" -eq 2 ] || { echo "args '$args' exited $status"; return 1; }
    [ -z "$output" ] || { echo "args '$args' printed on stdout"; return 1; }
    [ -n "$stderr" ] || { echo "args '$args' printed nothing on stderr"; return 1; }
  done
}

@test "--help prints the header and exits 0" {
  run zsh "$E" --help
  [ "$status" -eq 0 ]
  contains "$output" "estimate-step.zsh --step panel|decide|risk|fix|gate"
}

@test "read-only: the sink is byte-identical afterwards" {
  panel_recs 600 660 700 720 900 1200
  local before; before="$(cksum < "$K")"
  est --step panel
  [ "$status" -eq 0 ]
  [ "$(cksum < "$K")" = "$before" ]
}
