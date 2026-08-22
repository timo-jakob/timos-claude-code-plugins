#!/usr/bin/env bats
#
# Behavioral tests for build-telemetry-record.zsh (#566): the review-loop
# PAYLOAD for one `telemetry/v1` record, and the documented jq one-liners that
# turn a file of records into the three headline metrics (convergence rate, mean
# rounds, escalation breakdown). Epic #557; retrofitted onto the shared contract
# by epic #740's child (b) — issue #1004.
#
# Since #1004 this script builds ONLY the payload: the envelope belongs to
# development/scripts/telemetry/emit-telemetry.zsh. The payload's *values* are
# unchanged by that move — the derivations below are the same ones the
# pre-contract record carried at its top level — so these tests double as the
# "moved, not re-derived" evidence.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/resolve-issue/scripts/build-telemetry-record.zsh"
  EMIT="$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"
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

@test "one run produces exactly one payload object with the expected fields" {
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '')" -eq 1 ]     # single line
  echo "$output" | jq -e '. | type == "object"' >/dev/null
  [ "$(echo "$output" | jq -r '.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq -r '.escalation')" = "null" ]
  [ "$(echo "$output" | jq '.rounds')" -eq 2 ]
  [ "$(echo "$output" | jq '.max_rounds')" -eq 3 ]
  [ "$(echo "$output" | jq '.fixed')" -eq 1 ]            # the blocker was fixed
  [ "$(echo "$output" | jq '.waived')" -eq 1 ]           # the Low was logged/waived
  # findings per round in the USER-FACING severity vocabulary (#969)
  [ "$(echo "$output" | jq '.findings_by_round[0].by_severity.Critical')" -eq 1 ]
  [ "$(echo "$output" | jq '.findings_by_round[0].by_severity.Warning')" -eq 0 ]
  [ "$(echo "$output" | jq '.findings_by_round[0].by_severity.Suggestion')" -eq 1 ]
  # `round` is what every per-round join keys on — a regression to null would
  # otherwise ship silently, since no other assertion reads it
  [ "$(echo "$output" | jq '.findings_by_round[0].round')" -eq 1 ]
  [ "$(echo "$output" | jq '.findings_by_round[1].round')" -eq 2 ]
  # by_dimension merges blockers AND suggestions: assert BOTH halves, or
  # dropping the suggestions half of that merge stays green
  [ "$(echo "$output" | jq '.findings_by_round[0].by_dimension.bugs')" -eq 1 ]
  [ "$(echo "$output" | jq '.findings_by_round[0].by_dimension.code_quality')" -eq 1 ]
}

@test "the payload carries NO envelope key — the emitter owns those (#1004)" {
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  # every telemetry/v1 envelope key must be absent, so no consumer has two
  # places to read one fact. repo_type is included deliberately: it moved OUT
  # of this payload and into the envelope, which the loop supplies.
  local k
  for k in schema kind run_id parent_run_id ts repo repo_type pipeline issue pr \
           outcome wall_s tokens payload; do
    echo "$output" | jq -e --arg k "$k" 'has($k) | not' >/dev/null \
      || { echo "payload must not carry the envelope key: $k"; return 1; }
  done
  # ...and exactly the payload keys it does own
  [ "$(echo "$output" | jq -c 'keys_unsorted | sort')" = \
    '["convergence_assessment","escalation","findings_by_round","fixed","max_rounds","promotion_phase","rounds","status","waived"]' ]
}

@test "the payload embeds into a telemetry/v1 record the validator accepts (#1004)" {
  # the whole point of the retrofit: builder -> emitter -> a conformant record
  local R="$BATS_TEST_TMPDIR/emitrepo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" remote add origin https://github.com/timo-jakob/widget.git
  local P="$BATS_TEST_TMPDIR/payload.json"
  zsh "$S" --status "$ST" > "$P"

  run zsh "$EMIT" --pipeline review-loop --kind run --outcome success \
    --repo-dir "$R" --repo-type python --issue 1004 --ts 1720000000 --wall-s 42 \
    --payload "$P"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.schema')" = "telemetry/v1" ]
  [ "$(echo "$output" | jq -r '.pipeline')" = "review-loop" ]
  [ "$(echo "$output" | jq -r '.repo')" = "timo-jakob/widget" ]
  [ "$(echo "$output" | jq -r '.repo_type')" = "python" ]
  [ "$(echo "$output" | jq '.issue')" -eq 1004 ]
  [ "$(echo "$output" | jq '.wall_s')" -eq 42 ]
  [ "$(echo "$output" | jq -r '.tokens')" = "null" ]
  # the payload rode along unmodified — by EQUALITY, not by sampling a few
  # fields, so a dropped/reordered/re-encoded key cannot slip through (AC2)
  [ "$(echo "$output" | jq -cS '.payload')" = "$(jq -cS '.' "$P")" ]
  [ "$(echo "$output" | jq -r '.payload.status')" = "CONVERGED" ]
  [ "$(echo "$output" | jq -c '.payload.convergence_assessment.blocking_by_round')" = "[1,0]" ]

  run zsh "$VALIDATE" "$R/.claude/telemetry/telemetry.jsonl" --require-records
  [ "$status" -eq 0 ]
}

@test "per-round false_trips is recorded from summary.false_trips, null on a pre-#983 round (#983)" {
  cat > "$ST" <<'EOF'
{"status":"CONVERGED","rounds":3,"max_rounds":3,"repo_type":"python","escalation_reasons":[],
 "round_changelists":[
  {"round":1,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0,"false_trips":0},
   "blocking":[{"priority":"Critical","dimension":"bugs","file":"a.py","line":1,"title":"b1"}],"suggestions":[]},
  {"round":2,"summary":{"critical":1,"high":0,"low":0,"blocking":1,"conflicts":0,"false_trips":1},
   "blocking":[{"priority":"Critical","dimension":"bugs","file":"a.py","line":3,"title":"new","non_converging":false,"false_trip":true,"matched_prior":{"line":1,"title":"b1"}}],"suggestions":[]},
  {"round":3,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0},"blocking":[],"suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.findings_by_round[0].false_trips')" -eq 0 ]
  [ "$(echo "$output" | jq '.findings_by_round[1].false_trips')" -eq 1 ]
  # round 3 has a summary that OMITS false_trips (a pre-#983 changelist) ->
  # honest null, not a confident 0
  [ "$(echo "$output" | jq -r '.findings_by_round[2].false_trips')" = "null" ]
  # #983 x #969: the false-trip blocker is stamped non_converging:false, so it
  # counts as NEW (not carried) and does NOT suppress the prior round's fixed
  # count — a false trip is a fresh finding, not a stuck one
  [ "$(echo "$output" | jq '.findings_by_round[1].new')" -eq 1 ]
  [ "$(echo "$output" | jq '.findings_by_round[1].carried')" -eq 0 ]
  [ "$(echo "$output" | jq '.findings_by_round[1].fixed_from_prev')" -eq 1 ]
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
  run zsh "$S" --status "$ST"
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
  run zsh "$S" --status "$ST"
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
  run zsh "$S" --status "$ST"
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
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.convergence_assessment')" = "null" ]
  cat > "$ST" <<'EOF'
{"status":"AWAITING_FIX","rounds":1,"max_rounds":3,"repo_type":"python",
 "round_changelists":[{"round":1,"blocking":[{"priority":"High","dimension":"tests","file":"t.py","line":1,"title":"t1","non_converging":false}],"suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST"
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
  run zsh "$S" --status "$ST"
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
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.trend')" = "regressing" ]
  [ "$(echo "$output" | jq -r '.convergence_assessment.blockers_moving')" = "false" ]
}

@test "documented jq one-liners produce the three summary metrics over v1 records" {
  # These are the EXACT expressions ARCHITECTURE.md documents (section
  # "Review-loop telemetry"); if the doc changes, this test must change with it.
  local R="$BATS_TEST_TMPDIR/metricsrepo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" remote add origin https://github.com/timo-jakob/widget.git
  local F="$R/.claude/telemetry/telemetry.jsonl"
  local P="$BATS_TEST_TMPDIR/payload.json"

  zsh "$S" --status "$ST" > "$P"                                   # CONVERGED, 2 rounds
  zsh "$EMIT" --pipeline review-loop --outcome success --repo-dir "$R" \
    --issue 601 --ts 1720000000 --wall-s 10 --payload "$P" >/dev/null
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":3,"max_rounds":3,"repo_type":"python","round_changelists":[],"final_changelist":{"blocking":[]}}
EOF
  zsh "$S" --status "$ST" > "$P"                                   # escalated, 3 rounds
  zsh "$EMIT" --pipeline review-loop --outcome escalated --repo-dir "$R" \
    --issue 602 --ts 1720000002 --wall-s 20 --payload "$P" >/dev/null
  # a SKIPPED (--no-review) run: reviewed nothing, so it must not drag the
  # convergence rate down — the documented expression excludes it
  cat > "$ST" <<'EOF'
{"status":"SKIPPED","rounds":0,"max_rounds":3,"repo_type":null,"round_changelists":[],"final_changelist":null}
EOF
  zsh "$S" --status "$ST" > "$P"
  zsh "$EMIT" --pipeline review-loop --outcome success --repo-dir "$R" \
    --issue 604 --ts 1720000006 --wall-s 1 --payload "$P" >/dev/null

  # a PROMOTION sub-loop record (#995): a second pass over the SAME story, not a
  # story of its own — the rate recipes exclude it via promotion_phase
  cat > "$ST" <<'EOF'
{"status":"CONVERGED","rounds":1,"max_rounds":5,"promotion_phase":true,"repo_type":"python","round_changelists":[],"final_changelist":{"blocking":[]}}
EOF
  zsh "$S" --status "$ST" > "$P"
  # strict: jq -r prints the boolean true and the STRING "true" identically,
  # while the documented predicate below is a strict JSON comparison
  jq -e '.promotion_phase == true' "$P" >/dev/null
  zsh "$EMIT" --pipeline review-loop --outcome success --repo-dir "$R" \
    --issue 601 --ts 1720000008 --wall-s 30 --payload "$P" >/dev/null

  # a foreign pipeline sharing the sink must not skew review-loop's metrics
  printf '{}' > "$P"
  zsh "$EMIT" --pipeline refine-issue --outcome success --repo-dir "$R" \
    --issue 603 --ts 1720000004 --wall-s 5 --payload "$P" >/dev/null
  # ...and neither must an ENRICHMENT record: its outcome describes the
  # enrichment event, not the run, so every query filters kind=="run"
  zsh "$EMIT" --pipeline review-loop --kind enrichment --outcome success \
    --repo-dir "$R" --run-id review-loop-1720000000-abcd --ts 1720000010 \
    --payload "$P" >/dev/null

  local RL='[.[] | select(.kind == "run" and .pipeline == "review-loop")]'
  # terminal-record convergence rate (SKIPPED excluded, guarded divisor)
  [ "$(jq -s "$RL"' | map(select(.payload.status != "SKIPPED"))
    | map(select(.payload.promotion_phase != true))
    | if length == 0 then null else ([.[] | select(.payload.status == "CONVERGED")] | length) / length end' "$F")" = "0.5" ]
  # mean rounds to converge — CONVERGED records ONLY, never averaged over all
  # (averaging every record would give 6/4; the doc forbids exactly that).
  # DELIBERATELY unpredicated: the promotion pass's own CONVERGED record counts
  # here, because it genuinely ran that round — (2 + 1) / 2. A predicate copied
  # in from the rate recipes above would silently drop real rounds.
  [ "$(jq -s "$RL"' | [.[] | select(.payload.status == "CONVERGED")]
    | if length == 0 then null else (map(.payload.rounds) | add) / length end' "$F")" = "1.5" ]
  # ...and the promotion predicate is LOAD-BEARING, not decorative: without it
  # the promotion pass counts as its own story and the rate moves
  [ "$(jq -s "$RL"' | map(select(.payload.status != "SKIPPED"))
    | if length == 0 then null else ([.[] | select(.payload.status == "CONVERGED")] | length) / length end' "$F")" = "0.6666666666666666" ]
  # escalation breakdown — deliberately NOT predicated: a promotion pass
  # genuinely did those rounds (ARCHITECTURE.md, Review-loop telemetry)
  run jq -s "$RL"' | group_by(.payload.escalation) | map({(.[0].payload.escalation | tostring): length}) | add' "$F"
  echo "$output" | jq -e '.BUDGET_EXHAUSTED == 1' >/dev/null
  # the null bucket is the DANGEROUS half: it means "not an escalation", not
  # "succeeded" — here the two CONVERGED records (phase-1 + the promotion pass)
  # and the SKIPPED one
  echo "$output" | jq -e '.["null"] == 3' >/dev/null
  # the cross-pipeline enum groups the shared sink without reading any payload —
  # 4 successes (3 review-loop: CONVERGED, SKIPPED, the promotion pass; plus 1
  # refine-issue), the enrichment excluded
  [ "$(jq -s '[.[] | select(.kind == "run")] | group_by(.outcome) | map({(.[0].outcome): length}) | add | .success' "$F")" -eq 4 ]
}

@test "ARCHITECTURE.md's rate recipes really carry the promotion predicate (doc-drift pin)" {
  # The recipes ARE the deliverable — no script executes them, and the four
  # copies in this file are hand-typed under a comment saying "if the doc
  # changes, this test must change with it". That convention is unenforced in
  # the doc->test direction: deleting the promotion predicate from ARCHITECTURE
  # (or adding it to the mean-rounds cut, which the doc explicitly forbids)
  # leaves every test here green while the published rates silently re-inflate.
  # Same discipline the sibling suites apply to SKILL.md's fences.
  local arch_flat
  arch_flat=$(tr '\n' ' ' < "$REPO_ROOT/ARCHITECTURE.md" | tr -s ' ')
  # both RATE recipes carry it — two occurrences, not one
  [ "$(grep -o 'map(select(.payload.promotion_phase != true))' "$REPO_ROOT/ARCHITECTURE.md" | grep -c .)" -eq 2 ]
  contains "$arch_flat" 'map(select(.payload.status != "SKIPPED")) | map(select(.payload.promotion_phase != true))'
  # ...and the mean-rounds cut deliberately does NOT: a promotion pass genuinely
  # ran those rounds
  local mean_recipe
  mean_recipe=$(sed -n '/# mean rounds to converge/,/^# escalation breakdown/p' "$REPO_ROOT/ARCHITECTURE.md")
  [ -n "$mean_recipe" ]
  run ! grep -q 'promotion_phase' <<< "$mean_recipe"
}

@test "the documented rate one-liners yield null on a record-less stream, not a division error" {
  local F="$BATS_TEST_TMPDIR/empty.jsonl"
  : > "$F"
  local RL='[.[] | select(.kind == "run" and .pipeline == "review-loop")]'
  run jq -s "$RL"' | map(select(.payload.status != "SKIPPED"))
    | map(select(.payload.promotion_phase != true))
    | if length == 0 then null else ([.[] | select(.payload.status == "CONVERGED")] | length) / length end' "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
  run jq -s "$RL"' | [.[] | select(.payload.status == "CONVERGED")]
    | if length == 0 then null else (map(.payload.rounds) | add) / length end' "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "usage: --status is required (exit 2)" {
  run zsh "$S"
  [ "$status" -eq 2 ]
}

@test "usage: the envelope flags are gone — the emitter owns them now (exit 2)" {
  # a caller still passing --issue/--ts/--wall-s is wiring this to the OLD
  # contract; failing loudly beats silently dropping the value
  for f in --issue --ts --wall-s; do
    run zsh "$S" --status "$ST" "$f" 1
    [ "$status" -eq 2 ] || { echo "$f should be rejected, got $status"; return 1; }
  done
}

@test "usage: --status with no value is a usage error, not a bogus 'invalid status JSON'" {
  run zsh "$S" --status
  [ "$status" -eq 2 ]
}

@test "usage: an empty or flag-shaped --status value is a usage error (exit 2)" {
  # the whole point of the _need_val guard: under `nounset` these would abort
  # with a raw zsh parameter error and exit 1, misreporting a caller mistake as
  # "invalid status JSON"
  # assert the GUARD's own message: with _need_val removed both cases still
  # exit 2 via the downstream operand checks, so the exit code alone pins
  # nothing — only the message discriminates
  run zsh "$S" --status ""
  [ "$status" -eq 2 ]
  contains "$output" "requires a non-empty value"
  run zsh "$S" --status --help
  [ "$status" -eq 2 ]
  contains "$output" "requires a non-empty value"
}

@test "usage: --status pointing at a directory is exit 2, not a bogus 'invalid status JSON'" {
  # a directory has non-zero size, so it sails past a bare -s check
  run zsh "$S" --status "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]
}

@test "internal: invalid status JSON is exit 1, not a crash" {
  echo 'not json' > "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 1 ]
}

@test "a nonexistent --status path is a USAGE error (2), a zero-byte one is INTERNAL (1)" {
  # the two are different mistakes and must stay distinguishable: a caller path
  # typo is exit 2 (the sibling emitter's operand policy), while a file that
  # exists and is empty means the loop produced nothing — exit 1
  run zsh "$S" --status "$BATS_TEST_TMPDIR/no/such/file.json"
  [ "$status" -eq 2 ]
  : > "$ST"
  run zsh "$S" --status "$ST"
  [ "$status" -eq 1 ]
}

@test "internal: a whitespace-only status file is exit 1, never a silent empty payload" {
  # -s passes (non-zero size) but jq emits NOTHING and exits 0, so without the
  # single-object guard this would exit 0 having produced no payload at all —
  # and the emitter would then wrap an empty --payload in a valid envelope
  printf '   \n\n' > "$ST"
  # separate-stderr so $output is stdout ALONE — the point is that no payload
  # was printed, and bats would otherwise merge the diagnostic into it
  run --separate-stderr zsh "$S" --status "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "internal: a concatenated multi-document status file is exit 1, never two payload lines" {
  # jq runs the program per document, so this would emit TWO payload objects
  # where the contract allows exactly one
  cat > "$ST" <<'EOF'
{"status":"CONVERGED","rounds":1,"max_rounds":3,"repo_type":"python","round_changelists":[],"final_changelist":{"blocking":[]}}
{"status":"CONVERGED","rounds":2,"max_rounds":3,"repo_type":"python","round_changelists":[],"final_changelist":{"blocking":[]}}
EOF
  run --separate-stderr zsh "$S" --status "$ST"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "the documented first-pass one-liner pins min_by, and the ordering rule pins max_by, in OPPOSITE directions" {
  # An EXTENDED loop is the whole point: escalate -> grant -> --resume ->
  # converge emits two records sharing one `ts`, and first-pass must count it
  # as a MISS while the ordering rule reports its FINAL outcome as a success.
  # A min<->max flip, a dropped SKIPPED filter, or a changed grouping key would
  # otherwise ship green — the doc flags exactly this regression.
  local R="$BATS_TEST_TMPDIR/fprepo"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" remote add origin https://github.com/timo-jakob/widget.git
  local F="$R/.claude/telemetry/telemetry.jsonl"
  local P="$BATS_TEST_TMPDIR/fp-payload.json"

  emit() {  # $1 status · $2 outcome · $3 issue · $4 ts · $5 wall
    cat > "$BATS_TEST_TMPDIR/fp-status.json" <<EOF
{"status":"$1","rounds":1,"max_rounds":3,"repo_type":"python","round_changelists":[],"final_changelist":{"blocking":[]}}
EOF
    zsh "$S" --status "$BATS_TEST_TMPDIR/fp-status.json" > "$P"
    zsh "$EMIT" --pipeline review-loop --outcome "$2" --repo-dir "$R" \
      --issue "$3" --ts "$4" --wall-s "$5" --payload "$P" >/dev/null
  }

  emit_promo() {  # $1 issue · $2 ts · $3 wall — a promotion sub-loop's own record
    cat > "$BATS_TEST_TMPDIR/fp-status.json" <<EOF
{"status":"CONVERGED","rounds":1,"max_rounds":5,"promotion_phase":true,"repo_type":"python","round_changelists":[],"final_changelist":{"blocking":[]}}
EOF
    zsh "$S" --status "$BATS_TEST_TMPDIR/fp-status.json" > "$P"
    jq -e '.promotion_phase == true' "$P" >/dev/null
    zsh "$EMIT" --pipeline review-loop --outcome success --repo-dir "$R" \
      --issue "$1" --ts "$2" --wall-s "$3" --payload "$P" >/dev/null
  }

  emit CONVERGED        success   601 1720000000 10   # converged first pass
  emit BUDGET_EXHAUSTED escalated 602 1720000100 20   # never converged
  emit SKIPPED          success   604 1720000200 1    # reviewed nothing
  # issue 605: ONE extended loop -> two records, SAME ts, growing wall_s
  emit BUDGET_EXHAUSTED escalated 605 1720000300 5
  emit CONVERGED        success   605 1720000300 50
  # 602's promotion pass: a FRESH invocation, so a NEW ts -> its own group. It
  # must not become a fourth story that turns a never-converged one into a
  # first-pass success.
  emit_promo 602 1720000400 7

  local RL='[.[] | select(.kind == "run" and .pipeline == "review-loop")]'
  local GROUPED="$RL"' | map(select(.payload.status != "SKIPPED"))
    | map(select(.payload.promotion_phase != true)) | group_by([.repo, .issue, .ts])'

  # FIRST-PASS (min_by): 601 yes, 602 no, 605 no (it escalated first) -> 1/3
  [ "$(jq -s "$GROUPED"' | map(min_by(.wall_s))
    | if length == 0 then null else ([.[] | select(.payload.status == "CONVERGED")] | length) / length end' "$F")" = "0.3333333333333333" ]
  # FINAL outcome (max_by), the opposite end: 601 and 605 both converged -> 2/3
  [ "$(jq -s "$GROUPED"' | map(max_by(.wall_s))
    | if length == 0 then null else ([.[] | select(.payload.status == "CONVERGED")] | length) / length end' "$F")" = "0.6666666666666666" ]
  # the two really do disagree — that difference IS the extended loop
  [ "$(jq -s "$GROUPED"' | map(select(length > 1)) | length' "$F")" -eq 1 ]
  # and dropping the SKIPPED filter would silently change the denominator
  [ "$(jq -s "$RL"' | group_by([.repo, .issue, .ts]) | length' "$F")" -eq 5 ]
  # ...and so would dropping the promotion_phase predicate: the promotion pass
  # forms its own (repo, issue, ts) group, so first-pass would read 2/4 and
  # credit issue 602 — which never converged — with a first-pass success
  local UNPRED="$RL"' | map(select(.payload.status != "SKIPPED")) | group_by([.repo, .issue, .ts])'
  [ "$(jq -s "$UNPRED"' | map(min_by(.wall_s))
    | if length == 0 then null else ([.[] | select(.payload.status == "CONVERGED")] | length) / length end' "$F")" = "0.5" ]
}

@test "the first-pass one-liner also yields null on a record-less stream" {
  local F="$BATS_TEST_TMPDIR/empty-fp.jsonl"
  : > "$F"
  run jq -s '[.[] | select(.kind == "run" and .pipeline == "review-loop")]
    | map(select(.payload.status != "SKIPPED"))
    | map(select(.payload.promotion_phase != true))
    | group_by([.repo, .issue, .ts]) | map(min_by(.wall_s))
    | if length == 0 then null else ([.[] | select(.payload.status == "CONVERGED")] | length) / length end' "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

# --- #1435: findings_by_round[].by_class -------------------------------------

@test "#1435 by_class counts each residue class for a fully stamped round" {
  cat > "$ST" <<'EOF'
{"status":"CONVERGED_WITH_RESIDUE","rounds":2,"max_rounds":2,"repo_type":"claude-plugin",
 "escalation_reasons":[],"history":[],
 "round_changelists":[
  {"round":1,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0,"false_trips":0},
   "blocking":[{"file":"a.zsh","line":1,"dimension":"bugs","title":"x","priority":"High","non_converging":false,"class":"new_defect"}],
   "suggestions":[]},
  {"round":2,"summary":{"critical":0,"high":3,"low":0,"blocking":3,"conflicts":0,"false_trips":0},
   "blocking":[{"file":"a.zsh","line":1,"dimension":"bugs","title":"y","priority":"High","non_converging":false,"class":"incomplete_propagation"},
               {"file":"a.zsh","line":9,"dimension":"bugs","title":"z","priority":"High","non_converging":false,"class":"incomplete_propagation"},
               {"file":"a.bats","line":4,"dimension":"tests","title":"w","priority":"High","non_converging":false,"class":"under_assertion"}],
   "suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings_by_round[0].by_class == {new_defect:1,incomplete_propagation:0,under_assertion:0}' >/dev/null
  echo "$output" | jq -e '.findings_by_round[1].by_class == {new_defect:0,incomplete_propagation:2,under_assertion:1}' >/dev/null
  # residue is a SUCCESS status, so `escalation` (which tests ^ESCALATE_ /
  # BUDGET_EXHAUSTED) must stay null rather than gaining an arm of its own
  echo "$output" | jq -e '.status == "CONVERGED_WITH_RESIDUE" and .escalation == null' >/dev/null
}

@test "#1435 tc-corner-class-unstamped-null: by_class is null on an unstamped round, never zeros" {
  # a pre-#1435 changelist. Zeros would read as "this round found no new
  # defects", which is a claim nobody made — the same honest-gap convention
  # new/carried and false_trips already follow.
  cat > "$ST" <<'EOF'
{"status":"BUDGET_EXHAUSTED","rounds":2,"max_rounds":2,"repo_type":"claude-plugin",
 "escalation_reasons":[],"history":[],
 "round_changelists":[
  {"round":1,"summary":{"critical":0,"high":1,"low":0,"blocking":1,"conflicts":0,"false_trips":0},
   "blocking":[{"file":"a.zsh","line":1,"dimension":"bugs","title":"x","priority":"High","non_converging":false}],
   "suggestions":[]},
  {"round":2,"summary":{"critical":0,"high":2,"low":0,"blocking":2,"conflicts":0,"false_trips":0},
   "blocking":[{"file":"a.zsh","line":1,"dimension":"bugs","title":"y","priority":"High","non_converging":false,"class":"incomplete_propagation"},
               {"file":"b.zsh","line":2,"dimension":"bugs","title":"z","priority":"High","non_converging":false}],
   "suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings_by_round[0].by_class == null' >/dev/null
  # PARTIALLY stamped is unstamped: one classified item does not license a
  # histogram over the round
  echo "$output" | jq -e '.findings_by_round[1].by_class == null' >/dev/null
}

@test "#1435 a zero-blocker round reports by_class zeros, not null (determinately classified)" {
  # the empty array satisfies "every item is stamped" vacuously, exactly as it
  # does for the carried/new split — there are no per-item stamps to consult
  # and the three counts are determinately 0
  cat > "$ST" <<'EOF'
{"status":"CONVERGED","rounds":1,"max_rounds":3,"repo_type":"claude-plugin",
 "escalation_reasons":[],"history":[],
 "round_changelists":[
  {"round":1,"summary":{"critical":0,"high":0,"low":0,"blocking":0,"conflicts":0,"false_trips":0},
   "blocking":[],"suggestions":[]}],
 "final_changelist":{"blocking":[]}}
EOF
  run zsh "$S" --status "$ST"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings_by_round[0].by_class == {new_defect:0,incomplete_propagation:0,under_assertion:0}' >/dev/null
}
