#!/usr/bin/env bats
#
# Acceptance cases for the Node ops-api payload (#936) — the `cli`-tooled half of
# its story-spec `test_cases[]`, one test per `tc-*` id:
#
#   tc-happy-conformance-all-five          #1233
#   tc-error-missing-git-sha-fails-fast    #1241
#   tc-error-deprecated-major-without-sunset #1242
#   tc-error-under-reporting-aggregate     #1243
#
# These run against a REAL service built from the shipped template (see
# ../lib/node-ops-sandbox.zsh), and drive the SHIPPED
# check-ops-conformance.zsh — the same script bootstrap installs and wires as the
# `ops-conformance` CI job. They are NOT part of the default gate — `bats tests`
# does not recurse — see ../README.md for why, and #243 for the tier that will
# run them.

bats_require_minimum_version 1.5.0
load ../lib/ops-acceptance
# The shared assertion helpers (tests/README.md). `lacks` in particular, because a
# hand-rolled `! printf … | grep` is the inert-negation shape the suite lint bans.
load ../../assertions

setup_file() {
  # Unguarded and allowed to fail the whole file — a missing toolchain must be
  # loud. A skipped acceptance check that reads as green is the failure mode this
  # repo's test conventions are written against.
  load ../lib/ops-acceptance
  ops_provision
}

setup() { ops_sandbox; }
teardown() { ops_stop; }

@test "tc-happy-conformance-all-five: the shipped checker passes all five endpoints" {
  # The marquee criterion: a service built from the template passes
  # check-ops-conformance.zsh UNCHANGED.
  #
  # The exit status IS the verdict here — the checker prints its five PASS lines
  # as one static block reached only after the failure check, so they add no
  # discrimination over `status -eq 0` and asserting them would be theatre. The
  # per-endpoint lines are still worth reading in a failure report, so they are
  # asserted as a REGRESSION guard on the checker's own output shape, which is
  # what the acceptance tier would otherwise silently stop covering.
  ops_start lifecycle GIT_SHA=9e11997 BUILD_VERSION=1.4.2
  run zsh "$CHECKER" "$BASE"
  [ "$status" -eq 0 ]
  checker_passed "$output" "/info"
  checker_passed "$output" "/health"
  checker_passed "$output" "/health/live"
  checker_passed "$output" "/health/ready"
  checker_passed "$output" "/metrics"
}

@test "tc-error-readiness-503-fails-conformance: a shed pod fails conformance, and the failure NAMES the dependency" {
  # #1343. A 503 stays a conformance FAILURE — conformance asserts a SERVING
  # service, and there is deliberately no flag to tolerate one. What ops-api v2
  # buys is that the failure says WHICH dependency shed the pod, read out of the
  # RFC 9457 problem document rather than inferred from a bare status code.
  #
  # This is the checker's 503 branch exercised against a REAL service, not a
  # stubbed curl: the stub cases live in tests/check-ops-conformance.bats.
  ops_start hard-down GIT_SHA=9e11997
  run zsh "$CHECKER" "$BASE"
  [ "$status" -ne 0 ]
  checker_failed "$output" "/health/ready"
  contains "$output" "not ready — hard dependency 'orders-db' is down (503)"
  # It must NOT be misreported as a legacy v1 body: that message is the migration
  # instruction, and firing it at a correctly-migrated service would send an
  # adopter to re-do work they have already done.
  lacks "$output" 'ops-api v1 envelope'
  # NOTE the checker prints its five PASS lines as one static block reached only
  # AFTER the failure check, so a failing run emits no PASS lines at all. Asserting
  # /info still passed here would be asserting output the checker never produces.
}

@test "tc-corner-checker-base-url-unprefixed: a trailing-slash base URL still probes UNPREFIXED paths" {
  # #1346. The acceptance criterion this pins is "the checker's base-URL handling is
  # untouched", and the thing that could have broken it is cutting `servers: /v2`
  # in the contract: an implementer could reasonably conclude the runtime paths
  # gained a /v2 prefix. They did not — the server URL is the triangle's version
  # declaration, not a path prefix.
  ops_start lifecycle GIT_SHA=9e11997 BUILD_VERSION=1.4.2
  # A trailing slash must normalize, not produce //health/ready.
  run zsh "$CHECKER" "$BASE/"
  [ "$status" -eq 0 ]
  checker_passed "$output" "/health/ready"
  checker_passed "$output" "/health/live"
  # The report names the UNPREFIXED paths — a /v2 prefix would show up here.
  lacks "$output" '/v2/health'
  lacks "$output" '//health'
}

@test "tc-error-missing-git-sha-fails-fast: an unset GIT_SHA refuses to boot" {
  # Node stamps no VCS revision into a build, so /info's build.git_sha has no
  # truthful fallback — and a confidently-wrong commit in the ops surface sends an
  # operator to the wrong diff during an incident. The service must refuse to
  # start, naming the variable, rather than serve a placeholder.
  #
  # No GIT_SHA in the environment, and no OpsConfig.gitSha in the fixture.
  ops_run_expect_exit unwired
  [ "$OPS_STATUS" -ne 0 ]
  # The payload's actual refusal text, not a bare 'GIT_SHA' token: Node prints the
  # offending source line in an uncaught-exception trace, so any crash inside
  # resolveGitSha would satisfy a token needle while the claim under test — that
  # the service NAMES the missing variable — went unproven.
  grep -qF 'ops: GIT_SHA is not set and OpsConfig.gitSha was not supplied' "$OPS_LOG"
  # …and NOTHING may be left listening: a half-started surface answering probes
  # while /info is unservable is worse than a clean refusal.
  port_is_closed "$PORT"
}

@test "tc-error-deprecated-major-without-sunset: a deprecated major with no sunset refuses to boot" {
  # RFC 8594: a deprecated major must announce when it goes away. validateConfig
  # rejects it at STARTUP — earlier than the conformance job, which also fails it,
  # but only after a deploy.
  ops_run_expect_exit deprecated-no-sunset GIT_SHA=9e11997
  [ "$OPS_STATUS" -ne 0 ]
  grep -qF 'needs a sunset date (RFC 8594)' "$OPS_LOG"
  port_is_closed "$PORT"
}

@test "tc-error-under-reporting-aggregate: a hard dependency down forces a down aggregate" {
  # The components set a FLOOR on the aggregate, never an equality. Here the
  # service's own internalStatus hook claims "ok" while a hard dependency is down:
  # the floor must win, because under-reporting is the one direction the contract
  # forbids. (Over-reporting stays legal — that is what the hook is for.)
  ops_start under-report GIT_SHA=9e11997
  [ "$(jq -r .status <<< "$(http_body "$BASE/health")")" = "down" ]
  [ "$(jq -r '.components["orders-db"].status' <<< "$(http_body "$BASE/health")")" = "down" ]
  # …and the checker must REJECT that aggregate. `down` is a legitimate runtime
  # state but not a conforming one: conformance asserts a service that is serving.
  # This arm is what proves the case is testing the checker's verdict rather than
  # just the body — a payload that reported "ok" here would pass the checker and
  # fail this test.
  #
  # The status is pinned to 1, the checker's documented conformance-failure code,
  # NOT to `-ne 0`: exit 2 is its usage/tooling class (no jq, no curl, a bad URL)
  # and 127 is the checker having been renamed out from under us. And the reason
  # is asserted alongside it, because even the right exit code can be reached by an
  # unrelated one of the five checks failing.
  run zsh "$CHECKER" "$BASE"
  [ "$status" -eq 1 ]
  checker_failed "$output" 'aggregate status is "down"'
}
