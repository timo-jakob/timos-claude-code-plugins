#!/usr/bin/env bats
#
# Acceptance cases for "telemetry for the acceptance stage" (#1230, epic #741
# child (e)) — the `cli`-tooled test_cases[] of its story-spec, one test per
# `tc-*` id:
#
#   tc-happy-cli-leg                      #2081
#   tc-happy-rerun-idempotent             #2082
#   tc-happy-matrix                       #2083
#   tc-corner-cancelled-by-design         #2084
#   tc-corner-superseded-attempt          #2085
#   tc-corner-no-token-in-record          #2086
#   tc-corner-conclusion-map              #2087
#   tc-corner-expired-artifact            #2088
#   tc-corner-unparseable-junit           #2089
#   tc-corner-dir-sink-lookup             #2090
#   tc-corner-no-workflow                 #2091
#   tc-corner-window                      #2092
#   tc-corner-in-progress                 #2093
#   tc-error-gh-list-fails                #2094
#   tc-error-artifact-5xx                 #2095
#   tc-error-emitter-fails                #2096
#   tc-error-usage                        #2097
#   tc-error-builder-inconsistent-counts  #2098
#
# The use case: sam-operator collects the settled acceptance-check results of
# every repo he watches into the cross-repo telemetry directory, unattended,
# without double-counting — `collect-acceptance-telemetry.zsh --repo
# timo-jakob/ai-doc-organizer --telemetry-dir ~/telemetry`.
#
# These drive the real collector, builder and emitter against a fake `gh`
# (tests/fixtures/acceptance-telemetry/gh-stub.zsh) serving the committed
# fixture scenarios; nothing reaches GitHub. The default gate's
# tests/collect-acceptance-telemetry.bats and
# tests/build-acceptance-telemetry-record.bats cover the same criteria branch by
# branch.

bats_require_minimum_version 1.5.0
load ../../assertions
load ../../acceptance-telemetry

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  at_setup "$REPO_ROOT"
}

field() { jq -r "$1" <<<"$2"; }   # $1 = a jq path, $2 = one record

@test "tc-happy-cli-leg" {
  use_scenario single-cli
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 1 ]
  local r; r="$(cat "$T")"
  [ "$(field .pipeline "$r")" = acceptance ]
  [ "$(field .payload.interface "$r")" = cli ]
  [ "$(field .pr "$r")" = 412 ]
  [ "$(field .wall_s "$r")" = 74 ]
  [ "$(field .payload.check_run_id "$r")" = 31001 ]
  [ "$(jq -c .payload.tests <<<"$r")" = '{"passed":12,"failed":0,"skipped":1,"total":13}' ]
  [ "$(field .payload.harness "$r")" = real ]
  run zsh "$VALIDATE" --require-records "$T"
  [ "$status" -eq 0 ]
}

@test "tc-happy-rerun-idempotent" {
  use_scenario single-cli
  collect
  [ "$status" -eq 0 ]
  local before; before="$(lines "$T")"
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = "$before" ]
}

@test "tc-happy-matrix" {
  use_scenario matrix
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -r -s 'map(.payload.interface) | join(",")' "$T")" = "cli,rest" ]
  [ "$(jq -r -s 'map(select(.payload.interface == "rest")) | .[0].payload.harness' "$T")" = skeleton ]
}

@test "tc-corner-cancelled-by-design" {
  use_scenario single-cli
  fx_edit jobs-9001.json '.jobs[0].conclusion = "cancelled"'
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -r .outcome "$T")" = parked ]
  [ "$(jq -r .payload.conclusion "$T")" = cancelled ]
  lacks "$(cat "$T")" '"outcome":"failed"'
}

@test "tc-corner-superseded-attempt" {
  use_scenario superseded
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -c -s 'map([.payload.check_run_id, .outcome])' "$T")" = '[[33001,"parked"],[33002,"success"]]' ]
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 2 ]
}

@test "tc-corner-no-token-in-record" {
  local tok="ghs_fake-token-0000"
  use_scenario single-cli
  export GH_STUB_LEAK=1 GH_TOKEN="$tok"
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -r .payload.report_artifact.url "$T")" = "https://api.github.com/repos/$REPO/actions/artifacts/7001" ]
  local all; all="$(cat "$T")$output$stderr"
  lacks "$all" "$tok"
  lacks "$all" "sig=fakesigfakesig"
  lacks "$all" "results-receiver.actions.githubusercontent.com"
}

@test "tc-corner-conclusion-map" {
  use_scenario conclusions
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -r -s 'map(.payload.conclusion + ":" + .outcome) | join(" ")' "$T")" = "timed_out:failed startup_failure:failed neutral:parked action_required:parked stale:parked skipped:parked" ]
}

@test "tc-corner-expired-artifact" {
  use_scenario single-cli
  printf '410\n' > "$FX/zip-7001.status"
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.payload.tests, .payload.harness, .payload.report_artifact, .payload.conclusion]' "$T")" = '[{"passed":null,"failed":null,"skipped":null,"total":null},null,null,"success"]' ]
}

@test "tc-corner-unparseable-junit" {
  use_scenario single-cli
  printf 'truncated.xml\n' > "$FX/zip-7001.junit"
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.payload.tests, .payload.harness, .payload.report_artifact, .payload.conclusion]' "$T")" = '[{"passed":null,"failed":null,"skipped":null,"total":null},null,null,"success"]' ]
}

@test "tc-corner-dir-sink-lookup" {
  use_scenario single-cli
  local d="$BATS_TEST_TMPDIR/telemetry"
  mkdir -p "$d"
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" --telemetry-dir "$d"
  [ "$status" -eq 0 ]
  # already in $D/<repo-slug>.jsonl -> nothing appended
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" --telemetry-dir "$d"
  [ "$status" -eq 0 ]
  [ "$(lines "$d/timo-jakob-ai-doc-organizer.jsonl")" = 1 ]
  # present only in another repo's file -> appended to this repo's
  mv "$d/timo-jakob-ai-doc-organizer.jsonl" "$d/timo-jakob-other.jsonl"
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" --telemetry-dir "$d"
  [ "$status" -eq 0 ]
  [ "$(lines "$d/timo-jakob-ai-doc-organizer.jsonl")" = 1 ]
  [ "$(lines "$d/timo-jakob-other.jsonl")" = 1 ]
}

@test "tc-corner-no-workflow" {
  use_scenario single-cli
  printf '404\n' > "$FX/runs.status"
  mkdir -p "${T%/*}"
  printf '%s\n' '{"existing":"line"}' > "$T"
  collect
  [ "$status" -eq 0 ]
  [ "$(cat "$T")" = '{"existing":"line"}' ]
}

@test "tc-corner-window" {
  use_scenario window
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -r -s 'map(.pr) | join(",")' "$T")" = 416 ]
  contains "$(cat "$GH_LOG")" "created=>=$(jq -n -r 'now - 30 * 86400 | strftime("%Y-%m-%d")')"
}

@test "tc-corner-in-progress" {
  use_scenario single-cli
  fx_edit jobs-9001.json '.jobs[0].status = "in_progress" | .jobs[0].conclusion = null | .jobs[0].completed_at = null'
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 0 ]
  use_scenario single-cli
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 1 ]
}

@test "tc-error-gh-list-fails" {
  use_scenario single-cli
  printf '502\n' > "$FX/runs.status"
  collect
  [ "$status" -eq 3 ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  contains "$stderr" "$REPO"
  contains "$stderr" "actions/workflows/acceptance.yml/runs"
  [ "$(lines "$T")" = 0 ]
}

@test "tc-error-artifact-5xx" {
  use_scenario single-cli
  printf '502\n' > "$FX/zip-7001.status"
  collect
  [ "$status" -eq 3 ]
  [ "$(lines "$T")" = 0 ]
  rm "$FX/zip-7001.status"
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -c .payload.tests "$T")" = '{"passed":12,"failed":0,"skipped":1,"total":13}' ]
}

@test "tc-error-emitter-fails" {
  use_scenario conclusions
  fx_edit jobs-9004.json '.jobs |= .[0:3]'
  fail_emit_on 2
  collect
  [ "$status" -eq 3 ]
  [ "$(lines "$T")" = 1 ]
  run zsh "$VALIDATE" "$T"
  [ "$status" -eq 0 ]
  unset ACCEPTANCE_TELEMETRY_EMITTER_BIN
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 3 ]
  [ "$(jq -r -s 'map(.payload.check_run_id) | join(",")' "$T")" = "34001,34002,34003" ]
}

@test "tc-error-usage" {
  run --separate-stderr zsh "$COLLECT"
  [ "$status" -eq 2 ]
  contains "$stderr" "usage:"
  [ ! -e "$GH_LOG" ]
}

@test "tc-error-builder-inconsistent-counts" {
  local job="$BATS_TEST_TMPDIR/job.json" x
  jq -c '.jobs[0]' "$ATF/single-cli/jobs-9001.json" > "$job"
  for x in inconsistent negative; do
    run --separate-stderr zsh "$BUILDER" --job "$job" --junit "$ATF/junit/$x.xml" \
      --artifact-name acceptance-report-cli --artifact-url "https://api.github.com/repos/$REPO/actions/artifacts/7001"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}
