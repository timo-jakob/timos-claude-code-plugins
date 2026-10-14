#!/usr/bin/env bats
#
# collect-acceptance-telemetry.zsh (#1230): the gh-based collector that turns
# each settled `acceptance (<interface>)` check run of a repo into one
# `telemetry/v1` record through the shared emitter. Driven against a fake gh
# (tests/fixtures/acceptance-telemetry/gh-stub.zsh) serving committed fixture
# scenarios: the 30-day window, PR-less and in-progress skips, idempotency in
# the ONE resolved sink file, the artifact reliability rule (404 / 410 /
# expired / corrupt / unreadable / inconsistent -> withheld counts), the 0/2/3
# exit contract with its one named stderr line, and that no token or signed
# download URL ever reaches a sink, stdout or stderr. The payload rules
# themselves are tests/build-acceptance-telemetry-record.bats.

bats_require_minimum_version 1.5.0
load assertions
load acceptance-telemetry

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  at_setup "$REPO_ROOT"
}

summary() {  # $1 collected, $2 already recorded, $3 withheld
  [ "$output" = "collect-acceptance-telemetry: $REPO: collected $1, skipped as already recorded $2, recorded with withheld counts $3" ]
}
# one_err ENDPOINT RUN CHECK — stderr is exactly one line naming all four
one_err() {
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  contains "$stderr" "collect-acceptance-telemetry: $REPO: $1 failed"
  contains "$stderr" "— run $2, check run $3"
}
nulls() {  # $1 = a record: every count, harness and report_artifact null
  [ "$(jq -c '[.payload.tests, .payload.harness, .payload.report_artifact]' <<<"$1")" = '[{"passed":null,"failed":null,"skipped":null,"total":null},null,null]' ]
}

# ------------------------------------------------------------------ happy path

@test "one completed cli leg: exactly one valid run record with the job's id, PR, duration and counts" {
  use_scenario single-cli
  collect
  [ "$status" -eq 0 ]
  summary 1 0 0
  [ -z "$stderr" ]
  [ "$(lines "$T")" = 1 ]
  local r; r="$(cat "$T")"
  [ "$(jq -c '[.kind, .pipeline, .repo, .pr, .issue, .tokens, .outcome, .wall_s]' <<<"$r")" = '["run","acceptance","timo-jakob/ai-doc-organizer",412,null,null,"success",74]' ]
  [ "$(jq -r .ts <<<"$r")" = "$(jq -n -r '"2026-10-04T10:00:00Z" | fromdateiso8601')" ]
  [ "$(jq -c '[.payload.interface, .payload.check_run_id, .payload.harness]' <<<"$r")" = '["cli",31001,"real"]' ]
  [ "$(jq -c .payload.tests <<<"$r")" = '{"passed":12,"failed":0,"skipped":1,"total":13}' ]
  [ "$(jq -r .payload.report_artifact.url <<<"$r")" = "https://api.github.com/repos/$REPO/actions/artifacts/7001" ]
  run zsh "$VALIDATE" --require-records "$T"
  [ "$status" -eq 0 ]
}

@test "a job not named acceptance (<interface>) in the same run is never recorded" {
  use_scenario single-cli
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -c -s 'map(.payload.check_run_id)' "$T")" = '[31001]' ]
}

@test "a matrix run yields one record per leg; the skeleton leg reads harness skeleton" {
  use_scenario matrix
  collect
  [ "$status" -eq 0 ]
  summary 2 0 0
  [ "$(jq -c -s 'map([.payload.interface, .payload.harness, .pr])' "$T")" = '[["cli","real",413],["rest","skeleton",413]]' ]
}

@test "two attempts of one leg: two records, distinct check_run_ids, parked then success" {
  use_scenario superseded
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -c -s 'map([.payload.check_run_id, .outcome, .payload.conclusion])' "$T")" = '[[33001,"parked","cancelled"],[33002,"success","success"]]' ]
  # the cancelled attempt's window holds no artifact; the re-run's does
  nulls "$(sed -n 1p "$T")"
  [ "$(sed -n 2p "$T" | jq -c .payload.tests)" = '{"passed":12,"failed":0,"skipped":1,"total":13}' ]
}

@test "every non-success conclusion maps per the envelope table, and empty artifacts withhold counts" {
  use_scenario conclusions
  collect
  [ "$status" -eq 0 ]
  summary 6 0 6
  [ "$(jq -c -s 'map([.payload.conclusion, .outcome])' "$T")" = '[["timed_out","failed"],["startup_failure","failed"],["neutral","parked"],["action_required","parked"],["stale","parked"],["skipped","parked"]]' ]
  [ "$(jq -c -s 'map(.wall_s)' "$T")" = '[900,1,60,0,2,0]' ]
}

# ---------------------------------------------------------------- idempotency

@test "a re-run appends nothing and counts the skips" {
  use_scenario matrix
  collect
  collect
  [ "$status" -eq 0 ]
  summary 0 2 0
  [ "$(lines "$T")" = 2 ]
}

@test "a matching record in another file does not count: only the resolved sink is read" {
  use_scenario single-cli
  local other="$BATS_TEST_TMPDIR/other.jsonl"
  collect --telemetry-file "$other"
  [ "$(lines "$other")" = 1 ]
  collect
  [ "$status" -eq 0 ]
  summary 1 0 0
  [ "$(lines "$T")" = 1 ]
}

@test "only a pipeline acceptance record counts: another pipeline's record with the same id does not" {
  use_scenario single-cli
  mkdir -p "${T%/*}"
  zsh "$EMITTER" --pipeline maintenance --outcome success --wall-s 1 --repo "$REPO" \
    --payload <(printf '{"check_run_id":31001}') --telemetry-file "$T" > /dev/null
  collect
  [ "$status" -eq 0 ]
  summary 1 0 0
  [ "$(lines "$T")" = 2 ]
}

@test "--telemetry-dir: DIR/<repo-slug>.jsonl is the sink and the only file read for idempotency" {
  use_scenario single-cli
  local d="$BATS_TEST_TMPDIR/tdir"
  mkdir -p "$d"
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" --telemetry-dir "$d"
  [ "$status" -eq 0 ]
  mv "$d/timo-jakob-ai-doc-organizer.jsonl" "$d/timo-jakob-other.jsonl"
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" --telemetry-dir "$d"
  [ "$status" -eq 0 ]
  summary 1 0 0
  [ "$(lines "$d/timo-jakob-ai-doc-organizer.jsonl")" = 1 ]
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" --telemetry-dir "$d"
  summary 0 1 0
  [ "$(lines "$d/timo-jakob-ai-doc-organizer.jsonl")" = 1 ]
  [ "$(lines "$d/timo-jakob-other.jsonl")" = 1 ]
}

@test "no sink flag: the user-level default under HOME is written and read" {
  use_scenario single-cli
  run --separate-stderr zsh "$COLLECT" --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(lines "$HOME/.claude/telemetry/timo-jakob-ai-doc-organizer.jsonl")" = 1 ]
  run --separate-stderr zsh "$COLLECT" --repo "$REPO"
  summary 0 1 0
}

@test "no sink flag and an empty HOME: exit 3, nothing written" {
  use_scenario single-cli
  run --separate-stderr env HOME= zsh "$COLLECT" --repo "$REPO"
  [ "$status" -eq 3 ]
  contains "$stderr" "HOME is not set"
  [ -z "$output" ]
}

# ------------------------------------------------------------- what is walked

@test "the runs request carries created=>=<today-30d>; a run older than 30 days is not traversed" {
  use_scenario window
  collect
  [ "$status" -eq 0 ]
  local cutoff; cutoff="$(jq -n -r 'now - 30 * 86400 | strftime("%Y-%m-%d")')"
  contains "$(cat "$GH_LOG")" "actions/workflows/acceptance.yml/runs?created=>=$cutoff&per_page=100"
  lacks "$(cat "$GH_LOG")" "runs/9006/"
  [ "$(jq -c -s 'map(.pr)' "$T")" = '[416]' ]
}

@test "a run with no associated PR is skipped without fetching its jobs" {
  use_scenario single-cli
  fx_edit runs.json '.workflow_runs[0].pull_requests = []'
  collect
  [ "$status" -eq 0 ]
  summary 0 0 0
  [ ! -e "$T" ]
  lacks "$(cat "$GH_LOG")" "runs/9001/jobs"
}

@test "an in-progress job is skipped, and a later run records it once it completed" {
  use_scenario single-cli
  fx_edit jobs-9001.json '.jobs[0].status = "in_progress" | .jobs[0].conclusion = null | .jobs[0].completed_at = null'
  collect
  [ "$status" -eq 0 ]
  summary 0 0 0
  [ ! -e "$T" ]
  use_scenario single-cli
  collect
  summary 1 0 0
}

@test "no runs in the window and no acceptance workflow both exit 0 with no records" {
  use_scenario single-cli
  fx_edit runs.json '.workflow_runs = [] | .total_count = 0'
  collect
  [ "$status" -eq 0 ]
  summary 0 0 0
  printf '404\n' > "$FX/runs.status"
  collect
  [ "$status" -eq 0 ]
  summary 0 0 0
  [ -z "$stderr" ]
  [ ! -e "$T" ]
}

# --------------------------------------------- reliability rule: withheld counts

@test "an artifact that cannot be read withholds every count, keeps the conclusion, exits 0" {
  local how
  for how in list-404 list-410 zip-404 zip-410 expired none truncated corrupt-zip inconsistent no-xml out-of-window; do
    rm -rf -- "$FX" "${T%/*}"
    setup
    use_scenario single-cli
    case "$how" in
    list-404) printf '404\n' > "$FX/artifacts-9001.status" ;;
    list-410) printf '410\n' > "$FX/artifacts-9001.status" ;;
    zip-404) printf '404\n' > "$FX/zip-7001.status" ;;
    zip-410) printf '410\n' > "$FX/zip-7001.status" ;;
    expired) fx_edit artifacts-9001.json '.artifacts[0].expired = true' ;;
    none) fx_edit artifacts-9001.json '.artifacts = []' ;;
    truncated) printf 'truncated.xml\n' > "$FX/zip-7001.junit" ;;
    corrupt-zip) printf 'PK not a zip' > "$FX/zip-7001.raw" ;;
    inconsistent) printf 'inconsistent.xml\n' > "$FX/zip-7001.junit" ;;
    no-xml) printf 'not a report\n' > "$BATS_TEST_TMPDIR/notes.txt"
      (cd "$BATS_TEST_TMPDIR" && python3 -I -m zipfile -c "$FX/zip-7001.raw" notes.txt) ;;
    out-of-window) fx_edit artifacts-9001.json '.artifacts[0].created_at = "2026-10-04T11:00:00Z"' ;;
    esac
    collect
    [ "$status" -eq 0 ] || { printf '%s: exit %s %s\n' "$how" "$status" "$stderr" >&2; return 1; }
    summary 1 0 1 || { printf '%s: %s\n' "$how" "$output" >&2; return 1; }
    nulls "$(cat "$T")" || { printf '%s: not withheld\n' "$how" >&2; return 1; }
    [ "$(jq -c '[.payload.conclusion, .outcome]' "$T")" = '["success","success"]' ]
  done
}

@test "an expired artifact is never downloaded" {
  use_scenario single-cli
  fx_edit artifacts-9001.json '.artifacts[0].expired = true'
  collect
  [ "$status" -eq 0 ]
  lacks "$(cat "$GH_LOG")" "/zip"
}

# ------------------------------------------------------------- exit contract

@test "usage errors exit 2 before any gh call" {
  run --separate-stderr zsh "$COLLECT"
  [ "$status" -eq 2 ]; contains "$stderr" "--repo OWNER/NAME is required"; contains "$stderr" "usage:"
  run --separate-stderr zsh "$COLLECT" --repo not-a-slug
  [ "$status" -eq 2 ]; contains "$stderr" "--repo must be OWNER/NAME"
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" --range 60d
  [ "$status" -eq 2 ]; contains "$stderr" "unknown flag: --range"
  run --separate-stderr zsh "$COLLECT" --repo
  [ "$status" -eq 2 ]; contains "$stderr" "--repo requires a value"
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" extra
  [ "$status" -eq 2 ]; contains "$stderr" "unexpected argument: extra"
  : > "$BATS_TEST_TMPDIR/a-file"
  run --separate-stderr zsh "$COLLECT" --repo "$REPO" --telemetry-dir "$BATS_TEST_TMPDIR/a-file"
  [ "$status" -eq 2 ]; contains "$stderr" "--telemetry-dir is not a directory"
  [ ! -e "$GH_LOG" ]
}

@test "a failing runs listing exits 3 with one line naming the repo and the runs endpoint" {
  use_scenario single-cli
  printf '502\n' > "$FX/runs.status"
  collect
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  one_err "gh api repos/$REPO/actions/workflows/acceptance.yml/runs" none none
  contains "$stderr" "(HTTP 502)"
  [ ! -e "$T" ]
}

@test "#2560 a runs 404 on a repo that does not answer is a mistyped or inaccessible --repo: exit 3, not 'no workflow'" {
  use_scenario single-cli
  printf '404\n' > "$FX/runs.status"
  printf '404\n' > "$FX/repo.status"
  collect
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  one_err "gh api repos/$REPO" none none
  contains "$stderr" "(HTTP 404)"
  [ ! -e "$T" ]
}

@test "a failing jobs listing exits 3 naming the run" {
  use_scenario single-cli
  printf '500\n' > "$FX/jobs-9001.status"
  collect
  [ "$status" -eq 3 ]
  one_err "gh api repos/$REPO/actions/runs/9001/jobs" 9001 none
}

@test "a failing artifacts listing (not 404/410) exits 3 naming the run and the check run" {
  use_scenario single-cli
  printf '503\n' > "$FX/artifacts-9001.status"
  collect
  [ "$status" -eq 3 ]
  one_err "gh api repos/$REPO/actions/runs/9001/artifacts" 9001 31001
  [ ! -e "$T" ]
}

@test "an artifact download 5xx exits 3 with no record; a re-run after recovery appends it with counts" {
  use_scenario matrix
  printf '502\n' > "$FX/zip-7102.status"
  collect
  [ "$status" -eq 3 ]
  one_err "gh api repos/$REPO/actions/artifacts/7102/zip" 9002 32002
  [ "$(jq -c -s 'map(.payload.check_run_id)' "$T")" = '[32001]' ]
  rm "$FX/zip-7102.status"
  collect
  [ "$status" -eq 0 ]
  summary 1 1 0
  [ "$(sed -n 2p "$T" | jq -c '[.payload.check_run_id, .payload.tests.total]')" = '[32002,1]' ]
}

@test "an emitter failure stops at that record: earlier records stand, no partial line, a re-run resumes" {
  use_scenario conclusions
  fx_edit jobs-9004.json '.jobs |= .[0:3]'
  fail_emit_on 2
  collect
  [ "$status" -eq 3 ]
  one_err "emit-stub.zsh" 9004 34002
  contains "$stderr" "exit 3: emit-telemetry: cannot append to sink: stubbed failure"
  [ "$(lines "$T")" = 1 ]
  run zsh "$VALIDATE" --require-records "$T"
  [ "$status" -eq 0 ]
  unset ACCEPTANCE_TELEMETRY_EMITTER_BIN
  collect
  [ "$status" -eq 0 ]
  summary 2 1 2
  [ "$(jq -c -s 'map(.payload.check_run_id)' "$T")" = '[34001,34002,34003]' ]
}

@test "a job the builder refuses exits 3 naming the builder" {
  use_scenario single-cli
  fx_edit jobs-9001.json '.jobs[0].completed_at = "2026-10-04T09:00:00Z"'
  collect
  [ "$status" -eq 3 ]
  one_err "build-acceptance-telemetry-record.zsh" 9001 31001
  [ ! -e "$T" ]
}

# ------------------------------------------------------------------- secrets

@test "no token and no signed download URL reaches the sink, stdout or stderr" {
  local tok="ghs_fake-token-0000"
  use_scenario single-cli
  export GH_STUB_LEAK=1 GH_TOKEN="$tok"
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -r .payload.report_artifact.url "$T")" = "https://api.github.com/repos/$REPO/actions/artifacts/7001" ]
  local all; all="$(cat "$T")$output$stderr"
  lacks "$all" "$tok"; lacks "$all" "sig="; lacks "$all" "results-receiver"
  # ...and not on the failure path either, where gh's stderr is the tempting thing to echo
  rm -f "$T"
  printf '502\n' > "$FX/zip-7001.status"
  collect
  [ "$status" -eq 3 ]
  all="$output$stderr"
  lacks "$all" "$tok"; lacks "$all" "sig="; lacks "$all" "results-receiver"
}
