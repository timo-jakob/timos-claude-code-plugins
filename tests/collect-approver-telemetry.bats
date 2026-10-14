#!/usr/bin/env bats
#
# collect-approver-telemetry.zsh (#1231): the gh-based collector that turns each
# instrumented review a `claude-approver` Bot posted into one `telemetry/v1`
# record through the shared emitter. Driven against a fake gh
# (tests/fixtures/approver-telemetry/gh-stub.zsh) serving committed fixture
# scenarios: the 30-day window and its paging, the author + Bot filter, every
# not-instrumented branch, idempotency in the ONE resolved sink file, the 0/2/3
# exit contract with its one named stderr line, and that no token ever reaches a
# sink, stdout or stderr. The payload rules themselves are
# tests/build-approver-telemetry-record.bats.

bats_require_minimum_version 1.5.0
load assertions
load approver-telemetry

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  apt_setup "$REPO_ROOT"
}

summary() {  # $1 recorded, $2 already recorded, $3 not instrumented
  [ "$output" = "collect-approver-telemetry: $REPO: recorded $1, skipped as already recorded $2, skipped as not instrumented $3" ]
}
# one_err ENDPOINT PR REVIEW — stderr is exactly one line naming all four
one_err() {
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = 1 ]
  contains "$stderr" "collect-approver-telemetry: $REPO: $1 failed"
  contains "$stderr" "— PR $2, review $3"
}
# only_review ID — serve only that review of the not-instrumented scenario
only_review() {
  use_scenario not-instrumented
  fx_edit reviews-420.json "map(select(.id == $1))"
}

# ------------------------------------------------------------------ happy path

@test "one instrumented review: exactly one valid approve run record with the PR, wall time and payload" {
  use_scenario python-rc
  collect
  [ "$status" -eq 0 ]
  summary 1 0 0
  [ -z "$stderr" ]
  [ "$(lines "$T")" = 1 ]
  local r; r="$(cat "$T")"
  [ "$(jq -c '[.kind, .pipeline, .repo, .pr, .issue, .tokens, .outcome, .wall_s]' <<<"$r")" = '["run","approve","timo-jakob/ai-doc-organizer",412,null,null,"success",214]' ]
  [ "$(jq -r .ts <<<"$r")" = "$(jq -n -r '"2026-10-04T10:00:00Z" | fromdateiso8601')" ]
  [ "$(jq -c .payload <<<"$r")" = '{"verdict":"REQUEST_CHANGES","confidence":"LOW","risk_register_size":2,"dimensions":["bugs","security","performance","code_quality","tests","resilience"],"pr_type":"feat","language":"python","review_id":2930481177,"head_sha":"4f2c9e1a0b","approver_version":"v1"}' ]
  run zsh "$VALIDATE" --require-records "$T"
  [ "$status" -eq 0 ]
}

@test "PRs are walked in ascending number and each PR's reviews in ascending id, one record per review" {
  use_scenario two-prs
  collect
  [ "$status" -eq 0 ]
  summary 3 0 0
  [ "$(jq -c -s 'map([.pr, .payload.review_id, .payload.verdict, .outcome])' "$T")" = '[[412,2930481177,"REQUEST_CHANGES","success"],[413,2930481300,"COMMENT","success"],[413,2930481400,"APPROVE","success"]]' ]
}

# ------------------------------------------------------------- which reviews count

@test "a review by a non-approver author, or by a claude-approver login that is not a Bot, is ignored and uncounted" {
  local id
  for id in 3006 3007 other-bot; do
    rm -rf -- "$FX" "${T%/*}"
    setup
    if [ "$id" = other-bot ]; then
      only_review 3006
      fx_edit reviews-420.json '.[0].user = {"login": "renovate[bot]", "type": "Bot"}'
    else
      only_review "$id"
    fi
    collect
    printf 'case: %s\n' "$id" >&2
    [ "$status" -eq 0 ]
    summary 0 0 0
    [ ! -e "$T" ]
  done
}

@test "each not-instrumented review yields no record and is counted: no block, no started_at, truncated, non-positive wall, refused" {
  local id
  for id in 3001 3002 3003 3004 3005 3008; do
    rm -rf -- "$FX" "${T%/*}"
    setup
    only_review "$id"
    collect
    printf 'case: review %s\n' "$id" >&2
    [ "$status" -eq 0 ]
    summary 0 0 1
    [ ! -e "$T" ]
  done
}

@test "the whole not-instrumented scenario: six counted, two ignored, nothing recorded" {
  use_scenario not-instrumented
  collect
  [ "$status" -eq 0 ]
  summary 0 0 6
  [ ! -e "$T" ]
}

@test "started_at given as a digit string still counts; a fractional one does not" {
  use_scenario python-rc
  fx_edit reviews-412.json '.[0].body |= sub("\"started_at\":(?<n>[0-9]+)"; "\"started_at\":\"\(.n)\"")'
  collect
  [ "$status" -eq 0 ]
  summary 1 0 0
  [ "$(jq -r .wall_s "$T")" = 214 ]
  rm -f "$T"
  use_scenario python-rc
  fx_edit reviews-412.json '.[0].body |= sub("\"started_at\":(?<n>[0-9]+)"; "\"started_at\":\(.n).5")'
  collect
  summary 0 0 1
}

@test "a block complete but for started_at is not instrumented — the emitter is never reached without a wall time" {
  use_scenario python-rc
  fx_edit reviews-412.json '.[0].body |= sub(",\"started_at\":[0-9]+"; "")'
  collect
  [ "$status" -eq 0 ]
  summary 0 0 1
  [ ! -e "$T" ]
}

@test "a review with no submitted_at is not instrumented" {
  use_scenario python-rc
  fx_edit reviews-412.json '.[0].submitted_at = null'
  collect
  [ "$status" -eq 0 ]
  summary 0 0 1
}

@test "the last hidden block in a body is the one read" {
  use_scenario python-rc
  fx_edit reviews-412.json '.[0].body = ("<!-- claude-approver:findings\n{\"quoted\": true}\n-->\n" + .[0].body)'
  collect
  [ "$status" -eq 0 ]
  summary 1 0 0
}

# ------------------------------------------------------------------ the window

@test "the pulls request is newest-updated first; a PR updated more than 30 days ago is not traversed" {
  use_scenario python-rc
  collect
  [ "$status" -eq 0 ]
  contains "$(cat "$GH_LOG")" "repos/$REPO/pulls?state=all&sort=updated&direction=desc&per_page=100&page=1"
  lacks "$(cat "$GH_LOG")" "pulls/409/reviews"
  [ "$(jq -c -s 'map(.pr)' "$T")" = '[412]' ]
}

@test "a full page whose PRs are all inside the window reads the next page; a short page ends the walk" {
  use_scenario python-rc
  fx_edit pulls.json '[range(100) | {number: (1000 + .), updated_at: "@ago:1d"}]'
  local i
  for i in $(seq 1000 1099); do printf '[]\n' > "$FX/reviews-$i.json"; done
  printf '%s\n' '[{"number":412,"updated_at":"@ago:2d"}]' > "$FX/pulls-p2.json"
  collect
  [ "$status" -eq 0 ]
  summary 1 0 0
  contains "$(cat "$GH_LOG")" "&page=2"
  lacks "$(cat "$GH_LOG")" "&page=3"
}

@test "a full page that reaches past the window ends the walk" {
  use_scenario python-rc
  fx_edit pulls.json '[range(99) | {number: (1000 + .), updated_at: "@ago:1d"}] + [{number: 412, updated_at: "@ago:31d"}]'
  local i
  for i in $(seq 1000 1098); do printf '[]\n' > "$FX/reviews-$i.json"; done
  collect
  [ "$status" -eq 0 ]
  summary 0 0 0
  lacks "$(cat "$GH_LOG")" "&page=2"
  lacks "$(cat "$GH_LOG")" "pulls/412/reviews"
}

@test "no PR in the window exits 0 with no records" {
  use_scenario python-rc
  printf '[]\n' > "$FX/pulls.json"
  collect
  [ "$status" -eq 0 ]
  summary 0 0 0
  [ -z "$stderr" ]
  [ ! -e "$T" ]
}

# ---------------------------------------------------------------- idempotency

@test "a re-run appends nothing and counts the skips" {
  use_scenario two-prs
  collect
  collect
  [ "$status" -eq 0 ]
  summary 0 3 0
  [ "$(lines "$T")" = 3 ]
}

@test "a matching record in another file does not count: only the resolved sink is read" {
  use_scenario python-rc
  local other="$BATS_TEST_TMPDIR/other.jsonl"
  collect --telemetry-file "$other"
  [ "$(lines "$other")" = 1 ]
  collect
  [ "$status" -eq 0 ]
  summary 1 0 0
  [ "$(lines "$T")" = 1 ]
}

@test "only a pipeline approve record counts: another pipeline's record with the same review_id does not" {
  use_scenario python-rc
  mkdir -p "${T%/*}"
  zsh "$EMITTER" --pipeline maintenance --outcome success --wall-s 1 --repo "$REPO" \
    --payload <(printf '{"review_id":2930481177}') --telemetry-file "$T" > /dev/null
  collect
  [ "$status" -eq 0 ]
  summary 1 0 0
  [ "$(lines "$T")" = 2 ]
}

@test "--telemetry-dir: DIR/<repo-slug>.jsonl is the sink and the only file read for idempotency" {
  use_scenario python-rc
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
  use_scenario python-rc
  run --separate-stderr zsh "$COLLECT" --repo "$REPO"
  [ "$status" -eq 0 ]
  [ "$(lines "$HOME/.claude/telemetry/timo-jakob-ai-doc-organizer.jsonl")" = 1 ]
  run --separate-stderr zsh "$COLLECT" --repo "$REPO"
  summary 0 1 0
}

@test "no sink flag and an empty HOME: exit 3, nothing written" {
  use_scenario python-rc
  run --separate-stderr env HOME= zsh "$COLLECT" --repo "$REPO"
  [ "$status" -eq 3 ]
  contains "$stderr" "HOME is not set"
  [ -z "$output" ]
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

@test "a failing pulls listing exits 3 with one line naming the repo and the pulls endpoint" {
  use_scenario python-rc
  printf '502\n' > "$FX/pulls.status"
  collect
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  one_err "gh api repos/$REPO/pulls" none none
  contains "$stderr" "(HTTP 502)"
  [ ! -e "$T" ]
}

@test "a pulls 404 — a mistyped or inaccessible --repo — is a failure, never 'nothing to collect'" {
  use_scenario python-rc
  printf '404\n' > "$FX/pulls.status"
  collect
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  one_err "gh api repos/$REPO/pulls" none none
  contains "$stderr" "(HTTP 404)"
}

@test "a failing reviews listing stops there: earlier records stand, no partial line, a re-run resumes" {
  use_scenario two-prs
  printf '500\n' > "$FX/reviews-413.status"
  collect
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  one_err "gh api repos/$REPO/pulls/413/reviews" 413 none
  [ "$(jq -c -s 'map(.payload.review_id)' "$T")" = '[2930481177]' ]
  run zsh "$VALIDATE" --require-records "$T"
  [ "$status" -eq 0 ]
  rm "$FX/reviews-413.status"
  collect
  [ "$status" -eq 0 ]
  summary 2 1 0
}

@test "an unreadable reviews answer exits 3 naming the reviews endpoint" {
  use_scenario python-rc
  printf '{"message":"not a list"}\n' > "$FX/reviews-412.json"
  collect
  [ "$status" -eq 3 ]
  one_err "gh api repos/$REPO/pulls/412/reviews" 412 none
  contains "$stderr" "(unreadable response)"
}

@test "an emitter failure stops at that review: earlier records stand, no partial line, a re-run resumes" {
  use_scenario two-prs
  fail_emit_on 2
  collect
  [ "$status" -eq 3 ]
  one_err "emit-stub.zsh" 413 2930481300
  contains "$stderr" "exit 3: emit-telemetry: cannot append to sink: stubbed failure"
  [ "$(lines "$T")" = 1 ]
  run zsh "$VALIDATE" --require-records "$T"
  [ "$status" -eq 0 ]
  unset APPROVER_TELEMETRY_EMITTER_BIN
  collect
  [ "$status" -eq 0 ]
  summary 2 1 0
  [ "$(jq -c -s 'map(.payload.review_id)' "$T")" = '[2930481177,2930481300,2930481400]' ]
}

@test "a missing emitter exits 3 before any gh call" {
  use_scenario python-rc
  export APPROVER_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/no-such-emitter"
  collect
  [ "$status" -eq 3 ]
  one_err "no-such-emitter" none none
  [ ! -e "$GH_LOG" ]
}

# ------------------------------------------------------------------- secrets

@test "no token reaches the sink, stdout or stderr — on success and on the failure path" {
  local tok="ghs_fake-token-0000"
  use_scenario two-prs
  export GH_STUB_LEAK=1 GH_TOKEN="$tok"
  collect
  [ "$status" -eq 0 ]
  local all; all="$(cat "$T")$output$stderr"
  lacks "$all" "$tok"
  lacks "$all" "Authorization"
  rm -f "$T"
  printf '502\n' > "$FX/reviews-413.status"
  collect
  [ "$status" -eq 3 ]
  all="$(cat "$T")$output$stderr"
  lacks "$all" "$tok"
  lacks "$all" "Authorization"
}

@test "a token-shaped value inside a bot's block is never recorded: the review is not instrumented" {
  use_scenario python-rc
  fx_edit reviews-412.json '.[0].body |= sub("\"type_detected\":\"feat\""; "\"type_detected\":\"ghs_fake0000\"")'
  collect
  [ "$status" -eq 0 ]
  summary 0 0 1
  [ ! -e "$T" ]
}
