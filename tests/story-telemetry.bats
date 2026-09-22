#!/usr/bin/env bats
#
# story-telemetry.zsh (#1226): the resolve-issue run's own telemetry — parsing
# the sink flags out of $ARGUMENTS, pre-minting the run_id, and the never-fatal
# build + emit through the shared emitter. The payload's own shape is
# tests/build-story-telemetry-record.bats; the review loop's --parent-run-id /
# --telemetry-dir forwarding is tests/resolve-story-loop.bats.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  D="$REPO_ROOT/development/skills/resolve-issue/scripts/story-telemetry.zsh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"

  # a throwaway repo with a real-looking remote, so the emitter derives the
  # identity the persona's reporting stack would see
  R="$BATS_TEST_TMPDIR/tenant-service"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" remote add origin https://github.com/timos-platform/tenant-service.git
  DEFAULT_SINK="$R/.claude/telemetry/telemetry.jsonl"

  RUN="$BATS_TEST_TMPDIR/run.json"
  ST="$BATS_TEST_TMPDIR/state.json"
  TDIR="$BATS_TEST_TMPDIR/telemetry"
  SLUG_SINK="$TDIR/timos-platform-tenant-service.jsonl"
}

state() { printf '%s' "$1" > "$ST"; }

SUCCESS='{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","risk":"elevated","pr":413,"story_spec_present":true}'

emit() {
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$ST" \
    --repo-dir "$R" --issue 412 "$@"
}

# --- args ---------------------------------------------------------------------

@test "args: flags on both sides of the issue reference, in any order" {
  run --separate-stderr zsh "$D" args --telemetry-dir "$TDIR" 412 --telemetry-file "$BATS_TEST_TMPDIR/f.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.issue_ref' <<<"$output")" = "412" ]
  [ "$(jq -r '.telemetry_dir' <<<"$output")" = "$TDIR" ]
  [ "$(jq -r '.telemetry_file' <<<"$output")" = "$BATS_TEST_TMPDIR/f.jsonl" ]
}

@test "args: a bare issue reference (number or URL) has null sinks" {
  run --separate-stderr zsh "$D" args https://github.com/timos-platform/tenant-service/issues/412
  [ "$status" -eq 0 ]
  [ "$(jq -r '.issue_ref' <<<"$output")" = "https://github.com/timos-platform/tenant-service/issues/412" ]
  [ "$(jq -c '[.telemetry_file, .telemetry_dir]' <<<"$output")" = "[null,null]" ]
}

# $@ = the arguments; asserts exit 2, the invocation help, and an empty stdout
rejects() {
  run --separate-stderr zsh "$D" args "$@"
  [ "$status" -eq 2 ] || { echo "want 2, got $status for: $*"; return 1; }
  [ -z "$output" ]
  contains "$stderr" "usage: /development:resolve-issue <issue-number|url>"
}

@test "args: no arguments prints the invocation help and exits 2" {
  rejects
}

@test "args: a flag with no value, an empty value or a flag-shaped value is refused" {
  rejects 412 --telemetry-dir
  rejects 412 --telemetry-file ""
  rejects --telemetry-dir --telemetry-file x 412
}

@test "args: an unknown flag (a typo included) is refused" {
  rejects 412 --telemetry-dirr "$TDIR"
  contains "$stderr" "unknown flag: --telemetry-dirr"
}

@test "args: more than one issue reference is refused" {
  rejects 412 413
  contains "$stderr" "more than one issue reference"
}

@test "args: a repeated sink flag is refused rather than last-wins" {
  rejects 412 --telemetry-dir a --telemetry-dir b
}

@test "args writes nothing anywhere, even on success" {
  local before after
  before="$(find "$BATS_TEST_TMPDIR" | sort)"
  run zsh "$D" args 412 --telemetry-dir "$TDIR"
  [ "$status" -eq 0 ]
  after="$(find "$BATS_TEST_TMPDIR" | sort)"
  [ "$before" = "$after" ]
}

# --- start --------------------------------------------------------------------

@test "start pre-mints a run_id in the emitter's format, stamped with the start time" {
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts 1752403000
  [ "$status" -eq 0 ]
  jq -e '.run_id | test("^resolve-issue-1752403000-[0-9a-f]{4}$")' <<<"$output" >/dev/null
  [ "$(jq '.ts' <<<"$output")" -eq 1752403000 ]
  # the run file holds the same document
  [ "$(jq -cS . "$RUN")" = "$(jq -cS . <<<"$output")" ]
}

@test "start: loop_args carries --parent-run-id and exactly the sink flags given" {
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts 1 \
    --telemetry-dir "$TDIR" --telemetry-file "$BATS_TEST_TMPDIR/f.jsonl"
  [ "$status" -eq 0 ]
  local id
  id="$(jq -r '.run_id' <<<"$output")"
  [ "$(jq -c '.loop_args' <<<"$output")" = "$(jq -nc --arg id "$id" --arg f "$BATS_TEST_TMPDIR/f.jsonl" --arg d "$TDIR" \
    '["--parent-run-id",$id,"--telemetry-file",$f,"--telemetry-dir",$d]')" ]
  run --separate-stderr zsh "$D" start --run-file "$BATS_TEST_TMPDIR/run-bare.json" --ts 1
  [ "$(jq -c '.loop_args | length' <<<"$output")" -eq 2 ]
}

@test "start: two runs stamped the same second still get distinct ids" {
  run zsh "$D" start --run-file "$RUN" --ts 5
  local a; a="$(jq -r '.run_id' <<<"$output")"
  local b="" i
  # the suffix is 16 random bits; a handful of draws all colliding is ~0.
  # Each draw is a different run with its own run file, as runs of two issues are.
  for i in 1 2 3 4 5; do
    run zsh "$D" start --run-file "$BATS_TEST_TMPDIR/run-$i.json" --ts 5
    b="$(jq -r '.run_id' <<<"$output")"
    [ "$b" != "$a" ] && break
  done
  [ "$b" != "$a" ]
}

@test "start touches no telemetry sink" {
  run zsh "$D" start --run-file "$RUN" --telemetry-dir "$TDIR"
  [ "$status" -eq 0 ]
  [ ! -e "$TDIR" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "start: usage errors exit 2" {
  run --separate-stderr zsh "$D" start
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts -1
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$D" start --run-file "$RUN" --telemetry-dir ""
  [ "$status" -eq 2 ]
  [ ! -e "$RUN" ]
}

@test "start: an unwritable run file exits 1 (no stamp, no telemetry)" {
  run --separate-stderr zsh "$D" start --run-file "$BATS_TEST_TMPDIR/no/such/dir/run.json"
  [ "$status" -eq 1 ]
  contains "$stderr" "cannot write the run file"
}

# --- emit ---------------------------------------------------------------------

@test "emit: a PR-opening run appends exactly one valid resolve-issue record" {
  zsh "$D" start --run-file "$RUN" --ts 1752403000 >/dev/null
  state "$SUCCESS"
  emit --now 1752403312 --repo-type claude-plugin
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$DEFAULT_SINK")" -eq 1 ]
  local rec; rec="$(cat "$DEFAULT_SINK")"
  [ "$(jq -r '.pipeline' <<<"$rec")" = "resolve-issue" ]
  [ "$(jq -r '.kind' <<<"$rec")" = "run" ]
  [ "$(jq -r '.outcome' <<<"$rec")" = "success" ]
  [ "$(jq '.pr' <<<"$rec")" -eq 413 ]
  [ "$(jq '.issue' <<<"$rec")" -eq 412 ]
  [ "$(jq '.wall_s' <<<"$rec")" -eq 312 ]
  [ "$(jq -r '.repo' <<<"$rec")" = "timos-platform/tenant-service" ]
  [ "$(jq -r '.repo_type' <<<"$rec")" = "claude-plugin" ]
  [ "$(jq -r '.tokens' <<<"$rec")" = "null" ]
  # the pre-minted id IS the record's id, and its stamp IS the record's ts
  [ "$(jq -r '.run_id' <<<"$rec")" = "$(jq -r '.run_id' "$RUN")" ]
  [ "$(jq -r '.run_id | split("-")[2]' <<<"$rec")" = "$(jq -r '.ts' <<<"$rec")" ]
  # printed as well as appended
  [ "$(jq -cS . <<<"$output")" = "$(jq -cS . <<<"$rec")" ]
  zsh "$VALIDATE" "$DEFAULT_SINK" --require-records
}

@test "emit: a gate-parked run lands parked with a null pr" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state '{"outcome":"gate-parked","dependency_precheck":"PROCEED","gate_verdict":"NEEDS_REFINEMENT","risk":"normal"}'
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$DEFAULT_SINK")" = "parked" ]
  [ "$(jq -r '.payload.gate_verdict' "$DEFAULT_SINK")" = "NEEDS_REFINEMENT" ]
  [ "$(jq -r '.pr' "$DEFAULT_SINK")" = "null" ]
  zsh "$VALIDATE" "$DEFAULT_SINK" --require-records
}

@test "emit: a precheck-rejected run lands parked with the rejection type" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state '{"outcome":"precheck-parked","dependency_precheck":"REJECT_CYCLE"}'
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$DEFAULT_SINK")" = "parked" ]
  [ "$(jq -r '.payload.dependency_precheck' "$DEFAULT_SINK")" = "REJECT_CYCLE" ]
  zsh "$VALIDATE" "$DEFAULT_SINK" --require-records
}

@test "emit: an escalated run lands escalated with the typed status" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state '{"outcome":"escalated","dependency_precheck":"PROCEED","gate_verdict":"READY","escalation_status":"BUDGET_EXHAUSTED"}'
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$DEFAULT_SINK")" = "escalated" ]
  [ "$(jq -r '.payload.escalation_status' "$DEFAULT_SINK")" = "BUDGET_EXHAUSTED" ]
  zsh "$VALIDATE" "$DEFAULT_SINK" --require-records
}

@test "emit: a failed run lands failed" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state '{"outcome":"failed","dependency_precheck":"PROCEED","gate_verdict":"READY"}'
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$DEFAULT_SINK")" = "failed" ]
}

@test "emit: each loop work-dir's ledger lands in payload.review_loop_run_ids, in order" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  mkdir -p "$BATS_TEST_TMPDIR/wd-blocking" "$BATS_TEST_TMPDIR/wd-promo"
  printf 'review-loop-100-aaaa\nreview-loop-100-bbbb\n' > "$BATS_TEST_TMPDIR/wd-blocking/.telemetry-run-ids"
  printf 'review-loop-200-cccc\n' > "$BATS_TEST_TMPDIR/wd-promo/.telemetry-run-ids"
  emit --loop-work-dir "$BATS_TEST_TMPDIR/wd-blocking" --loop-work-dir "$BATS_TEST_TMPDIR/wd-promo" \
    --loop-work-dir "$BATS_TEST_TMPDIR/wd-never-ran"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.payload.review_loop_run_ids' "$DEFAULT_SINK")" \
    = '["review-loop-100-aaaa","review-loop-100-bbbb","review-loop-200-cccc"]' ]
}

@test "emit: --telemetry-dir lands the record in DIR/<slug>.jsonl, not the default" {
  zsh "$D" start --run-file "$RUN" --telemetry-dir "$TDIR" >/dev/null
  state "$SUCCESS"
  emit
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$SLUG_SINK")" -eq 1 ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "emit: --telemetry-file beats --telemetry-dir" {
  local F="$BATS_TEST_TMPDIR/one.jsonl"
  zsh "$D" start --run-file "$RUN" --telemetry-dir "$TDIR" --telemetry-file "$F" >/dev/null
  state "$SUCCESS"
  emit
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$F")" -eq 1 ]
  [ ! -e "$SLUG_SINK" ]
  [ ! -e "$DEFAULT_SINK" ]
}

# --- never fatal ----------------------------------------------------------------

# after a failed emit: exit 0, one advisory line, nothing in any sink
advised() {
  [ "$status" -eq 0 ] || { echo "want exit 0, got $status"; return 1; }
  [ -z "$output" ]
  [ "$(grep -c 'resolve-issue record NOT emitted' <<<"$stderr")" -eq 1 ]
  [ ! -e "$DEFAULT_SINK" ]
  [ ! -e "$SLUG_SINK" ]
  # a failed emit leaves the run un-emitted — the mark is written only after a
  # record lands, or a retry would be refused for a record that never existed
  if [ -e "$RUN" ] && jq -e . "$RUN" >/dev/null 2>&1; then
    [ "$(jq -r '.emitted // false' "$RUN")" = "false" ] || {
      echo "a failed emit marked the run emitted"; return 1; }
  fi
}

@test "a failed emit can be retried: exactly one record lands" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  STORY_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/no-emitter" emit
  advised
  emit
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$DEFAULT_SINK")" -eq 1 ]
  [ "$(jq -r '.emitted' "$RUN")" = "true" ]
}

@test "never fatal: the emitter absent" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  STORY_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/no-emitter" emit
  advised
}

@test "never fatal: the emitter not executable" {
  local E="$BATS_TEST_TMPDIR/emitter.zsh"
  cp "$REPO_ROOT/development/scripts/telemetry/emit-telemetry.zsh" "$E"
  chmod a-x "$E"
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  STORY_TELEMETRY_EMITTER_BIN="$E" emit
  advised
}

@test "never fatal: the emitter exits non-zero" {
  local E="$BATS_TEST_TMPDIR/failing-emitter.sh"
  printf '#!/usr/bin/env bash\necho "emit-telemetry: boom" >&2\nexit 3\n' > "$E"
  chmod +x "$E"
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  STORY_TELEMETRY_EMITTER_BIN="$E" emit
  advised
  contains "$stderr" "the emitter exited 3"
}

@test "never fatal: a --telemetry-dir naming a regular file (the emitter's exit 2)" {
  : > "$BATS_TEST_TMPDIR/a-file"
  zsh "$D" start --run-file "$RUN" --telemetry-dir "$BATS_TEST_TMPDIR/a-file" >/dev/null
  state "$SUCCESS"
  emit
  advised
  contains "$stderr" "the emitter exited 2"
  # the file named as the dir was not appended to either
  [ ! -s "$BATS_TEST_TMPDIR/a-file" ]
}

@test "never fatal: a state the builder rejects emits nothing" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state '{"outcome":"shipped","dependency_precheck":"PROCEED"}'
  emit
  advised
  contains "$stderr" "the payload builder rejected the state"
}

@test "never fatal: no run file (start never ran) emits nothing" {
  state "$SUCCESS"
  emit
  advised
  contains "$stderr" "no readable run file"
}

@test "never fatal: a run file without a well-formed run_id emits nothing" {
  printf '{"run_id":"review-loop-1-aaaa","ts":1}' > "$RUN"
  state "$SUCCESS"
  emit
  advised
}

@test "emit: usage errors are the caller's to fix (exit 2)" {
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --repo-dir "$R" --issue 412
  [ "$status" -eq 2 ]
  contains "$stderr" "--state is required"
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$ST" --repo-dir "$R" --issue '#412'
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$ST" --repo-dir "$R" --issue 412 --bogus x
  [ "$status" -eq 2 ]
}

@test "an unknown subcommand, or none, exits 2" {
  run --separate-stderr zsh "$D"
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$D" launch
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown subcommand: launch"
}

# --- args: the rest of the refusal set, --no-review, absolute paths ----------

@test "args: a repeated --telemetry-file is refused too" {
  rejects 412 --telemetry-file a --telemetry-file b
  contains "$stderr" "--telemetry-file given twice"
}

@test "args: sink flags with no issue reference are refused" {
  rejects --telemetry-dir "$TDIR"
  contains "$stderr" "no issue reference given"
  rejects --telemetry-file "$BATS_TEST_TMPDIR/f.jsonl"
  contains "$stderr" "no issue reference given"
}

@test "args: an empty issue reference is refused" {
  rejects "" 412
  contains "$stderr" "an empty issue reference"
}

@test "args: --no-review is the skill's own switch, accepted in any position" {
  run --separate-stderr zsh "$D" args --no-review 412
  [ "$status" -eq 0 ]
  [ "$(jq -r '.no_review' <<<"$output")" = "true" ]
  [ "$(jq -r '.issue_ref' <<<"$output")" = "412" ]
  run --separate-stderr zsh "$D" args 412
  [ "$(jq -r '.no_review' <<<"$output")" = "false" ]
  # the help names it, so a user can find it
  rejects 412 --bogus
  contains "$stderr" "[--no-review]"
}

@test "args and start make relative sink paths absolute against their own cwd" {
  mkdir -p "$BATS_TEST_TMPDIR/cwd"
  cd "$BATS_TEST_TMPDIR/cwd"
  # the physical spelling: on macOS the tmpdir sits behind a /var -> /private/var
  # symlink, and the script sees the resolved cwd
  local T; T="$(pwd -P)/.."
  T="$(cd "$T" && pwd -P)"
  run --separate-stderr zsh "$D" args 412 --telemetry-dir ../tel --telemetry-file rel.jsonl
  [ "$status" -eq 0 ]
  [ "$(jq -r '.telemetry_dir' <<<"$output")" = "$T/tel" ]
  [ "$(jq -r '.telemetry_file' <<<"$output")" = "$T/cwd/rel.jsonl" ]
  run --separate-stderr zsh "$D" start --run-file "$RUN" --telemetry-dir ../tel
  [ "$status" -eq 0 ]
  [ "$(jq -r '.telemetry_dir' <<<"$output")" = "$T/tel" ]
  [ "$(jq -r '.loop_args[3]' <<<"$output")" = "$T/tel" ]
}

# --- start: the rest of its exits, and the clock ------------------------------

@test "start: an unknown argument is a usage error and writes no run file" {
  run --separate-stderr zsh "$D" start --run-file "$RUN" --telemetry-dirr x
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown argument: --telemetry-dirr"
  [ ! -e "$RUN" ]
}

@test "start: an unreadable or garbage clock exits 1 and writes no run file" {
  local SB="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$SB"
  printf '#!/bin/sh\nexit 1\n' > "$SB/date"
  chmod +x "$SB/date"
  PATH="$SB:$PATH" run --separate-stderr zsh "$D" start --run-file "$RUN"
  [ "$status" -eq 1 ]
  contains "$stderr" "could not read the clock"
  [ ! -e "$RUN" ]
  printf '#!/bin/sh\necho garbage\n' > "$SB/date"
  PATH="$SB:$PATH" run --separate-stderr zsh "$D" start --run-file "$RUN"
  [ "$status" -eq 1 ]
  contains "$stderr" "could not read the clock"
  [ ! -e "$RUN" ]
}

@test "start: with no --ts the stamp is the clock at the call" {
  local before after
  before=$(date +%s)
  run --separate-stderr zsh "$D" start --run-file "$RUN"
  after=$(date +%s)
  [ "$status" -eq 0 ]
  local ts; ts="$(jq '.ts' <<<"$output")"
  [ "$ts" -ge "$before" ]
  [ "$ts" -le "$after" ]
  [ "$(jq -r '.run_id | split("-")[2]' <<<"$output")" = "$ts" ]
}

@test "start: --ts is bounded to 18 digits and normalised" {
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts 1234567890123456789
  [ "$status" -eq 2 ]
  [ ! -e "$RUN" ]
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts 007
  [ "$status" -eq 0 ]
  [ "$(jq '.ts' <<<"$output")" -eq 7 ]
  jq -e '.run_id | test("^resolve-issue-7-[0-9a-f]{4}$")' <<<"$output" >/dev/null
}

# --- emit: the clock, the clamp, the rest of its usage errors -----------------

@test "emit: with no --now, wall_s is measured against the clock" {
  zsh "$D" start --run-file "$RUN" --ts "$(( $(date +%s) - 5 ))" >/dev/null
  state "$SUCCESS"
  emit
  [ "$status" -eq 0 ]
  local w; w="$(jq '.wall_s' "$DEFAULT_SINK")"
  [ "$w" -ge 5 ]
  [ "$w" -le 65 ]
}

@test "emit: a backwards clock step clamps wall_s to 0 rather than losing the record" {
  zsh "$D" start --run-file "$RUN" --ts 1000 >/dev/null
  state "$SUCCESS"
  emit --now 900
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$DEFAULT_SINK")" -eq 1 ]
  [ "$(jq '.wall_s' "$DEFAULT_SINK")" -eq 0 ]
}

@test "emit: a non-integer --now is a usage error, not a swallowed advisory" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  emit --now abc
  [ "$status" -eq 2 ]
  contains "$stderr" "--now must be a non-negative integer"
  emit --now -5
  [ "$status" -eq 2 ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "emit: --run-file and --repo-dir are required (exit 2)" {
  state "$SUCCESS"
  run --separate-stderr zsh "$D" emit --state "$ST" --repo-dir "$R" --issue 412
  [ "$status" -eq 2 ]
  contains "$stderr" "--run-file is required"
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$ST" --issue 412
  [ "$status" -eq 2 ]
  contains "$stderr" "--repo-dir is required"
}

@test "never fatal: a run file with a well-formed run_id but no usable start stamp" {
  state "$SUCCESS"
  printf '{"run_id":"resolve-issue-5-abcd"}' > "$RUN"
  emit
  advised
  contains "$stderr" "carries no start stamp"
  printf '{"run_id":"resolve-issue-5-abcd","ts":"soon"}' > "$RUN"
  emit
  advised
  contains "$stderr" "carries no start stamp"
}

# --- emit: exactly once, the ledgers, the seams, the scratch files -----------

@test "emit: a second emit for the same run is refused — one record per run" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  emit
  [ "$status" -eq 0 ]
  [ "$(jq -r '.emitted' "$RUN")" = "true" ]
  emit
  [ "$status" -eq 0 ]
  contains "$stderr" "already emitted"
  [ "$(grep -c '' "$DEFAULT_SINK")" -eq 1 ]
}

@test "emit: a --loop-work-dir that is not a directory is warned about, and the record still lands" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  emit --loop-work-dir "$BATS_TEST_TMPDIR/typo-wd"
  [ "$status" -eq 0 ]
  contains "$stderr" "--loop-work-dir is not a directory: $BATS_TEST_TMPDIR/typo-wd"
  [ "$(jq -c '.payload.review_loop_run_ids' "$DEFAULT_SINK")" = "[]" ]
  # a real work-dir with no ledger is silent: that loop emitted nothing
  mkdir -p "$BATS_TEST_TMPDIR/quiet-wd"
  zsh "$D" start --run-file "$RUN" >/dev/null
  emit --loop-work-dir "$BATS_TEST_TMPDIR/quiet-wd"
  [ "$status" -eq 0 ]
  lacks "$stderr" "not a directory"
}

@test "emit: ids already in the state are kept, ledger ids appended, duplicates dropped" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":413,"review_loop_run_ids":["review-loop-1-aaaa"]}'
  mkdir -p "$BATS_TEST_TMPDIR/wd"
  printf 'review-loop-1-aaaa\nreview-loop-2-bbbb\n' > "$BATS_TEST_TMPDIR/wd/.telemetry-run-ids"
  emit --loop-work-dir "$BATS_TEST_TMPDIR/wd"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.payload.review_loop_run_ids' "$DEFAULT_SINK")" = '["review-loop-1-aaaa","review-loop-2-bbbb"]' ]
}

@test "never fatal: a builder that is missing, or cannot narrow the outcome" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  STORY_TELEMETRY_BUILDER_BIN="$BATS_TEST_TMPDIR/no-builder" emit
  advised
  contains "$stderr" "payload builder missing or not executable"
  local SBLD="$BATS_TEST_TMPDIR/half-builder.sh"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = --print-outcome ] && exit 1; done\necho "{}"\n' > "$SBLD"
  chmod +x "$SBLD"
  STORY_TELEMETRY_BUILDER_BIN="$SBLD" emit
  advised
  contains "$stderr" "could not narrow the outcome"
}

@test "emit leaves no scratch file behind, on success or on an advisory" {
  # The scratch files must be OBSERVABLE for this to test anything: BSD mktemp
  # (macOS) ignores TMPDIR when it is given no template, so scoping TMPDIR
  # leaves the files in the per-user temp dir and every assertion here passes
  # vacuously. Override mktemp itself instead, so the script's own calls land
  # in a directory this test owns.
  local TD="$BATS_TEST_TMPDIR/tmp" SB="$BATS_TEST_TMPDIR/mktemp-stub"
  mkdir -p "$TD" "$SB"
  printf '#!/bin/sh\nexec /usr/bin/mktemp "%s/scratch.XXXXXX"\n' "$TD" > "$SB/mktemp"
  chmod +x "$SB/mktemp"
  # the override is real: a plain mktemp under this PATH lands in $TD
  run env PATH="$SB:$PATH" mktemp
  [ "$status" -eq 0 ]
  case "$output" in "$TD"/scratch.*) ;; *) echo "stub not in effect: $output"; return 1 ;; esac
  rm -f "$TD"/scratch.*

  emit() {  # the suite's helper, with the stubbed mktemp on the child's PATH
    run --separate-stderr env PATH="$SB:$PATH" zsh "$D" emit --run-file "$RUN" \
      --state "$ST" --repo-dir "$R" --issue 412 "$@"
  }
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  emit
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TD")" ]
  # The advisory arm must be one raised AFTER the two mktemp calls, or the
  # sweep is vacuous: a missing emitter is refused before any scratch file
  # exists, so it would hold however _advise behaved. A failing emitter and a
  # non-object state both advise past that point.
  local E="$BATS_TEST_TMPDIR/failing-emitter-scratch.sh"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$E"
  chmod +x "$E"
  zsh "$D" start --run-file "$RUN" >/dev/null
  STORY_TELEMETRY_EMITTER_BIN="$E" emit
  [ "$status" -eq 0 ]
  contains "$stderr" "the emitter exited 3"
  [ -z "$(ls -A "$TD")" ]
  zsh "$D" start --run-file "$RUN" >/dev/null
  state 'not json'
  emit
  [ "$status" -eq 0 ]
  contains "$stderr" "NOT emitted"
  [ -z "$(ls -A "$TD")" ]
}

# --- the reference's commands match the script --------------------------------

@test "every flag reference/telemetry.md passes to story-telemetry.zsh is one the script accepts" {
  # The skill runs these blocks verbatim; they are the only place its flags meet
  # the parser, so a misspelt flag there would exit 2 (or, if dropped, silently
  # lose the promotion ids) on every real run with this suite still green.
  local ref="$REPO_ROOT/development/skills/resolve-issue/reference/telemetry.md"
  local sub flags f
  for sub in start emit; do
    flags="$(awk -v s="story-telemetry.zsh\" $sub" '
      index($0, s) { on = 1 }
      on { print }
      on && !/\\$/ { on = 0 }' "$ref" | grep -oE -- '--[a-z-]+' | sort -u)"
    [ -n "$flags" ] || { echo "no $sub block found in telemetry.md"; return 1; }
    while IFS= read -r f; do
      grep -qE -- "^ +${f}\) " "$D" || { echo "telemetry.md passes $f to $sub; the script has no such flag"; return 1; }
    done <<<"$flags"
  done
  # emit's documented set, both ways: nothing the reference needs is missing
  for f in --run-file --state --repo-dir --issue --repo-type --loop-work-dir; do
    grep -qF -- "$f" <<<"$(awk '/story-telemetry.zsh" emit/{on=1} on{print} on && !/\\$/{on=0}' "$ref")" \
      || { echo "telemetry.md's emit block no longer passes $f"; return 1; }
  done
  # the loop_args key the reference reads is the one start writes
  grep -qF "jq -r '.loop_args[]'" "$ref"
  run zsh "$D" start --run-file "$RUN" --ts 1
  jq -e '.loop_args | type == "array"' <<<"$output" >/dev/null
}

# --- round-1 gaps: tilde, reuse, flag-shaped values, bounds, messages -------

@test "args and start expand a leading ~ — slash-command arguments arrive unexpanded" {
  local H="$BATS_TEST_TMPDIR/home"
  mkdir -p "$H" "$BATS_TEST_TMPDIR/cwd"
  cd "$BATS_TEST_TMPDIR/cwd"
  HOME="$H" run --separate-stderr zsh "$D" args 412 --telemetry-dir '~/telemetry' --telemetry-file '~'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.telemetry_dir' <<<"$output")" = "$H/telemetry" ]
  [ "$(jq -r '.telemetry_file' <<<"$output")" = "$H" ]
  HOME="$H" run --separate-stderr zsh "$D" start --run-file "$RUN" --telemetry-dir '~/telemetry'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.telemetry_dir' <<<"$output")" = "$H/telemetry" ]
  # and no directory literally named ~ appeared under the cwd
  [ ! -e "$BATS_TEST_TMPDIR/cwd/~" ]
}

@test "start always mints a fresh run, whatever an earlier run left in the file" {
  # start cannot tell a fresh invocation from a re-entry, so it never guesses:
  # every call is a new run with THIS call's stamp and sinks (the skill calls
  # it once per invocation and re-reads the file on re-entry)
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts 100
  local first; first="$(jq -r '.run_id' <<<"$output")"
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts 200 --telemetry-dir "$TDIR"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.run_id' <<<"$output")" != "$first" ]
  [ "$(jq '.ts' <<<"$output")" -eq 200 ]
  [ "$(jq -r '.telemetry_dir' <<<"$output")" = "$TDIR" ]
  [ "$(jq -r '.run_id' "$RUN")" = "$(jq -r '.run_id' <<<"$output")" ]
  # a malformed or non-JSON leftover is overwritten the same way
  printf '{"run_id":"review-loop-1-aaaa","ts":1}' > "$RUN"
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts 50
  [ "$status" -eq 0 ]
  jq -e '.run_id | test("^resolve-issue-50-[0-9a-f]{4}$")' "$RUN" >/dev/null
  printf 'not json' > "$RUN"
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts 60
  [ "$status" -eq 0 ]
  jq -e '.run_id | test("^resolve-issue-60-[0-9a-f]{4}$")' "$RUN" >/dev/null
}

@test "emit forwards an integer-valued float pr as an integer, not a lost record" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":413.0}'
  emit
  [ "$status" -eq 0 ]
  [ "$(jq '.pr' "$DEFAULT_SINK")" -eq 413 ]
}

@test "args: a flag-shaped sink value is refused by the flag-shape check itself" {
  rejects 412 --telemetry-dir --no-review
  contains "$stderr" "--telemetry-dir requires a non-empty value"
  rejects 412 --telemetry-file --telemetry-dir x
  contains "$stderr" "--telemetry-file requires a non-empty value"
}

@test "start and emit: a flag-shaped value is a usage error" {
  run --separate-stderr zsh "$D" start --run-file "$RUN" --telemetry-file --telemetry-dir
  [ "$status" -eq 2 ]
  contains "$stderr" "requires a non-empty value"
  [ ! -e "$RUN" ]
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  emit --repo-type --now
  [ "$status" -eq 2 ]
  contains "$stderr" "requires a non-empty value"
  [ ! -e "$DEFAULT_SINK" ]
}

@test "emit: a failing or garbage clock with no --now is one advisory, not a math error" {
  local SB="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$SB"
  zsh "$D" start --run-file "$RUN" --ts 1 >/dev/null
  state "$SUCCESS"
  printf '#!/bin/sh\nexit 1\n' > "$SB/date"
  chmod +x "$SB/date"
  PATH="$SB:$PATH" emit
  advised
  contains "$stderr" "could not read the clock for wall_s"
  printf '#!/bin/sh\necho garbage\n' > "$SB/date"
  PATH="$SB:$PATH" emit
  advised
  contains "$stderr" "could not read the clock for wall_s"
}

@test "emit: --now and --issue are bounded to 18 digits (exit 2)" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  emit --now 1234567890123456789
  [ "$status" -eq 2 ]
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$ST" --repo-dir "$R" --issue 1234567890123456789
  [ "$status" -eq 2 ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "emit: each advisory names its own cause" {
  zsh "$D" start --run-file "$RUN" >/dev/null
  # a state file that does not exist
  run --separate-stderr zsh "$D" emit --run-file "$RUN" --state "$BATS_TEST_TMPDIR/absent.json" \
    --repo-dir "$R" --issue 412
  advised
  contains "$stderr" "no readable state file"
  # a state that is not a JSON object
  state 'not json'
  emit
  advised
  contains "$stderr" "the state file is not a JSON object"
  # a run file whose run_id is malformed
  printf '{"run_id":"review-loop-1-aaaa","ts":1}' > "$RUN"
  state "$SUCCESS"
  emit
  advised
  contains "$stderr" "no well-formed run_id"
}

@test "never fatal: no jq on PATH is one advisory" {
  local SB="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$SB"
  local t
  # a PATH with the shell's basics but no jq
  for t in zsh date mktemp rm cat; do ln -s "$(command -v "$t")" "$SB/$t"; done
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  # the restricted PATH is the CHILD's only: bats' own `run` needs its tools
  run --separate-stderr env PATH="$SB" "$SB/zsh" "$D" emit --run-file "$RUN" --state "$ST" --repo-dir "$R" --issue 412
  [ "$status" -eq 0 ]
  contains "$stderr" "jq not found on PATH"
  [ ! -e "$DEFAULT_SINK" ]
}

@test "--help prints the usage and exits 0" {
  run zsh "$D" --help
  [ "$status" -eq 0 ]
  contains "$output" "story-telemetry.zsh emit"
}

@test "the loop_args notes stand in every file that invokes the loop" {
  # A missed invocation loses parentage silently (the emitter exits 0), so the
  # instruction must stay present wherever an invocation template lives.
  local base="$REPO_ROOT/development/skills/resolve-issue"
  grep -qF "Every loop invocation carries the run's \`loop_args\` (#1226)" "$base/reference/review-loop.md"
  grep -qF "A granted resume carries the run's \`loop_args\` too (#1226)" "$base/reference/interactive.md"
  grep -qF "Every sub-loop invocation also carries the run's \`loop_args\`" "$base/reference/promotion.md"
  grep -qF "the run's \`loop_args\` (Step 0) on every invocation" "$base/SKILL.md"
}

# --- round-1 fix pass: the internal exits, ~user --------------------------------

# a PATH holding the shell and its basics but no jq — the CHILD's only, since
# bats' own `run` needs its tools. $1 = the directory to build it in.
_nojq_path() {
  mkdir -p "$1"
  local t
  for t in zsh date mktemp rm cat od tr; do
    ln -sf "$(command -v "$t")" "$1/$t"
  done
}

@test "args: jq missing is an internal failure (exit 1), not a usage error" {
  local SB="$BATS_TEST_TMPDIR/nojq-args"
  _nojq_path "$SB"
  run --separate-stderr env PATH="$SB" "$SB/zsh" "$D" args 412
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "failed to print the parsed arguments"
}

@test "start: jq missing is an internal failure (exit 1) and writes no run file" {
  local SB="$BATS_TEST_TMPDIR/nojq-start"
  _nojq_path "$SB"
  run --separate-stderr env PATH="$SB" "$SB/zsh" "$D" start --run-file "$RUN" --ts 1
  [ "$status" -eq 1 ]
  contains "$stderr" "failed to build the run file"
  [ ! -e "$RUN" ]
}

@test "a ~user spelling is left as written, not expanded" {
  local H="$BATS_TEST_TMPDIR/home"
  mkdir -p "$H" "$BATS_TEST_TMPDIR/cwd"
  cd "$BATS_TEST_TMPDIR/cwd"
  HOME="$H" run --separate-stderr zsh "$D" args 412 --telemetry-dir '~bob/t'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.telemetry_dir' <<<"$output")" = "$(pwd -P)/~bob/t" ]
}

# --- closing-sweep fixes ------------------------------------------------------

@test "emit: a literal \"null\" --repo-type is dropped, not stamped on the record" {
  # the conductor reads repo_type out of JSON; `jq -r` of an absent one prints
  # the string "null", which must never become repo_type: "null"
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  emit --repo-type null
  [ "$status" -eq 0 ]
  [ "$(jq -r '.repo_type | type' "$DEFAULT_SINK")" = "null" ]
  # a real repo type still rides along
  zsh "$D" start --run-file "$RUN" >/dev/null
  emit --repo-type claude-plugin
  [ "$status" -eq 0 ]
  [ "$(jq -r 'select(.repo_type == "claude-plugin") | .repo_type' "$DEFAULT_SINK" | head -1)" = "claude-plugin" ]
}

@test "emit: a ledger that cannot be read names its own cause" {
  # a directory at the ledger path passes the -r guard and makes jq fail; the
  # advisory must name the ledger, not blame the (perfectly good) state file
  zsh "$D" start --run-file "$RUN" >/dev/null
  state "$SUCCESS"
  mkdir -p "$BATS_TEST_TMPDIR/wd-bad/.telemetry-run-ids"
  emit --loop-work-dir "$BATS_TEST_TMPDIR/wd-bad"
  advised
  contains "$stderr" "could not read the loop run-id ledger"
}

@test "start: the run_id keeps its 4-hex suffix when /dev/urandom cannot be read" {
  # the fallback arm of _rand4. A short suffix would pass start and then be
  # refused by emit's own format check, costing the record while the loops
  # already carry that id as their parent.
  local SB="$BATS_TEST_TMPDIR/no-od"
  mkdir -p "$SB"
  local t
  for t in zsh jq date; do ln -sf "$(command -v "$t")" "$SB/$t"; done
  # PATH is the CHILD's only: with no `od` on it, _rand4 takes its fallback
  run --separate-stderr env PATH="$SB" "$SB/zsh" "$D" start --run-file "$RUN" --ts 1
  [ "$status" -eq 0 ]
  jq -e '.run_id | test("^resolve-issue-1-[0-9a-f]{4}$")' <<<"$output" >/dev/null
}

@test "start: a literal \"null\" sink value is dropped, never made into a path" {
  # args prints null for an absent sink, and a conductor may substitute it; a
  # literal null would become <cwd>/null — a sink inside the repo — for the run
  # and every loop parented to it
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr zsh "$D" start --run-file "$RUN" --ts 1 --telemetry-file null --telemetry-dir null
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.telemetry_file, .telemetry_dir]' <<<"$output")" = "[null,null]" ]
  [ "$(jq -c '.loop_args | length' <<<"$output")" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/null" ]
}
