#!/usr/bin/env bats
#
# Acceptance cases for "per-step wall_s and an estimate-step prior" (#2197,
# epic #2195 child (b)) — the `cli`-tooled test_cases[] of its story-spec, one
# test per `tc-*` id:
#
#   tc-happy-panel-prior                 #2227
#   tc-happy-gate-scaled                 #2228
#   tc-corner-extended-loop-dedup        #2229
#   tc-corner-pre-change-skipped         #2230
#   tc-corner-null-step-not-zero         #2231
#   tc-corner-scope-filter               #2232
#   tc-corner-jobs-missing-skipped       #2233
#   tc-corner-repo-type-null-excluded    #2234
#   tc-corner-non-run-records-ignored    #2235
#   tc-error-below-threshold             #2236
#   tc-error-absent-sink                 #2237
#   tc-error-gate-without-scope          #2238
#   tc-error-scope-or-jobs-on-non-gate   #2239
#   tc-error-bad-jobs-or-step            #2240
#   tc-error-unreadable-sink             #2241
#   tc-error-malformed-timings           #2242
#
# The use case: timo-platform-builder wants to know, before a round's gate or
# panel starts, how long it usually takes in this repo. The local sink holds
# review-loop records for repo_type claude-plugin; full gates of 1200 s recorded
# at jobs 10 give `estimate-step.zsh --step gate --scope full --jobs 5
# --repo-type claude-plugin` a median and p80 of 2400 s.
#
# The sink is a fixture file; the one loop case runs resolve-story-loop.zsh in
# step mode against a throwaway git repo with detection stubbed. Nothing reaches
# GitHub. The default gate's tests/estimate-step.bats, tests/gate-attest-scope.bats
# and tests/build-telemetry-record.bats cover the same criteria.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  E="$SCRIPTS/estimate-step.zsh"
  LOOP="$SCRIPTS/resolve-story-loop.zsh"
  K="$BATS_TEST_TMPDIR/telemetry.jsonl"
  : > "$K"
  N=0
}

# one review-loop record for timo-jakob/timos-claude-code-plugins
# rec <step_wall_s_by_round json> [<gate_by_round json>] [<repo_type json>] [<issue> <ts> <wall_s>]
rec() {
  N=$((N + 1))
  jq -cn --argjson sw "$1" --argjson g "${2:-[]}" --argjson rt "${3:-\"claude-plugin\"}" \
    --argjson i "${4:-$((2190 + N))}" --argjson ts "${5:-$((1791360000 + N))}" --argjson w "${6:-2400}" \
    '{schema:"telemetry/v1", kind:"run", pipeline:"review-loop",
      repo:"timo-jakob/timos-claude-code-plugins", repo_type:$rt, issue:$i, ts:$ts, wall_s:$w,
      payload:{step_wall_s_by_round:$sw, gate_by_round:$g}}' >> "$K"
}
sw() {  # sw <panel> <decide> <risk> <fix> -> one round-1 step_wall_s list
  printf '[{"round":1,"step_wall_s":{"panel":%s,"decide":%s,"risk":%s,"fix":%s}}]' "$1" "$2" "$3" "$4"
}
gate() {  # gate <scope> <wall_s> <jobs|null> -> one round-1 gate_by_round list
  printf '[{"round":1,"gate":{"scope":"%s","attested":true,"wall_s":%s,"slowest":[],"jobs":%s}}]' "$1" "$2" "$3"
}

est() { run --separate-stderr zsh "$E" --sink "$K" "$@"; }

@test "tc-happy-panel-prior (#2227)" {
  local p
  for p in 600 660 700 720 900 1200; do rec "$(sw "$p" null 45 null)"; done
  est --step panel
  [ "$status" -eq 0 ]
  [ "$output" = '{"step":"panel","scope":null,"jobs":null,"repo_type":null,"n":6,"median_s":700,"p80_s":900}' ]
}

@test "tc-happy-gate-scaled (#2228)" {
  local i
  for i in 1 2 3 4 5; do rec '[]' "$(gate full 1200 10)"; done
  est --step gate --scope full --jobs 5 --repo-type claude-plugin
  [ "$status" -eq 0 ]
  [ "$output" = '{"step":"gate","scope":"full","jobs":5,"repo_type":"claude-plugin","n":5,"median_s":2400,"p80_s":2400}' ]
}

@test "tc-corner-extended-loop-dedup (#2229)" {
  local r3 r5 r
  r3='['; r5='['
  for r in 1 2 3; do r3+="{\"round\":$r,\"step_wall_s\":{\"panel\":$((r * 100)),\"decide\":null,\"risk\":null,\"fix\":null}},"; done
  for r in 1 2 3 4 5; do r5+="{\"round\":$r,\"step_wall_s\":{\"panel\":$((r * 100)),\"decide\":null,\"risk\":null,\"fix\":null}},"; done
  r3="${r3%,}]"; r5="${r5%,}]"
  rec "$r3" '[]' '"claude-plugin"' 2196 1791360000 3000
  rec "$r5" '[]' '"claude-plugin"' 2196 1791360000 5000
  est --step panel
  [ "$status" -eq 0 ]
  jq -e '.n == 5' <<< "$output"
}

@test "tc-corner-pre-change-skipped (#2230)" {
  local i
  for i in 1 2 3 4 5 6; do
    jq -cn --argjson i "$i" '{kind:"run", pipeline:"review-loop", repo:"timo-jakob/timos-claude-code-plugins",
      issue:$i, ts:$i, wall_s:600, payload:{findings_by_round:[], gate_by_round:[]}}' >> "$K"
  done
  est --step panel
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "estimate-step: 0 samples, fewer than 5 — withheld" ]
}

@test "tc-corner-null-step-not-zero (#2231)" {
  local i
  for i in 1 2 3 4 5; do rec "$(sw 600 null 45 null)"; done
  for i in 1 2 3 4 5; do rec "$(sw 600 30 45 null)"; done
  est --step decide
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 30' <<< "$output"
}

@test "tc-corner-scope-filter (#2232)" {
  local w
  for w in 1790 1800 1805 1810 1795; do rec '[]' "$(gate full "$w" 10)"; done
  for w in 118 120 122 119 121; do rec '[]' "$(gate selected "$w" 10)"; done
  est --step gate --scope selected
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 120' <<< "$output"
}

@test "tc-corner-jobs-missing-skipped (#2233)" {
  local i
  for i in 1 2 3; do rec '[]' "$(gate full 900 null)"; done
  for i in 1 2 3 4 5; do rec '[]' "$(gate full 1200 8)"; done
  est --step gate --scope full --jobs 4
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 2400' <<< "$output"
}

@test "tc-corner-repo-type-null-excluded (#2234)" {
  local i
  for i in 1 2 3 4 5; do rec "$(sw 600 null 45 null)"; done
  for i in 1 2 3 4 5; do rec "$(sw 900 null 45 null)" '[]' null; done
  est --step panel --repo-type claude-plugin
  [ "$status" -eq 0 ]
  jq -e '.n == 5 and .median_s == 600' <<< "$output"
  est --step panel
  [ "$status" -eq 0 ]
  jq -e '.n == 10' <<< "$output"
}

@test "tc-corner-non-run-records-ignored (#2235)" {
  local i
  for i in 1 2 3 4; do rec "$(sw 600 null 45 null)"; done
  local slow; slow="$(sw 9000 null 45 null)"
  jq -cn --argjson sw "$slow" '{kind:"enrichment", pipeline:"review-loop",
    repo:"timo-jakob/timos-claude-code-plugins", issue:1, ts:1, wall_s:1, payload:{step_wall_s_by_round:$sw}}' >> "$K"
  jq -cn --argjson sw "$slow" '{kind:"run", pipeline:"refine-issue",
    repo:"timo-jakob/timos-claude-code-plugins", issue:2, ts:2, wall_s:1, payload:{step_wall_s_by_round:$sw}}' >> "$K"
  est --step panel
  [ "$status" -eq 1 ]
  [ "$stderr" = "estimate-step: 4 samples, fewer than 5 — withheld" ]
}

@test "tc-error-below-threshold (#2236)" {
  local p
  for p in 600 660 700 720; do rec "$(sw "$p" null 45 null)"; done
  est --step panel
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "estimate-step: 4 samples, fewer than 5 — withheld" ]
}

@test "tc-error-absent-sink (#2237)" {
  run --separate-stderr zsh "$E" --step panel --sink /nonexistent.jsonl
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "estimate-step: 0 samples, fewer than 5 — withheld" ]
}

@test "tc-error-gate-without-scope (#2238)" {
  est --step gate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--scope"
}

@test "tc-error-scope-or-jobs-on-non-gate (#2239)" {
  est --step panel --scope full
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  est --step fix --jobs 4
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "tc-error-bad-jobs-or-step (#2240)" {
  est --step gate --scope full --jobs 0
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  est --step gate --scope full --jobs x
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  est --step build
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  est --step panel --frobnicate
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "tc-error-unreadable-sink (#2241)" {
  [ "$(id -u)" -ne 0 ] || skip "root can read a mode-000 file"
  rec "$(sw 600 null 45 null)"
  chmod 000 "$K"
  est --step panel
  chmod 600 "$K"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "tc-error-malformed-timings (#2242)" {
  local R="$BATS_TEST_TMPDIR/repo" WD="$BATS_TEST_TMPDIR/wd" ST="$BATS_TEST_TMPDIR/status.json"
  local F="$BATS_TEST_TMPDIR/findings.json" T="$BATS_TEST_TMPDIR/timings.json" STUB="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "{\\"languages\\":[\\"python\\"]}"\n' > "$STUB"
  chmod +x "$STUB"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name tester
  echo base > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" branch -M main
  echo "print(1)" > "$R/app.py"
  printf '%s' '[{"severity":"CRITICAL","dimension":"bugs","file":"app.py","line":1,"title":"T","description":"d","reviewer":"r"}]' > "$F"
  printf '[1,2]' > "$T"
  run --separate-stderr env DETECT_STACK_BIN="$STUB" \
    zsh "$LOOP" --repo "$R" --base main --work-dir "$WD" --findings-file "$F" --status-file "$ST" \
    --step-timings "$T"
  [ "$status" -eq 20 ]
  jq -e '.history[0].step_wall_s == {panel:null, decide:null, risk:null, fix:null}
         and (.history | length) == 1' "$ST"
  contains "$stderr" "--step-timings is not one JSON object"
}
