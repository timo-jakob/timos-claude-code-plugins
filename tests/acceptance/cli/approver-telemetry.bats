#!/usr/bin/env bats
#
# Acceptance cases for "telemetry for the Approver" (#1231, epic #741 child
# (f)) — the `cli`-tooled test_cases[] of its story-spec, one test per `tc-*`
# id:
#
#   tc-happy-python-request-changes      #2100
#   tc-happy-rerun-idempotent            #2101
#   tc-happy-swift-seven-lenses          #2102
#   tc-happy-claude-plugin-ten-lenses    #2389
#   tc-corner-pre-instrumentation-review #2103
#   tc-corner-malformed-block            #2104
#   tc-corner-pasted-block-by-human      #2105
#   tc-corner-token-never-recorded       #2106
#   tc-error-verdict-state-mismatch      #2107
#   tc-error-gh-listing-fails            #2108
#   tc-error-missing-repo                #2109
#
# The use case: sam-operator collects every Approver review posted on the repos
# he watches into the cross-repo telemetry directory, unattended, to see whether
# the Approver is calibrated or rubber-stamping —
# `collect-approver-telemetry.zsh --repo timo-jakob/ai-doc-organizer
# --telemetry-dir ~/telemetry`.
#
# These drive the real collector, builder and emitter against a fake `gh`
# (tests/fixtures/approver-telemetry/gh-stub.zsh) serving the committed fixture
# scenarios; nothing reaches GitHub. The default gate's
# tests/collect-approver-telemetry.bats and
# tests/build-approver-telemetry-record.bats cover the same criteria branch by
# branch.

bats_require_minimum_version 1.5.0
load ../../assertions
load ../../approver-telemetry

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  apt_setup "$REPO_ROOT"
}

field() { jq -c "$1" <<<"$2"; }   # $1 = a jq path, $2 = one record

@test "tc-happy-python-request-changes" {
  use_scenario python-rc
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 1 ]
  local r; r="$(cat "$T")"
  [ "$(field .pipeline "$r")" = '"approve"' ]
  [ "$(field .outcome "$r")" = '"success"' ]
  [ "$(field .pr "$r")" = 412 ]
  [ "$(field .wall_s "$r")" = 214 ]
  [ "$(field .payload.risk_register_size "$r")" = 2 ]
  [ "$(field '[.payload.verdict, .payload.confidence, .payload.pr_type, .payload.language]' "$r")" = '["REQUEST_CHANGES","LOW","feat","python"]' ]
  run zsh "$VALIDATE" --require-records "$T"
  [ "$status" -eq 0 ]
}

@test "tc-happy-rerun-idempotent" {
  use_scenario python-rc
  collect
  [ "$status" -eq 0 ]
  local before; before="$(lines "$T")"
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = "$before" ]
  contains "$output" "skipped as already recorded 1"
}

@test "tc-happy-swift-seven-lenses" {
  use_scenario swift
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 1 ]
  [ "$(jq -r .payload.language "$T")" = swift ]
  [ "$(jq -c .payload.dimensions "$T")" = '["bugs","security","performance","code_quality","tests","swift6_compliance","resilience"]' ]
}

@test "tc-happy-claude-plugin-ten-lenses" {
  REPO="timo-jakob/timos-claude-code-plugins"
  use_scenario claude-plugin
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 1 ]
  [ "$(jq -c '[.repo, .payload.language, .payload.pr_type]' "$T")" = '["timo-jakob/timos-claude-code-plugins","claude-plugin","fix"]' ]
  [ "$(jq -c .payload.dimensions "$T")" = '["bugs","security","performance","code_quality","tests","prose_logic","contract","script_quality","manifest_bump","manifest"]' ]
  run zsh "$VALIDATE" --require-records "$T"
  [ "$status" -eq 0 ]
}

@test "tc-corner-pre-instrumentation-review" {
  use_scenario not-instrumented
  fx_edit reviews-420.json 'map(select(.id == 3002))'
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 0 ]
  contains "$output" "skipped as not instrumented 1"
}

@test "tc-corner-malformed-block" {
  use_scenario not-instrumented
  fx_edit reviews-420.json 'map(select(.id == 3003))'
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 0 ]
  contains "$output" "skipped as not instrumented 1"
}

@test "tc-corner-pasted-block-by-human" {
  use_scenario not-instrumented
  fx_edit reviews-420.json 'map(select(.id == 3006))'
  collect
  [ "$status" -eq 0 ]
  [ "$(lines "$T")" = 0 ]
  contains "$output" "recorded 0, skipped as already recorded 0, skipped as not instrumented 0"
}

@test "tc-corner-token-never-recorded" {
  local tok="ghs_fake-token-0000"
  use_scenario python-rc
  export GH_STUB_LEAK=1 GH_TOKEN="$tok"
  collect
  [ "$status" -eq 0 ]
  local all; all="$(cat "$T")$output$stderr"
  lacks "$all" "$tok"
}

@test "tc-error-verdict-state-mismatch" {
  local review="$BATS_TEST_TMPDIR/review.json" block="$BATS_TEST_TMPDIR/block.json"
  jq -c '.[0] | .state = "APPROVED"' "$APF/python-rc/reviews-412.json" > "$review"
  jq -r '.[0].body | capture("<!-- claude-approver:findings\\n(?<j>.*)\\n-->").j' "$APF/python-rc/reviews-412.json" > "$block"
  [ "$(jq -r .verdict "$block")" = REQUEST_CHANGES ]
  run --separate-stderr zsh "$BUILDER" --review "$review" --block "$block"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "tc-error-gh-listing-fails" {
  use_scenario two-prs
  printf '502\n' > "$FX/reviews-413.status"
  collect
  [ "$status" -eq 3 ]
  [ "$(lines "$T")" = 1 ]
  [ "$(jq -c '[.pr, .payload.review_id]' "$T")" = '[412,2930481177]' ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  contains "$stderr" "$REPO"
  contains "$stderr" "pulls/413/reviews"
  contains "$stderr" "PR 413"
  run zsh "$VALIDATE" "$T"
  [ "$status" -eq 0 ]
}

@test "tc-error-missing-repo" {
  run --separate-stderr zsh "$COLLECT" --telemetry-file "$T"
  [ "$status" -eq 2 ]
  [ ! -e "$T" ]
  [ ! -e "$GH_LOG" ]
}
