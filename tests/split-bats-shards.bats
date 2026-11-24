#!/usr/bin/env bats
#
# Behavioural tests for scripts/split-bats-shards.zsh (#3084): the script that
# splits the bats suite into the legs of CI's script-tests matrix. What these
# pin down:
#   * every bats file is assigned to exactly one leg;
#   * with timing data the legs are balanced by the given times, slowest file
#     first to the lightest leg;
#   * with no timing data the split falls back to an even split by file count;
#   * `check` fails when the legs do not cover the suite exactly once;
#   * the workflow's legs and its one required check are wired to the script.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/scripts/split-bats-shards.zsh"
  WF="$REPO_ROOT/.github/workflows/script-tests.yml"
  W="$BATS_TEST_TMPDIR/work"
  mkdir -p "$W/tests"
  cd "$W"
}

# mk_suite NAME… — empty bats files in $W/tests
mk_suite() {
  local n
  for n in "$@"; do : > "tests/$n.bats"; done
}

# timings NAME=SECONDS… — a run-gate-shaped timings file at $W/t.json
timings() {
  local kv out=""
  for kv in "$@"; do
    out+="${out:+,}{\"file\":\"tests/${kv%%=*}.bats\",\"wall_s\":${kv#*=}}"
  done
  printf '{"files":[%s]}\n' "$out" > t.json
}

@test "with timings: every file lands in exactly one leg, and the union is the suite" {
  mk_suite a b c d e f g
  timings a=5 b=1 c=9 d=2 e=7 f=3 g=4
  run --separate-stderr zsh "$S" plan --legs 3 --tests-dir tests --timings t.json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.schema == "bats-shards/v1" and .legs == 3 and .basis == "timings"'
  echo "$output" | jq -e '(.shards | length) == 3'
  # every file once: the flattened legs, sorted, equal the suite, with no repeat
  [ "$(echo "$output" | jq -c '[.shards[].files[]] | sort')" \
    = '["tests/a.bats","tests/b.bats","tests/c.bats","tests/d.bats","tests/e.bats","tests/f.bats","tests/g.bats"]' ]
}

@test "with timings: legs are balanced by the given times, slowest first to the lightest leg" {
  mk_suite a b c d e
  timings a=8 b=7 c=6 d=5 e=4
  run --separate-stderr zsh "$S" plan --legs 2 --tests-dir tests --timings t.json
  [ "$status" -eq 0 ]
  # a(8)->1, b(7)->2, c(6)->2 (7<8), d(5)->1 (8<13), e(4)->1 (13=13, lower leg)
  [ "$(echo "$output" | jq -c '[.shards[] | {leg, est_s, files}]')" \
    = '[{"leg":1,"est_s":17,"files":["tests/a.bats","tests/d.bats","tests/e.bats"]},{"leg":2,"est_s":13,"files":["tests/b.bats","tests/c.bats"]}]' ]
}

@test "with timings: one slow file is not paired with the next-slowest on a count split" {
  # a count split gives each leg two files whatever they weigh; the time split
  # keeps the heavy file alone and gives the light ones to the other leg
  mk_suite a b c d
  timings a=100 b=90 c=1 d=1
  run --separate-stderr zsh "$S" plan --legs 2 --tests-dir tests --timings t.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '[.shards[] | {est_s, files}]')" \
    = '[{"est_s":100,"files":["tests/a.bats"]},{"est_s":92,"files":["tests/b.bats","tests/c.bats","tests/d.bats"]}]' ]
}

@test "with timings: a file the timings do not name gets their mean" {
  mk_suite a b new
  timings a=10 b=2
  run --separate-stderr zsh "$S" plan --legs 2 --tests-dir tests --timings t.json
  [ "$status" -eq 0 ]
  # mean 6: a(10)->1, new(6)->2, b(2)->2
  [ "$(echo "$output" | jq -c '[.shards[] | {est_s, files}]')" \
    = '[{"est_s":10,"files":["tests/a.bats"]},{"est_s":8,"files":["tests/b.bats","tests/new.bats"]}]' ]
}

@test "timings are matched by basename, whatever directory they were recorded from" {
  mk_suite a b
  printf '{"files":[{"file":"elsewhere/a.bats","wall_s":9},{"file":"b.bats","wall_s":1}]}\n' > t.json
  run --separate-stderr zsh "$S" plan --legs 2 --tests-dir tests --timings t.json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.basis == "timings" and ([.shards[].est_s] == [9, 1])'
}

@test "no timing data: an even split by file count" {
  mk_suite a b c d e f g h i j
  run --separate-stderr zsh "$S" plan --legs 4 --tests-dir tests
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.basis == "count"'
  [ "$(echo "$output" | jq -c '[.shards[].files | length]')" = '[3,3,2,2]' ]
  [ "$(echo "$output" | jq -c '[.shards[].files[]] | sort | length')" = '10' ]
}

@test "no timing data: a missing, malformed or non-matching timings file falls back to count" {
  mk_suite a b c
  run --separate-stderr zsh "$S" plan --legs 2 --tests-dir tests --timings no-such.json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.basis == "count"'
  contains "$stderr" "timings unreadable (no-such.json)"
  echo 'not json' > bad.json
  run --separate-stderr zsh "$S" plan --legs 2 --tests-dir tests --timings bad.json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.basis == "count"'
  contains "$stderr" "splitting by file count"
  timings zzz=5
  run --separate-stderr zsh "$S" plan --legs 2 --tests-dir tests --timings t.json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.basis == "count" and ([.shards[].files | length] == [2, 1])'
}

@test "check passes a plan that covers the suite exactly once" {
  mk_suite a b c d
  zsh "$S" plan --legs 2 --tests-dir tests > plan.json
  run --separate-stderr zsh "$S" check --plan plan.json --tests-dir tests
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "check fails when a file is in no leg, and names it" {
  mk_suite a b c d
  zsh "$S" plan --legs 2 --tests-dir tests > plan.json
  # a bats file added after the plan was made: no leg runs it
  mk_suite late
  run --separate-stderr zsh "$S" check --plan plan.json --tests-dir tests
  [ "$status" -eq 1 ]
  contains "$stderr" "missing from every leg: tests/late.bats"
  contains "$stderr" "the legs do not cover the suite exactly once"
}

@test "check fails when a file is listed twice or is not in the suite" {
  mk_suite a b c
  jq -n '{schema:"bats-shards/v1",legs:2,basis:"count",
          shards:[{leg:1,est_s:2,files:["tests/a.bats","tests/b.bats"]},
                  {leg:2,est_s:2,files:["tests/b.bats","tests/c.bats","tests/gone.bats"]}]}' > plan.json
  run --separate-stderr zsh "$S" check --plan plan.json --tests-dir tests
  [ "$status" -eq 1 ]
  contains "$stderr" "listed twice: tests/b.bats"
  contains "$stderr" "not in the suite: tests/gone.bats"
}

@test "files prints one leg's files, one per line" {
  mk_suite a b c d
  timings a=4 b=3 c=2 d=1
  zsh "$S" plan --legs 2 --tests-dir tests --timings t.json > plan.json
  run zsh "$S" files --plan plan.json --leg 2
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'tests/b.bats\ntests/c.bats')" ]
}

@test "--help prints the header's usage and exits 0" {
  run zsh "$S" --help
  [ "$status" -eq 0 ]
  contains "$output" "split-bats-shards.zsh plan  --legs N [--tests-dir DIR] [--timings FILE]"
}

@test "usage errors exit 2; an unreadable or foreign plan exits 3" {
  mk_suite a b
  run zsh "$S"
  [ "$status" -eq 2 ]
  run zsh "$S" split --legs 2
  [ "$status" -eq 2 ]
  run zsh "$S" plan --legs 0 --tests-dir tests
  [ "$status" -eq 2 ]
  run zsh "$S" plan --legs x --tests-dir tests
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$S" plan --legs 3 --tests-dir tests
  [ "$status" -eq 2 ]
  contains "$stderr" "more than the 2 bats files"
  run zsh "$S" plan --legs 2 --tests-dir no-such-dir
  [ "$status" -eq 2 ]
  run zsh "$S" plan --legs
  [ "$status" -eq 2 ]
  zsh "$S" plan --legs 2 --tests-dir tests > plan.json
  run zsh "$S" files --plan plan.json --leg 3
  [ "$status" -eq 2 ]
  run zsh "$S" files --plan plan.json --leg 0
  [ "$status" -eq 2 ]
  run zsh "$S" files --plan no-such.json --leg 1
  [ "$status" -eq 3 ]
  echo '{"legs":2}' > foreign.json
  run zsh "$S" check --plan foreign.json --tests-dir tests
  [ "$status" -eq 3 ]
}

@test "the real suite: the committed timings split it into legs that cover it exactly once" {
  cd "$REPO_ROOT"
  zsh "$S" plan --legs 4 --tests-dir tests --timings tests/bats-timings.json > "$BATS_TEST_TMPDIR/real.json"
  jq -e '.basis == "timings" and .legs == 4' "$BATS_TEST_TMPDIR/real.json"
  run --separate-stderr zsh "$S" check --plan "$BATS_TEST_TMPDIR/real.json" --tests-dir tests
  [ "$status" -eq 0 ]
}

@test "the workflow's leg list and the --legs it plans name the same count" {
  local legs planned
  legs="$(yq -r '.jobs.bats.strategy.matrix.leg | length' "$WF")"
  planned="$(grep -oE 'split-bats-shards\.zsh plan --legs [0-9]+' "$WF" | grep -oE '[0-9]+$')"
  [ -n "$planned" ]
  [ "$legs" = "$planned" ]
  local want="" i
  for (( i = 1; i <= planned; i++ )); do want+="${want:+,}$i"; done
  [ "$(yq -r '.jobs.bats.strategy.matrix.leg | join(",")' "$WF")" = "$want" ]
  # each leg runs ITS number, checks coverage first, then runs only its files
  [ "$(yq -r '.jobs.bats.steps[] | select(.name == "Run shell-script behavioral tests") | .env.LEG' "$WF")" \
    = '${{ matrix.leg }}' ]
  local run_step
  run_step="$(yq -r '.jobs.bats.steps[] | select(.name == "Run shell-script behavioral tests") | .run' "$WF")"
  # whole-line anchors: a `|| true` (or any suffix) on the check line would
  # stop a dropped file failing the leg, and a substring match would miss it
  local check_ln files_ln gate_ln
  check_ln="$(grep -nE '^ *zsh scripts/split-bats-shards\.zsh check --plan "\$plan" --tests-dir tests$' <<< "$run_step" | cut -d: -f1)"
  files_ln="$(grep -nE '^ *zsh scripts/split-bats-shards\.zsh files --plan "\$plan" --leg "\$LEG" > "\$leg_files"$' <<< "$run_step" | cut -d: -f1)"
  gate_ln="$(grep -nE '^ *zsh development/skills/resolve-issue/scripts/run-gate\.zsh --tests-dir tests --files-from "\$leg_files"$' <<< "$run_step" | cut -d: -f1)"
  [ -n "$check_ln" ]
  [ -n "$files_ln" ]
  [ -n "$gate_ln" ]
  # the coverage check runs before the leg's files are listed and run
  [ "$check_ln" -lt "$files_ln" ]
  [ "$files_ln" -lt "$gate_ln" ]
}

@test "one required check: the aggregating job carries the required name and fails unless every leg passed" {
  # the context branch protection requires today
  [ "$(yq -r '.jobs["bats-required"].name' "$WF")" = 'bats (ubuntu-latest)' ]
  [ "$(yq -r '.jobs["bats-required"].needs' "$WF")" = 'bats' ]
  # always(): a skipped required check would count as passing
  [ "$(yq -r '.jobs["bats-required"].if' "$WF")" = 'always()' ]
  # no leg reports under the required name
  local leg_name
  leg_name="$(yq -r '.jobs.bats.name' "$WF")"
  [ "$leg_name" != 'bats (ubuntu-latest)' ]
  contains "$leg_name" '${{ matrix.leg }}'
  # the gate step fails on every result but success
  local step
  step="$(yq -r '.jobs["bats-required"].steps[0].run' "$WF")"
  [ "$(yq -r '.jobs["bats-required"].steps[0].env.LEGS_RESULT' "$WF")" = '${{ needs.bats.result }}' ]
  local r
  for r in failure cancelled skipped; do
    run env LEGS_RESULT="$r" bash -c "$step"
    [ "$status" -eq 1 ]
  done
  run env LEGS_RESULT=success bash -c "$step"
  [ "$status" -eq 0 ]
}
