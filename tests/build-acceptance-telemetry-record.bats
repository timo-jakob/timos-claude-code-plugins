#!/usr/bin/env bats
#
# build-acceptance-telemetry-record.zsh (#1230): the pure payload builder for
# one settled `acceptance (<interface>)` check run — the payload's shape, the
# <testsuite>-level JUnit counts, the harness rule, the reliability rule (an
# unreadable report withholds every count), the count-consistency refusal, the
# job refusals, and the conclusion -> outcome table behind --print-outcome. The
# collector that feeds it from GitHub is tests/collect-acceptance-telemetry.bats.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  B="$REPO_ROOT/development/scripts/telemetry/build-acceptance-telemetry-record.zsh"
  J="$REPO_ROOT/tests/fixtures/acceptance-telemetry/junit"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  JOB="$BATS_TEST_TMPDIR/job.json"
  X="$BATS_TEST_TMPDIR/report.xml"
  URL="https://api.github.com/repos/timo-jakob/ai-doc-organizer/actions/artifacts/7001"
  printf '%s' '{"id":31877410925,"run_id":9001,"run_attempt":1,"name":"acceptance (cli)","status":"completed","conclusion":"success","head_sha":"4f2c9e1","started_at":"2026-10-04T10:00:00Z","completed_at":"2026-10-04T10:01:14Z"}' > "$JOB"
}

edit() { jq -c "$1" "$JOB" > "$JOB.new" && mv "$JOB.new" "$JOB"; }
build() { run --separate-stderr zsh "$B" --job "$JOB" "$@"; }
# report FILE… — build with the given JUnit files as the cli leg's artifact
report() {
  local a=() f
  for f in "$@"; do a+=(--junit "$f"); done
  build "${a[@]}" --artifact-name acceptance-report-cli --artifact-url "$URL"
}
withheld() {  # the last build exited 0 with every count, harness and report_artifact null
  [ "$status" -eq 0 ]
  [ "$(jq -c .tests <<<"$output")" = '{"passed":null,"failed":null,"skipped":null,"total":null}' ]
  [ "$(jq -c '[.harness, .report_artifact]' <<<"$output")" = '[null,null]' ]
  [ "$(jq -r .conclusion <<<"$output")" = "success" ]
}
refused() {  # $1 = the refusal text expected on stderr
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "$1"
}

# ------------------------------------------------------------------- payload

@test "a pytest report: the payload carries exactly the documented keys and the <testsuite> counts" {
  report "$J/pytest-real.xml"
  [ "$status" -eq 0 ]
  [ "$(jq -c 'keys_unsorted' <<<"$output")" = '["interface","conclusion","tests","report_artifact","harness","check_run_id","head_sha"]' ]
  [ "$(jq -c .tests <<<"$output")" = '{"passed":12,"failed":0,"skipped":1,"total":13}' ]
  [ "$(jq -r .interface <<<"$output")" = "cli" ]
  [ "$(jq -r .conclusion <<<"$output")" = "success" ]
  [ "$(jq -r .harness <<<"$output")" = "real" ]
  [ "$(jq -c .report_artifact <<<"$output")" = "{\"name\":\"acceptance-report-cli\",\"url\":\"$URL\"}" ]
  [ "$(jq -c '[.check_run_id, .head_sha]' <<<"$output")" = '[31877410925,"4f2c9e1"]' ]
}

@test "failed counts failures plus errors; an absent attribute is 0 and shifts no other count" {
  printf '%s\n' '<testsuites><testsuite tests="5" failures="1" errors="2">' \
    '<testcase classname="t" name="a"/></testsuite></testsuites>' > "$X"
  report "$X"
  [ "$status" -eq 0 ]
  [ "$(jq -c .tests <<<"$output")" = '{"passed":2,"failed":3,"skipped":0,"total":5}' ]
  printf '%s\n' '<testsuite tests="3" skipped="1"><testcase classname="t" name="a"/></testsuite>' > "$X"
  report "$X"
  [ "$(jq -c .tests <<<"$output")" = '{"passed":2,"failed":0,"skipped":1,"total":3}' ]
}

@test "only the innermost <testsuite> elements count, so a nesting aggregate is never added twice" {
  report "$J/nested.xml"
  [ "$status" -eq 0 ]
  [ "$(jq -c .tests <<<"$output")" = '{"passed":3,"failed":1,"skipped":1,"total":5}' ]
}

@test "every --junit file of the artifact is summed" {
  edit '.name = "acceptance (rest)"'
  run --separate-stderr zsh "$B" --job "$JOB" --junit "$J/pytest-real.xml" --junit "$J/skeleton-rest.xml" \
    --artifact-name acceptance-report-rest --artifact-url "$URL"
  [ "$status" -eq 0 ]
  [ "$(jq -c .tests <<<"$output")" = '{"passed":13,"failed":0,"skipped":1,"total":14}' ]
  [ "$(jq -r .harness <<<"$output")" = "real" ]
}

@test "a byte-order mark, CRLF line ends, single-quoted attributes and a DOCTYPE still parse" {
  printf '\357\273\277<?xml version="1.0"?>\r\n<!DOCTYPE testsuites>\r\n<testsuites>\r\n' > "$X"
  printf "<testsuite tests='2' failures='0' errors='0' skipped='1'>\r\n" >> "$X"
  printf "<testcase classname='t' name='a'/><testcase classname='t' name='b'><skipped/></testcase>\r\n" >> "$X"
  printf '</testsuite>\r\n</testsuites>\r\n' >> "$X"
  report "$X"
  [ "$status" -eq 0 ]
  [ "$(jq -c .tests <<<"$output")" = '{"passed":1,"failed":0,"skipped":1,"total":2}' ]
}

# --------------------------------------------------------------- harness rule

@test "harness is skeleton when every testcase is the spine marker of the job's own interface" {
  edit '.name = "acceptance (rest)"'
  run --separate-stderr zsh "$B" --job "$JOB" --junit "$J/skeleton-rest.xml" \
    --artifact-name acceptance-report-rest --artifact-url "$URL"
  [ "$status" -eq 0 ]
  [ "$(jq -r .harness <<<"$output")" = "skeleton" ]
  [ "$(jq -c .tests <<<"$output")" = '{"passed":1,"failed":0,"skipped":0,"total":1}' ]
}

@test "harness is real when the marker's classname names another interface" {
  report "$J/skeleton-rest.xml"
  [ "$status" -eq 0 ]
  [ "$(jq -r .harness <<<"$output")" = "real" ]
}

@test "harness is real when any other testcase sits beside the marker" {
  report "$J/nested.xml"
  [ "$status" -eq 0 ]
  [ "$(jq -r .harness <<<"$output")" = "real" ]
}

# ---------------------------------------------- reliability rule: withheld, not guessed

@test "no --junit: every count, harness and report_artifact is null and the conclusion stands" {
  build
  withheld
}

@test "a truncated report is unreadable: counts withheld, exit 0" {
  report "$J/truncated.xml"
  withheld
}

@test "each malformed shape is unreadable rather than half-counted" {
  local bad
  for bad in \
    '<testsuites><testsuite tests="1"><testcase name="a"/></testsuite>' \
    '<testsuites><testsuite tests="1"><testcase name="a"/></testsuites></testsuite>' \
    '<testsuite tests="1"><testcase name="a"/></testsuite><testsuite tests="1"/>' \
    '<testsuite tests="1"><testcase name="a"/></testsuite> trailing text' \
    '<testsuite tests="one"><testcase name="a"/></testsuite>' \
    '<testsuite failures="0"><testcase name="a"/></testsuite>' \
    '<testsuite tests="1" errors="x"><testcase name="a"/></testsuite>' \
    '<testsuite tests="1"><testcase name="a"/><!-- never closed </testsuite>' \
    '<testsuite tests="1"><testcase name="a"><![CDATA[ never closed </testcase></testsuite>' \
    '<testsuite tests="1"><testcase name="a" /></testsuite' \
    '<results><case/></results>' \
    '<testsuites><testsuite tests="0"/></testsuites>' \
    ''; do
    printf '%s\n' "$bad" > "$X"
    report "$X"
    printf 'case: %s\n' "$bad" >&2
    withheld
  done
}

@test "markup inside CDATA, a comment or a quoted attribute value is not read as a tag" {
  printf '%s\n' '<testsuites><!-- <testsuite tests="9"> -->' \
    '<testsuite tests="1" failures="0" errors="0"><testcase classname="t" name="x[a>b]">' \
    '<system-out><![CDATA[<testcase name="ghost"/> </testsuite>]]></system-out></testcase>' \
    '</testsuite></testsuites>' > "$X"
  report "$X"
  [ "$status" -eq 0 ]
  [ "$(jq -c .tests <<<"$output")" = '{"passed":1,"failed":0,"skipped":0,"total":1}' ]
}

# ------------------------------------------------------------- refusals

@test "inconsistent counts: failures + errors + skipped above tests is refused with no output" {
  report "$J/inconsistent.xml"
  refused "report refused — passed + failed + skipped != total"
}

@test "a negative count is refused with no output, even when the totals add up" {
  report "$J/negative.xml"
  refused "report refused — a <testsuite> carries a negative count"
}

@test "--print-outcome refuses an inconsistent report too" {
  run --separate-stderr zsh "$B" --job "$JOB" --junit "$J/inconsistent.xml" \
    --artifact-name acceptance-report-cli --artifact-url "$URL" --print-outcome
  refused "report refused"
}

@test "a job that is not one settled acceptance check run is refused" {
  local e
  for e in '.status = "in_progress"' '.conclusion = null' '.name = "build"' '.name = "acceptance"' \
    '.id = 0' '.id = "31001"' '.head_sha = ""' '.started_at = null' '.completed_at = "yesterday"' \
    '.completed_at = "2026-10-04T09:59:59Z"'; do
    setup
    edit "$e"
    build
    [ "$status" -eq 1 ] || { printf 'not refused: %s\n' "$e" >&2; return 1; }
    [ -z "$output" ]
    contains "$stderr" "job refused — "
  done
}

@test "each job refusal names its rule" {
  edit '.status = "in_progress" | .conclusion = null | .completed_at = null'
  build
  [ "$status" -eq 1 ]
  contains "$stderr" "status must be \"completed\" (the check run has not settled)"
  contains "$stderr" "conclusion must be a non-empty string"
  contains "$stderr" "completed_at must be an ISO-8601 UTC timestamp"
  edit '.status = "completed" | .conclusion = "success" | .completed_at = "2026-10-04T09:00:00Z"'
  build
  contains "$stderr" "completed_at is before started_at"
}

# -------------------------------------------------------------- outcome table

@test "--print-outcome maps every conclusion per the envelope table" {
  local pair
  for pair in success:success failure:failed timed_out:failed startup_failure:failed \
    skipped:parked cancelled:parked neutral:parked action_required:parked stale:parked \
    something_new:failed; do
    edit ".conclusion = \"${pair%%:*}\""
    build --print-outcome
    [ "$status" -eq 0 ]
    [ "$output" = "${pair#*:}" ] || { printf '%s -> %s\n' "$pair" "$output" >&2; return 1; }
  done
}

@test "a cancelled check is parked, never failed, and the payload keeps the conclusion verbatim" {
  edit '.conclusion = "cancelled"'
  build --print-outcome
  [ "$output" = "parked" ]
  build
  [ "$(jq -r .conclusion <<<"$output")" = "cancelled" ]
}

# --------------------------------------------------------------------- usage

@test "usage errors exit 2 with nothing on stdout" {
  run --separate-stderr zsh "$B"
  [ "$status" -eq 2 ]; [ -z "$output" ]; contains "$stderr" "--job is required"
  build --junit "$J/pytest-real.xml"
  [ "$status" -eq 2 ]; contains "$stderr" "--junit needs --artifact-name and --artifact-url"
  build --artifact-name acceptance-report-cli --artifact-url "$URL"
  [ "$status" -eq 2 ]; contains "$stderr" "none was given"
  build --bogus
  [ "$status" -eq 2 ]; contains "$stderr" "unknown flag: --bogus"
  build extra
  [ "$status" -eq 2 ]; contains "$stderr" "unexpected argument: extra"
  build --junit
  [ "$status" -eq 2 ]; contains "$stderr" "--junit requires a value"
  run --separate-stderr zsh "$B" --job "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]; contains "$stderr" "--job file does not exist"
  run --separate-stderr zsh "$B" --job "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ]; contains "$stderr" "--job is a directory"
}

@test "a signed download URL is refused as --artifact-url; only the API artifact URL is accepted" {
  build --junit "$J/pytest-real.xml" --artifact-name acceptance-report-cli \
    --artifact-url "https://results-receiver.actions.githubusercontent.com/actions/artifacts/7001?sig=fakesig"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--artifact-url must be an API artifact URL"
  build --junit "$J/pytest-real.xml" --artifact-name acceptance-report-cli \
    --artifact-url "$URL/zip"
  [ "$status" -eq 2 ]
}

@test "a --job that is not one JSON object exits 1" {
  printf '[1]' > "$JOB"
  build
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "--job must be a single JSON object"
}

# ------------------------------------------------------------- ARCHITECTURE.md

@test "ARCHITECTURE.md documents the decision, the collector and builder, the exit contract and the payload keys" {
  local arch
  arch="$(tr -s '[:space:]' ' ' < "$ARCH")"
  contains "$arch" "## Acceptance telemetry (#1230)"
  contains "$arch" "**Collected from the machine that has the emitter, from settled results.**"
  contains "$arch" "Vendoring the emitter into every bootstrapped repo was rejected: a copy of the contract per repo is the copy-adaptation drift the contract exists to end, and it would still need a collection step."
  contains "$arch" "Deferring acceptance telemetry was rejected: the stage's adoption is precisely what the epic's coverage claim measures."
  contains "$arch" "\`development/scripts/telemetry/collect-acceptance-telemetry.zsh --repo OWNER/NAME [--telemetry-file PATH] [--telemetry-dir DIR]\`"
  contains "$arch" "one \`kind: \"run\"\` record, \`pipeline: \"acceptance\"\`, per completed \`acceptance (<interface>)\` check run — every job attempt"
  contains "$arch" "A check run whose id is already \`payload.check_run_id\` on a \`pipeline: \"acceptance\"\` record in **that one file** is skipped; a record in any other file does not count."
  contains "$arch" "\`build-acceptance-telemetry-record.zsh\`"
  contains "$arch" "total = Σ \`tests\`, failed = Σ (\`failures\` + \`errors\`), skipped = Σ \`skipped\`, passed = total − failed − skipped"
  contains "$arch" "an artifact that is absent (404), expired (410) or unreadable yields a record whose counts, \`harness\` and \`report_artifact\` are all \`null\` — withheld, never guessed — with the conclusion intact"
  contains "$arch" "| \`0\` | the collection completed — including nothing to collect, a repo with no \`acceptance.yml\` workflow (its runs endpoint answers 404 while the repo itself answers), and records with withheld counts |"
  contains "$arch" "| \`2\` | usage — no \`--repo\`, a malformed one, an unknown or dangling flag, a positional, a \`--telemetry-dir\` that exists and is not a directory; judged before any \`gh\` call |"
  contains "$arch" "| \`3\` | a \`gh\` call listing runs or jobs failed (other than the workflow's 404 on a repo that answers; a mistyped or inaccessible \`--repo\` is a failure, #2560), the artifacts listing or an artifact download failed other than 404/410, or the builder or the emitter failed |"
  contains "$arch" "Every exit 3 prints one stderr line naming the repo, the failing endpoint or script, and the run and check-run id it was processing"
  contains "$arch" "after a transient failure (\`gh\`, the emitter) a re-run resumes through idempotency. A job the builder refuses refuses again on every re-run, so it halts collection until its run leaves the 30-day window."
  local k
  for k in interface conclusion tests report_artifact harness check_run_id head_sha; do
    contains "$arch" "| \`$k\` |"
  done
  contains "$arch" "| \`parked\` | \`skipped\`, \`cancelled\`, \`neutral\`, \`action_required\`, \`stale\` — never counted as a failure |"
}
