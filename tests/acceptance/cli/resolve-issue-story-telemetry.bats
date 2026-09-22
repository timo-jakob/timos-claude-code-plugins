#!/usr/bin/env bats
#
# Acceptance cases for "telemetry for story-mode runs + the per-pipeline
# instrumentation conventions" (#1226) — the `cli`-tooled test_cases[] of its
# story-spec, one test per `tc-*` id:
#
#   tc-happy-dir-sink-success                 #1720
#   tc-happy-default-sink-parked-gate         #1721
#   tc-happy-precheck-reject                  #1722
#   tc-corner-promotion-and-resume-parented   #1723
#   tc-corner-file-beats-dir                  #1724
#   tc-corner-in-repo-dir-not-a-finding       #1725
#   tc-corner-closed-issue-no-record          #1726
#   tc-corner-premint-matches-ts              #1727
#   tc-error-dir-is-a-file                    #1728
#   tc-error-emitter-absent                   #1729
#   tc-error-flag-without-value               #1730
#   tc-error-loop-parent-run-id-empty         #1731
#   tc-error-builder-malformed-input          #1732
#
# The use case: timo-platform-builder resolves story #412 in the private
# timos-platform/tenant-service repo with `--telemetry-dir ~/telemetry`, and
# expects the run's outcome and its review-loop churn to land, linked, in
# ~/telemetry/timos-platform-tenant-service.jsonl — the file his reporting stack
# globs.
#
# A resolve-issue run is model-driven, so these cases drive exactly the
# deterministic steps the skill calls, in the order its reference/telemetry.md
# prescribes: `story-telemetry.zsh args` on $ARGUMENTS, `start` once the target
# is classified as a single issue (every case here is one), the review loop
# (hook mode, with the run's `loop_args` appended), then `emit` at the run's
# ending. Detection is stubbed and nothing reaches GitHub, so these
# run offline. The default gate's tests/story-telemetry.bats,
# tests/build-story-telemetry-record.bats and the #1226 block of
# tests/resolve-story-loop.bats cover the same criteria.

bats_require_minimum_version 1.5.0
load ../../assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/resolve-issue/scripts"
  DRIVER="$SCRIPTS/story-telemetry.zsh"
  LOOP="$SCRIPTS/resolve-story-loop.zsh"
  BUILDER="$SCRIPTS/build-story-telemetry-record.zsh"
  VALIDATE="$REPO_ROOT/development/scripts/telemetry/validate-telemetry.zsh"

  DETECT="$BATS_TEST_TMPDIR/detect.sh"
  printf '#!/usr/bin/env bash\necho "{\\"languages\\":[\\"python\\"]}"\n' > "$DETECT"
  chmod +x "$DETECT"

  # the persona's product repo, with the story's diff already on the branch
  R="$BATS_TEST_TMPDIR/tenant-service"
  mkdir -p "$R"
  git -C "$R" init -q
  git -C "$R" config user.email platform@timos.example
  git -C "$R" config user.name "Timo Platform"
  git -C "$R" remote add origin git@github.com:timos-platform/tenant-service.git
  printf '# tenant-service\n' > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -qm "initial tenant-service"
  git -C "$R" branch -M main
  printf 'def provision_tenant(slug):\n    return {"slug": slug, "plan": "growth"}\n' > "$R/tenants.py"

  TEL="$BATS_TEST_TMPDIR/home/telemetry"          # ~/telemetry
  DIR_SINK="$TEL/timos-platform-tenant-service.jsonl"
  DEFAULT_SINK="$R/.claude/telemetry/telemetry.jsonl"
  SCRATCH="$BATS_TEST_TMPDIR/scratch"             # the session scratchpad
  mkdir -p "$SCRATCH"
  RUN="$SCRATCH/story-run-412.json"               # keyed by the issue, as documented
  STATE="$SCRATCH/story-state-412.json"
  WD="$SCRATCH/loop-wd"
  PWD_="$SCRATCH/promotion-wd"
}

CLEAN_PANEL='printf "[]" > "$REVIEW_FINDINGS"'
# A resumed round carries the previous round's blocker to verify, and since
# #1583 its panel must account for every carried entry — here: confirmed fixed.
RESUME_PANEL='if [ -n "${REVIEW_FIX_VERIFICATION:-}" ] && [ -s "$REVIEW_FIX_VERIFICATION" ]; then jq "[.[] | {file, dimension, title, confirmed: [\"bugs\"], re_raised: [], unconfirmed: []}]" "$REVIEW_FIX_VERIFICATION" > "$REVIEW_FINDINGS.carry.json"; fi; printf "[]" > "$REVIEW_FINDINGS"'
BLOCKER_PANEL='printf "%s" "[{\"severity\":\"CRITICAL\",\"dimension\":\"bugs\",\"file\":\"tenants.py\",\"line\":2,\"title\":\"plan is hard-coded to growth\",\"description\":\"new tenants must start on the trial plan\",\"reviewer\":\"bugs\"}]" > "$REVIEW_FINDINGS"'

# Step 0 then the single-issue start: parse $ARGUMENTS, then stamp + pre-mint.
# $@ = the skill's arguments.
step0() {
  run --separate-stderr zsh "$DRIVER" args "$@"
  [ "$status" -eq 0 ] || return 1
  local parsed="$output"
  local -a start_args=(start --run-file "$RUN")
  local f d
  f="$(jq -r '.telemetry_file // empty' <<<"$parsed")"
  d="$(jq -r '.telemetry_dir // empty' <<<"$parsed")"
  [ -n "$f" ] && start_args+=(--telemetry-file "$f")
  [ -n "$d" ] && start_args+=(--telemetry-dir "$d")
  zsh "$DRIVER" "${start_args[@]}" >/dev/null
}

# one review-loop invocation carrying the run's loop_args; $1 = work-dir, rest
# = loop flags
review_loop() {
  local wd="$1"; shift
  local -a la=()
  while IFS= read -r a; do la+=("$a"); done < <(jq -r '.loop_args[]' "$RUN")
  run --separate-stderr env DETECT_STACK_BIN="$DETECT" \
    zsh "$LOOP" --repo "$R" --base main --work-dir "$wd" --issue 412 "${la[@]}" "$@"
}

# the run's ending; $1 = state JSON, rest = extra emit flags
ending() {
  printf '%s' "$1" > "$STATE"
  shift
  run --separate-stderr zsh "$DRIVER" emit --run-file "$RUN" --state "$STATE" \
    --repo-dir "$R" --issue 412 --repo-type python "$@"
}

run_id() { jq -r '.run_id' "$RUN"; }

@test "tc-happy-dir-sink-success: --telemetry-dir lands the story record and its loop records, linked, in DIR/<slug>.jsonl" {
  step0 412 --telemetry-dir "$TEL"
  review_loop "$WD" --review-cmd "$CLEAN_PANEL" --fix-cmd true
  [ "$status" -eq 0 ]
  ending '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","risk":"elevated","pr":413,"story_spec_present":true}' \
    --loop-work-dir "$WD"
  [ "$status" -eq 0 ]
  local story
  story="$(jq -c 'select(.pipeline == "resolve-issue")' "$DIR_SINK")"
  [ "$(grep -c '' <<<"$story")" -eq 1 ]
  [ "$(jq -r '.outcome' <<<"$story")" = "success" ]
  [ "$(jq '.pr' <<<"$story")" -eq 413 ]
  [ "$(jq '.wall_s >= 0 and (.wall_s | floor) == .wall_s' <<<"$story")" = "true" ]
  # every review-loop record points back at the story run
  [ "$(jq -s --arg id "$(run_id)" '[.[] | select(.pipeline == "review-loop" and .parent_run_id == $id)] | length' "$DIR_SINK")" -ge 1 ]
  [ "$(jq -s --arg id "$(run_id)" '[.[] | select(.pipeline == "review-loop" and .parent_run_id != $id)] | length' "$DIR_SINK")" -eq 0 ]
  # and the story lists each of them
  [ "$(jq -sc '[.[] | select(.pipeline == "review-loop") | .run_id]' "$DIR_SINK")" \
    = "$(jq -c '.payload.review_loop_run_ids' <<<"$story")" ]
  [ ! -e "$DEFAULT_SINK" ]
  zsh "$VALIDATE" "$DIR_SINK" --require-records
}

@test "tc-happy-default-sink-parked-gate: no sink flags, NEEDS_REFINEMENT -> one parked record in the local default" {
  step0 412
  ending '{"outcome":"gate-parked","dependency_precheck":"PROCEED","gate_verdict":"NEEDS_REFINEMENT","risk":"normal"}'
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$DEFAULT_SINK")" -eq 1 ]
  [ "$(jq -r '.outcome' "$DEFAULT_SINK")" = "parked" ]
  [ "$(jq -r '.payload.gate_verdict' "$DEFAULT_SINK")" = "NEEDS_REFINEMENT" ]
  [ "$(jq -r '.pr' "$DEFAULT_SINK")" = "null" ]
  zsh "$VALIDATE" "$DEFAULT_SINK" --require-records
}

@test "tc-happy-precheck-reject: an OPEN blocker -> parked, REJECT_BLOCKED, gate null, no review-loop record" {
  step0 412
  ending '{"outcome":"precheck-parked","dependency_precheck":"REJECT_BLOCKED"}' --loop-work-dir "$WD"
  [ "$status" -eq 0 ]
  [ "$(grep -c '' "$DEFAULT_SINK")" -eq 1 ]
  [ "$(jq -r '.outcome' "$DEFAULT_SINK")" = "parked" ]
  [ "$(jq -r '.payload.dependency_precheck' "$DEFAULT_SINK")" = "REJECT_BLOCKED" ]
  [ "$(jq -r '.payload.gate_verdict' "$DEFAULT_SINK")" = "null" ]
  [ "$(jq -c '.payload.review_loop_run_ids' "$DEFAULT_SINK")" = "[]" ]
  [ "$(jq -s '[.[] | select(.pipeline == "review-loop")] | length' "$DEFAULT_SINK")" -eq 0 ]
}

@test "tc-corner-promotion-and-resume-parented: escalate, grant, resume, promote — every loop record parented and listed" {
  step0 412 --telemetry-dir "$TEL"
  # blocking phase: escalates on budget
  review_loop "$WD" --max-rounds 1 --review-cmd "$BLOCKER_PANEL" --fix-cmd true
  [ "$status" -eq 13 ]
  # the human grants more rounds; the fix lands; the resumed loop converges
  printf 'def provision_tenant(slug):\n    return {"slug": slug, "plan": "trial"}\n' > "$R/tenants.py"
  review_loop "$WD" --resume --max-rounds 3 --review-cmd "$RESUME_PANEL" --fix-cmd true
  [ "$status" -eq 0 ]
  # promotion sub-loop, fresh work-dir, same loop_args
  printf '[{"file":"tenants.py","line":2,"dimension":"code_quality","title":"name the trial plan constant"}]' > "$SCRATCH/promoted.json"
  review_loop "$PWD_" --promote "$SCRATCH/promoted.json" --review-cmd "$CLEAN_PANEL" --fix-cmd true
  [ "$status" -eq 0 ]
  ending '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","risk":"normal","pr":413}' \
    --loop-work-dir "$WD" --loop-work-dir "$PWD_"
  [ "$status" -eq 0 ]
  local loops
  loops="$(jq -sc '[.[] | select(.pipeline == "review-loop")]' "$DIR_SINK")"
  [ "$(jq 'length' <<<"$loops")" -eq 3 ]
  [ "$(jq --arg id "$(run_id)" '[.[] | select(.parent_run_id == $id)] | length' <<<"$loops")" -eq 3 ]
  [ "$(jq '[.[] | select(.payload.promotion_phase == true)] | length' <<<"$loops")" -eq 1 ]
  [ "$(jq -c '[.[].run_id]' <<<"$loops")" \
    = "$(jq -c 'select(.pipeline == "resolve-issue") | .payload.review_loop_run_ids' "$DIR_SINK")" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "tc-corner-file-beats-dir: flags on both sides of the issue ref -> every record in PATH" {
  local F="$BATS_TEST_TMPDIR/home/tenant-412.jsonl"
  step0 --telemetry-dir "$TEL" 412 --telemetry-file "$F"
  review_loop "$WD" --review-cmd "$CLEAN_PANEL" --fix-cmd true
  [ "$status" -eq 0 ]
  ending '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":413}' --loop-work-dir "$WD"
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.pipeline == "resolve-issue")] | length' "$F")" -eq 1 ]
  [ "$(jq -s '[.[] | select(.pipeline == "review-loop")] | length' "$F")" -ge 1 ]
  [ ! -e "$TEL" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "tc-corner-in-repo-dir-not-a-finding: an in-repo --telemetry-dir sink never reaches the scoped findings" {
  local TD="$R/tmp-telemetry"
  export SNAP="$BATS_TEST_TMPDIR/scopes"
  mkdir -p "$SNAP"
  step0 412 --telemetry-dir "$TD"
  review_loop "$WD" --max-rounds 1 \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/r$REVIEW_ROUND"; '"$BLOCKER_PANEL" --fix-cmd true
  [ "$status" -eq 13 ]
  [ -s "$TD/timos-platform-tenant-service.jsonl" ]
  printf 'def provision_tenant(slug):\n    return {"slug": slug, "plan": "trial"}\n' > "$R/tenants.py"
  review_loop "$WD" --resume --max-rounds 3 \
    --review-cmd 'cp "$REVIEW_SCOPE_FILE" "$SNAP/r$REVIEW_ROUND"; '"$RESUME_PANEL" --fix-cmd true
  [ "$status" -eq 0 ]
  [ -e "$SNAP/r2" ]
  run ! grep -qF 'tmp-telemetry/' "$SNAP"/r*
}

@test "tc-corner-closed-issue-no-record: a CLOSED #412 stops in Step 0 — nothing in DIR or the local default" {
  # Step 0 parses $ARGUMENTS, then classifies; a non-OPEN issue stops there,
  # before `start` (which runs only once the target is a single issue) — so the
  # only telemetry step a closed issue reaches is `args`, which writes nothing.
  run --separate-stderr zsh "$DRIVER" args 412 --telemetry-dir "$TEL"
  [ "$status" -eq 0 ]
  # the documented order the skill follows: start is placed after classification
  grep -qF 'Immediately after Step 0 classifies the target as a **single issue**' \
    "$REPO_ROOT/development/skills/resolve-issue/reference/telemetry.md"
  # joined first: a multi-line `grep -F` pattern is an OR of its lines, so it
  # would pass on either half alone
  tr '\n' ' ' < "$REPO_ROOT/development/skills/resolve-issue/reference/telemetry.md" \
    | grep -qF 'an issue that is not `OPEN`'
  [ ! -e "$RUN" ]
  [ ! -e "$TEL" ]
  [ ! -e "$DEFAULT_SINK" ]
  # and an `emit` reached by mistake without a `start` still writes nothing
  ending '{"outcome":"failed","dependency_precheck":null}'
  [ "$status" -eq 0 ]
  [ ! -e "$TEL" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "tc-corner-premint-matches-ts: the record's run_id is the --parent-run-id the loop got, in the emitter's format" {
  step0 412 --telemetry-dir "$TEL"
  review_loop "$WD" --review-cmd "$CLEAN_PANEL" --fix-cmd true
  [ "$status" -eq 0 ]
  ending '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":413}' --loop-work-dir "$WD"
  [ "$status" -eq 0 ]
  local story loopr
  story="$(jq -c 'select(.pipeline == "resolve-issue")' "$DIR_SINK")"
  loopr="$(jq -c 'select(.pipeline == "review-loop")' "$DIR_SINK" | head -1)"
  [ "$(jq -r '.run_id' <<<"$story")" = "$(jq -r '.parent_run_id' <<<"$loopr")" ]
  jq -e '.run_id | test("^resolve-issue-[0-9]+-[0-9a-f]{4}$")' <<<"$story" >/dev/null
  [ "$(jq -r '.run_id | split("-")[2]' <<<"$story")" = "$(jq -r '.ts' <<<"$story")" ]
}

@test "tc-error-dir-is-a-file: --telemetry-dir naming a file -> normal result, one advisory, no record anywhere" {
  mkdir -p "$BATS_TEST_TMPDIR/home"
  : > "$BATS_TEST_TMPDIR/home/telemetry"          # ~/telemetry is a FILE
  step0 412 --telemetry-dir "$BATS_TEST_TMPDIR/home/telemetry"
  review_loop "$WD" --review-cmd "$CLEAN_PANEL" --fix-cmd true
  [ "$status" -eq 0 ]
  [ "$(jq -r '.status' <<<"$output")" = "CONVERGED" ]
  ending '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":413}' --loop-work-dir "$WD"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'resolve-issue record NOT emitted' <<<"$stderr")" -eq 1 ]
  [ ! -s "$BATS_TEST_TMPDIR/home/telemetry" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "tc-error-emitter-absent: no emitter -> normal result, no partial line in any sink" {
  step0 412 --telemetry-dir "$TEL"
  STORY_TELEMETRY_EMITTER_BIN="$BATS_TEST_TMPDIR/no-such-emitter" \
    ending '{"outcome":"pr-opened","dependency_precheck":"PROCEED","gate_verdict":"READY","pr":413}'
  [ "$status" -eq 0 ]
  contains "$stderr" "emitter missing or not executable"
  [ ! -e "$TEL" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "tc-error-flag-without-value: a dangling flag, a typo'd flag, or two issue refs -> help, stop, no record" {
  local bad
  # each string is one $ARGUMENTS, word-split as the skill splits it
  for bad in "412 --telemetry-dir" "412 --telemetry-dirr $TEL" "412 413"; do
    # shellcheck disable=SC2086
    run --separate-stderr zsh "$DRIVER" args $bad
    [ "$status" -eq 2 ] || { echo "accepted: $bad"; return 1; }
    contains "$stderr" "usage: /development:resolve-issue <issue-number|url>"
  done
  [ ! -e "$RUN" ]
  [ ! -e "$TEL" ]
  [ ! -e "$DEFAULT_SINK" ]
}

@test "tc-error-loop-parent-run-id-empty: --parent-run-id '' or with no value -> exit 2, nothing emitted" {
  run --separate-stderr env DETECT_STACK_BIN="$DETECT" zsh "$LOOP" --repo "$R" --base main \
    --work-dir "$WD" --review-cmd "$CLEAN_PANEL" --fix-cmd true --parent-run-id ''
  [ "$status" -eq 2 ]
  run --separate-stderr env DETECT_STACK_BIN="$DETECT" zsh "$LOOP" --repo "$R" --base main \
    --work-dir "$WD" --review-cmd "$CLEAN_PANEL" --fix-cmd true --parent-run-id
  [ "$status" -eq 2 ]
  [ ! -e "$DEFAULT_SINK" ]
  [ ! -e "$WD/.telemetry-run-ids" ]
}

@test "tc-error-builder-malformed-input: invalid JSON or an unknown outcome -> non-zero, empty stdout" {
  printf 'not json {' > "$STATE"
  run --separate-stderr zsh "$BUILDER" --state "$STATE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  printf '{"outcome":"merged","dependency_precheck":"PROCEED"}' > "$STATE"
  run --separate-stderr zsh "$BUILDER" --state "$STATE"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
